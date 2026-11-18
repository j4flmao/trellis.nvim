--- Cell bit sets → characters, per glyph style (research R13). Every glyph is one display cell,
--- so a lane is always exactly two cells wide (lane column + gap column).
local layout = require("trellis.graph.layout")
local B = layout.bits

local M = {}

local band, bor = bit.band, bit.bor
local LINES = bor(B.UP, B.DOWN, B.LEFT, B.RIGHT)

local function lines_table(t)
  local U, D, L, R = B.UP, B.DOWN, B.LEFT, B.RIGHT
  return {
    [0] = " ",
    [U] = t.v,
    [D] = t.v,
    [bor(U, D)] = t.v,
    [L] = t.h,
    [R] = t.h,
    [bor(L, R)] = t.h,
    [bor(U, D, L, R)] = t.cross,
    [bor(D, R)] = t.dr,
    [bor(D, L)] = t.dl,
    [bor(U, R)] = t.ur,
    [bor(U, L)] = t.ul,
    [bor(U, D, R)] = t.udr,
    [bor(U, D, L)] = t.udl,
    [bor(D, L, R)] = t.dlr,
    [bor(U, L, R)] = t.ulr,
  }
end

M.styles = {
  ascii = {
    lines = lines_table({
      v = "|",
      h = "-",
      cross = "+",
      dr = ".",
      dl = ".",
      ur = "'",
      ul = "'",
      udr = "+",
      udl = "+",
      dlr = "+",
      ulr = "+",
    }),
    diag = "/",
    commit = "*",
    merge = "o",
    head = "@",
    overflow = "~",
  },
  unicode = {
    lines = lines_table({
      v = "│",
      h = "─",
      cross = "┼",
      dr = "┌",
      dl = "┐",
      ur = "└",
      ul = "┘",
      udr = "├",
      udl = "┤",
      dlr = "┬",
      ulr = "┴",
    }),
    diag = "╱",
    commit = "●",
    merge = "○",
    head = "◉",
    overflow = "…",
  },
}
M.styles.rounded = vim.deepcopy(M.styles.unicode)
M.styles.rounded.lines[bor(B.DOWN, B.RIGHT)] = "╭"
M.styles.rounded.lines[bor(B.DOWN, B.LEFT)] = "╮"
M.styles.rounded.lines[bor(B.UP, B.RIGHT)] = "╰"
M.styles.rounded.lines[bor(B.UP, B.LEFT)] = "╯"
-- The flog-symbols font mapping is not decided yet (spec checklist: default glyph style gate);
-- until then it renders like "rounded".
M.styles["flog-symbols"] = M.styles.rounded

--- Style to use: the configured one, or ascii when box-drawing glyphs are double width.
---@param configured string
---@return string
function M.resolve_style(configured)
  if vim.o.ambiwidth == "double" and configured ~= "ascii" then
    return "ascii"
  end
  return M.styles[configured] and configured or "rounded"
end

local function cell_char(st, c, is_head)
  if band(c, B.NODE) ~= 0 then
    if is_head then
      return st.head
    end
    return band(c, B.MERGE) ~= 0 and st.merge or st.commit
  end
  if band(c, B.DIAG) ~= 0 then
    return st.diag
  end
  return st.lines[band(c, LINES)] or " "
end

--- Render a layout row to text (trailing blanks trimmed).
---@param row trellis.LayoutRow
---@param style string
---@param opts? { max_lanes?: integer, head?: boolean }
---@return string text, integer width display cells used before trimming overflow
function M.render(row, style, opts)
  opts = opts or {}
  local st = M.styles[style] or M.styles.rounded
  local cells = row.cells
  local last = 0
  for x in pairs(cells) do
    if cells[x] ~= 0 and x > last then
      last = x
    end
  end
  local limit = opts.max_lanes and (2 * opts.max_lanes - 1) or last
  local out = {}
  for x = 1, math.min(last, limit) do
    out[x] = cells[x] and cell_char(st, cells[x], opts.head) or " "
  end
  if last > limit then
    local node_beyond = false
    for x = limit + 1, last do
      if cells[x] and band(cells[x], B.NODE) ~= 0 then
        node_beyond = true
      end
    end
    out[#out + 1] = " "
    out[#out + 1] = node_beyond and (opts.head and st.head or st.commit) or st.overflow
  end
  local text = table.concat(out):gsub("%s+$", "")
  return text, last
end

return M
