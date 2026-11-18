-- Merge topologies: the graph engine's hard cases.
local S = {}
local function add(name, desc, build)
  S[#S + 1] = { name = name, desc = desc, build = build }
end

local function branch_commits(r, name, from, n)
  r:branch(name, from)
  r:switch(name)
  for i = 1, n do
    r:commit({ msg = name .. " " .. i, files = { [name .. ".txt"] = i .. "\n" } })
  end
end

add("simple-merge", "one feature branch merged into main", function(r)
  r:commit({ msg = "root", files = { ["a.txt"] = "a\n" } })
  branch_commits(r, "feature", "main", 2)
  r:switch("main")
  r:commit({ msg = "main 1", files = { ["m.txt"] = "1\n" } })
  r:merge({ "feature" })
end)

add("merge-sequence", "three branches merged one after another", function(r)
  r:commit({ msg = "root", files = { ["a.txt"] = "a\n" } })
  for _, b in ipairs({ "b1", "b2", "b3" }) do
    branch_commits(r, b, "main", 2)
    r:switch("main")
  end
  for _, b in ipairs({ "b1", "b2", "b3" }) do
    r:merge({ b })
  end
end)

local function octopus(n)
  return function(r)
    r:commit({ msg = "root", files = { ["a.txt"] = "a\n" } })
    local names = {}
    for i = 1, n do
      names[i] = "o" .. i
      branch_commits(r, names[i], "main", 1)
      r:switch("main")
    end
    r:commit({ msg = "main before octopus", files = { ["m.txt"] = "1\n" } })
    r:merge(names, { msg = "Octopus " .. n })
    r:commit({ msg = "after octopus", files = { ["m.txt"] = "2\n" } })
  end
end
add("octopus-3", "octopus merge with 3 branches", octopus(3))
add("octopus-5", "octopus merge with 5 branches", octopus(5))

add("criss-cross", "two branches merging each other (criss-cross)", function(r)
  r:commit({ msg = "A", files = { ["a.txt"] = "a\n" } })
  r:branch("side")
  local b = r:commit_sha({ msg = "B", files = { ["b.txt"] = "b\n" } })
  r:switch("side")
  local c = r:commit_sha({ msg = "C", files = { ["c.txt"] = "c\n" } })
  r:switch("main")
  r:merge({ c }, { msg = "D = merge C into main" })
  r:switch("side")
  r:merge({ b }, { msg = "E = merge B into side" })
  r:commit({ msg = "side after", files = { ["c.txt"] = "c2\n" } })
  r:switch("main")
  r:commit({ msg = "main after", files = { ["b.txt"] = "b2\n" } })
  r:merge({ "side" }, { msg = "final criss-cross merge" })
end)

add("merge-of-merges", "feature with its own sub-feature merge, then merged", function(r)
  r:commit({ msg = "root", files = { ["a.txt"] = "a\n" } })
  branch_commits(r, "feature", "main", 1)
  branch_commits(r, "sub", "feature", 2)
  r:switch("feature")
  r:commit({ msg = "feature 2", files = { ["feature.txt"] = "2\n" } })
  r:merge({ "sub" })
  r:switch("main")
  r:commit({ msg = "main 1", files = { ["m.txt"] = "1\n" } })
  r:merge({ "feature" })
end)

add("back-merge", "main merged into feature, then feature into main", function(r)
  r:commit({ msg = "root", files = { ["a.txt"] = "a\n" } })
  branch_commits(r, "feature", "main", 1)
  r:switch("main")
  r:commit({ msg = "main 1", files = { ["m.txt"] = "1\n" } })
  r:switch("feature")
  r:merge({ "main" }, { msg = "Merge main into feature" })
  r:commit({ msg = "feature 2", files = { ["feature.txt"] = "2\n" } })
  r:switch("main")
  r:commit({ msg = "main 2", files = { ["m.txt"] = "2\n" } })
  r:merge({ "feature" })
end)

add("crossing-merges", "branches merged in reverse creation order (crossing edges)", function(r)
  r:commit({ msg = "root", files = { ["a.txt"] = "a\n" } })
  for _, b in ipairs({ "x1", "x2", "x3" }) do
    branch_commits(r, b, "main", 2)
    r:switch("main")
    r:commit({ msg = "main after " .. b, files = { ["m.txt"] = b .. "\n" } })
  end
  for _, b in ipairs({ "x3", "x1", "x2" }) do
    r:merge({ b })
  end
end)

add("multiple-roots", "an unrelated history merged in", function(r)
  r:commit({ msg = "main root", files = { ["a.txt"] = "a\n" } })
  r:commit({ msg = "main 2", files = { ["a.txt"] = "b\n" } })
  r:orphan("other")
  r:commit({ msg = "other root", files = { ["o.txt"] = "o\n" } })
  r:commit({ msg = "other 2", files = { ["o.txt"] = "p\n" } })
  r:switch("main")
  r:merge({ "other" }, { unrelated = true, msg = "Merge unrelated history" })
end)

add("orphan-unmerged", "two disjoint histories (gh-pages style)", function(r)
  r:commit({ msg = "main 1", files = { ["a.txt"] = "1\n" } })
  r:commit({ msg = "main 2", files = { ["a.txt"] = "2\n" } })
  r:orphan("gh-pages")
  r:commit({ msg = "pages 1", files = { ["index.html"] = "1\n" } })
  r:commit({ msg = "pages 2", files = { ["index.html"] = "2\n" } })
  r:switch("main")
end)

add("wide-branches", "16 branches from the root merged one by one (many lanes)", function(r)
  r:commit({ msg = "root", files = { ["a.txt"] = "a\n" } })
  local names = {}
  for i = 1, 16 do
    names[i] = ("w%02d"):format(i)
    branch_commits(r, names[i], "main", 1)
    r:switch("main")
  end
  for _, b in ipairs(names) do
    r:merge({ b })
  end
end)

add("long-lived", "feature that merges main four times", function(r)
  r:commit({ msg = "root", files = { ["a.txt"] = "a\n" } })
  r:branch("feature")
  for i = 1, 4 do
    r:switch("main")
    r:commit({ msg = "main " .. i, files = { ["m.txt"] = i .. "\n" } })
    r:switch("feature")
    r:commit({ msg = "feature " .. i, files = { ["f.txt"] = i .. "\n" } })
    r:merge({ "main" }, { msg = "Merge main into feature (" .. i .. ")" })
  end
  r:switch("main")
end)

add("fork-same-parent", "three unmerged branches from the same commit", function(r)
  r:commit({ msg = "root", files = { ["a.txt"] = "a\n" } })
  r:commit({ msg = "fork point", files = { ["a.txt"] = "b\n" } })
  for _, b in ipairs({ "k1", "k2", "k3" }) do
    branch_commits(r, b, "main", 2)
    r:switch("main")
  end
  r:commit({ msg = "main moves on", files = { ["a.txt"] = "c\n" } })
end)

add("stacked", "stacked branches s1 <- s2 <- s3 on main", function(r)
  r:commit({ msg = "root", files = { ["a.txt"] = "a\n" } })
  r:commit({ msg = "main 2", files = { ["a.txt"] = "b\n" } })
  branch_commits(r, "s1", "main", 2)
  branch_commits(r, "s2", "s1", 2)
  branch_commits(r, "s3", "s2", 1)
  r:switch("main")
end)

add("nested-octopus", "octopus merge on a branch, then merged into main", function(r)
  r:commit({ msg = "root", files = { ["a.txt"] = "a\n" } })
  branch_commits(r, "hub", "main", 1)
  local spokes = {}
  for i = 1, 3 do
    spokes[i] = "spoke" .. i
    branch_commits(r, spokes[i], "hub", 1)
  end
  r:switch("hub")
  r:merge(spokes, { msg = "Octopus on hub" })
  r:switch("main")
  r:commit({ msg = "main 1", files = { ["m.txt"] = "1\n" } })
  r:merge({ "hub" })
end)

return S
