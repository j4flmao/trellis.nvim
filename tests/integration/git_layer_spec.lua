-- T015, T016, T018, T019: runner, stream, repository discovery, refs on fixture repositories.
local fixtures = require("tests.fixtures")
local argv = require("trellis.git.argv")
local runner = require("trellis.git.runner")
local stream = require("trellis.git.stream")
local repo_mod = require("trellis.git.repo")
local refs = require("trellis.git.refs")
local log = require("trellis.git.parse.log")

-- Runs in a child Neovim per case (tests/helpers/child.lua): these cases wait on git callbacks.
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function wait_for(fn, ms)
  local done, a, b = false, nil, nil
  fn(function(x, y)
    done, a, b = true, x, y
  end)
  vim.wait(ms or 10000, function()
    return done
  end, 5)
  assert(done, "timed out")
  return a, b
end

local function discover(path)
  return wait_for(function(cb)
    repo_mod.discover(path, cb)
  end)
end

-- runner -------------------------------------------------------------------------------------

T["runner"] = MiniTest.new_set()

T["runner"]["success, failure, ok_codes and the command log"] = function()
  local r = fixtures.get("linear")
  local before = #runner.history
  local err, res = wait_for(function(cb)
    runner.run(r.path, { "rev-parse", "HEAD" }, nil, cb)
  end)
  eq(err, nil)
  eq(#vim.trim(res.stdout), 40)
  local entry = runner.history[#runner.history]
  eq(#runner.history, before + 1)
  eq(entry.argv[1], "git")
  eq(entry.code, 0)
  eq(type(entry.duration_ms), "number")

  err = wait_for(function(cb)
    runner.run(r.path, { "rev-parse", "--verify", "no-such-ref" }, nil, cb)
  end)
  eq(err:match("^git failed: ") ~= nil, true)

  err = wait_for(function(cb)
    runner.run(r.path, argv.G05("symbolic").args, { ok_codes = { 1 } }, cb)
  end)
  eq(err, nil)
end

T["runner"]["stdin and sync variant"] = function()
  local r = fixtures.get("single")
  local err, res = runner.run_sync(r.path, { "hash-object", "--stdin" }, { stdin = "hello\n" })
  eq(err, nil)
  eq(vim.trim(res.stdout), "ce013625030ba8dba906f756967f9e9ca394464a")
end

-- stream -------------------------------------------------------------------------------------

T["stream"] = MiniTest.new_set()

local function collect_stream(r, args, opts)
  local parser = log.new_parser()
  local commits, done, code = {}, false, nil
  local s = stream.start(
    r.path,
    args,
    vim.tbl_extend("force", {
      on_records = function(recs)
        vim.list_extend(commits, parser.push(recs))
      end,
      on_exit = function(c)
        vim.list_extend(commits, parser.finish())
        code, done = c, true
      end,
    }, opts or {})
  )
  return s,
    commits,
    function()
      vim.wait(10000, function()
        return done
      end, 5)
      return done, code
    end
end

T["stream"]["delivers the same commits as git log"] = function()
  local r = fixtures.get("wide-branches")
  local q = { revs = { "--branches", "--tags", "HEAD" }, order = "topo" }
  local _, commits, wait = collect_stream(r, argv.G10(q).args)
  local done, code = wait()
  eq({ done, code }, { true, 0 })
  local expected = r:topo({ "--branches", "--tags", "HEAD" })
  eq(#commits, #expected)
  for i = 1, #expected do
    eq(commits[i].sha, expected[i].sha)
  end
end

T["stream"]["pause stops delivery, resume continues to EOF"] = function()
  local dir = require("tests.fixtures.fastimport.gen").build(
    require("tests.helpers.repo").root .. "/.tests/fixtures/synthetic-20k",
    { commits = 20000, merge_ratio = 0.1 }
  )
  local s, commits, wait =
    collect_stream({ path = dir }, argv.G10({ revs = { "--all" }, order = "topo" }).args)
  vim.wait(5000, function()
    return #commits > 0
  end, 1)
  s.pause()
  vim.wait(50)
  local n = #commits
  vim.wait(300)
  -- At most the batches already scheduled before pause() may land.
  eq(#commits - n < 2000, true)
  eq(s.paused(), true)
  eq(s.done(), false)
  s.resume()
  local done, code = wait()
  eq({ done, code }, { true, 0 })
  eq(#commits, 20000)
end

T["stream"]["kill ends the process early"] = function()
  local dir = require("tests.helpers.repo").root .. "/.tests/fixtures/synthetic-20k"
  local s, commits, wait =
    collect_stream({ path = dir }, argv.G10({ revs = { "--all" }, order = "topo" }).args)
  vim.wait(5000, function()
    return #commits > 0
  end, 1)
  s.kill()
  local done = wait()
  eq(done, true)
  eq(#commits < 20000, true)
end

T["stream"]["records split across chunks; custom separator"] = function()
  local r = fixtures.get("control-chars")
  local _, commits, wait = collect_stream(r, argv.G10({ revs = { "HEAD" }, order = "topo" }).args)
  wait()
  eq(commits[1].subject, "ends with RS\30")
  local lines, done = {}, false
  stream.start(r.path, { "rev-list", "HEAD" }, {
    sep = "\n",
    on_records = function(recs)
      vim.list_extend(lines, recs)
    end,
    on_exit = function()
      done = true
    end,
  })
  vim.wait(5000, function()
    return done
  end, 5)
  eq(#lines, 5)
end

-- repo ---------------------------------------------------------------------------------------

T["repo"] = MiniTest.new_set()

T["repo"]["discovers root, gitdir, commondir and features"] = function()
  local r = fixtures.get("linear")
  local err, repo = discover(r.path)
  eq(err, nil)
  eq(repo.root, r.path)
  eq(repo.gitdir, r.path .. "/.git")
  eq(repo.commondir, r.path .. "/.git")
  eq(repo.shallow, false)
  eq(repo.state.kind, "clean")
  eq(repo.features.supported, true)
  eq(repo.features.sha256, false)
  eq(#repo.worktrees, 1)
  eq(repo.worktrees[1].current, true)
  -- Cached instance is reused.
  local _, again = discover(r.path .. "/")
  eq(again == repo, true)
end

T["repo"]["subdirectory, not a repository"] = function()
  local r = fixtures.get("rename-chain")
  local _, repo = discover(r.path .. "/src")
  eq(repo.root, r.path)
  -- Outside any repository (the checkout itself is one, so not under .tests/).
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local err = discover(tmp)
  eq(type(err) == "string" and err:match("^not a git repository") ~= nil, true)
  vim.fn.delete(tmp, "rf")
end

T["repo"]["linked worktrees share the common dir"] = function()
  local r = fixtures.get("worktrees")
  local wt = r.path .. ".aux-wt-a"
  local _, repo = discover(wt)
  eq(repo.root, wt)
  eq(repo.commondir, r.path .. "/.git")
  eq(repo.gitdir, r.path .. "/.git/worktrees/" .. vim.fs.basename(wt))
  eq(#repo.worktrees, 3)
  local current = vim.tbl_filter(function(w)
    return w.current
  end, repo.worktrees)
  eq(#current, 1)
  eq(current[1].branch, "refs/heads/wt-a")
end

T["repo"]["shallow, sha256, unborn"] = function()
  local _, shallow = discover(fixtures.get("shallow").path)
  eq(shallow.shallow, true)
  local _, sha256 = discover(fixtures.get("sha256").path)
  eq(sha256.features.sha256, true)
  local err, unborn = discover(fixtures.get("unborn").path)
  eq(err, nil)
  eq(unborn.state.kind, "clean")
end

T["repo"]["in-progress operations"] = function()
  for name, kind in pairs({
    ["in-progress-rebase"] = "rebase",
    ["in-progress-merge"] = "merge",
    ["in-progress-cherry-pick"] = "cherry-pick",
  }) do
    local _, repo = discover(fixtures.get(name).path)
    eq({ name = name, kind = repo.state.kind, external = repo.state.external }, {
      name = name,
      kind = kind,
      external = true,
    })
  end
  local _, rb = discover(fixtures.get("in-progress-rebase").path)
  eq(rb.state.rebase.head_name, "refs/heads/topic")
  eq(#rb.state.rebase.onto, 40)
end

T["repo"]["worktree porcelain without -z"] = function()
  local out = "worktree /a\nHEAD "
    .. ("1"):rep(40)
    .. "\nbranch refs/heads/main\n\nworktree /b\nHEAD "
    .. ("2"):rep(40)
    .. "\ndetached\nlocked reason\n\n"
  local list = repo_mod.parse_worktrees(out, false)
  eq(#list, 2)
  eq(list[2].detached, true)
  eq(list[2].locked, true)
  eq(list[1].branch, "refs/heads/main")
end

-- refs ---------------------------------------------------------------------------------------

T["refs"] = MiniTest.new_set()

local function load_refs(name)
  local _, repo = discover(fixtures.get(name).path)
  local err, map = wait_for(function(cb)
    refs.load(repo, cb)
  end)
  eq(err, nil)
  return map, repo
end

T["refs"]["kinds, peeled tags, HEAD first"] = function()
  local map = load_refs("tags")
  local r = fixtures.get("tags")
  local tip = r:rev("HEAD")
  local kinds = vim.tbl_map(function(ref)
    return ref.kind .. ":" .. ref.short
  end, map.by_sha[tip])
  eq(kinds, { "head:HEAD", "local:main", "tag:latest", "tag:v1.0.0" })
  -- Annotated tag on an inner commit is peeled to the commit.
  eq(map.by_name["refs/tags/v0.2-annotated"].target, r:rev("HEAD~1"))
  eq(map.head.detached, false)
  eq(map.head.ref, "refs/heads/main")
  eq(map.by_name["refs/heads/main"].current, true)
end

T["refs"]["remotes, upstream, origin/HEAD skipped"] = function()
  local map = load_refs("remote-branches")
  eq(map.by_name["refs/remotes/origin/main"].kind, "remote")
  eq(map.by_name["refs/remotes/origin/HEAD"], nil)
  eq(map.by_name["refs/heads/main"].upstream, "refs/remotes/origin/main")
end

T["refs"]["detached HEAD, stash, backups, worktrees"] = function()
  local d = load_refs("detached-head")
  eq(d.head.detached, true)
  eq(d.head.ref, nil)

  local s = load_refs("stash")
  local stash = s.by_name["refs/stash"]
  eq(stash.kind, "stash")
  eq(#refs.decorations(s, stash.target), 0)
  eq(#refs.decorations(s, stash.target, { show_stashes = true }), 1)

  local b = load_refs("backup-refs")
  local backup = b.by_name["refs/trellis/backup/20261117T000000-0000/heads/main"]
  eq(backup.kind, "backup")
  eq(#refs.decorations(b, backup.target), 0)

  local w = load_refs("worktrees")
  local wt = vim.tbl_filter(function(ref)
    return ref.kind == "worktree"
  end, vim.tbl_values(w.by_name))
  eq(#wt, 2)
end

T["refs"]["unborn repository has no HEAD sha"] = function()
  local map = load_refs("unborn")
  eq(map.head.sha, nil)
  eq(map.head.ref, "refs/heads/main")
  eq(next(map.by_sha), nil)
end

T["refs"]["10k tags parse in under 100 ms; generation increments"] = function()
  local r = fixtures.get("many-tags")
  local out = r:git(argv.G04().args)
  local t0 = vim.uv.hrtime()
  local map = refs.parse(out, { detached = false, sha = r:rev("HEAD"), ref = "refs/heads/main" })
  local ms = (vim.uv.hrtime() - t0) / 1e6
  eq(vim.tbl_count(map.by_name), 10000 + 1 + 1)
  eq(ms < 100, true)
  local map2 = refs.parse(out, map.head, { generation = map.generation })
  eq(map2.generation, map.generation + 1)
end

return require("tests.helpers.child").run_in_child(T, "tests/integration/git_layer_spec.lua")
