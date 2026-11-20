--- Fixture scenarios: discovery and on-disk cache.
---
--- Scenario files live in tests/fixtures/build/*.lua and return a list of
--- `{ name, desc, build = function(r, ctx) ... end }`. `build` may return a different Repo
--- (e.g. a shallow clone) to replace the initialized one.
---
--- Built fixtures are cached in .tests/fixtures/<name>; the cache key covers the scenario file
--- and the builder helper, so editing either rebuilds. Cached fixtures are shared: tests must
--- not modify them — use `fixtures.fresh(name)` for a private copy.
local Repo = require("tests.helpers.repo")

local M = {}

M.files = { "basic", "merges", "refs", "content", "special", "demo" }
M.dir = Repo.root .. "/.tests/fixtures"

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local scenarios ---@type table[]?
local by_name = {}

---@return { name: string, desc: string, build: function, file: string }[]
function M.list()
  if scenarios then
    return scenarios
  end
  scenarios = {}
  for _, file in ipairs(M.files) do
    local path = Repo.root .. "/tests/fixtures/build/" .. file .. ".lua"
    local list = assert(loadfile(path))("__fixture_module__")
    for _, s in ipairs(list) do
      assert(not by_name[s.name], "duplicate fixture name " .. s.name)
      s.file = path
      scenarios[#scenarios + 1] = s
      by_name[s.name] = s
    end
  end
  return scenarios
end

---@return string[]
function M.names()
  return vim.tbl_map(function(s)
    return s.name
  end, M.list())
end

local function cache_key(s)
  return vim.fn.sha256(read(s.file) .. read(Repo.root .. "/tests/helpers/repo.lua") .. s.name)
end

--- Build scenario `name` at `path` (replacing anything there).
---@return tests.Repo
function M.build(name, path)
  M.list()
  local s = assert(by_name[name], "unknown fixture " .. name)
  local r = Repo.new({ path = path })
  local ctx = {
    --- Auxiliary repository next to the fixture (submodule sources, clone origins, worktrees).
    aux = function(suffix, opts)
      return Repo.new(vim.tbl_extend("force", opts or {}, { path = path .. ".aux-" .. suffix }))
    end,
    aux_path = function(suffix)
      return path .. ".aux-" .. suffix
    end,
  }
  local result = s.build(r, ctx) or r
  return result
end

--- Cached, read-only fixture.
---@return tests.Repo
function M.get(name)
  M.list()
  local s = assert(by_name[name], "unknown fixture " .. name)
  local path = M.dir .. "/" .. name
  local key_file = path .. ".key"
  local key = cache_key(s)
  local f = io.open(key_file, "rb")
  local old = f and f:read("*a")
  if f then
    f:close()
  end
  if old == key and vim.uv.fs_stat(path) then
    return Repo.open(path)
  end
  os.remove(key_file)
  for _, p in ipairs(vim.fn.glob(path .. ".aux-*", true, true)) do
    vim.fn.delete(p, "rf")
  end
  vim.fn.mkdir(M.dir, "p")
  local r = M.build(name, path)
  local out = assert(io.open(key_file, "wb"))
  out:write(key)
  out:close()
  return r
end

--- Private, writable copy built from scratch in a temp dir.
---@return tests.Repo
function M.fresh(name)
  local tmp = Repo.new()
  local path = tmp.path
  return M.build(name, path)
end

return M
