local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local show = require("trellis.git.parse.show")

local A = ("a"):rep(40)

T["details"] = function()
  local out = table.concat({
    A,
    ("b"):rep(40) .. " " .. ("c"):rep(40),
    "Alice",
    "alice@example.com",
    "1700000000",
    "1700000000 +0700",
    "Bob",
    "bob@example.com",
    "1700000060",
    "1700000060 -0130",
    "G",
    "Alice <alice@example.com>",
    "Subject line\n\nBody line 1\nBody line 2\n\n",
  }, "\0")
  local d = show.parse_details(out)
  eq(d.sha, A)
  eq(d.parents, { ("b"):rep(40), ("c"):rep(40) })
  eq(d.author, { name = "Alice", email = "alice@example.com", time = 1700000000, tz = "+0700" })
  eq(d.committer.tz, "-0130")
  eq(d.committer.time, 1700000060)
  eq(d.signature, { status = "G", signer = "Alice <alice@example.com>" })
  eq(d.body, "Subject line\n\nBody line 1\nBody line 2")
end

T["unsigned commit has no signature"] = function()
  local out = table.concat(
    { A, "", "a", "e", "1", "1 +0000", "c", "e", "1", "1 +0000", "N", "", "x\n" },
    "\0"
  )
  eq(show.parse_details(out).signature, nil)
  eq(show.parse_details(out).parents, {})
  eq(show.parse_details("garbage"), nil)
end

T["numstat with renames, binaries and odd paths"] = function()
  local s = "3\t1\tsrc/a.lua\0"
    .. "-\t-\tassets/logo.png\0"
    .. "0\t0\t\0old name.txt\0new name.txt\0"
    .. "10\t0\tdir/tab\there.txt\0"
  eq(show.parse_numstat(s), {
    { added = 3, removed = 1, binary = false, path = "src/a.lua" },
    { binary = true, path = "assets/logo.png" },
    { added = 0, removed = 0, binary = false, old_path = "old name.txt", path = "new name.txt" },
    { added = 10, removed = 0, binary = false, path = "dir/tab\there.txt" },
  })
  eq(show.parse_numstat(""), {})
end

T["name-status and merge"] = function()
  local ns = show.parse_name_status(
    "M\0src/a.lua\0A\0assets/logo.png\0R087\0old name.txt\0new name.txt\0D\0gone\0"
  )
  eq(ns[3], { status = "R", score = 87, old_path = "old name.txt", path = "new name.txt" })
  eq(ns[4], { status = "D", path = "gone" })
  local stats = show.parse_numstat("3\t1\tsrc/a.lua\0-\t-\tassets/logo.png\0")
  local files = show.merge_changes(stats, ns)
  eq(files[1], { status = "M", path = "src/a.lua", added = 3, removed = 1, binary = false })
  eq(files[2].binary, true)
  eq(files[3].old_path, "old name.txt")
  eq(files[4].added, nil)
end

return T
