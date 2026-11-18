--- Fixture repository builder (tasks.md T010). Deterministic: fixed author/committer names,
--- dates advancing 60 s per commit, no signing, global/system git config ignored.
---
--- ```lua
--- local Repo = require("tests.helpers.repo")
--- local r = Repo.new()
--- r:commit({ msg = "root", files = { ["a.txt"] = "a\n" } })
--- r:branch("feature"); r:switch("feature")
--- r:commit({ msg = "f1" }); r:switch("main")
--- r:merge({ "feature" }, { msg = "Merge feature" })
--- local sha = r:rev("HEAD")
--- r:destroy()
--- ```
--- Works inside the test runner and under `nvim -l` (tests/fixtures/build/demo.lua).
local M = {}

---@class tests.Repo
---@field path string
---@field time integer   last used unix time
---@field author { [1]: string, [2]: string }
local Repo = {}
Repo.__index = Repo

local source = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
M.root = vim.fn.fnamemodify(source, ":p:h:h:h"):gsub("\\", "/"):gsub("/$", "")
M.BASE_TIME = 1700000000
M.NULL = vim.fn.has("win32") == 1 and "NUL" or "/dev/null"

local counter = 0

M.git_env = {
  GIT_CONFIG_GLOBAL = M.NULL,
  GIT_CONFIG_NOSYSTEM = "1",
  GIT_TERMINAL_PROMPT = "0",
  LC_ALL = "C",
}

local GIT_FLAGS = {
  "-c",
  "commit.gpgsign=false",
  "-c",
  "tag.gpgsign=false",
  "-c",
  "init.defaultBranch=main",
  "-c",
  "core.autocrlf=false",
  "-c",
  "protocol.file.allow=always",
  "-c",
  "advice.detachedHead=false",
  "-c",
  "merge.conflictStyle=merge",
}

--- Run git synchronously in `cwd`. Errors unless `opts.allow_fail`.
---@return string stdout, vim.SystemCompleted res
function M.git(cwd, args, opts)
  opts = opts or {}
  local cmd = { "git" }
  vim.list_extend(cmd, GIT_FLAGS)
  vim.list_extend(cmd, args)
  local env = vim.tbl_extend("force", M.git_env, opts.env or {})
  local res = vim.system(cmd, { cwd = cwd, env = env, text = true, stdin = opts.stdin }):wait()
  if res.code ~= 0 and not opts.allow_fail then
    error(
      ("git %s failed (%d) in %s:\n%s%s"):format(
        table.concat(args, " "),
        res.code,
        cwd,
        res.stderr or "",
        res.stdout or ""
      ),
      2
    )
  end
  return res.stdout or "", res
end

--- Create a fresh repository (removed and recreated if `opts.path` exists).
---@param opts? { path?: string, branch?: string, object_format?: string, init?: boolean }
---@return tests.Repo
function M.new(opts)
  opts = opts or {}
  local path = opts.path
  if not path then
    counter = counter + 1
    path = ("%s/.tests/tmp/%d-%d"):format(M.root, vim.uv.os_getpid(), counter)
  end
  vim.fn.delete(path, "rf")
  vim.fn.mkdir(path, "p")
  local r = M.open(path)
  if opts.init ~= false then
    local args = { "init", "-q", "-b", opts.branch or "main" }
    if opts.object_format then
      args[#args + 1] = "--object-format=" .. opts.object_format
    end
    r:git(args)
  end
  return r
end

--- Wrap an existing repository directory.
---@return tests.Repo
function M.open(path)
  return setmetatable({
    path = path:gsub("\\", "/"),
    time = M.BASE_TIME,
    author = { "Alice", "alice@example.com" },
  }, Repo)
end

function Repo:git(args, opts)
  return M.git(self.path, args, opts)
end

--- Trimmed stdout.
function Repo:out(args, opts)
  return vim.trim((self:git(args, opts)))
end

function Repo:rev(rev)
  return self:out({ "rev-parse", "--verify", "-q", rev .. "^{commit}" })
end

--- Environment for one commit: next timestamp unless `time` is given.
function Repo:env(time, author)
  if time then
    self.time = time
  else
    self.time = self.time + 60
  end
  local a = author or self.author
  local date = ("%d +0000"):format(self.time)
  return {
    GIT_AUTHOR_NAME = a[1],
    GIT_AUTHOR_EMAIL = a[2],
    GIT_AUTHOR_DATE = date,
    GIT_COMMITTER_NAME = a[1],
    GIT_COMMITTER_EMAIL = a[2],
    GIT_COMMITTER_DATE = date,
  }
end

--- Write files: string = content (binary-safe), false = delete.
---@param files table<string, string|false>
function Repo:write(files)
  local names = vim.tbl_keys(files)
  table.sort(names)
  for _, name in ipairs(names) do
    local content = files[name]
    local full = self.path .. "/" .. name
    if content == false then
      os.remove(full)
    else
      vim.fn.mkdir(vim.fs.dirname(full), "p")
      local f = assert(io.open(full, "wb"))
      f:write(content)
      f:close()
    end
  end
end

function Repo:read(name)
  local f = io.open(self.path .. "/" .. name, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

---@class tests.CommitSpec
---@field msg? string
---@field files? table<string, string|false>
---@field time? integer
---@field author? { [1]: string, [2]: string }
---@field allow_empty_message? boolean

--- Commit (staging everything). Returns nothing; use `r:rev("HEAD")` when the sha is needed.
---@param spec? tests.CommitSpec|string
function Repo:commit(spec)
  if type(spec) == "string" then
    spec = { msg = spec }
  end
  spec = spec or {}
  if spec.files then
    self:write(spec.files)
  end
  self:git({ "add", "-A" })
  local args = { "commit", "-q", "--allow-empty", "--cleanup=verbatim", "-F", "-" }
  if spec.allow_empty_message then
    args[#args + 1] = "--allow-empty-message"
  end
  self:git(args, { env = self:env(spec.time, spec.author), stdin = spec.msg or "commit" })
end

--- Commit and return the new HEAD sha.
function Repo:commit_sha(spec)
  self:commit(spec)
  return self:rev("HEAD")
end

function Repo:branch(name, rev)
  self:git({ "branch", name, rev })
end

function Repo:switch(name)
  self:git({ "switch", "-q", name })
end

function Repo:detach(rev)
  self:git({ "switch", "-q", "--detach", rev })
end

--- Start an orphan branch with an empty index and worktree.
function Repo:orphan(name)
  self:git({ "switch", "-q", "--orphan", name })
end

---@param branches string[]
---@param opts? { msg?: string, strategy?: string, allow_fail?: boolean, unrelated?: boolean, time?: integer }
function Repo:merge(branches, opts)
  opts = opts or {}
  local args = {
    "merge",
    "-q",
    "--no-ff",
    "--no-edit",
    "-m",
    opts.msg or ("Merge " .. table.concat(branches, ", ")),
  }
  if opts.strategy then
    vim.list_extend(args, { "-s", opts.strategy })
  end
  if opts.unrelated then
    args[#args + 1] = "--allow-unrelated-histories"
  end
  vim.list_extend(args, branches)
  return self:git(args, { env = self:env(opts.time), allow_fail = opts.allow_fail })
end

---@param opts? { msg?: string }
function Repo:tag(name, rev, opts)
  local args = { "tag" }
  if opts and opts.msg then
    vim.list_extend(args, { "-a", "-m", opts.msg })
  end
  args[#args + 1] = name
  args[#args + 1] = rev or "HEAD"
  self:git(args, { env = self:env() })
end

function Repo:mv(old, new)
  vim.fn.mkdir(vim.fs.dirname(self.path .. "/" .. new), "p")
  self:git({ "mv", old, new })
end

--- `git update-ref --stdin` with the given instruction lines.
function Repo:update_refs(lines)
  self:git({ "update-ref", "--stdin" }, { stdin = table.concat(lines, "\n") .. "\n" })
end

function Repo:worktree(path, branch)
  self:git({ "worktree", "add", "-q", path, branch })
end

--- Clone this repository into `dest` (extra args e.g. {"--depth=2"}); returns the clone.
---@return tests.Repo
function Repo:clone(dest, args)
  vim.fn.delete(dest, "rf")
  local cmd = { "clone", "-q" }
  vim.list_extend(cmd, args or {})
  vim.list_extend(cmd, { "file://" .. self.path, dest })
  M.git(M.root, cmd)
  return M.open(dest)
end

--- `git log --topo-order` sha/parent lists for given revs (default all branches/tags/HEAD).
---@return { sha: string, parents: string[] }[]
function Repo:topo(revs)
  local args = { "log", "--topo-order", "--format=%H %P" }
  vim.list_extend(args, revs or { "--branches", "--remotes", "--tags", "HEAD" })
  local out = self:git(args, { allow_fail = true })
  local list = {}
  for line in out:gmatch("[^\n]+") do
    local parts = vim.split(line, " ", { trimempty = true })
    list[#list + 1] = { sha = parts[1], parents = { unpack(parts, 2) } }
  end
  return list
end

function Repo:destroy()
  vim.fn.delete(self.path, "rf")
end

M.Repo = Repo
return M
