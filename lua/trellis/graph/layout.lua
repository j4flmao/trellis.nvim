--- Incremental lane layout engine. Pure Lua: no Neovim API, no I/O.
---
--- Feed commits in a topological order (children before parents) with `push`; each call returns
--- the rows to draw for that commit. The only state carried between commits is the lane array,
--- so history can be laid out page by page while it streams in.
---
--- Rows are arrays of cells by character column: lane i is drawn at column 2i-1, the gap after
--- it at column 2i. A cell is a bit set of line directions (see `M.bits`); glyphs.lua turns
--- cells into characters for a style.
---
--- Drawing rules
---   * Commit row: the commit's node in its lane. Other lanes waiting for this commit converge
---     into the node horizontally on the same row ("●─┴─╯").
---   * The first parent always continues in the commit's lane. Several lanes may wait for the
---     same commit; they converge on that commit's row.
---   * Each further parent gets one connector row with a single horizontal span from the
---     commit's lane: into a lane already waiting for that parent ("├─┤") or into a new lane
--- ("├─╮"). Farthest spans are drawn first, so new lanes never cross each other.
---   * After a commit, if a lane in the middle is free, lanes to its right shift left by one on
---     a connector row drawn with diagonals ("╱"), one step per commit.
local M = {}

local bor = bit.bor

M.bits = {
  UP = 1,
  DOWN = 2,
  LEFT = 4,
  RIGHT = 8,
  NODE = 16,
  MERGE = 32,
  DIAG = 64, -- "╱" in a gap column: from the lane above-right to the lane below-left
}
local UP, DOWN, LEFT, RIGHT, NODE, MERGE, DIAG = 1, 2, 4, 8, 16, 32, 64

---@class trellis.LayoutRow
---@field kind "commit"|"connector"
---@field commit integer? commit index for commit rows (and the commit a connector belongs to)
---@field cells integer[] bit sets by column (1-based); missing = empty
---@field colors integer[] lane color index by column
---@field tracks table<integer, { v?: table<string, true>, h?: table<string, true>, d?: table<string, true> }>? debug only

---@class trellis.Layout
---@field lanes (string|false)[] expected sha per lane, false = free
---@field colors integer[] color per lane (stable for the lane's lifetime)
---@field next_color integer
---@field ncolors integer
---@field debug boolean
local Layout = {}
Layout.__index = Layout

---@param opts? { colors?: integer, debug?: boolean }
---@return trellis.Layout
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    lanes = {},
    colors = {},
    next_color = 1,
    ncolors = opts.colors or 8,
    debug = opts.debug or false,
  }, Layout)
end

local function col_of(lane)
  return 2 * lane - 1
end

function Layout:alloc_color()
  local c = self.next_color
  self.next_color = c % self.ncolors + 1
  return c
end

--- Current number of lanes (including free lanes in the middle).
function Layout:width()
  return #self.lanes
end

function Layout:new_row(kind, commit)
  local row = { kind = kind, commit = commit, cells = {}, colors = {} }
  if self.debug then
    row.tracks = {}
  end
  return row
end

--- Add bits (and optionally a color and a debug track) to a cell.
local function put(row, x, bits, color, track_kind, sha)
  row.cells[x] = bor(row.cells[x] or 0, bits)
  if color and not row.colors[x] then
    row.colors[x] = color
  end
  if row.tracks and sha then
    local t = row.tracks[x]
    if not t then
      t = {}
      row.tracks[x] = t
    end
    local s = t[track_kind]
    if not s then
      s = {}
      t[track_kind] = s
    end
    s[sha] = true
  end
end

--- Vertical line for every active lane except those in `skip`.
function Layout:draw_verticals(row, skip, pending)
  local lanes, colors = self.lanes, self.colors
  for i = 1, #lanes do
    local sha = lanes[i]
    if sha and not skip[i] and not (pending and pending[i]) then
      put(row, col_of(i), bor(UP, DOWN), colors[i], "v", sha)
    end
  end
end

--- Horizontal span on `row` between lanes a < b (exclusive), crossing active lanes.
function Layout:draw_span(row, a, b, color, sha, pending)
  local lanes = self.lanes
  for x = col_of(a) + 1, col_of(b) - 1 do
    if x % 2 == 0 then
      put(row, x, bor(LEFT, RIGHT), color, "h", sha)
    else
      local lane = (x + 1) / 2
      if lanes[lane] and not (pending and pending[lane]) then
        -- crossing: the lane's own vertical is drawn by draw_verticals
        put(row, x, bor(LEFT, RIGHT), nil, "h", sha)
      else
        put(row, x, bor(LEFT, RIGHT), color, "h", sha)
      end
    end
  end
end

local function find_lane(lanes, sha, exclude)
  for i = 1, #lanes do
    if lanes[i] == sha and i ~= exclude then
      return i
    end
  end
end

local function first_free(lanes, from)
  for i = from or 1, #lanes do
    if not lanes[i] then
      return i
    end
  end
  return #lanes + 1
end

local function trim(self)
  local lanes = self.lanes
  while #lanes > 0 and not lanes[#lanes] do
    lanes[#lanes] = nil
    self.colors[#lanes + 1] = nil
  end
end

---@param commit { sha: string, parents: string[] }
---@param idx integer commit index (stored on rows)
---@return trellis.LayoutRow[]
function Layout:push(commit, idx)
  local lanes, colors = self.lanes, self.colors
  local sha, parents = commit.sha, commit.parents
  local rows = {}

  -- Commit row ---------------------------------------------------------------------------
  local matches = {}
  for i = 1, #lanes do
    if lanes[i] == sha then
      matches[#matches + 1] = i
    end
  end
  local col
  if #matches == 0 then
    col = first_free(lanes)
    lanes[col] = sha
    colors[col] = self:alloc_color()
  else
    col = matches[1]
  end
  local is_match = { [col] = true }
  for _, i in ipairs(matches) do
    is_match[i] = true
  end

  local row = self:new_row("commit", idx)
  self:draw_verticals(row, is_match)
  local node = NODE
  if #matches > 0 then
    node = bor(node, UP)
  end
  if #parents > 0 then
    node = bor(node, DOWN)
  end
  if #parents > 1 then
    node = bor(node, MERGE)
  end
  if #matches > 1 then
    node = bor(node, RIGHT)
    -- Converge every other waiting lane into the node, right to left.
    local right = matches[#matches]
    for k = #matches, 2, -1 do
      local lane = matches[k]
      local bits = bor(UP, LEFT)
      if lane ~= right then
        bits = bor(bits, RIGHT)
      end
      put(row, col_of(lane), bits, colors[lane], "v", sha)
      put(row, col_of(lane), 0, nil, "h", sha)
      self:draw_span(row, matches[k - 1], lane, colors[lane], sha)
    end
  end
  put(row, col_of(col), node, colors[col])
  rows[1] = row
  for k = 2, #matches do
    lanes[matches[k]] = false
    colors[matches[k]] = nil
  end

  -- Parents ------------------------------------------------------------------------------
  local col_color = colors[col]
  if #parents == 0 then
    lanes[col] = false
    colors[col] = nil
  else
    lanes[col] = parents[1]
    local spans, pending = {}, {}
    for k = 2, #parents do
      local p = parents[k]
      local j = find_lane(lanes, p, col)
      if j and not pending[j] then
        spans[#spans + 1] = { lane = j, parent = p, new = false }
      else
        j = first_free(lanes, col + 1)
        lanes[j] = p
        colors[j] = self:alloc_color()
        pending[j] = true
        spans[#spans + 1] = { lane = j, parent = p, new = true }
      end
    end
    table.sort(spans, function(a, b)
      local da, db = math.abs(a.lane - col), math.abs(b.lane - col)
      if da ~= db then
        return da > db
      end
      return a.lane > b.lane
    end)
    -- Parents whose edges still run down the commit's lane at each span row.
    local remaining = {}
    for _, p in ipairs(parents) do
      remaining[p] = true
    end
    for _, s in ipairs(spans) do
      local r = self:new_row("connector", idx)
      local skip = { [col] = true, [s.lane] = true }
      self:draw_verticals(r, skip, pending)
      local dir_to = s.lane > col and RIGHT or LEFT
      local dir_back = s.lane > col and LEFT or RIGHT
      -- The commit's lane: line from the node above, continuing down (first parent).
      put(r, col_of(col), bor(UP, DOWN, dir_to), col_color)
      for p in pairs(remaining) do
        put(r, col_of(col), 0, nil, "v", p)
      end
      put(r, col_of(col), 0, nil, "h", s.parent)
      remaining[s.parent] = nil
      local color = colors[s.lane]
      local lo, hi = math.min(col, s.lane), math.max(col, s.lane)
      self:draw_span(r, lo, hi, color, s.parent, pending)
      if s.new then
        put(r, col_of(s.lane), bor(DOWN, dir_back), color, "v", s.parent)
        put(r, col_of(s.lane), 0, nil, "h", s.parent)
        pending[s.lane] = nil
      else
        put(r, col_of(s.lane), bor(UP, DOWN, dir_back), color, "v", s.parent)
        put(r, col_of(s.lane), 0, nil, "h", s.parent)
      end
      rows[#rows + 1] = r
    end
  end

  -- Compaction ---------------------------------------------------------------------------
  trim(self)
  local gap
  for i = 1, #lanes do
    if not lanes[i] then
      gap = i
      break
    end
  end
  if gap then
    local r = self:new_row("connector", idx)
    for i = 1, #lanes do
      local s = lanes[i]
      if s then
        if i < gap then
          put(r, col_of(i), bor(UP, DOWN), colors[i], "v", s)
        else
          -- lane i moves to i-1: diagonal in the gap column between them
          put(r, col_of(i) - 1, DIAG, colors[i], "d", s)
        end
      end
    end
    table.remove(lanes, gap)
    table.remove(colors, gap)
    rows[#rows + 1] = r
  end

  return rows
end

--- Push several commits; `first_idx` is the index of the first one.
---@return trellis.LayoutRow[]
function Layout:push_many(commits, first_idx)
  local out = {}
  for k, c in ipairs(commits) do
    for _, r in ipairs(self:push(c, first_idx + k - 1)) do
      out[#out + 1] = r
    end
  end
  return out
end

return M
