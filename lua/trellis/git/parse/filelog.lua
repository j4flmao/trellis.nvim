--- Parser for G23: `git log --follow --format=%x1e%H%x00%P%x00%an%x00%at%x00%s%x00 --name-status`.
---
--- Every record starts with RS and holds the commit fields followed by git's name-status lines
--- for that commit ("M\tpath", "R087\told\tnew"). A subject containing RS splits a record in
--- two; fragments are glued back until the record has its five NUL-terminated fields.
local util = require("trellis.git.parse.util")

local M = {}

---@class trellis.FileLogEntry: trellis.LogCommit
---@field status string        "A"|"M"|"D"|"R"|"C"|"T"
---@field path string          the file's path in this commit
---@field old_path string?     path before a rename/copy

local function count_nul(s)
  local n = 0
  for _ in s:gmatch("%z") do
    n = n + 1
  end
  return n
end

local function parse_record(rec)
  local f = util.split(rec, "\0")
  local sha, parents, author, time, subject = f[1], f[2], f[3], f[4], f[5]
  if not (sha and sha:match("^%x+$")) then
    return nil
  end
  local rest = table.concat(f, "\0", 6)
  local entry = {
    sha = sha,
    parents = vim.split(parents or "", " ", { trimempty = true }),
    author = author or "",
    time = tonumber(time) or 0,
    subject = subject or "",
  }
  for line in rest:gmatch("[^\n]+") do
    local parts = util.split(line, "\t")
    local code = parts[1]
    if code and code:match("^[ACDMRTUX]%d*$") then
      local letter = code:sub(1, 1)
      entry.status = letter
      if (letter == "R" or letter == "C") and parts[3] then
        entry.old_path = util.unquote(parts[2])
        entry.path = util.unquote(parts[3])
      else
        entry.path = util.unquote(parts[2] or "")
      end
      break
    end
  end
  return entry
end

---@param text string
---@return trellis.FileLogEntry[]
function M.parse(text)
  local out = {}
  local frags = util.split(text, "\30")
  local buf
  for i = 2, #frags do
    buf = buf and (buf .. "\30" .. frags[i]) or frags[i]
    if count_nul(buf) >= 5 then
      local e = parse_record(buf)
      if e then
        out[#out + 1] = e
      end
      buf = nil
    end
  end
  return out
end

return M
