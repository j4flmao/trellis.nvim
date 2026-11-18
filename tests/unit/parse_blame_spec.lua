local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local blame = require("trellis.git.parse.blame")

local A, B = ("a"):rep(40), ("b"):rep(40)

local OUTPUT = table.concat({
  A .. " 1 1 2",
  "author Alice",
  "author-mail <alice@example.com>",
  "author-time 1700000000",
  "author-tz +0000",
  "committer Alice",
  "committer-mail <alice@example.com>",
  "committer-time 1700000000",
  "committer-tz +0000",
  "summary add retry",
  "previous " .. B .. " src/old api.lua",
  "filename src/api.lua",
  B .. " 5 3 1",
  "author Bob",
  "author-mail <bob@example.com>",
  "author-time 1690000000",
  "author-tz +0200",
  "committer Bob",
  "committer-mail <bob@example.com>",
  "committer-time 1690000000",
  "committer-tz +0200",
  "summary initial",
  "boundary",
  "filename src/api.lua",
  A .. " 4 4 1",
  "previous " .. B .. " src/old api.lua",
  "filename src/api.lua",
  blame.UNCOMMITTED .. " 5 5 1",
  "author Not Committed Yet",
  "author-mail <not.committed.yet>",
  "author-time 1700000100",
  "author-tz +0000",
  "committer Not Committed Yet",
  "committer-mail <not.committed.yet>",
  "committer-time 1700000100",
  "committer-tz +0000",
  "summary Version of src/api.lua from src/api.lua",
  "previous " .. A .. " src/api.lua",
  'filename "src/api\\tx.lua"',
  "",
}, "\n")

T["entries, commit headers once, previous and boundary"] = function()
  local entries, commits = blame.parse(OUTPUT)
  eq(#entries, 4)
  eq(entries[1], {
    sha = A,
    orig_line = 1,
    final_line = 1,
    num_lines = 2,
    previous = { sha = B, path = "src/old api.lua" },
    filename = "src/api.lua",
  })
  eq(entries[3].previous.sha, B)
  eq(entries[4].sha, blame.UNCOMMITTED)
  eq(entries[4].filename, "src/api\tx.lua")
  eq(commits[A].author, "Alice")
  eq(commits[A]["author-time"], 1700000000)
  eq(commits[A].summary, "add retry")
  eq(commits[B].boundary, true)
  eq(commits[A].boundary, nil)
end

T["streaming in arbitrary chunks gives the same result"] = function()
  local expected_entries, expected_commits = blame.parse(OUTPUT)
  for size = 1, 60, 7 do
    local p = blame.new_parser()
    local got = {}
    for pos = 1, #OUTPUT, size do
      vim.list_extend(got, p.push(OUTPUT:sub(pos, pos + size - 1)))
    end
    vim.list_extend(got, p.finish())
    eq(got, expected_entries)
    eq(p.commits, expected_commits)
  end
end

T["output without trailing newline"] = function()
  local entries = blame.parse(A .. " 1 1 1\nauthor x\nfilename f")
  eq(#entries, 1)
end

return T
