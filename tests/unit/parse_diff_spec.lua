local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local diff = require("trellis.git.parse.diff")
local util = require("trellis.git.parse.util")

T["modify, add, delete, rename in one patch"] = function()
  local text = table.concat({
    "diff --git a/src/a.lua b/src/a.lua",
    "index 1111111..2222222 100644",
    "--- a/src/a.lua",
    "+++ b/src/a.lua",
    "@@ -1,3 +1,4 @@ local M = {}",
    " one",
    "-two",
    "+TWO",
    "+extra",
    " three",
    "@@ -10 +11 @@",
    "-x",
    "+y",
    "diff --git a/new.txt b/new.txt",
    "new file mode 100644",
    "index 0000000..3333333",
    "--- /dev/null",
    "+++ b/new.txt",
    "@@ -0,0 +1 @@",
    "+hello",
    "\\ No newline at end of file",
    "diff --git a/old.txt b/old.txt",
    "deleted file mode 100755",
    "--- a/old.txt",
    "+++ /dev/null",
    "@@ -1 +0,0 @@",
    "--- this looks like a header but is a removed line",
    "diff --git a/from me.txt b/to me.txt",
    "similarity index 90%",
    "rename from from me.txt",
    "rename to to me.txt",
    "",
  }, "\n")
  local files = diff.parse(text)
  eq(#files, 4)
  eq(files[1].status, "M")
  eq(#files[1].hunks, 2)
  eq(files[1].hunks[1].header, "local M = {}")
  eq(files[1].hunks[1].lines, { " one", "-two", "+TWO", "+extra", " three" })
  eq({ files[1].hunks[2].old_start, files[1].hunks[2].old_count }, { 10, 1 })
  eq(files[2].status, "A")
  eq(files[2].old_path, nil)
  eq(files[2].new_path, "new.txt")
  eq(files[2].hunks[1].lines, { "+hello", "\\ No newline at end of file" })
  eq(files[3].status, "D")
  eq(files[3].new_path, nil)
  eq(files[3].hunks[1].lines, { "--- this looks like a header but is a removed line" })
  eq(files[4].status, "R")
  eq(files[4].similarity, 90)
  eq({ files[4].old_path, files[4].new_path }, { "from me.txt", "to me.txt" })
  -- Hunk lines that look like headers ("--- ...") must not change file paths.
  eq(files[3].old_path, "old.txt")
  eq(files[1].old_path, "src/a.lua")
end

T["binary and mode-only changes"] = function()
  local files = diff.parse(table.concat({
    "diff --git a/logo.png b/logo.png",
    "index 1111111..2222222 100644",
    "Binary files a/logo.png and b/logo.png differ",
    "diff --git a/run.sh b/run.sh",
    "old mode 100644",
    "new mode 100755",
  }, "\n"))
  eq(files[1].binary, true)
  eq(files[1].old_path, "logo.png")
  eq(files[2].status, "T")
  eq({ files[2].old_mode, files[2].new_mode }, { "100644", "100755" })
end

T["quoted paths"] = function()
  local files = diff.parse(table.concat({
    'diff --git "a/tab\\there" "b/tab\\there"',
    '--- "a/tab\\there"',
    '+++ "b/tab\\there"',
    "@@ -1 +1 @@",
    "-a",
    "+b",
  }, "\n"))
  eq(files[1].new_path, "tab\there")
  eq(util.unquote('"caf\\303\\251"'), "café")
  eq(util.unquote("plain"), "plain")
end

T["-U0 hunks"] = function()
  local files = diff.parse(table.concat({
    "diff --git a/f b/f",
    "--- a/f",
    "+++ b/f",
    "@@ -3,0 +4,2 @@",
    "+new1",
    "+new2",
    "@@ -7,2 +9,0 @@",
    "-gone1",
    "-gone2",
  }, "\n"))
  local h = files[1].hunks
  eq({ h[1].old_start, h[1].old_count, h[1].new_start, h[1].new_count }, { 3, 0, 4, 2 })
  eq({ h[2].old_start, h[2].old_count, h[2].new_start, h[2].new_count }, { 7, 2, 9, 0 })
end

T["hunk header parser"] = function()
  eq(diff.parse_hunk_header("@@ -1 +1 @@"), {
    old_start = 1,
    old_count = 1,
    new_start = 1,
    new_count = 1,
    header = "",
    lines = {},
  })
  eq(diff.parse_hunk_header("not a hunk"), nil)
end

return T
