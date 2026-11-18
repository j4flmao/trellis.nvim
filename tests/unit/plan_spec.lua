-- T080 (plan model), T081 (simulate), T085 (helpers run via nvim -l).
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local plan_mod = require("trellis.rebase.plan")
local simulate = require("trellis.rebase.simulate")
local Repo = require("tests.helpers.repo")

-- Distinct 7-character prefixes, like real shas.
local function sha(n)
  return ("%02x"):format(n):rep(20)
end

--- A plan over commits 1..n (oldest first) with subjects s1..sn.
local function fake_plan(n, subjects)
  local original, subj = {}, {}
  for i = 1, n do
    original[i] = sha(i)
    subj[sha(i)] = subjects and subjects[i] or ("s" .. i)
  end
  local entries = {}
  for i = 1, n do
    entries[i] = { action = "pick", sha = original[i], subject = subj[original[i]] }
  end
  return {
    id = "p",
    base = sha(999),
    onto = sha(999),
    head_ref = "refs/heads/main",
    head_sha = original[n],
    original = original,
    subjects = subj,
    published = {},
    messages = {},
    entries = entries,
    opts = { order = "oldest_first" },
  }
end

local function short(i)
  return sha(i):sub(1, 7)
end

T["plan"] = MiniTest.new_set()

T["plan"]["lines round trip and parse with aliases"] = function()
  local p = fake_plan(3)
  local lines = plan_mod.to_lines(p)
  eq(
    lines,
    { "pick " .. short(1) .. " s1", "pick " .. short(2) .. " s2", "pick " .. short(3) .. " s3" }
  )
  lines[2] = "f " .. short(2) .. " anything (subjects are ignored)"
  lines[3] = "F " .. short(3)
  local entries, diags = plan_mod.parse_lines(p, lines)
  eq(diags, {})
  eq(
    vim.tbl_map(function(e)
      return e.action
    end, entries),
    { "pick", "fixup", "fixup_C" }
  )
  eq(entries[2].sha, sha(2))
  eq(entries[2].lnum, 2)
end

T["plan"]["validation diagnostics"] = function()
  local p = fake_plan(3)
  local entries, diags = plan_mod.parse_lines(p, {
    "squash " .. short(1), -- nothing to fold into
    "pick " .. short(2),
    "pick " .. short(2), -- twice
    "pick deadbeef", -- unknown
    "frobnicate x",
    "label onto",
  })
  local by_line = {}
  for _, d in ipairs(diags) do
    by_line[d.lnum] = d
  end
  eq(by_line[1].message, "squash needs an earlier commit to fold into")
  eq(by_line[3].message:find("appears twice", 1, true) ~= nil, true)
  eq(by_line[4].message, "deadbeef is not one of the commits being rebased")
  eq(by_line[5].severity, "error")
  eq(by_line[6].message:find("not supported", 1, true) ~= nil, true)
  -- The missing commit 3 is reported as dropped (info).
  eq(by_line[0].severity, "info")
  eq(#entries, 2)
end

T["plan"]["abbreviations grow until unique among the plan's commits"] = function()
  local p = fake_plan(2)
  p.original = { "abcdef1" .. ("1"):rep(33), "abcdef1" .. ("2"):rep(33) }
  p.subjects = { [p.original[1]] = "a", [p.original[2]] = "b" }
  p.entries = {
    { action = "pick", sha = p.original[1] },
    { action = "pick", sha = p.original[2] },
  }
  local lines = plan_mod.to_lines(p)
  eq(lines, { "pick abcdef11 a", "pick abcdef12 b" })
  local entries, diags = plan_mod.parse_lines(p, lines)
  eq(diags, {})
  eq(#entries, 2)
  local _, d2 = plan_mod.parse_lines(p, { "pick abcdef1 a" })
  eq(d2[1].message, "ambiguous commit abcdef1")
end

T["plan"]["newest-first order mirrors the graph"] = function()
  local p = fake_plan(3)
  p.opts.order = "newest_first"
  local lines = plan_mod.to_lines(p)
  eq(lines[1]:sub(1, 12), "pick " .. short(3))
  local entries = plan_mod.parse_lines(p, lines)
  eq(entries[1].sha, sha(1)) -- entries are always oldest first
end

T["plan"]["todo serialization uses full shas and git's command names"] = function()
  local p = fake_plan(4)
  local entries = plan_mod.parse_lines(p, {
    "pick " .. short(1),
    "fixup -C " .. short(2),
    "exec make test",
    "reword " .. short(3),
    "update-ref refs/heads/stack",
    "drop " .. short(4),
  })
  eq(plan_mod.to_todo(p, entries), table.concat({
    "pick " .. sha(1) .. " s1",
    "fixup -C " .. sha(2) .. " s2",
    "exec make test",
    "reword " .. sha(3) .. " s3",
    "update-ref refs/heads/stack",
    "drop " .. sha(4) .. " s4",
  }, "\n") .. "\n")
end

T["plan"]["autosquash moves fixup!/squash!/amend! after their target"] = function()
  local p = fake_plan(6, {
    "add form",
    "add api",
    "fixup! add form",
    "squash! add api",
    "amend! add form",
    "fixup! fixup! add form",
  })
  local out = plan_mod.autosquash(p.entries)
  eq(
    vim.tbl_map(function(e)
      return e.action .. " " .. e.subject
    end, out),
    {
      "pick add form",
      "fixup fixup! add form",
      "fixup_C amend! add form",
      "fixup fixup! fixup! add form",
      "pick add api",
      "squash squash! add api",
    }
  )
end

T["plan"]["chain head and summary"] = function()
  local p = fake_plan(4)
  local entries = plan_mod.parse_lines(
    p,
    { "pick " .. short(1), "squash " .. short(2), "fixup " .. short(3), "drop " .. short(4) }
  )
  eq(plan_mod.chain_head(entries, 3), sha(1))
  local c = plan_mod.summary(p, entries)
  eq({ c.commits, c.squash, c.drop }, { 1, 2, 1 })
end

T["simulate"] = MiniTest.new_set()

T["simulate"]["unchanged plan keeps every hash"] = function()
  local p = fake_plan(3)
  local sim = simulate.run(p, p.entries)
  eq(sim.unchanged, true)
  eq(
    vim.tbl_map(function(c)
      return c.id
    end, sim.commits),
    { sha(3), sha(2), sha(1) }
  )
  eq(sim.commits[3].parents, { p.base })
end

T["simulate"]["reorder, fold, drop, reword"] = function()
  local p = fake_plan(5)
  -- 1, then 3 moved up, 2 folded into 3, 4 reworded, 5 dropped
  local entries = plan_mod.parse_lines(p, {
    "pick " .. short(1),
    "pick " .. short(3),
    "fixup " .. short(2),
    "reword " .. short(4),
    "drop " .. short(5),
  })
  local sim = simulate.run(p, entries)
  eq(sim.unchanged, false)
  eq(#sim.commits, 3)
  local oldest = sim.commits[3]
  eq({ oldest.id, oldest.changed }, { sha(1), false })
  eq(sim.commits[2].from, { sha(3), sha(2) })
  eq(sim.commits[2].changed, true)
  eq(sim.commits[1].changed, true)
  eq(sim.dropped, { sha(5) })
  eq(sim.commits[1].parents, { sim.commits[2].id })
end

T["simulate"]["planned message and moved refs"] = function()
  local p = fake_plan(2)
  p.messages[sha(2)] = "New subject\n\nbody\n"
  local entries = plan_mod.parse_lines(
    p,
    { "pick " .. short(1), "update-ref refs/heads/low", "pick " .. short(2) }
  )
  local sim = simulate.run(p, entries)
  eq(sim.commits[1].subject, "New subject")
  eq(sim.commits[1].changed, true)
  eq(sim.moved_refs["refs/heads/low"], sha(1))
end

T["helpers"] = MiniTest.new_set()

local function nvim_l(script, args)
  local cmd = { vim.v.progpath, "-l", Repo.root .. "/helpers/" .. script }
  vim.list_extend(cmd, args)
  return vim.system(cmd, { text = true }):wait()
end

T["helpers"]["seq_editor copies the plan; a missing plan exits 1"] = function()
  local dir = vim.fn.tempname() .. " with space"
  vim.fn.mkdir(dir, "p")
  local plan, todo = dir .. "/plan todo", dir .. "/git-rebase-todo"
  vim.fn.writefile({ "pick abc", "exec true" }, plan)
  vim.fn.writefile({ "pick something-else" }, todo)
  eq(nvim_l("seq_editor.lua", { plan, todo }).code, 0)
  eq(vim.fn.readfile(todo), { "pick abc", "exec true" })
  eq(nvim_l("seq_editor.lua", { dir .. "/missing", todo }).code, 1)
  vim.fn.delete(dir, "rf")
end

T["helpers"]["msg_editor writes the planned message of the chain head"] = function()
  local dir = vim.fn.tempname() .. " sp"
  local gitdir, msgdir = dir .. "/git dir", dir .. "/msg"
  vim.fn.mkdir(gitdir .. "/rebase-merge", "p")
  vim.fn.mkdir(msgdir, "p")
  local head = ("a"):rep(40)
  vim.fn.writefile({ "Planned subject", "", "Planned body" }, msgdir .. "/" .. head .. ".txt")
  local msg = dir .. "/COMMIT_EDITMSG"
  -- reword of head
  vim.fn.writefile(
    { "pick " .. ("1"):rep(40) .. " x", "reword " .. head .. " old" },
    gitdir .. "/rebase-merge/done"
  )
  vim.fn.writefile({ "old message", "# comment" }, msg)
  eq(nvim_l("msg_editor.lua", { gitdir, msgdir, msg }).code, 0)
  eq(vim.fn.readfile(msg), { "Planned subject", "", "Planned body" })
  -- squash chain: the head is the pick before the squashes (abbreviated shas in done)
  vim.fn.writefile(
    { "pick " .. head:sub(1, 7) .. " x", "squash 2222222 y", "s 3333333 z" },
    gitdir .. "/rebase-merge/done"
  )
  vim.fn.writefile({ "combined default" }, msg)
  eq(nvim_l("msg_editor.lua", { gitdir, msgdir, msg }).code, 0)
  eq(vim.fn.readfile(msg)[1], "Planned subject")
  -- no planned message: unchanged
  vim.fn.writefile({ "pick " .. ("4"):rep(40) .. " x" }, gitdir .. "/rebase-merge/done")
  vim.fn.writefile({ "keep me" }, msg)
  eq(nvim_l("msg_editor.lua", { gitdir, msgdir, msg }).code, 0)
  eq(vim.fn.readfile(msg), { "keep me" })
  vim.fn.delete(dir, "rf")
end

return T
