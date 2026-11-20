--- Parsers for `git reflog show -z` (G46) and `git stash list -z` (G48): NUL-terminated records,
--- fields separated by 0x1f.
local M = {}

local US = "\31"

local function records(s)
  local out = {}
  for rec in (s or ""):gmatch("([^%z]+)") do
    rec = rec:gsub("^\n+", "")
    if rec ~= "" then
      out[#out + 1] = vim.split(rec, US, { plain = true })
    end
  end
  return out
end

---@class trellis.ReflogEntry
---@field sha string
---@field selector string  e.g. HEAD@{3}
---@field action string    reflog message, e.g. "reset: moving to HEAD~1"
---@field time integer
---@field subject string   the commit's subject
---@field lost? boolean    no branch, tag, remote-tracking branch or HEAD reaches it

---@param s string G46 output
---@return trellis.ReflogEntry[]
function M.parse_reflog(s)
  local out = {}
  for _, f in ipairs(records(s)) do
    if f[1] and f[1]:match("^%x+$") then
      out[#out + 1] = {
        sha = f[1],
        selector = f[2] or "",
        action = f[3] or "",
        time = tonumber(f[4]) or 0,
        subject = f[5] or "",
      }
    end
  end
  return out
end

---@class trellis.StashEntry
---@field sha string
---@field selector string  stash@{n}
---@field time integer
---@field message string   "WIP on main: abc1234 subject" / "On main: message"

---@param s string G48 output
---@return trellis.StashEntry[]
function M.parse_stash(s)
  local out = {}
  for _, f in ipairs(records(s)) do
    if f[1] and f[1]:match("^%x+$") then
      out[#out + 1] = {
        sha = f[1],
        selector = f[2] or "",
        time = tonumber(f[3]) or 0,
        message = f[4] or "",
      }
    end
  end
  return out
end

--- Mark entries whose commit is in `lost_output` (G47: one sha per line).
---@param entries trellis.ReflogEntry[]
---@param lost_output string
function M.mark_lost(entries, lost_output)
  local lost = {}
  for sha in (lost_output or ""):gmatch("%x+") do
    lost[sha] = true
  end
  for _, e in ipairs(entries) do
    e.lost = lost[e.sha] or nil
  end
  return entries
end

return M
