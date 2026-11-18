-- Smoke tests for the test harness itself (tasks.md T003): if these fail, every other suite
-- is meaningless.

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["harness"] = MiniTest.new_set()

T["harness"]["runs on Neovim >= 0.11"] = function()
  eq(vim.fn.has("nvim-0.11"), 1)
end

T["harness"]["runtimepath has no user config or plugins"] = function()
  local function norm(p)
    return (p:gsub("\\", "/"):gsub("/+$", ""))
  end
  local root = norm(vim.fn.getcwd())
  local runtime = norm(vim.env.VIMRUNTIME)
  local mini = root .. "/.tests/deps/mini.test"
  for _, dir in ipairs(vim.opt.runtimepath:get()) do
    dir = norm(dir)
    -- Allowed: the checkout, mini.test, $VIMRUNTIME and its bundled packs (netrw, matchit).
    local prefix = norm(vim.fn.fnamemodify(vim.v.progpath, ":p:h:h"))
    local ok = dir == root
      or dir == mini
      or vim.startswith(dir, runtime)
      or vim.startswith(dir, prefix)
    eq({ dir = dir, allowed = ok }, { dir = dir, allowed = true })
  end
end

T["harness"]["XDG dirs are isolated under .tests/"] = function()
  for _, kind in ipairs({ "CONFIG", "DATA", "STATE", "CACHE" }) do
    local dir = vim.env["XDG_" .. kind .. "_HOME"]:gsub("\\", "/")
    eq(dir:match("/%.tests/xdg/") ~= nil, true)
  end
end

T["harness"]["git ignores global and system config"] = function()
  local res = vim
    .system({ "git", "config", "--show-origin", "--list" }, { cwd = vim.env.TEMP or "/tmp" })
    :wait()
  -- Outside a repository only global/system/command-line config could appear; both are disabled.
  eq(vim.trim(res.stdout or ""), "")
end

return T
