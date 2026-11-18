--- Parser for G32: `git log -L<s>,<e>:<path> --format=%x1e%H%x00%P%x00%an%x00%at%x00%s%x00`.
--- Each record holds the commit fields followed by the patch of the range in that commit.
local diff = require("trellis.git.parse.diff")
local util = require("trellis.git.parse.util")

local M = {}

---@class trellis.LineLogEntry: trellis.LogCommit
---@field files trellis.DiffFile[] patch of the tracked range in this commit

local function count_nul(s)
  local n = 0
  for _ in s:gmatch("%z") do
    n = n + 1
  end
  return n
end

---@param text string
---@return trellis.LineLogEntry[]
function M.parse(text)
  local out = {}
  local frags = util.split(text, "\30")
  local buf
  for i = 2, #frags do
    buf = buf and (buf .. "\30" .. frags[i]) or frags[i]
    if count_nul(buf) >= 5 then
      local f = util.split(buf, "\0")
      buf = nil
      if f[1]:match("^%x+$") then
        out[#out + 1] = {
          sha = f[1],
          parents = vim.split(f[2], " ", { trimempty = true }),
          author = f[3],
          time = tonumber(f[4]) or 0,
          subject = f[5],
          files = diff.parse(table.concat(f, "\0", 6)),
        }
      end
    end
  end
  return out
end

return M
