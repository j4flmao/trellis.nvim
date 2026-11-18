-- Minimal, isolated init for the test suite (tasks.md T003).
--
-- Used both by the test runner (`scripts/test.sh`) and by child Neovim instances started from
-- tests (`MiniTest.new_child_neovim()` + `child.restart({ "-u", "tests/minimal_init.lua" })`).
--
-- Guarantees:
--   * runtimepath = { plugin checkout, mini.test, $VIMRUNTIME } only: no user config or plugins
--   * XDG_* dirs point into .tests/xdg so nothing touches the developer's real state
--   * git ignores global/system config (deterministic fixtures, no user hooks/signing)
--
-- Environment:
--   TRELLIS_MINI_REF    mini.test git ref to install (default below)
--   TRELLIS_TEST_SUITE  unit | integration | e2e | bench (collect only that directory)
--   TRELLIS_TEST_FILE   run a single spec file instead of a whole suite

local is_windows = vim.fn.has("win32") == 1

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
root = root:gsub("\\", "/")
local tests_dir = root .. "/.tests"

-- Isolated XDG directories (inherited by child processes: child Neovim, git hooks, helpers).
for _, kind in ipairs({ "config", "data", "state", "cache" }) do
  local dir = tests_dir .. "/xdg/" .. kind
  vim.fn.mkdir(dir, "p")
  vim.env["XDG_" .. kind:upper() .. "_HOME"] = dir
end

-- Deterministic git: no global/system config, no prompts, C locale for parsed output.
vim.env.GIT_CONFIG_GLOBAL = is_windows and "NUL" or "/dev/null"
vim.env.GIT_CONFIG_NOSYSTEM = "1"
-- GIT_CONFIG_GLOBAL needs git >= 2.32; older git reads $HOME/.gitconfig (and the XDG file,
-- already isolated above): give it an empty home.
local home = tests_dir .. "/home"
vim.fn.mkdir(home, "p")
vim.env.HOME = home
if is_windows then
  vim.env.USERPROFILE = home
end
vim.env.GIT_TERMINAL_PROMPT = "0"
-- Commits made by trellis itself (cherry-pick, revert, annotated tags) need an identity.
vim.env.GIT_AUTHOR_NAME = "Trellis Test"
vim.env.GIT_AUTHOR_EMAIL = "test@example.com"
vim.env.GIT_COMMITTER_NAME = "Trellis Test"
vim.env.GIT_COMMITTER_EMAIL = "test@example.com"
vim.env.LC_ALL = "C"

-- Install mini.test once into .tests/deps.
local mini_ref = vim.env.TRELLIS_MINI_REF or "v0.16.0"
local mini_path = tests_dir .. "/deps/mini.test"
if not vim.uv.fs_stat(mini_path) then
  vim.fn.mkdir(tests_dir .. "/deps", "p")
  local res = vim
    .system({
      "git",
      "clone",
      "--quiet",
      "--depth=1",
      "--branch",
      mini_ref,
      "https://github.com/nvim-mini/mini.test",
      mini_path,
    })
    :wait()
  if res.code ~= 0 then
    io.stderr:write("trellis tests: failed to install mini.test " .. mini_ref .. "\n")
    io.stderr:write(res.stderr or "")
    vim.cmd("cquit 1")
  end
end

-- Keep the install's own runtime dirs (bundled treesitter parsers live in <prefix>/lib/nvim).
local prefix = vim.fs.normalize(vim.fn.fnamemodify(vim.v.progpath, ":p:h:h"))
local rtp = { root, mini_path, vim.env.VIMRUNTIME }
for _, p in ipairs(vim.opt.runtimepath:get()) do
  local n = vim.fs.normalize(p)
  if
    n:sub(1, #prefix) == prefix
    and vim.uv.fs_stat(n .. "/parser")
    and not vim.tbl_contains(rtp, p)
  then
    rtp[#rtp + 1] = p
  end
end
vim.opt.runtimepath = rtp
-- `require("tests.helpers.repo")`, `require("tests.fixtures")`
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
-- Only the runtime's own packs (netrw lives in $VIMRUNTIME/pack/dist/opt since 0.11).
vim.opt.packpath = { vim.env.VIMRUNTIME }
vim.o.swapfile = false
vim.o.shadafile = "NONE"

local function collect_files()
  if vim.env.TRELLIS_TEST_FILE and vim.env.TRELLIS_TEST_FILE ~= "" then
    return { vim.env.TRELLIS_TEST_FILE }
  end
  local suite = vim.env.TRELLIS_TEST_SUITE
  local dirs = suite and { suite } or { "unit", "integration" }
  local files = {}
  for _, dir in ipairs(dirs) do
    vim.list_extend(files, vim.fn.globpath(root .. "/tests/" .. dir, "**/*_spec.lua", true, true))
  end
  table.sort(files)
  return files
end

require("mini.test").setup({
  collect = { find_files = collect_files },
})
