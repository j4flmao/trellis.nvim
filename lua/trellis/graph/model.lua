--- Graph model: commits and rendered rows in struct-of-arrays form. Layout row tables are rendered to strings and dropped immediately,
--- so a loaded row costs a text string, a packed color string and a few array slots.
local glyphs = require("trellis.graph.glyphs")

local M = {}

---@class trellis.GraphModelImpl
---@field n integer number of commits
---@field sha string[]
---@field parents string[][]
---@field author string[]
---@field time integer[]
---@field subject string[]
---@field index table<string, integer>
---@field rows_kind integer[]     1 = commit row, 0 = connector
---@field rows_commit integer[]   commit index (for connector rows: the commit they follow)
---@field rows_text string[]      graph prefix glyphs
---@field rows_colors string[]    one byte per column: lane color index (0 = none)
---@field row_of_commit integer[]
---@field loaded integer          rows materialized
---@field complete boolean        stream reached EOF
---@field style string
---@field max_lanes integer
local Model = {}
Model.__index = Model

---@param opts? { style?: string, max_lanes?: integer }
---@return trellis.GraphModelImpl
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    n = 0,
    sha = {},
    parents = {},
    author = {},
    time = {},
    subject = {},
    index = {},
    rows_kind = {},
    rows_commit = {},
    rows_text = {},
    rows_colors = {},
    row_of_commit = {},
    loaded = 0,
    complete = false,
    style = opts.style or "rounded",
    max_lanes = opts.max_lanes or 40,
  }, Model)
end

---@param c trellis.LogCommit
---@return integer idx
function Model:add_commit(c)
  local n = self.n + 1
  self.n = n
  self.sha[n] = c.sha
  self.parents[n] = c.parents
  self.author[n] = c.author
  self.time[n] = c.time
  self.subject[n] = c.subject
  self.index[c.sha] = n
  return n
end

local char = string.char

local function pack_colors(row, width)
  local colors = row.colors
  local bytes = {}
  for x = 1, width do
    bytes[x] = char(colors[x] or 0)
  end
  return table.concat(bytes)
end

--- Render and store layout rows. Returns the first and last new row numbers.
---@param rows trellis.LayoutRow[]
---@return integer first, integer last
function Model:add_rows(rows)
  local first = self.loaded + 1
  for _, row in ipairs(rows) do
    local r = self.loaded + 1
    self.loaded = r
    local is_head = row.kind == "commit"
      and self.head_sha ~= nil
      and self.sha[row.commit] == self.head_sha
    local text, width =
      glyphs.render(row, self.style, { max_lanes = self.max_lanes, head = is_head })
    self.rows_text[r] = text
    self.rows_colors[r] = pack_colors(row, math.min(width, 2 * self.max_lanes + 1))
    self.rows_commit[r] = row.commit
    if row.kind == "commit" then
      self.rows_kind[r] = 1
      self.row_of_commit[row.commit] = r
    else
      self.rows_kind[r] = 0
    end
  end
  return first, self.loaded
end

--- Commit as a table (allocated on demand).
---@param idx integer
---@return trellis.LogCommit?
function Model:commit(idx)
  if not self.sha[idx] then
    return nil
  end
  return {
    sha = self.sha[idx],
    parents = self.parents[idx],
    author = self.author[idx],
    time = self.time[idx],
    subject = self.subject[idx],
  }
end

---@param sha string
---@return integer? idx
function Model:index_of(sha)
  return self.index[sha]
end

--- Commit index shown on row `r`, if it is a commit row.
---@param r integer
---@return integer?
function Model:commit_at_row(r)
  if self.rows_kind[r] == 1 then
    return self.rows_commit[r]
  end
end

--- Nearest commit row at or after (`dir` = 1) / before (`dir` = -1) row `r`.
---@return integer? row
function Model:next_commit_row(r, dir)
  local i = r
  while i >= 1 and i <= self.loaded do
    if self.rows_kind[i] == 1 then
      return i
    end
    i = i + dir
  end
end

return M
