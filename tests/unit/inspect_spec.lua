-- Pure pieces of the inspection views: line mapping, file-log parsing, content splitting.
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local linemap = require("trellis.linemap")
local filelog = require("trellis.git.parse.filelog")
local diff = require("trellis.git.parse.diff")

local function hunks(spec)
  local out = {}
  for _, h in ipairs(spec) do
    out[#out + 1] =
      { old_start = h[1], old_count = h[2], new_start = h[3], new_count = h[4], lines = {} }
  end
  return out
end

T["map_line"] = MiniTest.new_set()

T["map_line"]["insertions, deletions, modifications and boundaries"] = function()
  -- old:  1 2 3 4 5 6 7 8 9 10
  -- 2 lines inserted after old 3; old 6-7 deleted; old 9 modified into 3 lines.
  local h = hunks({ { 3, 0, 4, 2 }, { 6, 2, 7, 0 }, { 9, 1, 9, 3 } })
  local expect =
    { [1] = 1, [2] = 2, [3] = 3, [4] = 6, [5] = 7, [6] = 7, [7] = 7, [8] = 8, [9] = 9, [10] = 12 }
  for line, want in pairs(expect) do
    eq({ line = line, got = linemap.map_line(h, line) }, { line = line, got = want })
  end
  eq(linemap.map_line({}, 42), 42)
end

T["map_line"]["backward is the inverse on unchanged lines"] = function()
  local h = hunks({ { 3, 0, 4, 2 }, { 6, 2, 7, 0 }, { 9, 1, 9, 3 } })
  for _, old in ipairs({ 1, 2, 3, 4, 5, 8, 10 }) do
    local new = linemap.map_line(h, old)
    eq({ old = old, back = linemap.map_line(h, new, "backward") }, { old = old, back = old })
  end
  -- Inserted lines map back to the line they were inserted after (+1 clamp).
  eq(linemap.map_line(h, 4, "backward"), 3)
end

T["map_line"]["works on parsed -U0 output"] = function()
  local files = diff.parse(table.concat({
    "diff --git a/f b/f",
    "--- a/f",
    "+++ b/f",
    "@@ -1,0 +2 @@",
    "+new",
  }, "\n"))
  eq(linemap.map_line(files[1].hunks, 1), 1)
  eq(linemap.map_line(files[1].hunks, 2), 3)
end

T["filelog"] = MiniTest.new_set()

T["filelog"]["records with renames, deletes and RS in subjects"] = function()
  local A, B, C = ("a"):rep(40), ("b"):rep(40), ("c"):rep(40)
  local text = "\30"
    .. table.concat({ C, B, "Alice", "3", "rename\30with RS", "" }, "\0")
    .. "\n\nR087\tsrc/old.lua\tsrc/new.lua\n"
    .. "\30"
    .. table.concat({ B, A, "Bob", "2", "edit", "" }, "\0")
    .. "\n\nM\tsrc/old.lua\n"
    .. "\30"
    .. table.concat({ A, "", "Alice", "1", "add", "" }, "\0")
    .. '\n\nA\t"src/tab\\there.lua"\n'
  local list = filelog.parse(text)
  eq(#list, 3)
  eq(list[1].subject, "rename\30with RS")
  eq({ list[1].status, list[1].old_path, list[1].path }, { "R", "src/old.lua", "src/new.lua" })
  eq(list[1].parents, { B })
  eq({ list[2].status, list[2].path }, { "M", "src/old.lua" })
  eq(list[3].parents, {})
  eq(list[3].path, "src/tab\there.lua")
end

T["content splitting reproduces bytes"] = function()
  local split = require("trellis.view.filerev").split_content
  local cases = {
    { "a\nb\n", { "a", "b" }, "unix", true },
    { "a\nb", { "a", "b" }, "unix", false },
    { "a\r\nb\r\n", { "a", "b" }, "dos", true },
    { "a\r\nb\n", { "a\r", "b" }, "unix", true },
    { "", { "" }, "unix", false },
    { "\n", { "" }, "unix", true },
  }
  for _, c in ipairs(cases) do
    local lines, o = split(c[1])
    eq(
      { input = c[1], lines = lines, ff = o.fileformat, eol = o.eol },
      { input = c[1], lines = c[2], ff = c[3], eol = c[4] }
    )
    local nl = o.fileformat == "dos" and "\r\n" or "\n"
    eq(table.concat(lines, nl) .. (o.eol and nl or ""), c[1])
  end
end

T["uri kinds for history and empty sides"] = function()
  local uri = require("trellis.uri")
  eq(uri.parse("trellis://history/src/a.lua"), { kind = "history", path = "src/a.lua" })
  eq(uri.parse("trellis://empty/x"), { kind = "empty", path = "x" })
end

T["diff adapter selection"] = function()
  local adapters = require("trellis.adapters.diff")
  eq(adapters.select("never"), nil)
  eq(adapters.select("auto").name, "builtin") -- diffview is not installed in tests
  local fake = {
    name = "fake",
    available = function()
      return true
    end,
    open = function() end,
  }
  adapters.register(fake)
  eq(adapters.select("auto").name, "fake")
  eq(adapters.select("builtin").name, "builtin")
  table.remove(adapters.registered)
end

return T
