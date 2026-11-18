-- Every invocation in docs/git-commands.md is built with the required global options
-- and environment, and the never-run list is enforced.

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local argv = require("trellis.git.argv")
local runner = require("trellis.git.runner")

local SHA = ("a"):rep(40)

--- One sample invocation per contract ID.
local samples = {
  G01 = { argv.G01() },
  G02 = { argv.G02() },
  G03 = { argv.G03(true), argv.G03(false) },
  G04 = { argv.G04() },
  G05 = { argv.G05("symbolic"), argv.G05("sha") },
  G10 = {
    argv.G10({ revs = { "--branches", "HEAD" }, paths = { "src/" }, order = "topo" }),
    argv.G10({
      revs = { "HEAD" },
      paths = {},
      order = "date",
      author = "alice",
      since = "2 weeks",
      ["until"] = "today",
      grep = "fix",
      pickaxe = { mode = "S", value = "retry" },
      first_parent = true,
      max_count = 10,
    }),
  },
  G11 = { argv.G11(SHA) },
  G12 = { argv.G12(SHA), argv.G12(SHA, SHA), argv.G12(SHA, "cc") },
  G13 = { argv.G13(SHA) },
  G14 = { argv.G14({ SHA, SHA }) },
  G20 = { argv.G20(SHA, nil, "a.txt"), argv.G20(SHA, SHA) },
  G21 = { argv.G21(SHA, "a b.txt"), argv.G21(":2", "a.lua") },
  G22 = { argv.G22(SHA, "a.txt") },
  G23 = { argv.G23("src/x.lua"), argv.G23("src/x.lua", "HEAD~2") },
  G24 = { argv.G24("abc1234") },
  G25 = { argv.G25(SHA, "src/x.lua") },
  G30 = {
    argv.G30({
      path = "a.lua",
      ignore_whitespace = true,
      detect_moves = "copies",
      contents = "x\n",
    }),
  },
  G31 = { argv.G31(SHA, SHA, { "old.lua", "new.lua" }) },
  G32 = { argv.G32(3, 9, "a.lua", "HEAD") },
  G33 = { argv.G33("origin") },
  G40 = { argv.G40(SHA, false), argv.G40(SHA, true) },
  G41 = { argv.G41(SHA) },
  G42 = { argv.G42("origin/main", SHA) },
  G43 = { argv.G43(SHA, SHA) },
  G44 = { argv.G44(SHA, SHA) },
  G45 = { argv.G45(SHA) },
  W01 = { argv.W01({ "start", "create refs/trellis/backup/x/HEAD " .. SHA, "commit" }) },
  W02 = { argv.W02() },
  W10 = { argv.W10(SHA, { rebase_merges = true, update_refs = true, autostash = true }) },
  W11 = { argv.W11("continue"), argv.W11("skip"), argv.W11("abort") },
  W20 = { argv.W20("main"), argv.W20(SHA, true) },
  W21 = { argv.W21("create", "x", SHA), argv.W21("rename", "x", "y"), argv.W21("delete", "x") },
  W22 = {
    argv.W22("create", "v1", SHA),
    argv.W22("create", "v1", SHA, "msg"),
    argv.W22("delete", "v1"),
  },
  W23 = { argv.W23({ SHA, SHA }, true), argv.W23("continue") },
  W24 = { argv.W24(SHA, 1), argv.W24("abort"), argv.W24("skip") },
  W25 = { argv.W25("soft", SHA), argv.W25("hard", SHA) },
  W26 = { argv.W26("add", "a"), argv.W26("ours", "a"), argv.W26("theirs", "a") },
  W27 = { argv.W27() },
  W28 = { argv.W28(SHA) },
  W29 = { argv.W29("a.txt") },
  W30 = { argv.W30("keep", SHA), argv.W30("mixed", SHA) },
  W31 = { argv.W31("trellis: before undo") },
  G07 = { argv.G07() },
  G08 = { argv.G08(SHA, SHA) },
  G09 = { argv.G09({ "refs/heads/main", "refs/tags/v1" }) },
  G15 = { argv.G15(SHA, "HEAD") },
  G16 = { argv.G16("refs/trellis/backup/x/") },
  G26 = { argv.G26(SHA) },
}

local function contract_ids()
  local root = vim.fn.getcwd()
  local text = table.concat(vim.fn.readfile(root .. "/docs/git-commands.md"), "\n")
  local ids = {}
  for id in text:gmatch("\n| ([GW]%d%d) |") do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  return ids
end

T["argv module and contract list the same IDs"] = function()
  eq(argv.ids(), contract_ids())
end

T["every contract ID has a sample here"] = function()
  for _, id in ipairs(contract_ids()) do
    if not argv.non_commands[id] then
      eq({ id = id, has_sample = samples[id] ~= nil }, { id = id, has_sample = true })
    end
  end
end

T["builders report their own contract ID and a valid kind"] = function()
  for id, list in pairs(samples) do
    for _, i in ipairs(list) do
      eq(i.id, id)
      eq(vim.tbl_contains({ "R", "W", "O" }, i.kind), true)
    end
  end
end

T["global options and environment are always applied"] = function()
  for id, list in pairs(samples) do
    for _, i in ipairs(list) do
      local full, env = runner.build("/repo", i.args, { kind = i.kind })
      eq({ id = id, prefix = { unpack(full, 1, 8) } }, {
        id = id,
        prefix = {
          "git",
          "-C",
          "/repo",
          "-c",
          "core.quotepath=off",
          "-c",
          "color.ui=false",
          "--no-pager",
        },
      })
      eq(env.LC_ALL, "C")
      eq(env.GIT_TERMINAL_PROMPT, "0")
      eq(env.GIT_PAGER, "cat")
      eq({ id = id, optional_locks = env.GIT_OPTIONAL_LOCKS }, {
        id = id,
        optional_locks = i.kind == "R" and "0" or nil,
      })
    end
  end
end

T["read-only builders never use write subcommands"] = function()
  local writes = { rebase = true, switch = true, branch = true, tag = true, ["cherry-pick"] = true }
  for _, list in pairs(samples) do
    for _, i in ipairs(list) do
      local sub = runner.subcommand(i.args)
      if i.kind == "R" then
        eq({ sub = sub, write = writes[sub] or false }, { sub = sub, write = false })
      end
    end
  end
end

T["diff-producing commands pin a/ b/ prefixes"] = function()
  for _, i in ipairs({ argv.G20(SHA), argv.G31(SHA, SHA, {}), argv.G32(1, 2, "a"), argv.G45(SHA) }) do
    eq(vim.tbl_contains(i.args, "--src-prefix=a/"), true)
    eq(vim.tbl_contains(i.args, "--dst-prefix=b/"), true)
  end
end

T["log query serialization"] = function()
  local i = argv.G10({ revs = { "main" }, paths = { "src/" }, order = "default" })
  eq(
    i.args,
    { "log", "--no-color", "--format=" .. argv.LOG_FORMAT, "--parents", "main", "--", "src/" }
  )
  local d = argv.G10({ revs = {}, order = "date", first_parent = true })
  eq(d.args[3], "--date-order")
  eq(vim.tbl_contains(d.args, "--first-parent"), true)
end

T["never-run list"] = MiniTest.new_set({
  parametrize = {
    { { "push" } },
    { { "push", "--force", "origin", "main" } },
    { { "-c", "x=y", "gc" } },
    { { "prune" } },
    { { "reflog", "expire", "--all" } },
    { { "reflog", "delete", "HEAD@{1}" } },
    { { "filter-branch" } },
    { { "clean", "-fdx" } },
    { { "stash", "drop" } },
    { { "stash", "clear" } },
    { { "update-ref", "-d", "refs/heads/main" } },
  },
})

T["never-run list"]["is refused"] = function(args)
  MiniTest.expect.error(function()
    runner.build("/repo", args)
  end, "refusing")
end

T["allowed edge cases"] = function()
  runner.build("/repo", { "update-ref", "-d", "refs/trellis/backup/x/HEAD" })
  runner.build("/repo", { "update-ref", "-d", "refs/heads/x" }, { op_id = "op1" })
  runner.build("/repo", { "stash", "create" })
  runner.build("/repo", { "reflog", "show" })
  MiniTest.expect.error(function()
    runner.build("/repo", { "-c", "x=y" })
  end, "without a subcommand")
end

return T
