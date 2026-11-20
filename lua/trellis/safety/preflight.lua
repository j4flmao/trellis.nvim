--- Checks before an operation and the confirmation dialog (Constitution I).
local argv = require("trellis.git.argv")
local async = require("trellis.util.async")
local backup = require("trellis.safety.backup")
local status = require("trellis.git.parse.status")

local M = {}

--- Tracked changes (staged, unstaged, conflicts) in the worktree. Async.
---@return boolean dirty, trellis.StatusEntry[] entries
function M.status(repo)
  local err, res = backup.git(repo, argv.G07())
  if err then
    return false, {}
  end
  local entries = status.parse(res.stdout)
  return status.dirty(entries), entries
end

--- Error message if an operation is in progress (rebase, merge, cherry-pick, …).
---@return string?
function M.in_progress(repo)
  local st = require("trellis.git.repo").refresh_state(repo)
  if st.kind ~= "clean" then
    return ("a %s is in progress: finish it with :Trellis continue / skip / abort"):format(st.kind)
  end
end

--- Worktree (other than the current one) that has `branch` checked out. Async (refreshes
--- the worktree list).
---@param branch string refs/heads/x
---@return string? path
function M.checked_out_elsewhere(repo, branch)
  local feats = repo.features
  local err, res = backup.git(repo, argv.G03(feats.worktree_z))
  if not err then
    repo.worktrees = require("trellis.git.repo").parse_worktrees(res.stdout, feats.worktree_z)
    for _, wt in ipairs(repo.worktrees) do
      wt.current = wt.path == repo.root
    end
  end
  for _, wt in ipairs(repo.worktrees or {}) do
    if not wt.current and wt.branch == branch then
      return wt.path
    end
  end
end

--- Is `a` reachable from `b`? Async.
function M.is_ancestor(repo, a, b)
  local err, res = backup.git(repo, argv.G08(a, b))
  return not err and res.code == 0
end

---@class trellis.ConfirmSpec
---@field title string           question, e.g. "Reset main to a1b2c3d (hard)?"
---@field preview string[]       what will happen (commits dropped, files discarded, …)
---@field destructive boolean
---@field require_y? boolean     ask to type "y" (reset --hard, unmerged branch -D): even with safety.confirm = "never"

--- The UI used to ask. Tests replace it: `ui(spec, cb)` with `cb(true|false)`.
---@type fun(spec: trellis.ConfirmSpec, cb: fun(ok: boolean))
function M.ui(spec, cb)
  local lines = vim.list_extend({ spec.title, "" }, spec.preview)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = 20
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = math.min(#lines, math.max(3, vim.o.lines - 8))
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 2),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " trellis ",
  })
  local function done(ok)
    pcall(vim.api.nvim_win_close, win, true)
    cb(ok)
  end
  if spec.require_y then
    vim.ui.input({ prompt = "Type y to confirm: " }, function(answer)
      done(answer == "y")
    end)
  else
    vim.ui.select({ "Yes", "No" }, { prompt = spec.title }, function(choice)
      done(choice == "Yes")
    end)
  end
end

--- Ask according to `safety.confirm` ("always" | "destructive" | "never"). Async.
---@param spec trellis.ConfirmSpec
---@return boolean
function M.confirm(spec)
  local mode = require("trellis.config").get().safety.confirm
  local ask = spec.require_y or mode == "always" or (mode == "destructive" and spec.destructive)
  if not ask then
    return true
  end
  return async.await(function(cb)
    vim.schedule(function()
      M.ui(spec, cb)
    end)
  end)
end

--- Preview lines for uncommitted changes.
---@param entries trellis.StatusEntry[]
function M.describe_changes(entries)
  local out = {}
  for _, e in ipairs(entries) do
    if e.kind ~= "untracked" and e.kind ~= "ignored" then
      out[#out + 1] = ("  %s %s"):format(
        e.xy,
        e.orig_path and (e.orig_path .. " → " .. e.path) or e.path
      )
    end
  end
  return out
end

return M
