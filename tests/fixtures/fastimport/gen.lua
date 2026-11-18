-- Synthetic large repository generator via `git fast-import` (tasks.md T012).
--
-- As a script:
--   nvim -l tests/fixtures/fastimport/gen.lua <dir> [--commits N] [--merge-ratio R]
--                                               [--branches B] [--seed S]
-- As a module:
--   require("tests.fixtures.fastimport.gen").build(dir, { commits = 200000 })
--
-- Deterministic for given parameters (own PRNG, fixed dates). The result is cached: if <dir>
-- holds a repository generated with the same parameters, nothing is done.
local M = {}

M.defaults = { commits = 200000, merge_ratio = 0.15, branches = 8, seed = 1 }

--- Park–Miller minimal standard PRNG (portable, no math.random state).
local function prng(seed)
  local state = seed % 2147483647
  if state <= 0 then
    state = state + 2147483646
  end
  return function()
    state = (state * 16807) % 2147483647
    return state / 2147483647
  end
end

--- fast-import stream text for the given options.
---@param o { commits: integer, merge_ratio: number, branches: integer, seed: integer }
---@return string
function M.stream(o)
  local rand = prng(o.seed)
  local out = {}
  local heads = {} -- branch index -> mark of its tip
  local t = 1600000000
  local function emit(s)
    out[#out + 1] = s
  end
  for mark = 1, o.commits do
    local b = math.floor(rand() * o.branches) + 1
    if mark == 1 then
      b = 1
    end
    t = t + 60
    local msg = ("commit %d on b%d"):format(mark, b)
    emit(("commit refs/heads/b%d\nmark :%d\n"):format(b, mark))
    emit(
      ("author Gen <gen@example.com> %d +0000\ncommitter Gen <gen@example.com> %d +0000\n"):format(
        t,
        t
      )
    )
    emit(("data %d\n%s\n"):format(#msg, msg))
    local from = heads[b] or (mark > 1 and heads[1]) or nil
    if from then
      emit(("from :%d\n"):format(from))
      -- Merge another branch tip now and then.
      if rand() < o.merge_ratio then
        local other = math.floor(rand() * o.branches) + 1
        if other ~= b and heads[other] and heads[other] ~= from then
          emit(("merge :%d\n"):format(heads[other]))
        end
      end
    end
    local content = ("%d\n"):format(mark)
    emit(("M 644 inline b%d.txt\ndata %d\n%s\n"):format(b, #content, content))
    heads[b] = mark
  end
  emit("done\n")
  return table.concat(out)
end

local function key_of(o)
  return ("commits=%d merge_ratio=%s branches=%d seed=%d"):format(
    o.commits,
    o.merge_ratio,
    o.branches,
    o.seed
  )
end

--- Build (or reuse) the repository at `dir`. Returns the directory.
---@param dir string
---@param opts? table
---@return string
function M.build(dir, opts)
  local o = vim.tbl_extend("force", M.defaults, opts or {})
  local key = key_of(o)
  local marker = dir .. "/.git/trellis-synthetic"
  local f = io.open(marker, "rb")
  if f then
    local old = f:read("*a")
    f:close()
    if old == key then
      return dir
    end
  end
  vim.fn.delete(dir, "rf")
  vim.fn.mkdir(dir, "p")
  local env = {
    GIT_CONFIG_GLOBAL = vim.fn.has("win32") == 1 and "NUL" or "/dev/null",
    GIT_CONFIG_NOSYSTEM = "1",
  }
  local function git(args, stdin)
    local cmd = { "git", "-C", dir }
    vim.list_extend(cmd, args)
    local res = vim.system(cmd, { env = env, stdin = stdin, text = true }):wait()
    if res.code ~= 0 then
      error(("git %s failed: %s"):format(table.concat(args, " "), res.stderr))
    end
  end
  git({ "init", "-q", "-b", "b1" })
  git({ "fast-import", "--quiet", "--done" }, M.stream(o))
  git({ "commit-graph", "write", "--reachable" })
  local out = assert(io.open(marker, "wb"))
  out:write(key)
  out:close()
  return dir
end

if ... == "__fixture_module__" or not (_G.arg and _G.arg[0] and _G.arg[0]:match("gen%.lua$")) then
  return M
end

-- CLI
local args = _G.arg
local dir = args[1]
if not dir then
  io.stderr:write(
    "usage: nvim -l tests/fixtures/fastimport/gen.lua <dir> [--commits N] [--merge-ratio R] [--branches B] [--seed S]\n"
  )
  os.exit(2)
end
local opts = {}
local i = 2
while i <= #args do
  local k, v = args[i], args[i + 1]
  local name = k:match("^%-%-(.+)$")
  if not name or not v then
    io.stderr:write("bad argument: " .. tostring(k) .. "\n")
    os.exit(2)
  end
  opts[name:gsub("%-", "_")] = tonumber(v)
  i = i + 2
end
local started = vim.uv.hrtime()
M.build(vim.fn.fnamemodify(dir, ":p"):gsub("[/\\]$", ""), opts)
io.stdout:write(
  ("synthetic repository ready in %s (%.1f s)\n"):format(dir, (vim.uv.hrtime() - started) / 1e9)
)
