--- Diff views (FR-023): unified diff buffer (`git diff` output, filetype diff, one fold per
--- file) and side-by-side through an adapter.
local adapters = require("trellis.adapters.diff")
local argv = require("trellis.git.argv")
local base = require("trellis.view.base")
local config = require("trellis.config")
local parse = require("trellis.git.parse.diff")
local runner = require("trellis.git.runner")

local M = {}

--- foldexpr: a new fold at every "diff --git" line.
function M.foldexpr(lnum)
  local line = vim.fn.getline(lnum)
  if line:sub(1, 11) == "diff --git " then
    return ">1"
  end
  return "="
end

--- File and line (in the b version) under the cursor of a unified diff buffer.
---@return string? path, integer? line
function M.location(buf, lnum)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, lnum, false)
  local path, new_line
  for i = 1, #lines do
    local l = lines[i]
    if l:sub(1, 4) == "+++ " then
      path = l:sub(5) ~= "/dev/null" and l:sub(5):gsub("^b/", "") or nil
    elseif l:sub(1, 2) == "@@" then
      local h = parse.parse_hunk_header(l)
      new_line = h and h.new_start - 1 or nil
    elseif new_line and (l:sub(1, 1) == " " or l:sub(1, 1) == "+") then
      new_line = new_line + 1
    end
  end
  return path, new_line and math.max(1, new_line) or nil
end

---@class trellis.UnifiedOpts
---@field path? string
---@field old_path? string
---@field split? string
---@field on_open? fun(buf: integer)

--- Unified diff of `a`..`b` (b = nil: working tree), optionally limited to one file.
---@param repo trellis.Repository
---@param a string
---@param b string?
---@param opts? trellis.UnifiedOpts
function M.open(repo, a, b, opts)
  opts = opts or {}
  local paths = opts.path and { opts.path } or nil
  if opts.old_path and opts.old_path ~= opts.path then
    paths = { opts.old_path, opts.path }
  end
  local inv = argv.G20(a, b, paths)
  runner.run(repo.root, inv.args, { kind = inv.kind }, function(err, res)
    if err then
      return vim.notify("trellis: " .. err, vim.log.levels.ERROR)
    end
    local short = function(s)
      return s and s:sub(1, 7) or "worktree"
    end
    local name = ("trellis://diff/%s..%s%s"):format(
      short(a),
      short(b),
      opts.path and ("/" .. opts.path) or ""
    )
    local buf = base.create_buf(
      { name = name, kind = "diff", vars = { a = a, b = b, path = opts.path } },
      repo
    )
    local lines = vim.split(res.stdout:gsub("\n$", ""), "\n", { plain = true })
    if res.stdout == "" then
      lines = { "(no differences)" }
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "diff"
    local cfg = config.for_repo(repo.root)
    base.open_slot(buf, opts.split or cfg.views.commit.split, "diff")
    local wo = vim.wo
    wo.foldmethod = "expr"
    wo.foldexpr = "v:lua.require'trellis.view.diff'.foldexpr(v:lnum)"
    wo.foldlevel = 99
    wo.wrap = false
    base.apply_keymaps(buf, "diff", {
      close = function()
        if #vim.api.nvim_list_wins() > 1 then
          vim.cmd("close")
        else
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end,
      open_file = function()
        local path, line = M.location(buf, vim.api.nvim_win_get_cursor(0)[1])
        if not path then
          return
        end
        local filerev = require("trellis.view.filerev")
        if b then
          filerev.open(repo, b, path, { cursor = { line or 1, 0 } })
        else
          vim.cmd.edit(vim.fn.fnameescape(repo.root .. "/" .. path))
          pcall(vim.api.nvim_win_set_cursor, 0, { line or 1, 0 })
        end
      end,
    })
    if opts.on_open then
      opts.on_open(buf)
    end
  end)
end

--- Side-by-side diff of one file through the configured adapter.
---@param repo trellis.Repository
---@param a string?
---@param b string?
---@param opts trellis.DiffOpts
function M.side_by_side(repo, a, b, opts)
  local adapter = adapters.select(config.for_repo(repo.root).views.diff.side_by_side)
  if not adapter then
    return M.open(repo, a or argv.empty_tree(repo.features.sha256), b, opts)
  end
  adapter.open(repo, a, b, opts)
end

return M
