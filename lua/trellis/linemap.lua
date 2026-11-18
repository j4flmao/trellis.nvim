--- Map a line number between two versions of a file through `diff -U0` hunks (research R8).
--- Pure function, used by revision stepping (`]r`/`[r`) and blame time travel.
local M = {}

---@param hunks trellis.DiffHunk[] hunks of the diff old → new, in order
---@param line integer line in the old version ("forward") or the new version ("backward")
---@param direction? "forward"|"backward" default "forward"
---@return integer
function M.map_line(hunks, line, direction)
  local backward = direction == "backward"
  local delta = 0
  for _, h in ipairs(hunks) do
    local a_start, a_count, b_start, b_count = h.old_start, h.old_count, h.new_start, h.new_count
    if backward then
      a_start, a_count, b_start, b_count = b_start, b_count, a_start, a_count
    end
    if a_count == 0 then
      -- Pure insertion on the other side, after line a_start.
      if line > a_start then
        delta = delta + b_count
      else
        break
      end
    elseif line < a_start then
      break
    elseif line <= a_start + a_count - 1 then
      -- Inside a changed range: the same offset within the replacement, clamped.
      if b_count == 0 then
        return math.max(1, b_start) -- deleted: the line just above the deletion
      end
      return b_start + math.min(line - a_start, b_count - 1)
    else
      delta = delta + b_count - a_count
    end
  end
  return math.max(1, line + delta)
end

return M
