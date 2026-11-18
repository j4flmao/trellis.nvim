-- File content cases: renames, binary, large, eol, LFS, submodules, blame chains.
local S = {}
local function add(name, desc, build)
  S[#S + 1] = { name = name, desc = desc, build = build }
end

local function body(n, changed)
  local lines = {}
  for i = 1, n do
    lines[i] = ("line %02d"):format(i)
  end
  if changed then
    lines[changed[1]] = changed[2]
  end
  return table.concat(lines, "\n") .. "\n"
end

add("rename-chain", "a file renamed three times with edits in between", function(r)
  r:commit({ msg = "add old", files = { ["src/old.lua"] = body(20) } })
  r:commit({ msg = "edit old", files = { ["src/old.lua"] = body(20, { 3, "edit one" }) } })
  r:mv("src/old.lua", "src/mid.lua")
  r:commit({ msg = "rename to mid" })
  r:commit({ msg = "edit mid", files = { ["src/mid.lua"] = body(20, { 3, "edit two" }) } })
  r:mv("src/mid.lua", "lib/newer.lua")
  r:commit({ msg = "rename to lib/newer" })
  r:mv("lib/newer.lua", "src/renamed_thrice.lua")
  r:commit({
    msg = "rename to renamed_thrice",
    files = { ["src/renamed_thrice.lua"] = body(20, { 3, "edit three" }) },
  })
end)

local PNG = "\137PNG\r\n\26\n\0\0\0\rIHDR\0\0\0\1\0\0\0\1\8\6\0\0\0\31\21\196\137"

add("binary-file", "binary file added and modified", function(r)
  r:commit({ msg = "add logo", files = { ["assets/logo.png"] = PNG .. "\0\1\2" } })
  r:commit({ msg = "update logo", files = { ["assets/logo.png"] = PNG .. "\0\3\4\5" } })
end)

add("large-file", "a 6 MB text file (above the 5 MB default guard)", function(r)
  local line = ("x"):rep(1023) .. "\n"
  r:commit({ msg = "add big file", files = { ["big.txt"] = line:rep(6 * 1024) } })
end)

add("crlf", "eol attributes: text eol=crlf and a CRLF file stored as-is", function(r)
  r:commit({
    msg = "eol attributes",
    files = {
      [".gitattributes"] = "*.txt text eol=crlf\n*.bat -text\n",
      ["notes.txt"] = "one\ntwo\n",
      ["run.bat"] = "@echo off\r\necho hi\r\n",
    },
  })
end)

add("lfs-pointer", "LFS pointer file without git-lfs installed", function(r)
  r:commit({
    msg = "track model with LFS",
    files = {
      [".gitattributes"] = "*.bin filter=lfs diff=lfs merge=lfs -text\n",
      ["model.bin"] = "version https://git-lfs.github.com/spec/v1\noid sha256:"
        .. ("ab"):rep(32)
        .. "\nsize 123456\n",
    },
  })
end)

add("submodule", "a submodule added and then moved to a newer commit", function(r, ctx)
  local lib = ctx.aux("lib")
  lib:commit({ msg = "lib 1", files = { ["lib.lua"] = "return 1\n" } })
  lib:commit({ msg = "lib 2", files = { ["lib.lua"] = "return 2\n" } })
  r:commit({ msg = "root", files = { ["a.txt"] = "a\n" } })
  r:git({ "submodule", "add", "-q", "file://" .. lib.path, "vendor/lib" })
  r:git({ "-C", "vendor/lib", "checkout", "-q", "HEAD~1" })
  r:commit({ msg = "add submodule at lib 1" })
  r:git({ "-C", "vendor/lib", "checkout", "-q", "main" })
  r:commit({ msg = "bump submodule to lib 2" })
end)

add("blame-chain", "src/api.lua: the retry line changes in 6 commits", function(r)
  local function api(retry, extra)
    return table.concat({
      "local M = {}",
      "",
      "M.timeout = 30",
      "retry = " .. retry,
      extra or "-- end",
      "",
      "return M",
    }, "\n") .. "\n"
  end
  r:commit({ msg = "add api", files = { ["src/api.lua"] = api(1) } })
  for i, extra in ipairs({ "-- end", "-- tweak", "-- tweak", "-- final", "-- final" }) do
    r:commit({ msg = "retry = " .. (i + 1), files = { ["src/api.lua"] = api(i + 1, extra) } })
  end
  r:commit({ msg = "back to retry = 3", files = { ["src/api.lua"] = api(3, "-- final") } })
end)

add("mode-change", "executable bit toggled without content change", function(r)
  r:commit({ msg = "add script", files = { ["run.sh"] = "#!/bin/sh\necho hi\n" } })
  r:git({ "update-index", "--chmod=+x", "run.sh" })
  r:git({ "commit", "-q", "-m", "make executable" }, { env = r:env() })
end)

add("delete-readd", "file deleted and later re-added", function(r)
  r:commit({ msg = "add f", files = { ["f.txt"] = "v1\n" } })
  r:commit({ msg = "delete f", files = { ["f.txt"] = false } })
  r:commit({ msg = "re-add f", files = { ["f.txt"] = "v2\n" } })
end)

add("whitespace-moves", "whitespace-only edit and a moved block (blame -w / -M)", function(r)
  local block = "function a()\n  return 1\nend\n"
  local other = "function b()\n  return 2\nend\n"
  r:commit({ msg = "add functions", files = { ["m.lua"] = block .. "\n" .. other } })
  r:commit({ msg = "reindent", files = { ["m.lua"] = block:gsub("  ", "    ") .. "\n" .. other } })
  r:commit({
    msg = "move a below b",
    files = { ["m.lua"] = other .. "\n" .. block:gsub("  ", "    ") },
  })
end)

return S
