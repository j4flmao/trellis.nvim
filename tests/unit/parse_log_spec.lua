local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local log = require("trellis.git.parse.log")

local A, B, C = ("a"):rep(40), ("b"):rep(40), ("c"):rep(40)

--- Build git's exact output: every record terminated by RS + "\n".
local function rec(sha, parents, author, time, subject)
  return table.concat({ sha, parents, author, tostring(time), subject }, "\0") .. "\30\n"
end

T["parses records with parents, roots and merges"] = function()
  local out = rec(C, A .. " " .. B, "Alice", 3, "Merge b")
    .. rec(B, A, "Bob", 2, "b")
    .. rec(A, "", "Alice", 1, "root")
  local commits, errors = log.parse(out)
  eq(errors, {})
  eq(#commits, 3)
  eq(commits[1], { sha = C, parents = { A, B }, author = "Alice", time = 3, subject = "Merge b" })
  eq(commits[3].parents, {})
  eq(commits[2].subject, "b")
end

T["subject containing RS is kept intact"] = function()
  local out = rec(A, "", "x", 1, "left\30right")
    .. rec(B, A, "x", 2, "end\30")
    .. rec(C, B, "x", 3, "\30\30")
  local commits, errors = log.parse(out)
  eq(errors, {})
  eq(#commits, 3)
  eq(commits[1].subject, "left\30right")
  eq(commits[2].subject, "end\30")
  eq(commits[3].subject, "\30\30")
end

T["unicode, tabs and control characters are preserved"] = function()
  local subject = "Sửa lỗi 🐛 \t \27[31mred\27[0m 日本語 עברית"
  local commits = log.parse(rec(A, "", "Nguyễn", 1, subject))
  eq(commits[1].subject, subject)
  eq(commits[1].author, "Nguyễn")
end

T["streaming gives the same result for any chunking"] = function()
  local out = ""
  for i = 1, 30 do
    local sha = ("%040x"):format(i)
    local parent = i > 1 and ("%040x"):format(i - 1) or ""
    out = out .. rec(sha, parent, "a", i, i % 7 == 0 and ("with\30rs " .. i) or ("s" .. i))
  end
  local expected = log.parse(out)
  -- Split the raw byte stream at every possible chunk size, then on RS like stream.lua does.
  for size = 1, 40, 3 do
    local p = log.new_parser()
    local got, pending = {}, ""
    for pos = 1, #out, size do
      local data = pending .. out:sub(pos, pos + size - 1)
      local frags, start = {}, 1
      while true do
        local s = data:find("\30", start, true)
        if not s then
          break
        end
        frags[#frags + 1] = data:sub(start, s - 1)
        start = s + 1
      end
      pending = data:sub(start)
      vim.list_extend(got, p.push(frags))
    end
    if pending ~= "" then
      vim.list_extend(got, p.push({ pending }))
    end
    vim.list_extend(got, p.finish())
    eq({ size = size, n = #got }, { size = size, n = 30 })
    eq(got, expected)
  end
end

T["sha256 object names"] = function()
  local s1, s2 = ("1"):rep(64), ("2"):rep(64)
  local commits = log.parse(rec(s2, s1, "a", 2, "x") .. rec(s1, "", "a", 1, "y"))
  eq(commits[1].parents, { s1 })
end

T["empty output and garbage"] = function()
  eq(log.parse(""), {})
  local commits, errors = log.parse("not a record\30\n")
  eq(commits, {})
  eq(#errors, 1)
end

return T
