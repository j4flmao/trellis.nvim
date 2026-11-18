-- Ref decorations: tags, remotes, stash, worktrees, backups, unusual names.
local S = {}
local function add(name, desc, build)
  S[#S + 1] = { name = name, desc = desc, build = build }
end

add("tags", "lightweight and annotated tags, on tips and inner commits", function(r)
  r:commit({ msg = "root", files = { ["a.txt"] = "1\n" } })
  r:tag("v0.1")
  r:commit({ msg = "middle", files = { ["a.txt"] = "2\n" } })
  r:tag("v0.2-annotated", "HEAD", { msg = "annotated inner" })
  r:commit({ msg = "tip", files = { ["a.txt"] = "3\n" } })
  r:tag("v1.0.0", "HEAD", { msg = "release 1.0.0" })
  r:tag("latest")
end)

add("many-tags", "10,000 lightweight tags spread over 5 commits", function(r)
  local shas = {}
  for i = 1, 5 do
    shas[i] = r:commit_sha({ msg = "c" .. i, files = { ["a.txt"] = i .. "\n" } })
  end
  local lines = {}
  for i = 1, 10000 do
    lines[i] = ("create refs/tags/t%05d %s"):format(i, shas[(i % 5) + 1])
  end
  r:update_refs(lines)
end)

add("remote-branches", "remote-tracking branches, origin/HEAD and upstream config", function(r)
  local root = r:commit_sha({ msg = "root", files = { ["a.txt"] = "1\n" } })
  local c2 = r:commit_sha({ msg = "pushed", files = { ["a.txt"] = "2\n" } })
  r:commit({ msg = "local only", files = { ["a.txt"] = "3\n" } })
  r:update_refs({
    "create refs/remotes/origin/main " .. c2,
    "create refs/remotes/origin/old-feature " .. root,
    "create refs/remotes/upstream/main " .. root,
  })
  r:git({ "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" })
  r:git({ "config", "remote.origin.url", "https://github.com/example/demo.git" })
  r:git({ "config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*" })
  r:git({ "config", "branch.main.remote", "origin" })
  r:git({ "config", "branch.main.merge", "refs/heads/main" })
end)

add("stash", "one stash entry on top of history", function(r)
  r:commit({ msg = "root", files = { ["a.txt"] = "1\n" } })
  r:commit({ msg = "second", files = { ["a.txt"] = "2\n" } })
  r:write({ ["a.txt"] = "dirty\n" })
  r:git({ "stash", "push", "-q", "-m", "wip on main" }, { env = r:env() })
end)

add("worktrees", "two linked worktrees on their own branches", function(r, ctx)
  r:commit({ msg = "root", files = { ["a.txt"] = "1\n" } })
  r:branch("wt-a")
  r:branch("wt-b")
  r:commit({ msg = "main 2", files = { ["a.txt"] = "2\n" } })
  local pa, pb = ctx.aux_path("wt-a"), ctx.aux_path("wt-b")
  vim.fn.delete(pa, "rf")
  vim.fn.delete(pb, "rf")
  r:worktree(pa, "wt-a")
  r:worktree(pb, "wt-b")
  local a = require("tests.helpers.repo").open(pa)
  a.time = r.time
  a:commit({ msg = "work in a", files = { ["wa.txt"] = "a\n" } })
end)

add("backup-refs", "existing trellis backup refs", function(r)
  local c1 = r:commit_sha({ msg = "before rewrite", files = { ["a.txt"] = "1\n" } })
  r:commit({ msg = "after rewrite", files = { ["a.txt"] = "2\n" } })
  r:update_refs({
    "create refs/trellis/backup/20261117T000000-0000/heads/main " .. c1,
    "create refs/trellis/backup/20261117T000000-0000/HEAD " .. c1,
  })
end)

add("branch-names", "slashes, dots, unicode and case in branch names", function(r)
  r:commit({ msg = "root", files = { ["a.txt"] = "1\n" } })
  for _, name in ipairs({
    "feature/tính-năng",
    "fix/a.b",
    "release/1.0",
    "UPPER",
    "with-dash",
    "deep/nested/name",
  }) do
    r:branch(name)
  end
  r:commit({ msg = "main 2", files = { ["a.txt"] = "2\n" } })
end)

return S
