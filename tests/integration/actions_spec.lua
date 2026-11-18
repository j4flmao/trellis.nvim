-- T074: every US5 action is journaled, backed up and undone to the exact previous state;
-- conflicts stop the operation and the conflict panel continues, skips or aborts it.
local fixtures = require("tests.fixtures")
local S = require("tests.helpers.safety")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local actions = require("trellis.actions")
local ops = require("trellis.safety.ops")
local journal = require("trellis.safety.journal")

--- Run an action, check it is done and journaled, undo it, check the state is back.
local function roundtrip(r, repo, fn, check_after)
  local before = S.state(r)
  local op, err = S.run(fn)
  eq(err, nil)
  eq(op.status, "done")
  eq(journal.get(repo, op.id).status, "done")
  if check_after then
    check_after(op)
  end
  local u, uerr = S.run(function()
    return ops.undo(repo)
  end)
  eq(uerr, nil)
  eq(u.status, "done")
  eq(S.state(r), before)
  return op
end

T["checkout a branch and a detached commit"] = function()
  local r = fixtures.fresh("two-branches")
  local repo = S.repo(r.path)
  S.auto_confirm(true)
  roundtrip(r, repo, function()
    return actions.checkout(repo, "feature")
  end, function()
    eq(vim.trim(r:git({ "symbolic-ref", "HEAD" })), "refs/heads/feature")
  end)
  roundtrip(r, repo, function()
    return actions.checkout(repo, "main~1")
  end, function()
    eq(r:git({ "symbolic-ref", "-q", "HEAD" }, { allow_fail = true }), "")
    eq(r:rev("HEAD"), r:rev("main~1"))
  end)
end

T["branch create, rename, delete (unmerged needs y)"] = function()
  local r = fixtures.fresh("two-branches")
  local repo = S.repo(r.path)
  S.auto_confirm(true)
  roundtrip(r, repo, function()
    return actions.branch_create(repo, "new", "main~1")
  end, function()
    eq(r:rev("new"), r:rev("main~1"))
  end)
  roundtrip(r, repo, function()
    return actions.branch_rename(repo, "feature", "feature-renamed")
  end, function()
    eq(r:rev("feature-renamed") ~= nil, true)
  end)
  -- Renaming the checked-out branch moves HEAD with it, and undo puts both back.
  roundtrip(r, repo, function()
    return actions.branch_rename(repo, "main", "trunk")
  end, function()
    eq(vim.trim(r:git({ "symbolic-ref", "HEAD" })), "refs/heads/trunk")
  end)
  local op = roundtrip(r, repo, function()
    return actions.branch_delete(repo, "feature")
  end, function(o)
    eq(r:git({ "branch", "--list", "feature" }), "")
    eq(#S.backup_refs(r, o.id) > 0, true)
  end)
  eq(S.asked[#S.asked].require_y, true) -- feature is not merged into main
  eq(table.concat(S.asked[#S.asked].preview, "\n"):find("feature 2", 1, true) ~= nil, true)
  eq(op.kind, "branch-delete")
  -- The checked-out branch cannot be deleted.
  local _, err = S.run(function()
    return actions.branch_delete(repo, "main")
  end)
  eq(err, "cannot delete the checked-out branch main")
end

T["tags: lightweight, annotated (undo restores the tag object)"] = function()
  local r = fixtures.fresh("tags")
  local repo = S.repo(r.path)
  S.auto_confirm(true)
  roundtrip(r, repo, function()
    return actions.tag_create(repo, "light", "HEAD~1")
  end)
  roundtrip(r, repo, function()
    return actions.tag_create(repo, "ann", "HEAD", { message = "annotated" })
  end, function()
    eq(vim.trim(r:git({ "cat-file", "-t", "refs/tags/ann" })), "tag")
  end)
  local obj = vim.trim(r:git({ "rev-parse", "refs/tags/v1.0.0" }))
  roundtrip(r, repo, function()
    return actions.tag_delete(repo, "v1.0.0")
  end)
  eq(vim.trim(r:git({ "rev-parse", "refs/tags/v1.0.0" })), obj)
  eq(vim.trim(r:git({ "cat-file", "-t", obj })), "tag")
end

T["cherry-pick several commits in topological order"] = function()
  local r = fixtures.fresh("two-branches")
  local repo = S.repo(r.path)
  S.auto_confirm(true)
  -- Given newest first (as selected in the graph): applied oldest first.
  roundtrip(r, repo, function()
    return actions.cherry_pick(repo, { r:rev("feature"), r:rev("feature~1") })
  end, function()
    eq(vim.trim(r:git({ "log", "-2", "--format=%s" })), "feature 2\nfeature 1")
  end)
end

T["revert, including a merge with mainline chosen"] = function()
  local r = fixtures.fresh("simple-merge")
  local repo = S.repo(r.path)
  S.auto_confirm(true)
  roundtrip(r, repo, function()
    return actions.revert(repo, "HEAD~1")
  end, function()
    eq(vim.trim(r:git({ "log", "-1", "--format=%s" })):match("^Revert") ~= nil, true)
  end)
  local orig = vim.ui.select
  vim.ui.select = function(items, _, cb)
    cb(items[1])
  end
  roundtrip(r, repo, function()
    return actions.revert(repo, "HEAD")
  end, function()
    eq(r:read("feature.txt"), nil)
  end)
  vim.ui.select = orig
end

T["cherry-pick and revert refuse a dirty worktree"] = function()
  local r = fixtures.fresh("two-branches")
  r:write({ ["m.txt"] = "dirty\n" })
  local repo = S.repo(r.path)
  S.auto_confirm(true)
  local _, err = S.run(function()
    return actions.cherry_pick(repo, { "feature" })
  end)
  eq(err:find("needs a clean worktree", 1, true) ~= nil, true)
  eq(err:find("m.txt", 1, true) ~= nil, true)
  eq(r:read("m.txt"), "dirty\n")
end

T["restore_file writes a version and undo brings the old content (or absence) back"] = function()
  local r = fixtures.fresh("blame-chain")
  r:write({ ["src/api.lua"] = "my unsaved work\n" })
  local repo = S.repo(r.path)
  S.auto_confirm(true)
  local op = S.run(function()
    return actions.restore_file(repo, "HEAD~5", "src/api.lua")
  end)
  eq(op.status, "done")
  eq(r:read("src/api.lua"):find("retry = 2", 1, true) ~= nil, true)
  S.run(function()
    return ops.undo(repo)
  end)
  eq(r:read("src/api.lua"), "my unsaved work\n")
  -- A file that did not exist: undo removes it again.
  S.run(function()
    return actions.restore_file(repo, "HEAD", "src/api.lua")
  end)
  os.remove(r.path .. "/src/api.lua")
  local op2 = S.run(function()
    return actions.restore_file(repo, "HEAD~1", "src/api.lua")
  end)
  eq(op2.files["src/api.lua"].before, false)
  S.run(function()
    return ops.undo(repo)
  end)
  eq(r:read("src/api.lua"), nil)
end

T["conflict: cherry-pick stops, the panel resolves and continues; undo restores"] = function()
  local r = S.conflict_repo()
  local repo = S.repo(r.path)
  S.auto_confirm(true)
  local before = S.state(r)
  local op = S.run(function()
    return actions.cherry_pick(repo, { r:rev("topic~1") })
  end)
  eq(op.status, "stopped")
  eq(require("trellis.git.repo").refresh_state(repo).kind, "cherry-pick")
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
  eq(lines[1]:find("while applying " .. r:rev("topic~1"):sub(1, 7), 1, true) ~= nil, true)
  eq(lines[2]:find("ours = HEAD (main)", 1, true) ~= nil, true)
  eq(vim.tbl_contains(lines, " UU f.txt"), true)
  -- Take theirs, mark resolved, continue.
  local lnum = vim.fn.index(lines, " UU f.txt") + 1
  vim.api.nvim_set_current_win(vim.fn.bufwinid(v.bufnr))
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  vim.cmd("normal t")
  vim.wait(2000, function()
    return r:read("f.txt") == "topic\n"
  end)
  vim.cmd("normal a")
  eq(
    vim.wait(2000, function()
      return vim.tbl_contains(vim.api.nvim_buf_get_lines(v.bufnr, 0, -1, false), "Conflicted (0):")
    end),
    true
  )
  vim.cmd("normal C")
  eq(
    vim.wait(5000, function()
      return require("trellis.git.repo").refresh_state(repo).kind == "clean"
    end),
    true
  )
  vim.wait(500)
  eq(journal.get(repo, op.id).status, "done")
  eq(vim.trim(r:git({ "log", "-1", "--format=%s" })), "topic change")
  -- Undo the finished cherry-pick.
  S.run(function()
    return ops.undo(repo)
  end)
  eq(S.state(r), before)
end

T["conflict: abort returns to the exact previous state; skip moves on"] = function()
  local r = S.conflict_repo()
  local repo = S.repo(r.path)
  S.auto_confirm(true)
  local before = S.state(r)
  local op = S.run(function()
    return actions.cherry_pick(repo, { r:rev("topic~1") })
  end)
  eq(op.status, "stopped")
  local _, err = S.run(function()
    return ops.control(repo, "abort")
  end)
  eq(err, nil)
  eq(S.state(r), before)
  eq(journal.get(repo, op.id).status, "aborted")
  -- Two commits, the first conflicts: skip it, the second applies.
  local op2 = S.run(function()
    return actions.cherry_pick(repo, { r:rev("topic~1"), r:rev("topic") })
  end)
  eq(op2.status, "stopped")
  S.run(function()
    return ops.control(repo, "skip")
  end)
  eq(require("trellis.git.repo").refresh_state(repo).kind, "clean")
  eq(vim.trim(r:git({ "log", "-1", "--format=%s" })), "topic other")
  eq(journal.get(repo, op2.id).status, "done")
end

T["confirmation is respected: declining changes nothing"] = function()
  local r = fixtures.fresh("linear")
  local repo = S.repo(r.path)
  local before = S.state(r)
  S.auto_confirm(false)
  local _, err = S.run(function()
    return actions.reset(repo, "HEAD~1", "hard")
  end)
  eq(err, "cancelled")
  eq(S.state(r), before)
  eq(#journal.read(repo), 0)
end

T["graph keys run actions; :Trellis undo / ops / log"] = function()
  local r = fixtures.fresh("two-branches")
  S.auto_confirm(true)
  local G = require("tests.helpers.graph")
  local v = G.open(r.path)
  eq(G.wait_loaded(v), true)
  local m = v.shown.model
  -- feature~1 creates f.txt, so it applies cleanly on main (feature alone would conflict).
  local feature = r:rev("feature~1")
  vim.api.nvim_win_set_cursor(0, { m.row_of_commit[m.index[feature]], 0 })
  vim.cmd("normal c")
  eq(
    vim.wait(5000, function()
      return vim.trim(r:git({ "log", "-1", "--format=%s", "main" })) == "feature 1"
    end),
    true
  )
  -- The journal records "done" after git returns.
  local repo = S.repo(r.path)
  eq(
    vim.wait(5000, function()
      local list = journal.read(repo)
      return #list > 0 and list[#list].status == "done"
    end),
    true
  )
  vim.cmd("Trellis undo")
  eq(
    vim.wait(5000, function()
      return vim.trim(r:git({ "log", "-1", "--format=%s", "main" })) == "main 2"
    end),
    true
  )
  eq(
    vim.wait(5000, function()
      local list = journal.read(repo)
      return list[1] and list[1].status == "undone"
    end),
    true
  )
  vim.cmd("Trellis ops")
  eq(
    vim.wait(3000, function()
      return vim.b.trellis_view == "ops"
    end),
    true
  )
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  eq(text:find("undone", 1, true) ~= nil, true)
  eq(text:find("Cherry-pick", 1, true) ~= nil, true)
  vim.cmd("Trellis log")
  eq(
    vim.wait(3000, function()
      return vim.b.trellis_view == "log"
    end),
    true
  )
  eq(
    table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("cherry-pick", 1, true)
      ~= nil,
    true
  )
end

return require("tests.helpers.child").run_in_child(T, "tests/integration/actions_spec.lua")
