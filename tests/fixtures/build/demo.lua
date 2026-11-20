-- Demo repository for manual walkthroughs and README recordings.
--
-- As a script:  nvim -l tests/fixtures/build/demo.lua /tmp/trellis-demo
-- As a fixture: require("tests.fixtures").get("demo")
local mode = ...

local function build(r)
  local function api(retry)
    return ("local M = {}\n\nM.timeout = 30\nretry = %d\n\nreturn M\n"):format(retry)
  end
  local form =
    "local form = {}\nform.fields = { 'user', 'password' }\nform.submit = 'Log in'\nreturn form\n"

  r:commit({
    msg = "Initial commit",
    files = { ["README.md"] = "# demo\n", ["src/api.lua"] = api(1) },
  })
  r:commit({ msg = "Add renamed module", files = { ["src/module.lua"] = ("-- module\n"):rep(12) } })
  r:commit({ msg = "Raise retry to 5", files = { ["src/api.lua"] = api(5) } })
  r:tag("v1.0.0", "HEAD", { msg = "v1.0.0" })
  local pushed = r:rev("HEAD")

  -- A merged branch for the graph.
  r:branch("docs")
  r:switch("docs")
  r:commit({ msg = "Write usage docs", files = { ["docs/usage.md"] = "usage\n" } })
  r:switch("main")
  r:commit({ msg = "Lower retry to 3", files = { ["src/api.lua"] = api(3) } })
  r:merge({ "docs" }, { msg = "Merge branch 'docs'" })

  -- File history across renames and a binary asset.
  r:mv("src/module.lua", "src/module2.lua")
  r:commit({ msg = "Rename module (1)" })
  r:mv("src/module2.lua", "src/module3.lua")
  r:commit({ msg = "Rename module (2)" })
  r:mv("src/module3.lua", "src/renamed_thrice.lua")
  r:commit({ msg = "Rename module (3)" })
  r:commit({ msg = "Add logo", files = { ["assets/logo.png"] = "\137PNG\r\n\26\n\0\0\0demo" } })
  r:commit({ msg = "Tweak logo", files = { ["assets/logo.png"] = "\137PNG\r\n\26\n\0\0\1demo" } })
  r:commit({ msg = "Polish", files = { ["README.md"] = "# demo\n\nA demo repository.\n" } })
  r:commit({ msg = "Release prep", files = { ["CHANGELOG.md"] = "## 1.1\n" } })
  r:commit({ msg = "Bump version", files = { ["VERSION"] = "1.1\n" } })

  -- feature/login: 6 messy commits for the rebase planner.
  r:branch("feature/login")
  r:switch("feature/login")
  r.author = { "Bob", "bob@example.com" }
  r:commit({ msg = "add login form", files = { ["src/form.lua"] = form } })
  r:commit({
    msg = "wip",
    files = { ["src/validate.lua"] = "return function(p) return #p > 0 end\n" },
  })
  r:commit({ msg = "style form", files = { ["src/form.lua"] = form:gsub("Log in", "Sign in") } })
  r:commit({
    msg = "add remember me",
    files = { ["src/form.lua"] = form:gsub("'password' }", "'password', 'remember' }") },
  })
  r:commit({
    msg = "fix typo",
    files = {
      ["src/form.lua"] = form
        :gsub("'password' }", "'password', 'remember' }")
        :gsub("Log in", "Sign in"),
    },
  })
  r:commit({ msg = "wire up validation", files = { ["src/login.lua"] = "require('validate')\n" } })
  r.author = { "Alice", "alice@example.com" }
  r:switch("main")

  r:update_refs({ "create refs/remotes/origin/main " .. pushed })
  r:git({ "config", "remote.origin.url", "https://github.com/example/trellis-demo.git" })
  return r
end

if mode == "__fixture_module__" then
  return { { name = "demo", desc = "demo repository", build = build } }
end

-- CLI: nvim -l tests/fixtures/build/demo.lua <dir>
local dest = _G.arg and _G.arg[1]
if not dest then
  io.stderr:write("usage: nvim -l tests/fixtures/build/demo.lua <dir>\n")
  os.exit(2)
end
local script = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local root = vim.fn.fnamemodify(script, ":p:h:h:h:h")
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local Repo = require("tests.helpers.repo")
build(Repo.new({ path = vim.fn.fnamemodify(dest, ":p"):gsub("[/\\]$", "") }))
io.stdout:write("demo repository created in " .. dest .. "\n")
