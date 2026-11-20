--- Public Lua API. Functions of stories that are not implemented yet are
--- added in their milestones; `setup` works now.
local M = {}

--- Optional: validate and merge configuration. Returns the list of problems (also notified).
---@param opts? table
---@return string[]
function M.setup(opts)
  return require("trellis.config").setup(opts)
end

--- Open the commit graph.
---@param opts? { query?: trellis.GraphQuery, args?: string[], split?: "tab"|"vertical"|"horizontal"|"current", cwd?: string }
function M.graph(opts)
  require("trellis.view.graph").open(opts)
end

local function with_repo(opts, cb)
  if opts and opts.cwd then
    return require("trellis.git.repo").discover(opts.cwd, function(err, repo)
      if err then
        return vim.notify("trellis: " .. err, vim.log.levels.ERROR)
      end
      cb(repo)
    end)
  end
  require("trellis.commands").with_repo(cb)
end

--- Open the commit view.
---@param rev string
---@param opts? { cwd?: string, against?: string, split?: string }
function M.commit(rev, opts)
  with_repo(opts, function(repo)
    require("trellis.view.commit").open(repo, rev, opts)
  end)
end

--- Unified diff `a`..`b` (b = nil: working tree), or side-by-side with `opts.side_by_side`.
---@param a string
---@param b? string
---@param opts? { cwd?: string, path?: string, side_by_side?: boolean }
function M.diff(a, b, opts)
  opts = opts or {}
  with_repo(opts, function(repo)
    if opts.side_by_side and opts.path then
      require("trellis.view.diff").side_by_side(repo, a, b, { path = opts.path })
    else
      require("trellis.view.diff").open(repo, a, b, { path = opts.path })
    end
  end)
end

--- Open `trellis://<sha>/<path>`.
---@param rev string
---@param path string repo-relative
---@param opts? { cwd?: string, split?: string }
function M.file_at(rev, path, opts)
  with_repo(opts, function(repo)
    require("trellis.view.filerev").open(repo, rev, path, opts)
  end)
end

--- File history (default: the current buffer's file).
---@param path? string
---@param opts? { cwd?: string }
function M.file_history(path, opts)
  with_repo(opts, function(repo, rel)
    local p = path or rel
    if not p then
      return vim.notify("trellis: no file", vim.log.levels.ERROR)
    end
    require("trellis.view.filehistory").open(repo, p)
  end)
end

--- Toggle the blame column for the current window.
function M.blame()
  require("trellis.view.blame").toggle()
end

--- History of lines `start_line`..`end_line` of the current file.
function M.line_history(start_line, end_line)
  require("trellis.view.linehistory").open(start_line, end_line)
end

--- Permalink URL (copied to "" and "+). Without `opts.sha`: lines of the current file.
---@param opts? { sha?: string, path?: string, line1?: integer, line2?: integer, cwd?: string }
---@param cb? fun(err: string?, url: string?)
function M.permalink(opts, cb)
  opts = opts or {}
  if not opts.sha then
    local l = vim.api.nvim_win_get_cursor(0)[1]
    return require("trellis.permalink").current(opts.line1 or l, opts.line2 or opts.line1 or l, cb)
  end
  with_repo(opts, function(repo)
    require("trellis.permalink").for_repo(repo, opts, cb)
  end)
end

-- Actions (journaled, confirm per config, undoable) -----------------------------------------

local function act(opts, fn, cb)
  with_repo(opts, function(repo)
    local ops = require("trellis.safety.ops")
    if cb then
      return ops.spawn(function()
        return fn(require("trellis.actions"), repo)
      end, cb)
    end
    require("trellis.actions.ui").run(repo, function()
      return fn(require("trellis.actions"), repo)
    end)
  end)
end

--- Each action takes an optional `cb(op, err)`; without it the outcome is notified.
function M.checkout(rev, opts, cb)
  act(opts, function(a, repo)
    return a.checkout(repo, rev)
  end, cb)
end
function M.branch_create(name, rev, opts, cb)
  act(opts, function(a, repo)
    return a.branch_create(repo, name, rev, opts)
  end, cb)
end
function M.branch_rename(old, new, opts, cb)
  act(opts, function(a, repo)
    return a.branch_rename(repo, old, new)
  end, cb)
end
function M.branch_delete(name, opts, cb)
  act(opts, function(a, repo)
    return a.branch_delete(repo, name)
  end, cb)
end
function M.tag_create(name, rev, opts, cb)
  act(opts, function(a, repo)
    return a.tag_create(repo, name, rev, opts)
  end, cb)
end
function M.tag_delete(name, opts, cb)
  act(opts, function(a, repo)
    return a.tag_delete(repo, name)
  end, cb)
end
function M.cherry_pick(shas, opts, cb)
  act(opts, function(a, repo)
    return a.cherry_pick(repo, shas, opts)
  end, cb)
end
function M.revert(sha, opts, cb)
  act(opts, function(a, repo)
    return a.revert(repo, sha, opts)
  end, cb)
end
function M.reset(rev, mode, opts, cb)
  act(opts, function(a, repo)
    return a.reset(repo, rev, mode)
  end, cb)
end
function M.restore_file(sha, path, opts, cb)
  act(opts, function(a, repo)
    return a.restore_file(repo, sha, path)
  end, cb)
end
function M.undo(opts, cb)
  act(opts, function(_, repo)
    return require("trellis.safety.ops").undo(repo)
  end, cb)
end
function M.redo(opts, cb)
  act(opts, function(_, repo)
    return require("trellis.safety.ops").redo(repo)
  end, cb)
end
function M.restore_op(op_id, opts, cb)
  act(opts, function(_, repo)
    return require("trellis.safety.ops").restore_op(repo, op_id)
  end, cb)
end

--- Journal entries, newest first (sync read).
---@param opts? { cwd?: string, limit?: integer }
---@return table[]
function M.operations(opts)
  opts = opts or {}
  local repo
  require("trellis.git.repo").discover(opts.cwd or vim.fn.getcwd(), function(_, r)
    repo = r
  end)
  vim.wait(5000, function()
    return repo ~= nil
  end, 5)
  if not repo then
    return {}
  end
  local list = require("trellis.safety.journal").read(repo)
  local out = {}
  for i = #list, math.max(1, #list - (opts.limit or 50) + 1), -1 do
    out[#out + 1] = list[i]
  end
  return out
end

--- Open the rebase planner with `base` (exclusive) for HEAD.
---@param base string
---@param opts? { cwd?: string, rebase_merges?: boolean, update_refs?: boolean, autosquash?: boolean }
function M.rebase(base, opts)
  with_repo(opts, function(repo)
    require("trellis.view.plan").start(repo, base, opts)
  end)
end

function M.continue(opts, cb)
  act(opts, function(_, repo)
    return require("trellis.safety.ops").control(repo, "continue")
  end, cb)
end
function M.skip(opts, cb)
  act(opts, function(_, repo)
    return require("trellis.safety.ops").control(repo, "skip")
  end, cb)
end
function M.abort(opts, cb)
  act(opts, function(_, repo)
    return require("trellis.safety.ops").control(repo, "abort")
  end, cb)
end

--- Statusline text for the current buffer's repository: " main · rebase 3/7". Never runs git
--- (uses already-discovered repositories), so it is safe to call on every redraw.
---@return string
--- Reflog of `ref` (default HEAD); lost commits are marked and can be brought back with `gb`.
---@param ref? string
---@param opts? { cwd?: string }
function M.reflog(ref, opts)
  with_repo(opts, function(repo)
    require("trellis.view.reflog").open(repo, { ref = ref })
  end)
end

--- The stash list (<CR> changes, `a` apply).
---@param opts? { cwd?: string }
function M.stash(opts)
  with_repo(opts, function(repo)
    require("trellis.view.stash").open(repo)
  end)
end

--- Find a commit with Snacks, Telescope, fzf-lua or vim.ui.select (`pick.backend`).
---@param opts? { cwd?: string, backend?: string, on_choose?: fun(sha: string) }
function M.pick(opts)
  opts = opts or {}
  with_repo(opts, function(repo)
    require("trellis.pick").pick(repo, { backend = opts.backend, on_choose = opts.on_choose })
  end)
end

function M.statusline()
  local ok, text = pcall(function()
    local name = vim.api.nvim_buf_get_name(0)
    local vars = vim.b.trellis
    local path = type(vars) == "table" and vars.repo
      or (name ~= "" and vim.fs.dirname(vim.fs.normalize(name)))
      or vim.fn.getcwd()
    path = vim.fs.normalize(path)
    local best
    for _, repo in pairs(require("trellis.git.repo").cache) do
      if path == repo.root or vim.startswith(path, repo.root .. "/") then
        if not best or #repo.root > #best.root then
          best = repo
        end
      end
    end
    if not best then
      return ""
    end
    local st = require("trellis.git.repo").read_state(best.gitdir)
    local head = best.refs and best.refs.head
    local label = head
        and (head.ref and head.ref:gsub("^refs/heads/", "") or (head.sha or ""):sub(1, 7))
      or ""
    local out = " " .. label
    if st.kind ~= "clean" then
      out = out .. " · " .. st.kind
      if st.rebase and st.rebase.done and st.rebase.total then
        out = out .. (" %d/%d"):format(st.rebase.done, st.rebase.total)
      end
    end
    return out
  end)
  return ok and text or ""
end

--- Add a side-by-side diff adapter: `{ name, available(): boolean, open(repo, a, b, opts) }`.
function M.register_diff_adapter(adapter)
  require("trellis.adapters.diff").register(adapter)
end

--- Current buffer's trellis context, never throws.
---@return { view: string, sha?: string, path?: string, line?: integer }?
function M.current()
  local ok, vars = pcall(function()
    return vim.b.trellis
  end)
  if not ok or type(vars) ~= "table" then
    return nil
  end
  return { view = vars.view, sha = vars.sha, path = vars.path, line = vars.line }
end

return M
