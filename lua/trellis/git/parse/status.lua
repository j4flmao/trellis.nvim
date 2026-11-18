--- Parser for `git status --porcelain=v2 -z` (G07).
local M = {}

---@class trellis.StatusEntry
---@field kind "changed"|"renamed"|"unmerged"|"untracked"|"ignored"
---@field xy string     two status letters (index, worktree); "??" untracked
---@field path string
---@field orig_path? string

---@param s string
---@return trellis.StatusEntry[]
function M.parse(s)
  local out = {}
  local fields = vim.split(s, "\0", { plain = true })
  local i = 1
  while i <= #fields do
    local rec = fields[i]
    local t = rec:sub(1, 1)
    if t == "1" then
      -- 1 XY sub mH mI mW hH hI path
      local xy, path = rec:match("^1 (%S%S) %S+ %S+ %S+ %S+ %S+ %S+ (.*)$")
      out[#out + 1] = { kind = "changed", xy = xy, path = path }
    elseif t == "2" then
      -- 2 XY sub mH mI mW hH hI Xscore path \0 origPath
      local xy, path = rec:match("^2 (%S%S) %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.*)$")
      out[#out + 1] = { kind = "renamed", xy = xy, path = path, orig_path = fields[i + 1] }
      i = i + 1
    elseif t == "u" then
      -- u XY sub m1 m2 m3 mW h1 h2 h3 path
      local xy, path = rec:match("^u (%S%S) %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.*)$")
      out[#out + 1] = { kind = "unmerged", xy = xy, path = path }
    elseif t == "?" then
      out[#out + 1] = { kind = "untracked", xy = "??", path = rec:sub(3) }
    elseif t == "!" then
      out[#out + 1] = { kind = "ignored", xy = "!!", path = rec:sub(3) }
    end
    i = i + 1
  end
  return out
end

--- True when tracked files have staged or unstaged changes (or conflicts).
---@param entries trellis.StatusEntry[]
function M.dirty(entries)
  for _, e in ipairs(entries) do
    if e.kind ~= "untracked" and e.kind ~= "ignored" then
      return true
    end
  end
  return false
end

return M
