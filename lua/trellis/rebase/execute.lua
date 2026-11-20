--- Run a plan with native `git rebase -i` (research R9, FR-043/045).
---
--- trellis decides only the todo and the messages: GIT_SEQUENCE_EDITOR copies the planned todo
--- over git's, GIT_EDITOR supplies planned messages (both are `nvim -l` helpers), so hooks,
--- signing, update-ref and conflict semantics are git's own. The run goes through the safety
--- pipeline (backup refs, journal, undo); a conflict or an edit/break stop leaves the
--- operation "stopped" for :Trellis continue / skip / abort and the conflict panel.
local argv = require("trellis.git.argv")
local journal = require("trellis.safety.journal")
local ops = require("trellis.safety.ops")
local plan_mod = require("trellis.rebase.plan")
local preflight = require("trellis.safety.preflight")
local simulate = require("trellis.rebase.simulate")

local M = {}

local source = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
M.root = vim.fn.fnamemodify(source, ":p:h:h:h:h"):gsub("\\", "/"):gsub("/$", "")

local function q(s)
  return '"' .. s:gsub("\\", "/"):gsub('"', '\\"') .. '"'
end

function M.plan_dir(repo, plan)
  return journal.dir(repo) .. "/plans/" .. plan.id
end

--- Environment for git: the two helpers, run by git through sh.
function M.env(repo, plan)
  local dir = M.plan_dir(repo, plan)
  local nvim = q(vim.v.progpath)
  return {
    GIT_SEQUENCE_EDITOR = ("%s -l %s %s"):format(
      nvim,
      q(M.root .. "/helpers/seq_editor.lua"),
      q(dir .. "/todo")
    ),
    GIT_EDITOR = ("%s -l %s %s %s"):format(
      nvim,
      q(M.root .. "/helpers/msg_editor.lua"),
      q(repo.gitdir),
      q(dir .. "/msg")
    ),
  }
end

--- Write the todo and the planned messages (by chain-head sha).
function M.write_files(repo, plan, entries)
  local dir = M.plan_dir(repo, plan)
  require("trellis.util.fs").mkdirp(dir .. "/msg")
  local f = assert(io.open(dir .. "/todo", "wb"))
  f:write(plan_mod.to_todo(plan, entries))
  f:close()
  for sha, msg in pairs(plan.messages) do
    local m = assert(io.open(dir .. "/msg/" .. sha .. ".txt", "wb"))
    m:write(msg:sub(-1) == "\n" and msg or (msg .. "\n"))
    m:close()
  end
  return dir
end

--- Execute `entries` of `plan`. Inside async.run. Returns the operation (status "done" or
--- "stopped") or an error.
---@param repo trellis.Repository
---@param plan trellis.RebasePlanImpl
---@param entries trellis.PlanEntry[]
---@param diags trellis.PlanDiagnostic[]
---@return table? op, string? err
function M.run(repo, plan, entries, diags)
  for _, d in ipairs(diags or {}) do
    if d.severity == "error" then
      return nil, ("plan has errors (line %d: %s)"):format(d.lnum, d.message)
    end
  end
  local err = preflight.in_progress(repo) or plan_mod.stale_reason(repo, plan)
  if err then
    return nil, err
  end
  local sim = simulate.run(plan, entries)
  local has_exec = false
  for _, e in ipairs(entries) do
    if e.action == "exec" or e.action == "break" or e.action == "edit" then
      has_exec = true
    end
  end
  if sim.unchanged and not has_exec then
    return nil, "nothing to do: the plan does not change history"
  end

  -- Dirty worktree: autostash or cancel (FR-045, spec US4 scenario 7).
  local autostash = false
  local dirty, entries_status = preflight.status(repo)
  if dirty then
    local mode = require("trellis.config").get().safety.autostash
    if mode == "never" then
      return nil, 'the worktree has uncommitted changes (safety.autostash = "never")'
    elseif mode == "always" then
      autostash = true
    else
      local ok = preflight.confirm({
        title = "Uncommitted changes: autostash them for the rebase?",
        preview = preflight.describe_changes(entries_status),
        destructive = true,
        require_y = false,
      })
      if not ok then
        return nil, "cancelled: the worktree has uncommitted changes"
      end
      autostash = true
    end
  end

  local published = {}
  for _, sha in ipairs(plan.original) do
    if plan.published[sha] then
      published[#published + 1] = sha:sub(1, 7)
    end
  end
  local counts = plan_mod.summary(plan, entries)
  local branch = plan.head_ref and plan.head_ref:gsub("^refs/heads/", "") or "detached HEAD"
  local preview = {
    ("  %d commits → %d (%d folded, %d dropped, %d reworded)"):format(
      #plan.original,
      #sim.commits,
      counts.squash,
      counts.drop,
      counts.reword
    ),
  }
  local changed = 0
  for _, c in ipairs(sim.commits) do
    if c.changed then
      changed = changed + 1
    end
  end
  preview[#preview + 1] = ("  %d commit(s) get a new hash"):format(changed)
  if #published > 0 then
    preview[#preview + 1] = ("  ⚠ %d commit(s) are already on a remote (%s): updating it would need a force-push — trellis never pushes"):format(
      #published,
      table.concat(published, " ", 1, math.min(#published, 5))
    )
  end
  if autostash then
    preview[#preview + 1] = "  uncommitted changes are autostashed and re-applied afterwards"
  end
  if
    not preflight.confirm({
      title = ("Rebase %s onto %s?"):format(branch, plan.base:sub(1, 7)),
      preview = preview,
      destructive = true,
    })
  then
    return nil, "cancelled"
  end

  M.write_files(repo, plan, entries)
  local refs = plan.head_ref and { plan.head_ref } or {}
  for _, e in ipairs(entries) do
    if e.action == "update_ref" and not vim.tbl_contains(refs, e.arg) then
      refs[#refs + 1] = e.arg
    end
  end
  return ops.run(repo, {
    kind = "rebase",
    title = ("Rebase %s onto %s (%d commits)"):format(branch, plan.base:sub(1, 7), #sim.commits),
    refs = refs,
    commands = { argv.W10(plan.base, { autostash = autostash }) },
    env = M.env(repo, plan),
    plan_id = plan.id,
    may_stop = true,
  })
end

return M
