--- Invariant checker for graph/layout.lua output (data-model.md → Graph → Invariants).
---
--- Works on layout rows produced with `debug = true` (cells carry the parent shas their lines
--- lead to). Checks:
---   1. every commit has exactly one commit row with one node, in input order;
---   2. every drawn line segment connects to a matching segment (no dangling lines), except
---      lines leaving the last row towards parents that were never loaded;
---   3. every parent edge (c -> p) with both commits loaded is drawn: a downward path of
---      connected cells carrying p leads from c's node to p's node;
---   4. outside explicit crossings, a cell never mixes lines to different parents unless they
---      start at the same commit (the commit's own branch-out junction);
---   5. a lane's color does not change along a straight vertical run.
local layout = require("trellis.graph.layout")
local B = layout.bits

local M = {}

local function has(bits, b)
  return bit.band(bits, b) ~= 0
end

local function set_has(s, sha)
  return s ~= nil and s[sha] == true
end

local function count(s)
  local n = 0
  for _ in pairs(s or {}) do
    n = n + 1
  end
  return n
end

---@param commits { sha: string, parents: string[] }[]
---@param rows table[] all rows in order
---@return string[] violations
function M.check(commits, rows)
  local errs = {}
  local function err(fmt, ...)
    if #errs < 50 then
      errs[#errs + 1] = fmt:format(...)
    end
  end

  -- 1. one node per commit, in order --------------------------------------------------------
  local node_at = {} -- commit idx -> { r, x }
  local last_row = 0
  for r, row in ipairs(rows) do
    local nodes = 0
    for x, c in pairs(row.cells) do
      if has(c, B.NODE) then
        nodes = nodes + 1
        if row.kind ~= "commit" then
          err("row %d: node on a connector row", r)
        end
        if node_at[row.commit] then
          err("commit %s drawn twice", tostring(row.commit))
        end
        node_at[row.commit] = { r, x }
      end
    end
    if row.kind == "commit" then
      if nodes ~= 1 then
        err("row %d: commit row with %d nodes", r, nodes)
      end
      if row.commit <= last_row then
        err("row %d: commit %d out of input order", r, row.commit)
      end
      last_row = row.commit
    end
  end
  for i = 1, #commits do
    if not node_at[i] then
      err("commit %d (%s) has no row", i, commits[i].sha)
    end
  end

  local function cell(r, x)
    local row = rows[r]
    return row and row.cells[x] or 0
  end
  local function track(r, x)
    local row = rows[r]
    return row and row.tracks and row.tracks[x] or {}
  end

  -- 2. no dangling segments ----------------------------------------------------------------
  local nrows = #rows
  for r, row in ipairs(rows) do
    for x, c in pairs(row.cells) do
      if c ~= 0 then
        if
          has(c, B.UP) and not (has(cell(r - 1, x), B.DOWN) or has(cell(r - 1, x + 1), B.DIAG))
        then
          err("row %d col %d: line up into nothing", r, x)
        end
        if
          has(c, B.DOWN)
          and r < nrows
          and not (has(cell(r + 1, x), B.UP) or has(cell(r + 1, x - 1), B.DIAG))
        then
          err("row %d col %d: line down into nothing", r, x)
        end
        if has(c, B.LEFT) and not has(cell(r, x - 1), B.RIGHT) then
          err("row %d col %d: line left into nothing", r, x)
        end
        if has(c, B.RIGHT) and not has(cell(r, x + 1), B.LEFT) then
          err("row %d col %d: line right into nothing", r, x)
        end
        if has(c, B.DIAG) then
          if x % 2 ~= 0 then
            err("row %d col %d: diagonal on a lane column", r, x)
          end
          if not has(cell(r - 1, x + 1), B.DOWN) then
            err("row %d col %d: diagonal without a line above", r, x)
          end
          if r < nrows and not has(cell(r + 1, x - 1), B.UP) then
            err("row %d col %d: diagonal without a line below", r, x)
          end
        end
      end
    end
  end

  -- 3. every loaded parent edge is drawn ---------------------------------------------------
  local idx_of = {}
  for i, c in ipairs(commits) do
    idx_of[c.sha] = i
  end
  for i, c in ipairs(commits) do
    for _, p in ipairs(c.parents) do
      local pi = idx_of[p]
      if pi and node_at[i] and node_at[pi] then
        local target = node_at[pi]
        local start = node_at[i]
        local seen, queue, found = {}, { start }, false
        while #queue > 0 and not found do
          local cur = table.remove(queue)
          local r, x = cur[1], cur[2]
          local key = r * 100000 + x
          if not seen[key] then
            seen[key] = true
            local c0 = cell(r, x)
            local function visit(nr, nx, via)
              if nr == target[1] and nx == target[2] then
                found = true
                return
              end
              local t = track(nr, nx)
              local ok = (via == "v" and set_has(t.v, p))
                or (via == "h" and (set_has(t.h, p) or set_has(t.v, p)))
                or (via == "d" and set_has(t.d, p))
              if ok then
                queue[#queue + 1] = { nr, nx }
              end
            end
            if has(c0, B.DOWN) then
              if has(cell(r + 1, x), B.UP) then
                visit(r + 1, x, "v")
              end
              if has(cell(r + 1, x - 1), B.DIAG) then
                visit(r + 1, x - 1, "d")
              end
            end
            if has(c0, B.DIAG) and has(cell(r + 1, x - 1), B.UP) then
              visit(r + 1, x - 1, "v")
            end
            if not (r == start[1] and x == start[2]) then
              if has(c0, B.LEFT) then
                visit(r, x - 1, "h")
              end
              if has(c0, B.RIGHT) then
                visit(r, x + 1, "h")
              end
            end
          end
        end
        if not found then
          err("edge %d -> %d (%s -> %s) is not drawn", i, pi, c.sha:sub(1, 7), p:sub(1, 7))
        end
      end
    end
  end

  -- 4. no mixed lines outside crossings ----------------------------------------------------
  local CROSS = bit.bor(B.UP, B.DOWN, B.LEFT, B.RIGHT)
  for r, row in ipairs(rows) do
    for x, c in pairs(row.cells) do
      local t = row.tracks and row.tracks[x]
      if t and c ~= CROSS and not has(c, B.NODE) then
        if count(t.h) > 0 and count(t.v) > 0 then
          for sha in pairs(t.h) do
            if not t.v[sha] then
              err(
                "row %d col %d: horizontal line to %s mixed into another lane",
                r,
                x,
                sha:sub(1, 7)
              )
            end
          end
        end
      end
    end
  end

  -- 5. lane colors are stable on straight runs ---------------------------------------------
  local VERT = bit.bor(B.UP, B.DOWN)
  for r = 1, nrows - 1 do
    for x, c in pairs(rows[r].cells) do
      local below = cell(r + 1, x)
      if c == VERT and below == VERT then
        local a, b = rows[r].colors[x], rows[r + 1].colors[x]
        if a ~= b then
          err("row %d col %d: lane color changes %s -> %s", r, x, tostring(a), tostring(b))
        end
      end
    end
  end

  return errs
end

--- Run layout over `commits` (with debug tracks) and return rows.
---@param commits { sha: string, parents: string[] }[]
---@param opts? table layout options
---@return table[] rows
function M.layout_all(commits, opts)
  local L = layout.new(vim.tbl_extend("force", { debug = true }, opts or {}))
  local rows = {}
  for i, c in ipairs(commits) do
    for _, row in ipairs(L:push(c, i)) do
      rows[#rows + 1] = row
    end
  end
  return rows, L
end

--- Random DAG in a random topological order (children before parents).
---@param rand fun(): number in [0,1)
---@param n integer
--- `window` limits how far back merge parents reach (nil = anywhere); `order = "newest_first"`
--- emits commits in creation order reversed (git-like) instead of a random topological order.
---@param opts? { merge?: number, root?: number, missing?: number, octopus?: number, window?: integer, order?: string }
---@return { sha: string, parents: string[] }[]
function M.random_dag(rand, n, opts)
  opts = opts or {}
  local merge, root, missing = opts.merge or 0.2, opts.root or 0.03, opts.missing or 0
  local parents = {}
  for k = 1, n do
    local ps = {}
    if k > 1 and rand() >= root then
      -- Prefer recent parents so the graph has long-lived lanes.
      local function pick()
        local back = math.floor((rand() ^ 3) * math.min(k - 1, 40)) + 1
        return k - back
      end
      ps[1] = pick()
      if rand() < merge then
        local extra = rand() < (opts.octopus or 0.1) and 3 or 1
        for _ = 1, extra do
          local reach = opts.window and math.min(k - 1, opts.window) or (k - 1)
          local q = k - (math.floor(rand() * reach) + 1)
          if not vim.tbl_contains(ps, q) then
            ps[#ps + 1] = q
          end
        end
      end
    end
    parents[k] = ps
  end
  -- Random topological order: repeatedly emit a commit none of whose children are pending.
  local children_left = {}
  for k = 1, n do
    children_left[k] = 0
  end
  for k = 1, n do
    for _, p in ipairs(parents[k]) do
      children_left[p] = children_left[p] + 1
    end
  end
  local ready = {}
  if opts.order == "newest_first" then
    for k = 1, n do
      children_left[k] = -1
    end
  end
  for k = 1, n do
    if children_left[k] == 0 then
      ready[#ready + 1] = k
    end
  end
  local order = {}
  if opts.order == "newest_first" then
    for k = n, 1, -1 do
      order[#order + 1] = k
    end
  end
  while #ready > 0 do
    local pick = math.floor(rand() * #ready) + 1
    local k = table.remove(ready, pick)
    order[#order + 1] = k
    for _, p in ipairs(parents[k]) do
      children_left[p] = children_left[p] - 1
      if children_left[p] == 0 then
        ready[#ready + 1] = p
      end
    end
  end
  local drop = {}
  if missing > 0 then
    for k = 1, n do
      if rand() < missing then
        drop[k] = true
      end
    end
  end
  local commits = {}
  for _, k in ipairs(order) do
    if not drop[k] then
      local ps = {}
      for i, p in ipairs(parents[k]) do
        ps[i] = ("%040x"):format(p)
      end
      commits[#commits + 1] = { sha = ("%040x"):format(k), parents = ps }
    end
  end
  return commits
end

--- Deterministic PRNG.
function M.prng(seed)
  local state = seed
  return function()
    state = (state * 16807) % 2147483647
    return state / 2147483647
  end
end

return M
