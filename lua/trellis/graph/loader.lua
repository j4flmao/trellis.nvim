--- Graph loader: G10 stream → log parser → layout → model, with backpressure.
---
--- The stream is paused while more than `prefetch_rows` rows are loaded beyond the deepest row
--- the user has seen, and resumed when they scroll closer. `load_all()` (for `G`, search) reads
--- to EOF. A loader is single-use: refresh creates a new one.
---
--- Provisional mode (`check_topo = true`, used for the fast first screen without
--- commit-graph): the input order is not guaranteed topological; as soon as a commit arrives
--- whose parent is already drawn, loading stops with status "provisional_stopped" so the view
--- can wait for the real topological stream.
local argv = require("trellis.git.argv")
local layout = require("trellis.graph.layout")
local log = require("trellis.git.parse.log")
local model = require("trellis.graph.model")
local stream = require("trellis.git.stream")

local M = {}

---@alias trellis.LoaderStatus "loading"|"paused"|"complete"|"cancelled"|"error"|"provisional_stopped"

---@class trellis.LoaderOpts
---@field prefetch_rows integer
---@field style string
---@field max_lanes integer
---@field head_sha? string
---@field check_topo? boolean
---@field on_rows fun(first: integer, last: integer)
---@field on_done fun(status: trellis.LoaderStatus, err: string?)

---@class trellis.Loader
---@field repo trellis.Repository
---@field query trellis.GraphQuery
---@field model trellis.GraphModelImpl
---@field status trellis.LoaderStatus
---@field deepest integer
---@field started_at integer hrtime
---@field first_rows_at integer? hrtime of the first delivered rows
local Loader = {}
Loader.__index = Loader

---@param repo trellis.Repository
---@param query trellis.GraphQuery
---@param opts trellis.LoaderOpts
---@return trellis.Loader
function M.new(repo, query, opts)
  local m = model.new({ style = opts.style, max_lanes = opts.max_lanes })
  m.head_sha = opts.head_sha
  return setmetatable({
    repo = repo,
    query = query,
    opts = opts,
    model = m,
    layout = layout.new(),
    parser = log.new_parser(),
    status = "loading",
    deepest = 0,
    loading_all = false,
    started_at = vim.uv.hrtime(),
    true_parents = {},
    queue = {},
    qtail = 0,
    qpos = 1,
  }, Loader)
end

--- After a stripped (commit-filtered) load completes: lay the commits out again with only the
--- edges whose both ends are shown. Replaces `self.model`.
function Loader:relayout()
  local old = self.model
  local m = model.new({ style = self.opts.style, max_lanes = self.opts.max_lanes })
  m.head_sha = old.head_sha
  m.complete = old.complete
  local L = layout.new()
  for i = 1, old.n do
    local sha = old.sha[i]
    local parents = {}
    for _, p in ipairs(self.true_parents[sha] or old.parents[i]) do
      if old.index[p] then
        parents[#parents + 1] = p
      end
    end
    local c = {
      sha = sha,
      parents = parents,
      author = old.author[i],
      time = old.time[i],
      subject = old.subject[i],
    }
    local idx = m:add_commit(c)
    m:add_rows(L:push(c, idx))
  end
  self.model = m
  self.layout = L
  self.relaid = true
end

function Loader:start()
  local inv = argv.G10(self.query)
  local s, err = stream.start(self.repo.root, inv.args, {
    kind = inv.kind,
    on_records = function(records)
      -- Only queue raw records here: parsing and layout happen in time-budgeted slices.
      self:_enqueue(records)
    end,
    on_exit = function(code, stderr)
      self.exit = { code = code, stderr = stderr }
      self:_pump_soon()
    end,
  })
  if not s then
    self.status = "error"
    self.opts.on_done("error", err)
    return
  end
  self.stream = s
end

function Loader:done()
  return self.status ~= "loading" and self.status ~= "paused"
end

--- Work per main-loop turn while loading (ms). Parsed commits wait in a queue and are laid out
--- in slices; between slices the loop handles input and redraws (Constitution III: the UI is
--- never blocked by loading).
M.slice_ms = 4

-- The queue uses explicit head/tail indices: `#` on a table with consumed (nil) slots at the
-- front is undefined in Lua.
function Loader:_enqueue(commits)
  if #commits == 0 then
    return
  end
  local q, tail = self.queue, self.qtail
  for _, c in ipairs(commits) do
    tail = tail + 1
    q[tail] = c
  end
  self.qtail = tail
  self:_pump_soon()
end

function Loader:_pending()
  return self.qtail - self.qpos + 1
end

function Loader:_pump_soon()
  if self.pumping then
    return
  end
  self.pumping = true
  vim.defer_fn(function()
    self:_pump()
  end, 0)
end

function Loader:_pump()
  self.pumping = false
  if self:done() and self.status ~= "paused" then
    if self.exit and not self.finished then
      self.finished = true
      self:_finish(self.exit.code, self.exit.stderr)
    end
    return
  end
  -- Lay out chunks of 64 until the time budget is spent (the budget covers the processing).
  local deadline = vim.uv.hrtime() + M.slice_ms * 1e6
  local q = self.queue
  repeat
    local chunk = {}
    while self.qpos <= self.qtail and #chunk < 64 do
      chunk[#chunk + 1] = q[self.qpos]
      q[self.qpos] = nil
      self.qpos = self.qpos + 1
    end
    self:_batch(self.parser.push(chunk))
  until self.qpos > self.qtail or self:done() or vim.uv.hrtime() > deadline
  if self.qpos > self.qtail and self.exit and not self.parsed_tail and not self:done() then
    -- The stream ended: release the last parsed commit.
    self.parsed_tail = true
    self:_batch(self.parser.finish())
  end
  if self.qpos > self.qtail then
    self.queue, self.qpos, self.qtail = {}, 1, 0
  end
  if self:_pending() > 0 and not self:done() then
    self:_pump_soon()
  elseif self.exit and not self.finished then
    self.finished = true
    self:_finish(self.exit.code, self.exit.stderr)
  end
end

---@param commits trellis.LogCommit[]
function Loader:_batch(commits)
  if #commits == 0 or self:done() then
    return
  end
  local m, L = self.model, self.layout
  local first = m.loaded + 1
  for _, c in ipairs(commits) do
    if self.opts.check_topo then
      for _, p in ipairs(c.parents) do
        if m.index[p] then
          self:_stop("provisional_stopped")
          if m.loaded >= first then
            self.opts.on_rows(first, m.loaded)
          end
          return
        end
      end
    end
    local shown = c
    if self.opts.strip_parents then
      -- Commit filters: parents may never be shown; draw no edges until relayout().
      self.true_parents[c.sha] = c.parents
      shown = { sha = c.sha, parents = {}, author = c.author, time = c.time, subject = c.subject }
    end
    local idx = m:add_commit(shown)
    m:add_rows(L:push(shown, idx))
  end
  if not self.first_rows_at then
    self.first_rows_at = vim.uv.hrtime()
  end
  self.opts.on_rows(first, m.loaded)
  self:_throttle()
end

function Loader:_throttle()
  if not self.stream or self:done() then
    return
  end
  if
    not self.loading_all
    and self.model.loaded + self:_pending() - self.deepest > self.opts.prefetch_rows
  then
    if not self.stream.paused() then
      self.stream.pause()
      self.status = "paused"
    end
  elseif self.stream.paused() then
    self.stream.resume()
    self.status = "loading"
  end
end

--- The user has seen rows up to `row`: keep `prefetch_rows` loaded beyond it.
---@param row integer
function Loader:want(row)
  if row > self.deepest then
    self.deepest = row
    self:_throttle()
  end
end

--- Read to EOF (progress is reported through on_rows).
function Loader:load_all()
  self.loading_all = true
  self:_throttle()
end

function Loader:_stop(status)
  self.status = status
  if self.stream then
    self.stream.kill()
  end
end

function Loader:cancel()
  if not self:done() then
    self:_stop("cancelled")
    self.opts.on_done("cancelled")
  end
end

function Loader:_finish(code, stderr)
  if self.status == "cancelled" then
    return
  end
  if self.status == "provisional_stopped" then
    return self.opts.on_done("provisional_stopped")
  end
  self.model.complete = code == 0
  self.status = code == 0 and "complete" or "error"
  local err = code ~= 0 and vim.trim(stderr or ""):match("^[^\n]*") or nil
  self.opts.on_done(self.status, err)
end

return M
