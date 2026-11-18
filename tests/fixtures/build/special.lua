-- Repository states: shallow, in-progress operations, SHA-256.
local S = {}
local function add(name, desc, build)
  S[#S + 1] = { name = name, desc = desc, build = build }
end

add("shallow", "depth-2 clone of a 5-commit history (grafted root)", function(r, ctx)
  local src = ctx.aux("src")
  for i = 1, 5 do
    src:commit({ msg = "c" .. i, files = { ["a.txt"] = i .. "\n" } })
  end
  local path = r.path
  return src:clone(path, { "--depth=2" })
end)

local function conflict_setup(r)
  r:commit({ msg = "base", files = { ["f.txt"] = "base\n" } })
  r:branch("topic")
  r:commit({ msg = "main change", files = { ["f.txt"] = "main\n" } })
  r:switch("topic")
  r:commit({ msg = "topic change", files = { ["f.txt"] = "topic\n" } })
end

add("in-progress-rebase", "rebase stopped on a conflict", function(r)
  conflict_setup(r)
  r:git({ "rebase", "main" }, { allow_fail = true, env = r:env() })
end)

add("in-progress-merge", "merge stopped on a conflict", function(r)
  conflict_setup(r)
  r:switch("main")
  r:merge({ "topic" }, { allow_fail = true })
end)

add("in-progress-cherry-pick", "cherry-pick stopped on a conflict", function(r)
  conflict_setup(r)
  r:switch("main")
  r:git({ "cherry-pick", "topic" }, { allow_fail = true, env = r:env() })
end)

add("sha256", "SHA-256 object format repository with a merge", function(r)
  vim.fn.delete(r.path .. "/.git", "rf")
  r:git({ "init", "-q", "-b", "main", "--object-format=sha256" })
  r:commit({ msg = "root", files = { ["a.txt"] = "a\n" } })
  r:branch("side")
  r:commit({ msg = "main", files = { ["a.txt"] = "b\n" } })
  r:switch("side")
  r:commit({ msg = "side", files = { ["s.txt"] = "s\n" } })
  r:switch("main")
  r:merge({ "side" })
end)

return S
