-- Every fixture builds, and the log/show/diff parsers agree with
-- git's own view of each fixture.
local fixtures = require("tests.fixtures")
local argv = require("trellis.git.argv")
local log = require("trellis.git.parse.log")
local show = require("trellis.git.parse.show")
local diff = require("trellis.git.parse.diff")
local Repo = require("tests.helpers.repo")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["at least 40 scenarios with unique names"] = function()
  eq(#fixtures.names() >= 40, true)
end

local REVS = { "--branches", "--remotes", "--tags", "HEAD" }

local function git_log(r)
  local args = { "-c", "core.quotepath=off", "log", "--topo-order", "--format=" .. argv.LOG_FORMAT }
  vim.list_extend(args, REVS)
  local out = r:git(args, { allow_fail = true })
  return out
end

T["log parser matches git on every fixture"] = MiniTest.new_set({
  parametrize = vim.tbl_map(function(n)
    return { n }
  end, fixtures.names()),
})

T["log parser matches git on every fixture"]["fixture"] = function(name)
  local r = fixtures.get(name)
  local expected = r:topo(REVS)
  local commits, errors = log.parse(git_log(r))
  eq(errors, {})
  eq(#commits, #expected)
  for i, c in ipairs(commits) do
    eq({ c.sha, c.parents }, { expected[i].sha, expected[i].parents })
  end
end

T["subjects with control characters survive"] = function()
  local r = fixtures.get("control-chars")
  local commits = log.parse(git_log(r))
  local subjects = vim.tbl_map(function(c)
    return c.subject
  end, commits)
  eq(vim.tbl_contains(subjects, "record\30separator\30twice"), true)
  eq(vim.tbl_contains(subjects, "ends with RS\30"), true)
  eq(vim.tbl_contains(subjects, "escape \27[31mred\27[0m"), true)
end

T["details and file changes on real commits"] = function()
  local r = fixtures.get("rename-chain")
  local function run(inv)
    return r:git(vim.list_extend({ "-c", "core.quotepath=off" }, inv.args))
  end
  local head = r:rev("HEAD")
  local d = show.parse_details(run(argv.G11(head)))
  eq(d.sha, head)
  eq(d.author.name, "Alice")
  eq(d.body, "rename to renamed_thrice")
  local files = show.merge_changes(
    show.parse_numstat(run(argv.G12(head))),
    show.parse_name_status(run(argv.G13(head)))
  )
  eq(#files, 1)
  eq(files[1].status, "R")
  eq(files[1].old_path, "lib/newer.lua")
  eq(files[1].path, "src/renamed_thrice.lua")
  eq({ files[1].added, files[1].removed }, { 1, 1 })

  -- Root commit works thanks to --root.
  local root = r:out({ "rev-list", "--max-parents=0", "HEAD" })
  local rf = show.parse_name_status(run(argv.G13(root)))
  eq(rf, { { status = "A", path = "src/old.lua" } })
end

T["binary numstat and unicode paths"] = function()
  local r = fixtures.get("binary-file")
  local stats = show.parse_numstat(r:git(argv.G12(r:rev("HEAD")).args))
  eq(stats[1].binary, true)
  local u = fixtures.get("unicode-messages")
  local root = u:out({ "rev-list", "--max-parents=0", "HEAD" })
  local ns = show.parse_name_status(
    u:git(vim.list_extend({ "-c", "core.quotepath=off" }, argv.G13(root).args))
  )
  eq(ns[1].path, "tài-liệu.md")
end

T["diff parser on a real rename + edit"] = function()
  local r = fixtures.get("rename-chain")
  local out =
    r:git(vim.list_extend({ "-c", "core.quotepath=off" }, argv.G20("HEAD~1", "HEAD").args))
  local files = diff.parse(out)
  eq(#files, 1)
  eq(files[1].status, "R")
  eq({ files[1].old_path, files[1].new_path }, { "lib/newer.lua", "src/renamed_thrice.lua" })
  eq(#files[1].hunks, 1)
end

T["demo script runs under nvim -l"] = function()
  local dest = Repo.root .. "/.tests/tmp/demo-cli"
  local res = vim
    .system({ vim.v.progpath, "-l", Repo.root .. "/tests/fixtures/build/demo.lua", dest }, {
      env = Repo.git_env,
      text = true,
    })
    :wait()
  eq({ code = res.code, err = res.stderr }, { code = 0, err = "" })
  local r = Repo.open(dest)
  eq(r:out({ "rev-list", "--count", "main..feature/login" }), "6")
  r:destroy()
end

return T
