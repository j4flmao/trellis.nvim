-- Basic shapes and message edge cases.
local S = {}
local function add(name, desc, build)
  S[#S + 1] = { name = name, desc = desc, build = build }
end

add("unborn", "repository with no commits", function() end)

add("single", "one root commit", function(r)
  r:commit({ msg = "root", files = { ["README.md"] = "hello\n" } })
end)

add("linear", "10 commits on main", function(r)
  for i = 1, 10 do
    r:commit({ msg = "commit " .. i, files = { ["a.txt"] = i .. "\n" } })
  end
end)

add("detached-head", "HEAD detached one commit behind main", function(r)
  for i = 1, 3 do
    r:commit({ msg = "c" .. i, files = { ["a.txt"] = i .. "\n" } })
  end
  r:detach("HEAD~1")
end)

add("two-branches", "two unmerged branches from the root", function(r)
  r:commit({ msg = "root", files = { ["a.txt"] = "a\n" } })
  r:branch("feature")
  r:commit({ msg = "main 1", files = { ["m.txt"] = "1\n" } })
  r:commit({ msg = "main 2", files = { ["m.txt"] = "2\n" } })
  r:switch("feature")
  r:commit({ msg = "feature 1", files = { ["f.txt"] = "1\n" } })
  r:commit({ msg = "feature 2", files = { ["f.txt"] = "2\n" } })
  r:switch("main")
end)

add("fast-forward", "feature fast-forwarded into main", function(r)
  r:commit({ msg = "root", files = { ["a.txt"] = "a\n" } })
  r:branch("feature")
  r:switch("feature")
  r:commit({ msg = "f1", files = { ["f.txt"] = "1\n" } })
  r:commit({ msg = "f2", files = { ["f.txt"] = "2\n" } })
  r:switch("main")
  r:git({ "merge", "-q", "--ff-only", "feature" })
end)

add("unicode-messages", "non-ASCII subjects, authors and file names", function(r)
  r.author = { "Nguyễn Văn Anh", "anh@example.com" }
  r:commit({
    msg = "Sửa lỗi đăng nhập 🐛",
    files = { ["tài-liệu.md"] = "xin chào\n" },
  })
  r:commit({
    msg = "日本語のコミットメッセージ",
    files = { ["日本.txt"] = "こんにちは\n" },
  })
  r:commit({ msg = "תיקון באג בעברית", files = { ["a.txt"] = "1\n" } })
  r:commit({ msg = "combining: e\204\129 and emoji 👩‍💻🚀", files = { ["a.txt"] = "2\n" } })
end)

add("control-chars", "subjects with tab, ESC, RS, US and other control bytes", function(r)
  r:commit({ msg = "tab\there", files = { ["a.txt"] = "1\n" } })
  r:commit({ msg = "escape \27[31mred\27[0m", files = { ["a.txt"] = "2\n" } })
  r:commit({ msg = "record\30separator\30twice", files = { ["a.txt"] = "3\n" } })
  r:commit({ msg = "unit\31sep and \1 \2 \127", files = { ["a.txt"] = "4\n" } })
  r:commit({ msg = "ends with RS\30", files = { ["a.txt"] = "5\n" } })
end)

add("long-subject", "500-character subject", function(r)
  r:commit({ msg = ("long "):rep(100), files = { ["a.txt"] = "1\n" } })
  r:commit({ msg = "short", files = { ["a.txt"] = "2\n" } })
end)

add("multiline-body", "body with paragraphs, '#' lines and trailers", function(r)
  r:commit({
    msg = "Subject line\n\nFirst paragraph\nwraps here.\n\n# not a comment (verbatim)\n\nSigned-off-by: Alice <alice@example.com>\n",
    files = { ["a.txt"] = "1\n" },
  })
end)

add("empty-message", "a commit with an empty message", function(r)
  r:commit({ msg = "first", files = { ["a.txt"] = "1\n" } })
  r:commit({ msg = "", allow_empty_message = true, files = { ["a.txt"] = "2\n" } })
end)

add("same-timestamp", "every commit has the same date", function(r)
  r:commit({ msg = "root", time = 1700000000, files = { ["a.txt"] = "0\n" } })
  r:branch("side")
  for i = 1, 3 do
    r:commit({ msg = "main " .. i, time = 1700000000, files = { ["a.txt"] = i .. "\n" } })
  end
  r:switch("side")
  for i = 1, 3 do
    r:commit({ msg = "side " .. i, time = 1700000000, files = { ["s.txt"] = i .. "\n" } })
  end
  r:switch("main")
  r:merge({ "side" }, { time = 1700000000 })
end)

add(
  "date-skew",
  "children older than parents (clock skew): commit-date order is not topological",
  function(r)
    r:commit({ msg = "root", time = 1700100000, files = { ["a.txt"] = "0\n" } })
    r:branch("side")
    r:commit({ msg = "main older than root", time = 1700000000, files = { ["a.txt"] = "1\n" } })
    r:commit({ msg = "main even older", time = 1699900000, files = { ["a.txt"] = "2\n" } })
    r:switch("side")
    r:commit({ msg = "side newer", time = 1700200000, files = { ["s.txt"] = "1\n" } })
    r:switch("main")
    r:merge({ "side" }, { time = 1699800000 })
  end
)

return S
