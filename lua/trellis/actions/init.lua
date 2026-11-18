--- History actions (US5, FR-050/051), each through the safety pipeline (safety/ops.lua):
--- preflight → preview + confirm → backup refs + journal → git → undoable with :Trellis undo.
---
--- All functions are async (inside async.run via ops.spawn) and return `op, err`.
local argv = require("trellis.git.argv")
local backup = require("trellis.safety.backup")
local details = require("trellis.git.details")
local ops = require("trellis.safety.ops")
local preflight = require("trellis.safety.preflight")

local M = {}

local function resolve(repo, rev)
  local sha, err
  require("trellis.util.async").await(function(cb)
    details.resolve(repo, rev, function(e, s)
      err, sha = e, s
      cb()
    end)
  end)
  return sha, err
end

local function head_branch(repo)
  local _, head = backup.read_refs(repo, {})
  return head.symbolic, head.sha
end

local function require_clean(repo, what)
  local dirty, entries = preflight.status(repo)
  if dirty then
    local list = preflight.describe_changes(entries)
    return ("%s needs a clean worktree (commit or stash first):\n%s"):format(
      what,
      table.concat(list, "\n")
    )
  end
end

local function lines_of(text)
  local out = {}
  for l in (text or ""):gmatch("[^\n]+") do
    out[#out + 1] = "  " .. l
  end
  return out
end

--- Checkout a branch (attach) or any other revision (detached HEAD).
function M.checkout(repo, rev)
  local err = preflight.in_progress(repo)
  if err then
    return nil, err
  end
  local values = backup.read_refs(repo, { "refs/heads/" .. rev })
  local is_branch = values["refs/heads/" .. rev] ~= nil
  local inv, title
  if is_branch then
    local where = preflight.checked_out_elsewhere(repo, "refs/heads/" .. rev)
    if where then
      return nil, ("branch %s is checked out in %s"):format(rev, where)
    end
    inv, title = argv.W20(rev), "Checkout " .. rev
  else
    local sha, rerr = resolve(repo, rev)
    if not sha then
      return nil, rerr
    end
    inv, title = argv.W20(sha, true), "Checkout " .. sha:sub(1, 7) .. " (detached HEAD)"
  end
  if not preflight.confirm({ title = title .. "?", preview = {}, destructive = false }) then
    return nil, "cancelled"
  end
  return ops.run(repo, { kind = "checkout", title = title, refs = {}, commands = { inv } })
end

---@param opts? { checkout?: boolean }
function M.branch_create(repo, name, rev, opts)
  opts = opts or {}
  local sha, rerr = resolve(repo, rev or "HEAD")
  if not sha then
    return nil, rerr
  end
  local ref = "refs/heads/" .. name
  if backup.read_refs(repo, { ref })[ref] then
    return nil, "branch " .. name .. " already exists"
  end
  local cmds = { argv.W21("create", name, sha) }
  if opts.checkout then
    cmds[2] = argv.W20(name)
  end
  return ops.run(repo, {
    kind = "branch-create",
    title = ("Create branch %s at %s"):format(name, sha:sub(1, 7)),
    refs = { ref },
    commands = cmds,
  })
end

function M.branch_rename(repo, old, new)
  local refs = backup.read_refs(repo, { "refs/heads/" .. old, "refs/heads/" .. new })
  if not refs["refs/heads/" .. old] then
    return nil, "no branch " .. old
  end
  if refs["refs/heads/" .. new] then
    return nil, "branch " .. new .. " already exists"
  end
  local where = preflight.checked_out_elsewhere(repo, "refs/heads/" .. old)
  if where then
    return nil, ("branch %s is checked out in %s"):format(old, where)
  end
  return ops.run(repo, {
    kind = "branch-rename",
    title = ("Rename branch %s to %s"):format(old, new),
    refs = { "refs/heads/" .. old, "refs/heads/" .. new },
    commands = { argv.W21("rename", old, new) },
  })
end

function M.branch_delete(repo, name)
  local ref = "refs/heads/" .. name
  local tip = backup.read_refs(repo, { ref })[ref]
  if not tip then
    return nil, "no branch " .. name
  end
  local current = head_branch(repo)
  if current == ref then
    return nil, "cannot delete the checked-out branch " .. name
  end
  local where = preflight.checked_out_elsewhere(repo, ref)
  if where then
    return nil, ("branch %s is checked out in %s"):format(name, where)
  end
  local merged = preflight.is_ancestor(repo, tip, "HEAD")
  local preview = { ("  %s at %s (kept in a backup ref)"):format(name, tip:sub(1, 7)) }
  if not merged then
    local _, res = backup.git(repo, argv.G15("HEAD", tip))
    preview[#preview + 1] = "Not merged into HEAD — these commits are only on " .. name .. ":"
    vim.list_extend(preview, lines_of(res and res.stdout))
  end
  if
    not preflight.confirm({
      title = ("Delete branch %s%s?"):format(name, merged and "" or " (NOT merged)"),
      preview = preview,
      destructive = true,
      require_y = not merged,
    })
  then
    return nil, "cancelled"
  end
  return ops.run(repo, {
    kind = "branch-delete",
    title = "Delete branch " .. name,
    refs = { ref },
    commands = { argv.W21("delete", name) },
  })
end

---@param opts? { message?: string }
function M.tag_create(repo, name, rev, opts)
  opts = opts or {}
  local sha, rerr = resolve(repo, rev or "HEAD")
  if not sha then
    return nil, rerr
  end
  local ref = "refs/tags/" .. name
  if backup.read_refs(repo, { ref })[ref] then
    return nil, "tag " .. name .. " already exists"
  end
  return ops.run(repo, {
    kind = "tag-create",
    title = ("Create tag %s at %s"):format(name, sha:sub(1, 7)),
    refs = { ref },
    commands = { argv.W22("create", name, sha, opts.message) },
  })
end

function M.tag_delete(repo, name)
  local ref = "refs/tags/" .. name
  local value = backup.read_refs(repo, { ref })[ref]
  if not value then
    return nil, "no tag " .. name
  end
  if
    not preflight.confirm({
      title = "Delete tag " .. name .. "?",
      preview = { ("  %s → %s (kept in a backup ref)"):format(name, value:sub(1, 7)) },
      destructive = true,
    })
  then
    return nil, "cancelled"
  end
  return ops.run(repo, {
    kind = "tag-delete",
    title = "Delete tag " .. name,
    refs = { ref },
    commands = { argv.W22("delete", name) },
  })
end

--- Order commits oldest first by ancestry (stable for unrelated ones).
local function topo_oldest_first(repo, shas)
  local list = vim.deepcopy(shas)
  -- Insertion sort with ancestry checks; selections are small.
  local sorted = {}
  for _, s in ipairs(list) do
    local pos = #sorted + 1
    for i, t in ipairs(sorted) do
      if preflight.is_ancestor(repo, s, t) then
        pos = i
        break
      end
    end
    table.insert(sorted, pos, s)
  end
  return sorted
end

--- Cherry-pick one or more commits onto HEAD, oldest first. A conflict stops the operation
--- (`:Trellis continue | skip | abort`, conflict panel).
---@param opts? { x?: boolean }
function M.cherry_pick(repo, revs, opts)
  opts = opts or {}
  local err = preflight.in_progress(repo) or require_clean(repo, "cherry-pick")
  if err then
    return nil, err
  end
  local shas = {}
  for _, r in ipairs(revs) do
    local sha, rerr = resolve(repo, r)
    if not sha then
      return nil, rerr
    end
    shas[#shas + 1] = sha
  end
  shas = topo_oldest_first(repo, shas)
  local branch = head_branch(repo)
  local preview = {}
  for _, s in ipairs(shas) do
    preview[#preview + 1] = "  " .. s:sub(1, 7)
  end
  if
    not preflight.confirm({
      title = ("Cherry-pick %d commit(s) onto %s?"):format(
        #shas,
        branch and branch:gsub("^refs/heads/", "") or "HEAD"
      ),
      preview = preview,
      destructive = false,
    })
  then
    return nil, "cancelled"
  end
  return ops.run(repo, {
    kind = "cherry-pick",
    title = ("Cherry-pick %s onto %s"):format(
      #shas == 1 and shas[1]:sub(1, 7) or (#shas .. " commits"),
      branch and branch:gsub("^refs/heads/", "") or "HEAD"
    ),
    refs = branch and { branch } or {},
    commands = { argv.W23(shas, opts.x) },
    may_stop = true,
  })
end

--- Revert a commit (merges need `mainline`, asked when missing).
---@param opts? { mainline?: integer }
function M.revert(repo, rev, opts)
  opts = opts or {}
  local err = preflight.in_progress(repo) or require_clean(repo, "revert")
  if err then
    return nil, err
  end
  local sha, rerr = resolve(repo, rev)
  if not sha then
    return nil, rerr
  end
  local d
  require("trellis.util.async").await(function(cb)
    details.get(repo, sha, nil, function(_, x)
      d = x
      cb()
    end)
  end)
  local mainline = opts.mainline
  if d and #d.parents > 1 and not mainline then
    local choices = {}
    for i, p in ipairs(d.parents) do
      choices[i] = { i = i, label = ("parent %d %s"):format(i, p:sub(1, 7)) }
    end
    local choice = require("trellis.util.async").await(function(cb)
      vim.schedule(function()
        vim.ui.select(choices, {
          prompt = "Revert merge relative to",
          format_item = function(c)
            return c.label
          end,
        }, cb)
      end)
    end)
    if not choice then
      return nil, "cancelled"
    end
    mainline = choice.i
  end
  local branch = head_branch(repo)
  if
    not preflight.confirm({
      title = "Revert " .. sha:sub(1, 7) .. "?",
      preview = {},
      destructive = false,
    })
  then
    return nil, "cancelled"
  end
  return ops.run(repo, {
    kind = "revert",
    title = "Revert " .. sha:sub(1, 7),
    refs = branch and { branch } or {},
    commands = { argv.W24(sha, mainline) },
    may_stop = true,
  })
end

--- Reset the checked-out branch (or detached HEAD) to `rev`. Hard resets save uncommitted
--- changes in a stash commit first and require typing "y".
---@param mode "soft"|"mixed"|"hard"
function M.reset(repo, rev, mode)
  local err = preflight.in_progress(repo)
  if err then
    return nil, err
  end
  local sha, rerr = resolve(repo, rev)
  if not sha then
    return nil, rerr
  end
  local branch, head = head_branch(repo)
  local preview = {}
  local _, res = backup.git(repo, argv.G15(sha, "HEAD"))
  local dropped = lines_of(res and res.stdout)
  if #dropped > 0 then
    preview[#preview + 1] = "Commits that leave "
      .. (branch and branch:gsub("^refs/heads/", "") or "HEAD")
      .. " (kept in a backup ref):"
    vim.list_extend(preview, dropped)
  end
  local dirty, entries = preflight.status(repo)
  if mode == "hard" and dirty then
    preview[#preview + 1] = "Uncommitted changes that will be discarded (saved in a backup stash):"
    vim.list_extend(preview, preflight.describe_changes(entries))
  end
  if #preview == 0 then
    preview[1] = ("  %s → %s"):format((head or "?"):sub(1, 7), sha:sub(1, 7))
  end
  if
    not preflight.confirm({
      title = ("Reset %s to %s (%s)?"):format(
        branch and branch:gsub("^refs/heads/", "") or "HEAD",
        sha:sub(1, 7),
        mode
      ),
      preview = preview,
      destructive = true,
      require_y = mode == "hard",
    })
  then
    return nil, "cancelled"
  end
  return ops.run(repo, {
    kind = "reset",
    title = ("Reset %s to %s (%s)"):format(
      branch and branch:gsub("^refs/heads/", "") or "HEAD",
      sha:sub(1, 7),
      mode
    ),
    refs = branch and { branch } or {},
    reset_mode = mode,
    stash = mode == "hard" and dirty,
    commands = { argv.W25(mode, sha) },
  })
end

--- Write the version of `path` at `rev` to the working copy (journaled: the overwritten
--- content is saved as a blob first).
function M.restore_file(repo, rev, path)
  local sha, rerr = resolve(repo, rev)
  if not sha then
    return nil, rerr
  end
  local full = repo.root .. "/" .. path
  local before = false
  if vim.uv.fs_stat(full) then
    local err, res = backup.git(repo, argv.W29(path))
    if err then
      return nil, err
    end
    before = vim.trim(res.stdout)
  end
  if
    not preflight.confirm({
      title = ("Overwrite %s with its version at %s?"):format(path, sha:sub(1, 7)),
      preview = {
        before and "  the current content is kept in the journal (undo restores it)"
          or "  the file does not exist yet",
      },
      destructive = true,
    })
  then
    return nil, "cancelled"
  end
  local files = { [path] = { before = before } }
  return ops.run(repo, {
    kind = "restore-file",
    title = ("Restore %s from %s"):format(path, sha:sub(1, 7)),
    refs = {},
    files = files,
    commands = {},
    run = function(op)
      local err, res = backup.git(repo, argv.G22(sha, path), { text = false })
      if err then
        return err
      end
      vim.fn.mkdir(vim.fs.dirname(full), "p")
      local fh = assert(io.open(full, "wb"))
      fh:write(res.stdout)
      fh:close()
      local herr, h = backup.git(repo, argv.W29(path))
      if not herr then
        op.files[path].after = vim.trim(h.stdout)
      end
    end,
  })
end

return M
