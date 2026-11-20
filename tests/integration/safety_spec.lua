-- Journal, backup refs, undo/redo, dirty-worktree refusal, prune.
-- Runs in a child Neovim per case.
local fixtures = require("tests.fixtures")
local S = require("tests.helpers.safety")
local Repo = require("tests.helpers.repo")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local journal = require("trellis.safety.journal")

-- Journal ---------------------------------------------------------------------------------

T["journal"] = MiniTest.new_set()

T["journal"]["append and read fold snapshots by id; torn lines are skipped"] = function()
  local r = fixtures.fresh("linear")
  local repo = S.repo(r.path)
  journal.append(repo, { id = "a", kind = "reset", status = "running" })
  journal.append(repo, { id = "b", kind = "checkout", status = "done" })
  journal.append(repo, { id = "a", status = "done", after = { x = "1" } })
  local f = assert(io.open(journal.path(repo), "ab"))
  f:write('{"id": "c", "kind": "tor') -- crash mid-write
  f:close()
  local list, bad = journal.read(repo)
  eq(bad, 1)
  eq(#list, 2)
  eq(
    { list[1].id, list[1].kind, list[1].status, list[1].after },
    { "a", "reset", "done", { x = "1" } }
  )
  eq(journal.get(repo, "b").kind, "checkout")
  -- Appends after a torn line still work (the torn line stays isolated on its own line).
  f = assert(io.open(journal.path(repo), "ab"))
  f:write("\n")
  f:close()
  journal.append(repo, { id = "d", status = "done" })
  eq(#(journal.read(repo)), 3)
end

T["journal"]["concurrent appends from two worktrees never interleave"] = function()
  local r = fixtures.fresh("linear")
  r:branch("wt")
  local wt_path = r.path .. "-wt"
  r:worktree(wt_path, "wt")
  local script = Repo.root .. "/.tests/tmp/append-" .. vim.uv.os_getpid() .. ".lua"
  local fh = assert(io.open(script, "wb"))
  fh:write(([[
    vim.opt.rtp:prepend(%q)
    local dir, tag = _G.arg[1], _G.arg[2]
    local repo
    require("trellis.git.repo").discover(dir, function(_, x) repo = x end)
    vim.wait(5000, function() return repo end)
    local journal = require("trellis.safety.journal")
    for i = 1, 150 do
      assert(journal.append(repo, { id = tag .. i, kind = "x", status = "done", pad = string.rep("z", 3000) }))
    end
  ]]):format(Repo.root))
  fh:close()
  local procs = {}
  for i, dir in ipairs({ r.path, wt_path }) do
    procs[i] = vim.system(
      { vim.v.progpath, "-l", script, dir, "p" .. i .. "-" },
      { env = Repo.git_env, text = true }
    )
  end
  for _, p in ipairs(procs) do
    local res = p:wait(60000)
    eq({ code = res.code, err = res.stderr }, { code = 0, err = "" })
  end
  local repo = S.repo(r.path)
  local list, bad = journal.read(repo)
  eq(bad, 0)
  eq(#list, 300)
  -- Both worktrees share the common dir's journal.
  eq(journal.path(S.repo(wt_path)), journal.path(repo))
end

T["journal"]["stale locks of dead processes are broken; live locks time out"] = function()
  local r = fixtures.fresh("linear")
  local repo = S.repo(r.path)
  vim.fn.mkdir(journal.dir(repo), "p")
  local lock = journal.dir(repo) .. "/ops.lock"
  local fh = assert(io.open(lock, "wb"))
  fh:write(vim.json.encode({ pid = 999999, time = 0 }))
  fh:close()
  vim.uv.fs_utime(lock, 0, 0)
  eq(journal.append(repo, { id = "x" }), true)
  -- A live holder (this process) is waited for, then reported.
  fh = assert(io.open(lock, "wb"))
  fh:write(vim.json.encode({ pid = vim.uv.os_getpid(), time = os.time() }))
  fh:close()
  journal.lock_timeout_ms = 100
  local ok, err = journal.append(repo, { id = "y" })
  eq(ok, false)
  eq(err:find("pid " .. vim.uv.os_getpid(), 1, true) ~= nil, true)
  os.remove(lock)
end

-- Backups and undo --------------------------------------------------------------------------

T["undo"] = MiniTest.new_set()

T["undo"]["reset --hard on a dirty worktree: backups, undo restores refs and changes, redo"] = function()
  local r = fixtures.fresh("linear")
  r:write({ ["a.txt"] = "uncommitted edit\n" })
  r:git({ "add", "a.txt" })
  r:write({ ["a.txt"] = "uncommitted edit, more\n" })
  local before = S.state(r)
  local repo = S.repo(r.path)
  S.auto_confirm(true)
  local op, err = S.run(function()
    return require("trellis.actions").reset(repo, "HEAD~3", "hard")
  end)
  eq(err, nil)
  eq(op.status, "done")
  eq(S.asked[1].require_y, true)
  -- The preview names the dropped commits and the discarded change.
  local preview = table.concat(S.asked[1].preview, "\n")
  eq(preview:find("commit 10", 1, true) ~= nil, true)
  eq(preview:find("a.txt", 1, true) ~= nil, true)
  -- Backup refs: branch, HEAD and the stash of the discarded changes.
  local refs = S.backup_refs(r, op.id)
  table.sort(refs)
  eq(refs, {
    "refs/trellis/backup/" .. op.id .. "/HEAD",
    "refs/trellis/backup/" .. op.id .. "/heads/main",
    "refs/trellis/backup/" .. op.id .. "/stash",
  })
  eq(
    vim.trim(r:git({ "rev-parse", "refs/trellis/backup/" .. op.id .. "/heads/main" })),
    before.head
  )
  eq(r:read("a.txt"), "7\n")
  local after = S.state(r)

  local u, uerr = S.run(function()
    return require("trellis.safety.ops").undo(repo)
  end)
  eq(uerr, nil)
  eq(u.kind, "undo")
  local restored = S.state(r)
  eq(
    { restored.refs, restored.head, restored.symbolic, restored.worktree },
    { before.refs, before.head, before.symbolic, before.worktree }
  )
  eq(r:read("a.txt"), "uncommitted edit, more\n")
  eq(journal.get(repo, op.id).status, "undone")

  -- Redo needs a clean worktree: decline the offered stash first.
  S.auto_confirm(false)
  local _, rerr = S.run(function()
    return require("trellis.safety.ops").redo(repo)
  end)
  eq(rerr:match("^cancelled") ~= nil, true)
  eq(S.state(r).head, before.head)
  -- Accept: the changes go to `git stash push`, then the reset is re-applied.
  S.auto_confirm(true)
  local rd, rderr = S.run(function()
    return require("trellis.safety.ops").redo(repo)
  end)
  eq(rderr, nil)
  eq(rd.kind, "redo")
  eq(S.state(r).head, after.head)
  eq(vim.trim(r:git({ "stash", "list" })):find("trellis: before redo", 1, true) ~= nil, true)
  -- And undo again.
  r:git({ "stash", "drop" }) -- (test cleanup only; trellis itself never drops stashes)
  S.run(function()
    return require("trellis.safety.ops").undo(repo)
  end)
  eq(S.state(r).head, before.head)
end

T["undo"]["soft and mixed resets restore index and worktree exactly"] = function()
  for _, mode in ipairs({ "soft", "mixed" }) do
    local r = fixtures.fresh("linear")
    local repo = S.repo(r.path)
    local before = S.state(r)
    S.auto_confirm(true)
    local op = S.run(function()
      return require("trellis.actions").reset(repo, "HEAD~2", mode)
    end)
    eq(op.status, "done")
    eq(S.state(r).head ~= before.head, true)
    local _, err = S.run(function()
      return require("trellis.safety.ops").undo(repo)
    end)
    eq({ mode = mode, err = err }, { mode = mode, err = nil })
    eq({ mode = mode, state = S.state(r) }, { mode = mode, state = before })
  end
end

T["undo"]["nothing to undo / redo; a new operation clears redo"] = function()
  local r = fixtures.fresh("linear")
  local repo = S.repo(r.path)
  S.auto_confirm(true)
  local _, err = S.run(function()
    return require("trellis.safety.ops").undo(repo)
  end)
  eq(err, "nothing to undo")
  S.run(function()
    return require("trellis.actions").tag_create(repo, "t1")
  end)
  S.run(function()
    return require("trellis.safety.ops").undo(repo)
  end)
  S.run(function()
    return require("trellis.actions").tag_create(repo, "t2")
  end)
  local _, rerr = S.run(function()
    return require("trellis.safety.ops").redo(repo)
  end)
  eq(rerr, "nothing to redo")
end

T["undo"]["repository changed since the operation: asks before restoring"] = function()
  local r = fixtures.fresh("linear")
  local repo = S.repo(r.path)
  S.auto_confirm(true)
  S.run(function()
    return require("trellis.actions").branch_create(repo, "feature", "HEAD~1")
  end)
  -- Someone moves the branch outside trellis.
  r:git({ "branch", "-f", "feature", "HEAD~2" })
  S.auto_confirm(false)
  local _, err = S.run(function()
    return require("trellis.safety.ops").undo(repo)
  end)
  eq(err, "cancelled")
  eq(S.asked[1].title:find("changed since", 1, true) ~= nil, true)
  eq(r:rev("feature"), r:rev("HEAD~2"))
end

T["undo"]["prune deletes backups beyond retention and keeps recent ones"] = function()
  local r = fixtures.fresh("linear")
  local repo = S.repo(r.path)
  S.auto_confirm(true)
  local ids = {}
  for i = 1, 3 do
    local op = S.run(function()
      return require("trellis.actions").tag_create(repo, "p" .. i)
    end)
    ids[i] = op.id
    S.run(function()
      return require("trellis.actions").tag_delete(repo, "p" .. i)
    end)
  end
  require("trellis").setup({ safety = { backup_max_ops = 2 } })
  local n, err = S.run(function()
    return require("trellis.safety.ops").prune(repo)
  end)
  eq(err, nil)
  eq(n, 4)
  -- The 2 newest operations (p3 create + delete) keep their backups.
  local list = journal.read(repo)
  eq(#S.backup_refs(r, list[#list].id) > 0, true)
  eq(#S.backup_refs(r, ids[1]), 0)
  eq(journal.get(repo, ids[1]).pruned, true)
  -- Only trellis refs were deleted.
  eq(#vim.tbl_filter(function(l)
    return l:match("refs/tags/")
  end, S.state(r).refs), 0)
  eq(r:rev("HEAD") ~= nil, true)
end

return require("tests.helpers.child").run_in_child(T, "tests/integration/safety_spec.lua")
