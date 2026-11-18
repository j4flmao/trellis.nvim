--- What a window shows, for commands that act on "the current file": a working-copy file or a
--- trellis:// file-at-revision buffer. Also maps working-copy lines to a commit's version.
local argv = require("trellis.git.argv")
local diff = require("trellis.git.parse.diff")
local linemap = require("trellis.linemap")
local runner = require("trellis.git.runner")

local M = {}

---@class trellis.FileTarget
---@field repo trellis.Repository
---@field path string       repo-relative
---@field sha string?       nil = working copy
---@field buf integer

--- Resolve the file shown in `buf` (default current) to a repository path.
---@param cb fun(err: string?, t: trellis.FileTarget?)
function M.current(cb, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local vars = vim.b[buf].trellis
  local dir, file, sha, path
  if type(vars) == "table" and vars.view == "filerev" and vars.sha then
    dir, sha, path = vars.repo, vars.sha, vars.path
  else
    local name = vim.api.nvim_buf_get_name(buf)
    if name == "" or vim.bo[buf].buftype ~= "" then
      return cb("not a file buffer")
    end
    file = vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
    dir = vim.fs.dirname(file)
  end
  require("trellis.git.repo").discover(dir, function(err, repo)
    if err then
      return cb(err)
    end
    if not path then
      if file:sub(1, #repo.root + 1) ~= repo.root .. "/" then
        return cb("file is outside the repository")
      end
      path = file:sub(#repo.root + 2)
    end
    cb(nil, { repo = repo, path = path, sha = sha, buf = buf })
  end)
end

--- Map working-copy lines of `path` to the version at `rev` (lines added since map to the
--- nearest line above). `cb(lines)` keeps the input order.
---@param repo trellis.Repository
---@param rev string
---@param path string
---@param lines integer[]
---@param cb fun(mapped: integer[])
function M.map_worktree_lines(repo, rev, path, lines, cb)
  local inv = argv.G31(rev, nil, { path })
  runner.run(repo.root, inv.args, { kind = inv.kind }, function(err, res)
    local hunks = {}
    if not err then
      for _, f in ipairs(diff.parse(res.stdout)) do
        vim.list_extend(hunks, f.hunks)
      end
    end
    local out = {}
    for i, l in ipairs(lines) do
      out[i] = linemap.map_line(hunks, l, "backward")
    end
    cb(out)
  end)
end

return M
