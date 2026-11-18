-- T060 (line mapping properties), permalink URLs (T066), line-log parsing (T065).
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local linemap = require("trellis.linemap")
local permalink = require("trellis.permalink")
local linelog = require("trellis.git.parse.linelog")
local check = require("tests.helpers.graph_check")

T["linemap properties"] = MiniTest.new_set()

--- Random edit script → old lines, new lines and the -U0 hunks between them.
local function random_edit(rand, n)
  local old, new, hunks = {}, {}, {}
  for i = 1, n do
    old[i] = "l" .. i
  end
  local i = 1
  while i <= n + 1 do
    local r = rand()
    if r < 0.15 and i <= n then -- delete a run
      local k = math.min(n - i + 1, 1 + math.floor(rand() * 3))
      hunks[#hunks + 1] = { old_start = i, old_count = k, new_start = #new, new_count = 0 }
      i = i + k
    elseif r < 0.3 then -- insert a run before old line i
      local k = 1 + math.floor(rand() * 3)
      hunks[#hunks + 1] = { old_start = i - 1, old_count = 0, new_start = #new + 1, new_count = k }
      for j = 1, k do
        new[#new + 1] = "ins" .. i .. "." .. j
      end
      if i <= n then
        new[#new + 1] = old[i]
      end
      i = i + 1
    elseif r < 0.4 and i <= n then -- modify one line into 1–2 lines
      local k = 1 + math.floor(rand() * 2)
      hunks[#hunks + 1] = { old_start = i, old_count = 1, new_start = #new + 1, new_count = k }
      for j = 1, k do
        new[#new + 1] = "mod" .. i .. "." .. j
      end
      i = i + 1
    else
      if i <= n then
        new[#new + 1] = old[i]
      end
      i = i + 1
    end
  end
  return old, new, hunks
end

T["linemap properties"]["unchanged lines map exactly, both directions"] = function()
  local rand = check.prng(31337)
  for _ = 1, 300 do
    local old, new, hunks = random_edit(rand, 5 + math.floor(rand() * 30))
    local new_index = {}
    for j, l in ipairs(new) do
      new_index[l] = j
    end
    for i, l in ipairs(old) do
      local j = new_index[l]
      if j then
        eq({ line = i, fwd = linemap.map_line(hunks, i) }, { line = i, fwd = j })
        eq({ line = j, back = linemap.map_line(hunks, j, "backward") }, { line = j, back = i })
      end
    end
    -- Every result is a valid line number of the other side.
    for i = 1, #old do
      local j = linemap.map_line(hunks, i)
      eq(j >= 1 and j <= math.max(1, #new), true)
    end
  end
end

T["permalink"] = MiniTest.new_set()

T["permalink"]["remote URL forms"] = function()
  local cases = {
    ["https://github.com/owner/repo.git"] = { host = "github.com", repo = "owner/repo" },
    ["https://github.com/owner/repo"] = { host = "github.com", repo = "owner/repo" },
    ["git@github.com:owner/repo.git"] = { host = "github.com", repo = "owner/repo" },
    ["ssh://git@gitlab.example.com:2222/group/sub/repo.git"] = {
      host = "gitlab.example.com",
      repo = "group/sub/repo",
    },
    ["https://user:token@bitbucket.org/team/repo.git"] = {
      host = "bitbucket.org",
      repo = "team/repo",
    },
    ["https://codeberg.org/me/thing/"] = { host = "codeberg.org", repo = "me/thing" },
  }
  for url, want in pairs(cases) do
    eq({ url = url, got = permalink.parse_remote(url) }, { url = url, got = want })
  end
  eq(permalink.parse_remote("not a url"), nil)
end

T["permalink"]["file and commit URLs per forge"] = function()
  local sha = ("a"):rep(40)
  local function url(remote, o)
    return (permalink.build(remote, vim.tbl_extend("force", { sha = sha }, o or {})))
  end
  eq(
    url("git@github.com:o/r.git", { path = "src/a b.lua", line1 = 3, line2 = 9 }),
    "https://github.com/o/r/blob/" .. sha .. "/src/a%20b.lua#L3-L9"
  )
  eq(
    url("git@github.com:o/r.git", { path = "x.lua", line1 = 3, line2 = 3 }),
    "https://github.com/o/r/blob/" .. sha .. "/x.lua#L3"
  )
  eq(url("https://github.com/o/r"), "https://github.com/o/r/commit/" .. sha)
  eq(
    url("https://gitlab.com/g/r.git", { path = "x", line1 = 1, line2 = 2 }),
    "https://gitlab.com/g/r/-/blob/" .. sha .. "/x#L1-2"
  )
  eq(
    url("https://codeberg.org/u/r.git", { path = "x", line1 = 1, line2 = 2 }),
    "https://codeberg.org/u/r/src/commit/" .. sha .. "/x#L1-L2"
  )
  eq(
    url("git@bitbucket.org:t/r.git", { path = "x", line1 = 4, line2 = 5 }),
    "https://bitbucket.org/t/r/src/" .. sha .. "/x#lines-4:5"
  )
  eq(url("git@bitbucket.org:t/r.git"), "https://bitbucket.org/t/r/commits/" .. sha)
  local _, err = permalink.build("https://git.example.com/a/b", { sha = sha })
  eq(err, "unknown forge git.example.com: add it to permalink.patterns")
  eq(
    url("https://git.example.com/a/b", {
      patterns = { ["example%.com"] = "{base}/view/{sha}/{path}?l={line1}" },
      path = "p",
      line1 = 7,
    }),
    "https://git.example.com/a/b/view/" .. sha .. "/p?l=7"
  )
end

T["line log records with patches"] = function()
  local A, B = ("a"):rep(40), ("b"):rep(40)
  local text = "\30"
    .. table.concat({ B, A, "Alice", "2", "retry\30 = 2", "" }, "\0")
    .. "\n\n"
    .. table.concat({
      "diff --git a/src/api.lua b/src/api.lua",
      "--- a/src/api.lua",
      "+++ b/src/api.lua",
      "@@ -4,1 +4,1 @@",
      "-retry = 1",
      "+retry = 2",
    }, "\n")
    .. "\n"
    .. "\30"
    .. table.concat({ A, "", "Alice", "1", "add", "" }, "\0")
    .. "\n\n"
    .. table.concat({
      "diff --git a/src/api.lua b/src/api.lua",
      "--- /dev/null",
      "+++ b/src/api.lua",
      "@@ -0,0 +4,1 @@",
      "+retry = 1",
    }, "\n")
    .. "\n"
  local list = linelog.parse(text)
  eq(#list, 2)
  eq(list[1].subject, "retry\30 = 2")
  eq(list[1].files[1].hunks[1].lines, { "-retry = 1", "+retry = 2" })
  eq(list[2].parents, {})
  eq(list[2].files[1].hunks[1].new_start, 4)
end

return T
