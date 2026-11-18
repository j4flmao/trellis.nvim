--- Repository discovery, worktrees, in-progress operation state (G01–G03, G06).
local argv = require("trellis.git.argv")
local async = require("trellis.util.async")
local features = require("trellis.git.features")
local runner = require("trellis.git.runner")

local M = {}

---@class trellis.Worktree
---@field path string
---@field head string?      sha; nil for an unborn branch
---@field branch string?    refs/heads/x; nil when detached
---@field detached boolean
---@field bare boolean
---@field locked boolean
---@field prunable boolean
---@field current boolean   the worktree this Repository was discovered from

--- Repositories by commondir .. NUL .. gitdir.
---@type table<string, trellis.Repository>
M.cache = {}

local git_version ---@type integer[]?

local function norm(p)
  return vim.fs.normalize(p)
end

local function is_abs(p)
  return p:sub(1, 1) == "/" or p:match("^%a:[/\\]") ~= nil
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

--- Parse `git worktree list --porcelain [-z]`.
---@param out string
---@param nul boolean output was produced with -z
---@return trellis.Worktree[]
function M.parse_worktrees(out, nul)
  local sep = nul and "\0" or "\n"
  local list, cur = {}, nil
  for _, line in ipairs(vim.split(out, sep, { plain = true })) do
    if line == "" then
      cur = nil
    else
      local key, val = line:match("^(%S+) ?(.*)$")
      if key == "worktree" then
        cur = {
          path = norm(val),
          detached = false,
          bare = false,
          locked = false,
          prunable = false,
          current = false,
        }
        list[#list + 1] = cur
      elseif cur then
        if key == "HEAD" then
          cur.head = val:match("^%x+$") and not val:match("^0+$") and val or nil
        elseif key == "branch" then
          cur.branch = val
        elseif key == "detached" then
          cur.detached = true
        elseif key == "bare" then
          cur.bare = true
        elseif key == "locked" then
          cur.locked = true
        elseif key == "prunable" then
          cur.prunable = true
        end
      end
    end
  end
  return list
end

--- In-progress operation from files in the (worktree-specific) git dir.
---@param gitdir string
---@return trellis.RepoState
function M.read_state(gitdir)
  local state = { kind = "clean", external = false }
  if exists(gitdir .. "/rebase-merge") then
    local dir = gitdir .. "/rebase-merge"
    state.kind = "rebase"
    state.rebase = {
      interactive = exists(dir .. "/interactive"),
      head_name = vim.trim(read_file(dir .. "/head-name") or ""),
      onto = vim.trim(read_file(dir .. "/onto") or ""),
      stopped_sha = vim.trim(read_file(dir .. "/stopped-sha") or "") ~= "" and vim.trim(
        read_file(dir .. "/stopped-sha")
      ) or nil,
      done = tonumber(vim.trim(read_file(dir .. "/msgnum") or "")),
      total = tonumber(vim.trim(read_file(dir .. "/end") or "")),
    }
  elseif exists(gitdir .. "/rebase-apply") then
    state.kind = exists(gitdir .. "/rebase-apply/applying") and "am" or "rebase"
  elseif exists(gitdir .. "/MERGE_HEAD") then
    state.kind = "merge"
  elseif exists(gitdir .. "/REVERT_HEAD") then
    state.kind = "revert"
  elseif exists(gitdir .. "/CHERRY_PICK_HEAD") then
    state.kind = "cherry-pick"
  elseif exists(gitdir .. "/sequencer/todo") then
    -- Multi-commit sequence stopped between commits (no *_HEAD file).
    local first = read_file(gitdir .. "/sequencer/todo") or ""
    state.kind = first:match("^%s*revert") and "revert" or "cherry-pick"
  elseif exists(gitdir .. "/BISECT_LOG") then
    state.kind = "bisect"
  end
  -- Operations trellis starts are recorded by the safety layer (Phase 6); until then every
  -- in-progress operation is external.
  state.external = state.kind ~= "clean"
  return state
end

local function run(root, inv)
  return async.await(function(cb)
    runner.run(root, inv.args, { kind = inv.kind, ok_codes = inv.ok_codes }, cb)
  end)
end

--- Cached `git version` (one process per Neovim session).
---@param cb fun(err: string?, version: integer[]?)
function M.git_version(cb)
  if git_version then
    return cb(nil, git_version)
  end
  runner.run(nil, argv.G02().args, nil, function(err, res)
    if err then
      return cb(err)
    end
    local v = features.parse_version(res.stdout)
    if not v then
      return cb("cannot parse git version: " .. vim.trim(res.stdout))
    end
    git_version = v
    cb(nil, v)
  end)
end

--- Discover the repository containing `path` (a directory). Async.
---@param path string
---@param cb fun(err: string?, repo: trellis.Repository?)
function M.discover(path, cb)
  async.run(function()
    local verr, version = async.await(M.git_version)
    if verr then
      return verr
    end
    if not features.at_least(version, features.MIN) then
      return ("git %s is too old (trellis needs >= %s); see :checkhealth trellis"):format(
        features.version_string(version),
        features.version_string(features.MIN)
      )
    end

    local err, res = run(path, argv.G01())
    if err then
      local msg = res and vim.trim(res.stderr) or err
      if msg:find("not a git repository", 1, true) then
        return "not a git repository: " .. path
      elseif msg:find("must be run in a work tree", 1, true) then
        return "bare repositories are not supported: " .. path
      end
      return err
    end
    local lines = vim.split(vim.trim(res.stdout), "\n", { plain = true })
    local root, gitdir, commondir, shallow, object_format = unpack(lines)
    root, gitdir = norm(root), norm(gitdir)
    if not is_abs(commondir) then
      commondir = path .. "/" .. commondir
    end
    commondir = norm(vim.fn.fnamemodify(commondir, ":p"))
    commondir = commondir:gsub("/$", "")

    local feats = features.detect(version, commondir, object_format)
    local werr, wres = run(root, argv.G03(feats.worktree_z))
    local worktrees = werr and {} or M.parse_worktrees(wres.stdout, feats.worktree_z)
    for _, wt in ipairs(worktrees) do
      wt.current = wt.path == root
    end

    local key = commondir .. "\0" .. gitdir
    local repo = M.cache[key] or {}
    repo.root = root
    repo.gitdir = gitdir
    repo.commondir = commondir
    repo.shallow = shallow == "true"
    repo.features = feats
    repo.worktrees = worktrees
    repo.state = M.read_state(gitdir)
    M.cache[key] = repo
    return nil, repo
  end, function(err, msg, repo)
    if err then
      return cb(err)
    end
    if msg then
      return cb(msg)
    end
    cb(nil, repo)
  end)
end

--- Refresh the in-progress state (cheap, file stats only).
---@param repo trellis.Repository
function M.refresh_state(repo)
  repo.state = M.read_state(repo.gitdir)
  return repo.state
end

--- For tests: forget the cached git version.
function M._reset()
  git_version = nil
  M.cache = {}
end

return M
