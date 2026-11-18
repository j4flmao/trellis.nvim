--- The safety pipeline for every ref-moving operation (plan.md → Safety pipeline, FR-060/061).
---
---   snapshot refs + HEAD → (stash create) → backup refs → journal "running" → git commands
---   → snapshot "after" → journal "done" | "stopped" (conflict) | "failed"
---
--- Undo, redo and restore are operations too (journaled, with backups), so they can be undone.
--- Restoring a state never moves the checked-out branch with update-ref: HEAD is switched first
--- when needed, other refs move in one verified transaction, and the checked-out branch moves
--- with `reset --keep` (or the original soft/mixed mode), which refuses to lose local changes.
--- A dirty worktree is never touched without asking (an offered `git stash push`).
local argv = require("trellis.git.argv")
local async = require("trellis.util.async")
local backup = require("trellis.safety.backup")
local events = require("trellis.events")
local journal = require("trellis.safety.journal")
local preflight = require("trellis.safety.preflight")

local M = {}

local REGULAR_EXCLUDED = { undo = true, redo = true, restore = true }

local function emit(name, data)
  pcall(events.emit, name, data)
end

---@class trellis.OpSpec
---@field kind string
---@field title string
---@field refs string[]                 refs that may move (HEAD is always recorded)
---@field commands trellis.GitInvocation[]
---@field stash? boolean                save uncommitted changes first (they will be discarded)
---@field reset_mode? string
---@field files? table                  restore_file: { [path] = { before = blob|false, after = blob? } }
---@field target? string                undo/redo/restore: the operation acted on
---@field may_stop? boolean             a conflict stops the operation instead of failing it
---@field run? fun(op: table): string?  extra steps after the commands (inside async)

--- Record the "after" state and final status.
function M.finish(repo, op, status)
  op.after, op.after_head = backup.read_refs(repo, op.refs)
  op.status = status
  op.finished_at = os.time()
  journal.append(repo, op)
  emit(
    "TrellisOperationFinished",
    { id = op.id, kind = op.kind, status = op.status, before = op.before, after = op.after }
  )
  return op
end

local function same_state(a, ah, b, bh)
  for k, v in pairs(a) do
    if b[k] ~= v then
      return false
    end
  end
  for k, v in pairs(b) do
    if a[k] ~= v then
      return false
    end
  end
  return ah.sha == bh.sha and ah.symbolic == bh.symbolic
end

--- Run an operation through the pipeline. Must be called inside async.run.
---@param repo trellis.Repository
---@param spec trellis.OpSpec
---@return table? op, string? err
function M.run(repo, spec)
  local op = {
    id = journal.new_id(),
    kind = spec.kind,
    title = spec.title,
    refs = spec.refs,
    argv = {},
    target = spec.target,
    reset_mode = spec.reset_mode,
    files = spec.files,
    env = spec.env,
    plan_id = spec.plan_id,
    status = "running",
    started_at = os.time(),
  }
  op.before, op.before_head = backup.read_refs(repo, spec.refs)
  if spec.stash then
    local sha, err = backup.stash_create(repo)
    if err then
      return nil, "could not save uncommitted changes: " .. err
    end
    op.stash = sha
  end
  local berr = backup.write(repo, op)
  if berr then
    return nil, "could not write backup refs: " .. berr
  end
  local ok, jerr = journal.append(repo, op)
  if not ok then
    return nil, "could not write the journal: " .. tostring(jerr)
  end
  emit("TrellisOperationStarted", { id = op.id, kind = op.kind, title = op.title })

  for _, inv in ipairs(spec.commands) do
    op.argv[#op.argv + 1] = inv.args
    local err = backup.git(repo, inv, { op_id = op.id, env = spec.env })
    local st = require("trellis.git.repo").refresh_state(repo)
    if not err and spec.may_stop and st.kind ~= "clean" then
      -- Paused without an error: an `edit` or `break` stop in a rebase.
      M.finish(repo, op, "stopped")
      return op
    end
    if err then
      if spec.may_stop and st.kind ~= "clean" then
        M.finish(repo, op, "stopped")
        emit("TrellisConflict", { op_id = op.id })
        return op
      end
      op.error = err
      M.finish(repo, op, "failed")
      if not same_state(op.before, op.before_head, op.after, op.after_head) then
        err = err .. " (refs changed before the failure: :Trellis ops can restore them)"
      end
      return op, err
    end
  end
  if spec.run then
    local err = spec.run(op)
    if err then
      op.error = err
      M.finish(repo, op, "failed")
      return op, err
    end
  end
  M.finish(repo, op, "done")
  return op
end

-- Restoring states ------------------------------------------------------------------------------

local function short(ref)
  return (ref:gsub("^refs/heads/", ""))
end

--- Commands that move refs and HEAD from (cur, cur_head) to (want, want_head).
local function restore_commands(refs, cur, cur_head, want, want_head, reset_mode)
  local cmds = {}
  local function txn(names)
    local lines = { "start" }
    for _, ref in ipairs(names) do
      local w, c = want[ref], cur[ref]
      if w ~= c then
        if not w then
          lines[#lines + 1] = ("delete %s %s"):format(ref, c)
        elseif not c then
          lines[#lines + 1] = ("create %s %s"):format(ref, w)
        else
          lines[#lines + 1] = ("update %s %s %s"):format(ref, w, c)
        end
      end
    end
    if #lines > 1 then
      lines[#lines + 1] = "commit"
      cmds[#cmds + 1] = argv.W01(lines)
    end
  end
  local final_branch = want_head.symbolic
  local switching = want_head.symbolic ~= cur_head.symbolic
  if switching then
    if final_branch then
      txn({ final_branch }) -- not checked out yet: safe to move before switching to it
      cmds[#cmds + 1] = argv.W20(short(final_branch))
    elseif want_head.sha then
      cmds[#cmds + 1] = argv.W20(want_head.sha, true)
    end
  end
  local rest = {}
  for _, ref in ipairs(refs) do
    if ref ~= final_branch then
      rest[#rest + 1] = ref
    end
  end
  txn(rest)
  if switching then
    -- After switching, HEAD is the branch (moved above when it is one of the op's refs) or the
    -- detached sha. A branch that is not one of the op's refs is never moved.
    return cmds
  end
  local head_target = final_branch and want[final_branch] or want_head.sha
  if head_target and head_target ~= cur_head.sha then
    cmds[#cmds + 1] = argv.W30(reset_mode or "keep", head_target)
  end
  return cmds
end

local function describe_moves(refs, cur, want)
  local out = {}
  for _, ref in ipairs(refs) do
    if cur[ref] ~= want[ref] then
      out[#out + 1] = ("  %s: %s → %s"):format(
        ref,
        (cur[ref] or "(none)"):sub(1, 7),
        (want[ref] or "(deleted)"):sub(1, 7)
      )
    end
  end
  return out
end

--- Bring the repository to `target`'s "before" (undo, restore) or "after" (redo) state as a new
--- journaled operation of `kind`. Inside async.run.
---@return table? op, string? err
function M.restore(repo, target, side, kind)
  local want = side == "before" and target.before or target.after
  local want_head = side == "before" and target.before_head or target.after_head
  local other = side == "before" and target.after or target.before
  local other_head = side == "before" and target.after_head or target.before_head
  if not want or not want_head then
    return nil, ("operation %s has no recorded %s state"):format(target.id, side)
  end
  local cur, cur_head = backup.read_refs(repo, target.refs)
  if other and not same_state(cur, cur_head, other, other_head) then
    local preview = describe_moves(target.refs, other, cur)
    if cur_head.sha ~= other_head.sha then
      preview[#preview + 1] = ("  HEAD: %s → %s"):format(
        (other_head.sha or "?"):sub(1, 7),
        (cur_head.sha or "?"):sub(1, 7)
      )
    end
    local ok = preflight.confirm({
      title = "The repository changed since this operation. Restore anyway?",
      preview = preview,
      destructive = true,
      require_y = true,
    })
    if not ok then
      return nil, "cancelled"
    end
  end
  local mode = (
    target.kind == "reset" and (target.reset_mode == "soft" or target.reset_mode == "mixed")
  )
      and target.reset_mode
    or "keep"
  -- soft/mixed resets never change worktree files, so the changes they leave behind (their own
  -- effect) are not "dirty" for undoing or redoing them.
  local touches_worktree = (mode == "keep" and cur_head.sha ~= want_head.sha)
    or cur_head.symbolic ~= want_head.symbolic
    or (side == "before" and target.stash ~= nil)
  -- Files the operation wrote (restore_file): only those are touched. Their current content is
  -- saved as blobs first, so this restore is undoable too and nothing is lost; if they changed
  -- since the operation, ask.
  local files
  if target.files then
    files = {}
    local changed = {}
    for path, f in pairs(target.files) do
      local cur_blob = false
      if vim.uv.fs_stat(repo.root .. "/" .. path) then
        local e, res = backup.git(repo, argv.W29(path))
        if e then
          return nil, e
        end
        cur_blob = vim.trim(res.stdout)
      end
      -- (explicit ifs: `x and false or y` would yield y — `before = false` means "absent")
      local expected, wanted
      if side == "before" then
        expected, wanted = f.after, f.before
      else
        expected, wanted = f.before, f.after
      end
      if expected ~= nil and cur_blob ~= expected then
        changed[#changed + 1] = "  " .. path
      end
      files[path] = { before = cur_blob, after = wanted }
    end
    if #changed > 0 then
      local ok = preflight.confirm({
        title = "These files changed since the operation. Overwrite them? (their current content is kept in the journal)",
        preview = changed,
        destructive = true,
        require_y = true,
      })
      if not ok then
        return nil, "cancelled"
      end
    end
  end
  if touches_worktree then
    local dirty, entries = preflight.status(repo)
    if dirty then
      local ok = preflight.confirm({
        title = "Uncommitted changes: stash them (git stash push) and continue?",
        preview = preflight.describe_changes(entries),
        destructive = true,
      })
      if not ok then
        return nil, "cancelled: the worktree has uncommitted changes"
      end
      local err = backup.git(repo, argv.W31("trellis: before " .. kind .. " of " .. target.id))
      if err then
        return nil, err
      end
    end
  end
  local op, err = M.run(repo, {
    kind = kind,
    title = ("%s %s: %s"):format(kind, target.id, target.title),
    refs = target.refs,
    target = target.id,
    commands = restore_commands(target.refs, cur, cur_head, want, want_head, mode),
    files = files,
    run = function(op)
      for path, f in pairs(files or {}) do
        local blob = f.after
        local full = repo.root .. "/" .. path
        if blob == false then
          os.remove(full)
        elseif blob then
          local e, res = backup.git(repo, argv.G26(blob), { text = false })
          if e then
            return e
          end
          vim.fn.mkdir(vim.fs.dirname(full), "p")
          local fh = assert(io.open(full, "wb"))
          fh:write(res.stdout)
          fh:close()
        end
      end
      if side == "before" and target.stash then
        -- --index restores what was staged too; fall back to the content alone.
        local e = backup.git(repo, argv.W28(target.stash, true), { op_id = op.id })
        if e then
          e = backup.git(repo, argv.W28(target.stash), { op_id = op.id })
        end
        if e then
          return "refs restored, but re-applying the saved changes failed: "
            .. e
            .. " (they are in "
            .. backup.ref_for(target.id, "stash")
            .. ")"
        end
      end
    end,
  })
  if op and op.status == "done" then
    target.status = side == "before" and "undone" or "done"
    target.restored_by = op.id
    journal.append(repo, target)
  end
  return op, err
end

--- The operation `:Trellis undo` acts on: the newest regular operation that is done.
function M.undo_candidate(repo)
  local ops = journal.read(repo)
  for i = #ops, 1, -1 do
    local op = ops[i]
    if not REGULAR_EXCLUDED[op.kind] and op.status == "done" then
      return op
    end
  end
end

--- The operation `:Trellis redo` re-applies: the most recent undo whose target is still undone,
--- as long as no regular operation happened after it.
function M.redo_candidate(repo)
  local ops = journal.read(repo)
  local by_id = {}
  for _, op in ipairs(ops) do
    by_id[op.id] = op
  end
  for i = #ops, 1, -1 do
    local op = ops[i]
    if not REGULAR_EXCLUDED[op.kind] then
      return nil -- a new operation since: nothing to redo
    end
    if op.kind == "undo" and op.status == "done" then
      local target = by_id[op.target]
      if target and target.status == "undone" then
        return target
      end
    end
  end
end

---@return table? op, string? err
function M.undo(repo)
  local target = M.undo_candidate(repo)
  if not target then
    return nil, "nothing to undo"
  end
  return M.restore(repo, target, "before", "undo")
end

---@return table? op, string? err
function M.redo(repo)
  local target = M.redo_candidate(repo)
  if not target then
    return nil, "nothing to redo"
  end
  return M.restore(repo, target, "after", "redo")
end

--- Restore the "before" state of any operation (`:Trellis ops`).
function M.restore_op(repo, id)
  local target = journal.get(repo, id)
  if not target then
    return nil, "unknown operation " .. id
  end
  return M.restore(repo, target, "before", "restore")
end

-- Stopped operations (conflicts) --------------------------------------------------------------

--- Newest operation stopped on a conflict, if git still has it in progress.
function M.stopped(repo)
  local ops = journal.read(repo)
  for i = #ops, 1, -1 do
    if ops[i].status == "stopped" then
      return ops[i]
    end
  end
end

local CONTROL = {
  rebase = function(action)
    return argv.W11(action)
  end,
  ["cherry-pick"] = function(action)
    return argv.W23(action)
  end,
  revert = function(action)
    return argv.W24(action)
  end,
}

--- continue / skip / abort the in-progress cherry-pick or revert. Inside async.run.
---@param action "continue"|"skip"|"abort"
---@return table? op, string? err
function M.control(repo, action)
  local st = require("trellis.git.repo").refresh_state(repo)
  local build = CONTROL[st.kind]
  if not build then
    if st.kind == "clean" then
      return nil, "no operation in progress"
    end
    return nil, ("`:Trellis %s` is not supported for a %s"):format(action, st.kind)
  end
  local op = M.stopped(repo)
  local inv = build(action)
  -- A trellis rebase continues with its planned-message helper; anything else with git's
  -- default (editor disabled).
  local env = op and op.kind == st.kind and op.env or nil
  local err = backup.git(repo, inv, { op_id = op and op.id, env = env })
  if op then
    op.argv = op.argv or {}
    op.argv[#op.argv + 1] = inv.args
  end
  local now = require("trellis.git.repo").refresh_state(repo)
  if now.kind ~= "clean" then
    -- Still in progress: another conflict (error) or the next edit/break stop (no error).
    if op then
      journal.append(repo, op)
    end
    if err then
      return op, (action == "continue" and "still conflicted: " or "") .. err
    end
    return op
  end
  if op then
    M.finish(repo, op, action == "abort" and "aborted" or "done")
    if action == "abort" and not same_state(op.before, op.before_head, op.after, op.after_head) then
      return op, "aborted, but refs differ from the backup: :Trellis ops can restore them"
    end
  end
  return op, err
end

-- Pruning -----------------------------------------------------------------------------------

--- Operations whose backups are beyond retention (age or count). Inside async.run.
function M.prunable(repo)
  local cfg = require("trellis.config").get().safety
  local ops = journal.read(repo)
  local out, kept = {}, 0
  local cutoff = os.time() - cfg.backup_retention_days * 86400
  for i = #ops, 1, -1 do
    local op = ops[i]
    if not op.pruned and op.status ~= "running" and op.status ~= "stopped" then
      kept = kept + 1
      if (op.started_at or 0) < cutoff or kept > cfg.backup_max_ops then
        out[#out + 1] = op
      end
    end
  end
  return out
end

--- Delete backup refs of prunable operations (asks first). Inside async.run.
---@return integer pruned, string? err
function M.prune(repo, opts)
  opts = opts or {}
  local list = M.prunable(repo)
  if #list == 0 then
    return 0
  end
  if not opts.yes then
    local preview = {}
    for i, op in ipairs(list) do
      if i > 20 then
        preview[#preview + 1] = ("  … and %d more"):format(#list - 20)
        break
      end
      preview[#preview + 1] = ("  %s %s"):format(op.id, op.title or op.kind)
    end
    local ok = preflight.confirm({
      title = ("Delete the backup refs of %d old operations?"):format(#list),
      preview = preview,
      destructive = true,
    })
    if not ok then
      return 0, "cancelled"
    end
  end
  for _, op in ipairs(list) do
    local err = backup.delete(repo, backup.list(repo, op.id))
    if err then
      return 0, err
    end
    journal.append(repo, { id = op.id, pruned = true })
  end
  return #list
end

--- Run `fn` inside async.run and report errors (helper for commands/keys).
---@param fn fun(): (table?, string?)
---@param cb? fun(op: table?, err: string?)
function M.spawn(fn, cb)
  async.run(fn, function(err, op, msg)
    err = err or msg
    if cb then
      return cb(op, err)
    end
    if err then
      vim.notify(
        "trellis: " .. err,
        err == "cancelled" and vim.log.levels.INFO or vim.log.levels.ERROR
      )
    end
  end)
end

return M
