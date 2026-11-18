-- T083 / SC-003: for every scripted plan, trellis's executor and native `git rebase -i` with the
-- same todo produce identical trees and messages, and :Trellis undo restores the original refs
-- and worktree exactly. Two byte-identical repositories are built per plan (fixed dates).
local Repo = require("tests.helpers.repo")
local S = require("tests.helpers.safety")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function build(r)
  r:commit({
    msg = "base",
    files = { ["base.txt"] = "b\n", ["shared.txt"] = "1\n2\n3\n4\n5\n6\n7\n8\n" },
  })
  for i = 1, 6 do
    r:commit({
      msg = ("c%d subject\n\nbody of c%d\n"):format(i, i),
      files = { ["f" .. i .. ".txt"] = "c" .. i .. "\n" },
    })
  end
  r:branch("stack-1", "HEAD~3")
  r:branch("stack-2", "HEAD~1")
end

local function build_autosquash(r)
  r:commit({ msg = "base", files = { ["base.txt"] = "b\n" } })
  r:commit({ msg = "add form", files = { ["form.txt"] = "form\n" } })
  r:commit({ msg = "add api", files = { ["api.txt"] = "api\n" } })
  r:commit({ msg = "fixup! add form", files = { ["form.txt"] = "form v2\n" } })
  r:commit({ msg = "squash! add api\n\nmore api", files = { ["api.txt"] = "api v2\n" } })
  r:commit({ msg = "amend! add form\n\nadd form (amended)", files = { ["form.txt"] = "form v3\n" } })
  r:commit({ msg = "unrelated", files = { ["u.txt"] = "u\n" } })
end

--- Plans: `lines(c)` with c[i] = sha of commit i (oldest first); `messages` keyed by commit
--- index (chain head); `stop(r, round)` runs at each edit/break stop.
local PLANS = {
  {
    "reverse order",
    function(c)
      return {
        "pick " .. c[6],
        "pick " .. c[5],
        "pick " .. c[4],
        "pick " .. c[3],
        "pick " .. c[2],
        "pick " .. c[1],
      }
    end,
  },
  {
    "swap two",
    function(c)
      return {
        "pick " .. c[1],
        "pick " .. c[3],
        "pick " .. c[2],
        "pick " .. c[4],
        "pick " .. c[5],
        "pick " .. c[6],
      }
    end,
  },
  {
    "last to first",
    function(c)
      return {
        "pick " .. c[6],
        "pick " .. c[1],
        "pick " .. c[2],
        "pick " .. c[3],
        "pick " .. c[4],
        "pick " .. c[5],
      }
    end,
  },
  {
    "first to last",
    function(c)
      return {
        "pick " .. c[2],
        "pick " .. c[3],
        "pick " .. c[4],
        "pick " .. c[5],
        "pick " .. c[6],
        "pick " .. c[1],
      }
    end,
  },
  {
    "interleave",
    function(c)
      return {
        "pick " .. c[2],
        "pick " .. c[1],
        "pick " .. c[4],
        "pick " .. c[3],
        "pick " .. c[6],
        "pick " .. c[5],
      }
    end,
  },
  {
    "drop one",
    function(c)
      return {
        "pick " .. c[1],
        "drop " .. c[2],
        "pick " .. c[3],
        "pick " .. c[4],
        "pick " .. c[5],
        "pick " .. c[6],
      }
    end,
  },
  {
    "drop first and last",
    function(c)
      return {
        "drop " .. c[1],
        "pick " .. c[2],
        "pick " .. c[3],
        "pick " .. c[4],
        "pick " .. c[5],
        "drop " .. c[6],
      }
    end,
  },
  {
    "drop by deleting lines",
    function(c)
      return { "pick " .. c[1], "pick " .. c[3], "pick " .. c[5] }
    end,
  },
  {
    "keep only one",
    function(c)
      return { "pick " .. c[4] }
    end,
  },
  {
    "fixup",
    function(c)
      return {
        "pick " .. c[1],
        "pick " .. c[2],
        "fixup " .. c[3],
        "pick " .. c[4],
        "pick " .. c[5],
        "pick " .. c[6],
      }
    end,
  },
  {
    "squash with default message",
    function(c)
      return {
        "pick " .. c[1],
        "pick " .. c[2],
        "squash " .. c[3],
        "pick " .. c[4],
        "pick " .. c[5],
        "pick " .. c[6],
      }
    end,
  },
  {
    "squash with planned message",
    function(c)
      return {
        "pick " .. c[1],
        "pick " .. c[2],
        "squash " .. c[3],
        "pick " .. c[4],
        "pick " .. c[5],
        "pick " .. c[6],
      }
    end,
    messages = { [2] = "Squashed two and three\n\nPlanned body.\n" },
  },
  {
    "squash chain of three with message",
    function(c)
      return {
        "pick " .. c[1],
        "pick " .. c[2],
        "squash " .. c[3],
        "squash " .. c[4],
        "pick " .. c[5],
        "pick " .. c[6],
      }
    end,
    messages = { [2] = "Three in one\n" },
  },
  {
    "fixup chain into the first, reordered",
    function(c)
      return {
        "pick " .. c[1],
        "fixup " .. c[4],
        "fixup " .. c[5],
        "pick " .. c[2],
        "pick " .. c[3],
        "pick " .. c[6],
      }
    end,
  },
  {
    "squash into the first commit",
    function(c)
      return {
        "pick " .. c[1],
        "squash " .. c[2],
        "pick " .. c[3],
        "pick " .. c[4],
        "pick " .. c[5],
        "pick " .. c[6],
      }
    end,
    messages = { [1] = "First and second\n" },
  },
  {
    "fixup -C",
    needs = { 2, 32 },
    function(c)
      return {
        "pick " .. c[1],
        "pick " .. c[2],
        "fixup -C " .. c[3],
        "pick " .. c[4],
        "pick " .. c[5],
        "pick " .. c[6],
      }
    end,
  },
  {
    "fixup -C chain",
    needs = { 2, 32 },
    function(c)
      return {
        "pick " .. c[1],
        "fixup " .. c[2],
        "fixup -C " .. c[3],
        "pick " .. c[4],
        "pick " .. c[5],
        "pick " .. c[6],
      }
    end,
  },
  {
    "fixup -c with planned message",
    needs = { 2, 32 },
    function(c)
      return {
        "pick " .. c[1],
        "pick " .. c[2],
        "fixup -c " .. c[3],
        "pick " .. c[4],
        "pick " .. c[5],
        "pick " .. c[6],
      }
    end,
    messages = { [2] = "Edited by fixup -c\n" },
  },
  {
    "reword one",
    function(c)
      return {
        "pick " .. c[1],
        "reword " .. c[2],
        "pick " .. c[3],
        "pick " .. c[4],
        "pick " .. c[5],
        "pick " .. c[6],
      }
    end,
    messages = { [2] = "Reworded second\n\nNew body.\n" },
  },
  {
    "reword first and last",
    function(c)
      return {
        "reword " .. c[1],
        "pick " .. c[2],
        "pick " .. c[3],
        "pick " .. c[4],
        "pick " .. c[5],
        "reword " .. c[6],
      }
    end,
    messages = { [1] = "New first\n", [6] = "New last\n" },
  },
  {
    "reword without a planned message keeps it",
    function(c)
      return {
        "pick " .. c[1],
        "reword " .. c[2],
        "pick " .. c[3],
        "pick " .. c[4],
        "pick " .. c[5],
        "pick " .. c[6],
      }
    end,
  },
  {
    "reword and fixup into it",
    function(c)
      return {
        "reword " .. c[1],
        "fixup " .. c[2],
        "pick " .. c[3],
        "pick " .. c[4],
        "pick " .. c[5],
        "pick " .. c[6],
      }
    end,
    messages = { [1] = "Reworded with fixup\n" },
  },
  {
    "exec after a commit",
    function(c)
      return {
        "pick " .. c[1],
        "pick " .. c[2],
        "pick " .. c[3],
        "exec git log -1 --format=%s",
        "pick " .. c[4],
        "pick " .. c[5],
        "pick " .. c[6],
      }
    end,
  },
  {
    "exec between every commit",
    function(c)
      return {
        "pick " .. c[1],
        "exec true",
        "pick " .. c[2],
        "exec true",
        "pick " .. c[3],
        "exec true",
        "pick " .. c[4],
        "pick " .. c[5],
        "pick " .. c[6],
      }
    end,
  },
  {
    "break then continue",
    function(c)
      return {
        "pick " .. c[1],
        "pick " .. c[2],
        "break",
        "pick " .. c[3],
        "pick " .. c[4],
        "pick " .. c[5],
        "pick " .. c[6],
      }
    end,
    stop = function() end,
  },
  {
    "edit stop and amend",
    function(c)
      return {
        "pick " .. c[1],
        "pick " .. c[2],
        "edit " .. c[3],
        "pick " .. c[4],
        "pick " .. c[5],
        "pick " .. c[6],
      }
    end,
    stop = function(r)
      r:write({ ["f3.txt"] = "c3 amended\n" })
      r:git({ "add", "f3.txt" })
      r:git(
        { "commit", "-q", "--amend", "-m", "c3 amended during edit" },
        { env = r:env(1800000000) }
      )
    end,
  },
  {
    "two edit stops",
    function(c)
      return {
        "pick " .. c[1],
        "edit " .. c[2],
        "pick " .. c[3],
        "edit " .. c[4],
        "pick " .. c[5],
        "pick " .. c[6],
      }
    end,
    stop = function() end,
  },
  {
    "update-ref keeps a stacked branch on its commit",
    needs = { 2, 38 },
    function(c)
      return {
        "pick " .. c[1],
        "pick " .. c[2],
        "reword " .. c[3],
        "update-ref refs/heads/stack-1",
        "pick " .. c[4],
        "pick " .. c[5],
        "pick " .. c[6],
      }
    end,
    messages = { [3] = "Stack tip, reworded\n" },
    refs = { "refs/heads/stack-1" },
  },
  {
    "two update-refs while reordering",
    needs = { 2, 38 },
    function(c)
      return {
        "pick " .. c[2],
        "pick " .. c[1],
        "pick " .. c[3],
        "update-ref refs/heads/stack-1",
        "pick " .. c[4],
        "pick " .. c[5],
        "update-ref refs/heads/stack-2",
        "pick " .. c[6],
      }
    end,
    refs = { "refs/heads/stack-1", "refs/heads/stack-2" },
  },
  {
    "combined: reorder, fold, drop, reword, exec",
    function(c)
      return {
        "reword " .. c[2],
        "pick " .. c[1],
        "fixup " .. c[4],
        "exec true",
        "drop " .. c[3],
        "pick " .. c[6],
        "squash " .. c[5],
      }
    end,
    messages = { [2] = "Second becomes first\n", [6] = "Six and five\n" },
  },
  {
    "squash then fixup in one chain",
    function(c)
      return {
        "pick " .. c[1],
        "squash " .. c[2],
        "fixup " .. c[3],
        "pick " .. c[4],
        "pick " .. c[5],
        "pick " .. c[6],
      }
    end,
    messages = { [1] = "Chain head\n" },
  },
  {
    "reverse with folds",
    function(c)
      return {
        "pick " .. c[6],
        "fixup " .. c[5],
        "pick " .. c[4],
        "squash " .. c[3],
        "pick " .. c[2],
        "pick " .. c[1],
      }
    end,
    messages = { [4] = "Four and three\n" },
  },
}

local function q(s)
  return '"' .. s:gsub("\\", "/") .. '"'
end

local function commits(r, base)
  local out = r:git({ "log", "--reverse", "--format=%T%x00%B%x1e", base .. "..HEAD" })
  return out
end

--- Native twin: git rebase -i with `cp <todo>` as sequence editor and the same message helper.
local function native(r, base, todo_text, messages, stop)
  local dir = r.path .. "-native"
  vim.fn.mkdir(dir .. "/msg", "p")
  local todo_file = dir .. "/todo"
  vim.fn.writefile(vim.split(todo_text, "\n", { plain = true }), todo_file, "b")
  for sha, m in pairs(messages) do
    local f = assert(io.open(dir .. "/msg/" .. sha .. ".txt", "wb"))
    f:write(m)
    f:close()
  end
  local env = {
    GIT_SEQUENCE_EDITOR = "cp " .. q(todo_file),
    GIT_EDITOR = ("%s -l %s %s %s"):format(
      q(vim.v.progpath),
      q(Repo.root .. "/helpers/msg_editor.lua"),
      q(r.path .. "/.git"),
      q(dir .. "/msg")
    ),
  }
  local _, res = r:git({ "rebase", "-i", base }, { env = env, allow_fail = true })
  local round = 0
  while vim.uv.fs_stat(r.path .. "/.git/rebase-merge") do
    round = round + 1
    assert(round < 10, "native rebase did not finish: " .. (res.stderr or ""))
    if stop then
      stop(r, round)
    end
    _, res = r:git({ "rebase", "--continue" }, { env = env, allow_fail = true })
  end
  assert(res.code == 0, "native rebase failed: " .. (res.stderr or ""))
end

local function run_case(spec, builder, opts)
  opts = opts or {}
  local a, b = Repo.new(), Repo.new()
  builder(a)
  builder(b)
  eq(a:rev("HEAD"), b:rev("HEAD")) -- byte-identical twins
  local base = a:rev(opts.base or "HEAD~6")
  local repo = S.repo(a.path)
  S.auto_confirm(true)
  local before = S.state(a)

  local plan, perr = S.run(function()
    require("trellis.safety.ops").spawn(function() end)
    require("trellis.util.async").await(function(cb)
      require("trellis.git.refs").load(repo, cb)
    end)
    return require("trellis.rebase.plan").from_range(repo, base, opts.plan_opts or {})
  end)
  eq(perr, nil)
  local c = plan.original
  local lines, messages = {}, {}
  if spec.lines then
    for _, l in ipairs(spec.lines(c)) do
      lines[#lines + 1] = l
    end
  else
    lines = require("trellis.rebase.plan").to_lines(plan)
  end
  for idx, m in pairs(spec.messages or {}) do
    plan.messages[c[idx]] = m
    messages[c[idx]] = m
  end
  local entries, diags = require("trellis.rebase.plan").parse_lines(plan, lines)
  for _, d in ipairs(diags) do
    eq({ diag = d.severity ~= "error" and "ok" or d.message }, { diag = "ok" })
  end
  local op, err = S.run(function()
    return require("trellis.rebase.execute").run(repo, plan, entries, diags)
  end)
  eq(err, nil)
  local round = 0
  while op and op.status == "stopped" do
    round = round + 1
    assert(round < 10, "trellis rebase did not finish")
    if spec.stop then
      spec.stop(a, round)
    end
    op, err = S.run(function()
      return require("trellis.safety.ops").control(repo, "continue")
    end)
    eq(err, nil)
    if require("trellis.git.repo").refresh_state(repo).kind == "clean" then
      break
    end
  end
  eq(require("trellis.git.repo").refresh_state(repo).kind, "clean")

  native(
    b,
    b:rev(opts.base or "HEAD~6"),
    require("trellis.rebase.plan").to_todo(plan, entries),
    messages,
    spec.stop
  )

  eq(commits(a, base), commits(b, base))
  for _, ref in ipairs(spec.refs or {}) do
    eq(
      { ref = ref, tree = a:out({ "log", "-1", "--format=%T%x00%B", ref }) },
      { ref = ref, tree = b:out({ "log", "-1", "--format=%T%x00%B", ref }) }
    )
  end

  -- Undo restores the exact original state.
  local u, uerr = S.run(function()
    return require("trellis.safety.ops").undo(repo)
  end)
  eq(uerr, nil)
  eq(u.status, "done")
  local after = S.state(a)
  eq(after.refs, before.refs)
  eq(
    { after.head, after.symbolic, after.worktree, after.index },
    { before.head, before.symbolic, before.worktree, before.index }
  )
end

T["equivalence with native rebase -i"] = MiniTest.new_set({
  parametrize = vim.tbl_map(function(p)
    return { p[1] }
  end, PLANS),
})

T["equivalence with native rebase -i"]["plan"] = function(name)
  for _, p in ipairs(PLANS) do
    if p[1] == name then
      if p.needs then
        require("tests.helpers.gitver").require(p.needs, name)
      end
      return run_case({ lines = p[2], messages = p.messages, stop = p.stop, refs = p.refs }, build)
    end
  end
  error("unknown plan " .. name)
end

T["autosquash plan equals git rebase -i --autosquash"] = function()
  local a, b = Repo.new(), Repo.new()
  build_autosquash(a)
  build_autosquash(b)
  local repo = S.repo(a.path)
  S.auto_confirm(true)
  local base = a:rev("HEAD~6")
  local plan = S.run(function()
    return require("trellis.rebase.plan").from_range(repo, base, { autosquash = true })
  end)
  local lines = require("trellis.rebase.plan").to_lines(plan)
  -- git < 2.32 has no `amend!` commits: the amend stays a pick (natively too).
  local amend =
    require("trellis.git.features").at_least(require("tests.helpers.gitver").version(), { 2, 32 })
  eq(
    vim.tbl_map(function(l)
      return l:match("^(%S+)")
    end, lines),
    amend and { "pick", "fixup", "fixup", "pick", "squash", "pick" }
      or { "pick", "fixup", "pick", "squash", "pick", "pick" }
  )
  local entries, diags = require("trellis.rebase.plan").parse_lines(plan, lines)
  local op, err = S.run(function()
    return require("trellis.rebase.execute").run(repo, plan, entries, diags)
  end)
  eq({ err, op.status }, { nil, "done" })
  -- Native: git builds its own autosquash todo (sequence editor accepts it unchanged).
  local env = {
    GIT_SEQUENCE_EDITOR = "true",
    GIT_EDITOR = ("%s -l %s %s %s"):format(
      q(vim.v.progpath),
      q(Repo.root .. "/helpers/msg_editor.lua"),
      q(b.path .. "/.git"),
      q(b.path .. "-none")
    ),
  }
  local _, res = b:git(
    { "rebase", "-i", "--autosquash", b:rev("HEAD~6") },
    { env = env, allow_fail = true }
  )
  eq(res.code, 0)
  eq(commits(a, base), commits(b, base))
end

return require("tests.helpers.child").run_in_child(T, "tests/e2e/rebase_equivalence_spec.lua")
