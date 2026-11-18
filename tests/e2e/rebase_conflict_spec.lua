-- T084 (conflicts, abort, external rebases, stale plans, dirty worktree), T082 (prediction),
-- T090/T091 (plan buffer + preview). Runs in a child Neovim per case.
local fixtures = require("tests.fixtures")
local S = require("tests.helpers.safety")
local Repo = require("tests.helpers.repo")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local plan_mod = require("trellis.rebase.plan")
local execute = require("trellis.rebase.execute")
local ops = require("trellis.safety.ops")

--- feature/login of the demo fixture: "style form" (3), "add remember me" (4) and "fix typo" (5)
--- edit the same lines of src/form.lua.
local function demo()
  local r = fixtures.fresh("demo")
  r:switch("feature/login")
  local repo = S.repo(r.path)
  S.auto_confirm(true)
  local plan = S.run(function()
    return plan_mod.from_range(repo, "main", {})
  end)
  return r, repo, plan
end

local function lines_with(plan, order, actions)
  local out = {}
  for i, idx in ipairs(order) do
    out[i] = ((actions and actions[i]) or "pick") .. " " .. plan.original[idx]:sub(1, 7)
  end
  return out
end

local CONFLICTING = { 1, 2, 4, 3, 5, 6 } -- "add remember me" before "style form"

T["prediction"] = MiniTest.new_set()

T["prediction"]["exact: merge-tree flags the reordered commit and its path"] = function()
  require("tests.helpers.gitver").require({ 2, 40 }, "git merge-tree --merge-base")
  local _, repo, plan = demo()
  local entries = plan_mod.parse_lines(plan, lines_with(plan, CONFLICTING))
  local risks = S.run(function()
    return require("trellis.rebase.predict").predict(repo, plan, entries)
  end)
  local flagged = {}
  for i, r in pairs(risks) do
    flagged[#flagged + 1] = { i = i, level = r.level, paths = r.paths, exact = r.exact }
  end
  eq(#flagged >= 1, true)
  table.sort(flagged, function(a, b)
    return a.i < b.i
  end)
  eq(flagged[1].level, "conflict")
  eq(flagged[1].exact, true)
  eq(flagged[1].paths, { "src/form.lua" })
  -- The original order predicts nothing.
  local clean = S.run(function()
    return require("trellis.rebase.predict").predict(
      repo,
      plan,
      plan_mod.parse_lines(plan, plan_mod.to_lines(plan))
    )
  end)
  eq(clean, {})
end

T["prediction"]["heuristic fallback without merge-tree --merge-base"] = function()
  local _, repo, plan = demo()
  repo.features.merge_tree_base = false
  local entries = plan_mod.parse_lines(plan, lines_with(plan, CONFLICTING))
  local risks = S.run(function()
    return require("trellis.rebase.predict").predict(repo, plan, entries)
  end)
  local levels = {}
  for _, r in pairs(risks) do
    levels[#levels + 1] = r.level .. ":" .. table.concat(r.paths, ",")
  end
  eq(vim.tbl_contains(levels, "possible:src/form.lua"), true)
end

T["prediction"]["cancellation returns nothing"] = function()
  local _, repo, plan = demo()
  local entries = plan_mod.parse_lines(plan, lines_with(plan, CONFLICTING))
  local token = { cancelled = true }
  local risks = S.run(function()
    return require("trellis.rebase.predict").predict(repo, plan, entries, token)
  end)
  eq(risks, nil)
end

T["conflicts"] = MiniTest.new_set()

local function run_conflicting()
  local r, repo, plan = demo()
  local before = S.state(r)
  local entries, diags = plan_mod.parse_lines(plan, lines_with(plan, CONFLICTING))
  local op, err = S.run(function()
    return execute.run(repo, plan, entries, diags)
  end)
  eq(err, nil)
  eq(op.status, "stopped")
  eq(require("trellis.git.repo").refresh_state(repo).kind, "rebase")
  return r, repo, before, op
end

T["conflicts"]["stop, resolve, continue; undo restores"] = function()
  local r, repo, before, op = run_conflicting()
  -- Resolve by taking the commit being applied, then continue until done.
  local rounds = 0
  while require("trellis.git.repo").refresh_state(repo).kind ~= "clean" do
    rounds = rounds + 1
    assert(rounds < 8)
    r:git({ "checkout", "--theirs", "--", "src/form.lua" }, { allow_fail = true })
    r:git({ "add", "src/form.lua" })
    S.run(function()
      return ops.control(repo, "continue")
    end)
  end
  eq(require("trellis.safety.journal").get(repo, op.id).status, "done")
  eq(#vim.split(vim.trim(r:git({ "log", "--format=%s", "main..HEAD" })), "\n"), 6)
  S.run(function()
    return ops.undo(repo)
  end)
  eq(S.state(r), before)
end

T["conflicts"]["abort returns to the exact pre-rebase state"] = function()
  local r, repo, before, op = run_conflicting()
  local _, err = S.run(function()
    return ops.control(repo, "abort")
  end)
  eq(err, nil)
  eq(S.state(r), before)
  eq(require("trellis.safety.journal").get(repo, op.id).status, "aborted")
end

T["conflicts"]["skip drops the conflicting commit and goes on"] = function()
  local r, repo = run_conflicting()
  local rounds = 0
  while require("trellis.git.repo").refresh_state(repo).kind ~= "clean" do
    rounds = rounds + 1
    assert(rounds < 8)
    S.run(function()
      return ops.control(repo, "skip")
    end)
  end
  eq(#vim.split(vim.trim(r:git({ "log", "--format=%s", "main..HEAD" })), "\n") < 6, true)
end

T["conflicts"]["the conflict panel drives a rebase"] = function()
  local r, repo = run_conflicting()
  local v
  require("trellis.view.conflict").open(repo, {
    on_open = function(x)
      v = x
    end,
  })
  eq(
    vim.wait(3000, function()
      return v ~= nil
    end),
    true
  )
  local lines = vim.api.nvim_buf_get_lines(v.bufnr, 0, -1, false)
  eq(lines[1]:match("^rebase stopped on a conflict while applying %x+") ~= nil, true)
  eq(vim.tbl_contains(lines, " UU src/form.lua"), true)
  vim.api.nvim_set_current_win(vim.fn.bufwinid(v.bufnr))
  vim.cmd("normal A")
  eq(
    vim.wait(5000, function()
      return require("trellis.git.repo").refresh_state(repo).kind == "clean"
    end),
    true
  )
  eq(r:rev("HEAD"), r:rev("feature/login"))
end

T["refusals"] = MiniTest.new_set()

T["refusals"]["stale plan: HEAD moved after the plan was made"] = function()
  local r, repo, plan = demo()
  r:commit({ msg = "external commit", files = { ["x.txt"] = "x\n" } })
  local entries, diags = plan_mod.parse_lines(plan, lines_with(plan, { 2, 1, 3, 4, 5, 6 }))
  local _, err = S.run(function()
    return execute.run(repo, plan, entries, diags)
  end)
  eq(err:match("^plan is stale") ~= nil, true)
end

T["refusals"]["plans with errors and unchanged plans are not executed"] = function()
  local _, repo, plan = demo()
  local entries, diags = plan_mod.parse_lines(plan, { "squash " .. plan.original[1]:sub(1, 7) })
  local _, err = S.run(function()
    return execute.run(repo, plan, entries, diags)
  end)
  eq(err:match("^plan has errors") ~= nil, true)
  local e2, d2 = plan_mod.parse_lines(plan, plan_mod.to_lines(plan))
  local _, err2 = S.run(function()
    return execute.run(repo, plan, e2, d2)
  end)
  eq(err2, "nothing to do: the plan does not change history")
end

T["refusals"]["dirty worktree: autostash on yes, unchanged on no"] = function()
  local r, repo, plan = demo()
  r:write({ ["README.md"] = "dirty edit\n" })
  local entries, diags = plan_mod.parse_lines(plan, lines_with(plan, { 2, 1, 3, 4, 5, 6 }))
  S.auto_confirm(false)
  local _, err = S.run(function()
    return execute.run(repo, plan, entries, diags)
  end)
  eq(err:match("^cancelled") ~= nil, true)
  eq(r:read("README.md"), "dirty edit\n")
  S.auto_confirm(true)
  local op, err2 = S.run(function()
    return execute.run(repo, plan, entries, diags)
  end)
  eq({ err2, op.status }, { nil, "done" })
  eq(r:read("README.md"), "dirty edit\n")
  eq(
    vim.trim(r:git({ "log", "--reverse", "--format=%s", "main..HEAD" })):match("^wip") ~= nil,
    true
  )
end

T["refusals"]["published commits are announced (force-push needed; trellis never pushes)"] = function()
  local r, repo = demo()
  r:update_refs({ "create refs/remotes/origin/feature/login " .. r:rev("feature/login~2") })
  local plan = S.run(function()
    return plan_mod.from_range(repo, "main", {})
  end)
  local entries, diags = plan_mod.parse_lines(plan, lines_with(plan, { 2, 1, 3, 4, 5, 6 }))
  S.auto_confirm(false)
  S.run(function()
    return execute.run(repo, plan, entries, diags)
  end)
  local preview = table.concat(S.asked[1].preview, "\n")
  eq(preview:find("force%-push") ~= nil, true)
  eq(preview:find("4 commit") ~= nil, true)
end

T["external rebase in progress is adopted by :Trellis abort"] = function()
  local r = fixtures.fresh("in-progress-rebase")
  local repo = S.repo(r.path)
  eq(require("trellis.git.repo").refresh_state(repo).kind, "rebase")
  local _, err = S.run(function()
    return ops.control(repo, "abort")
  end)
  eq(err, nil)
  eq(require("trellis.git.repo").refresh_state(repo).kind, "clean")
  -- And a planner refuses to start while a rebase is running.
  local r2 = fixtures.fresh("in-progress-rebase")
  local repo2 = S.repo(r2.path)
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  require("trellis.view.plan").start(repo2, "HEAD~1")
  vim.wait(3000, function()
    return #msgs > 0
  end)
  vim.notify = orig
  eq(msgs[1]:find("in progress", 1, true) ~= nil, true)
end

T["plan buffer"] = MiniTest.new_set()

local function open_planner()
  local r = fixtures.fresh("demo")
  r:switch("feature/login")
  local repo = S.repo(r.path)
  S.auto_confirm(true)
  local v
  require("trellis.view.plan").start(repo, "main", {
    on_open = function(x)
      v = x
    end,
  })
  eq(
    vim.wait(5000, function()
      return v ~= nil
    end),
    true
  )
  return r, repo, v
end

T["plan buffer"]["lines, header, preview; keys reorder and change actions"] = function()
  local r, _, v = open_planner()
  local buf = v.bufnr
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(#lines, 6)
  eq(lines[1]:match("^pick %x+ add login form$") ~= nil, true)
  eq(vim.bo[buf].buftype, "acwrite")
  eq(vim.bo[buf].modifiable, true)
  local preview = vim.api.nvim_buf_get_lines(v.preview_buf, 0, -1, false)
  eq(preview[1]:find("wire up validation", 1, true) ~= nil, true)
  eq(preview[#preview]:find("(base)", 1, true) ~= nil, true)
  -- <M-k> moves "fix typo" up; <M-f> makes it a fixup.
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  local function press(keys)
    vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
  end
  press("<M-k>")
  eq(vim.api.nvim_win_get_cursor(0)[1], 4)
  press("<M-f>")
  eq(vim.api.nvim_get_current_line():match("^fixup %x+ fix typo$") ~= nil, true)
  require("trellis.view.plan").update(v)
  eq(#v.sim.commits, 5)
  local changed = #vim.api.nvim_buf_get_extmarks(
    v.preview_buf,
    require("trellis.view.plan").preview_ns,
    0,
    -1,
    {}
  )
  eq(changed >= 2, true)
  -- Built-in editing works too: `dd` + `p` reorder, `ciw` changes the action.
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("normal! ddp")
  eq(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]:find("add login form", 1, true) ~= nil, true)
  vim.cmd("normal! u")
  vim.cmd("normal! ciwdrop")
  vim.cmd("stopinsert")
  require("trellis.view.plan").update(v)
  eq(#v.sim.dropped, 1)
  eq(r ~= nil, true)
end

T["plan buffer"]["invalid lines get diagnostics; :w executes the plan"] = function()
  local r, repo, v = open_planner()
  local buf = v.bufnr
  vim.api.nvim_buf_set_lines(
    buf,
    0,
    1,
    false,
    { "squash " .. v.plan.original[1]:sub(1, 7) .. " add login form" }
  )
  require("trellis.view.plan").update(v)
  local diags = vim.diagnostic.get(buf, { namespace = require("trellis.view.plan").diag_ns })
  eq(#diags, 1)
  eq(diags[1].lnum, 0)
  -- Fix it: reorder "wip" first, then :w.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "pick " .. v.plan.original[2]:sub(1, 7),
    "pick " .. v.plan.original[1]:sub(1, 7),
    "pick " .. v.plan.original[3]:sub(1, 7),
    "pick " .. v.plan.original[4]:sub(1, 7),
    "pick " .. v.plan.original[5]:sub(1, 7),
    "pick " .. v.plan.original[6]:sub(1, 7),
  })
  require("trellis.view.plan").update(v)
  eq(#vim.diagnostic.get(buf, { namespace = require("trellis.view.plan").diag_ns }), 0)
  vim.cmd("write")
  eq(
    vim.wait(10000, function()
      return vim.trim(r:git({ "log", "--reverse", "--format=%s", "main..HEAD" })):match("^wip")
        ~= nil
    end),
    true
  )
  eq(
    vim.wait(3000, function()
      return not vim.api.nvim_buf_is_valid(buf)
    end),
    true
  )
  eq(repo ~= nil, true)
end

T["plan buffer"]["<M-m> plans a message; the commit gets it"] = function()
  local r, _, v = open_planner()
  vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- wip
  vim.api.nvim_feedkeys(vim.keycode("<M-m>"), "x", false)
  eq(
    vim.wait(3000, function()
      return vim.bo.filetype == "gitcommit"
    end),
    true
  )
  vim.api.nvim_buf_set_lines(
    0,
    0,
    -1,
    false,
    { "Add password validation", "", "Planned in trellis." }
  )
  vim.cmd("write")
  vim.cmd("close")
  eq(vim.api.nvim_buf_get_lines(v.bufnr, 1, 2, false)[1]:match("^reword ") ~= nil, true)
  vim.api.nvim_set_current_win(vim.fn.bufwinid(v.bufnr))
  vim.cmd("write")
  eq(
    vim.wait(10000, function()
      return r:git({ "log", "--format=%B", "main..HEAD" }):find("Planned in trellis.", 1, true)
        ~= nil
    end),
    true
  )
end

T["entry points: gr in the graph and :Trellis rebase"] = function()
  local r = fixtures.fresh("demo")
  r:switch("feature/login")
  vim.cmd("cd " .. r.path)
  vim.cmd("Trellis rebase main")
  eq(
    vim.wait(5000, function()
      return vim.b.trellis_view == "plan"
    end),
    true
  )
  eq(#vim.api.nvim_buf_get_lines(0, 0, -1, false), 6)
  vim.cmd("normal ZQ")
  local G = require("tests.helpers.graph")
  local gv = G.open(r.path)
  eq(G.wait_loaded(gv), true)
  local m = gv.shown.model
  vim.api.nvim_win_set_cursor(0, { m.row_of_commit[m.index[r:rev("feature/login~2")]], 0 })
  vim.cmd("normal gr")
  eq(
    vim.wait(5000, function()
      return vim.b.trellis_view == "plan"
    end),
    true
  )
  eq(#vim.api.nvim_buf_get_lines(0, 0, -1, false), 2)
  eq(Repo ~= nil, true)
end

return require("tests.helpers.child").run_in_child(T, "tests/e2e/rebase_conflict_spec.lua")
