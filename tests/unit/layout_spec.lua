-- Graph layout engine, test-first. Layout invariants (tests/helpers/graph_check.lua) on hand-made shapes and
-- 1,000 random DAGs; fixture repositories are covered in tests/integration/layout_fixtures_spec.lua.
local check = require("tests.helpers.graph_check")
local layout = require("trellis.graph.layout")
local glyphs = require("trellis.graph.glyphs")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

--- Commits from a compact spec: { "c b", "b a", "a" } = c has parent b, b has parent a.
local function dag(spec)
  local commits = {}
  for _, line in ipairs(spec) do
    local parts = vim.split(line, " ", { trimempty = true })
    local function sha(s)
      return (s .. ("_"):rep(40)):sub(1, 40)
    end
    local ps = {}
    for i = 2, #parts do
      ps[#ps + 1] = sha(parts[i])
    end
    commits[#commits + 1] = { sha = sha(parts[1]), parents = ps }
  end
  return commits
end

local function render(rows)
  local lines = {}
  for _, row in ipairs(rows) do
    lines[#lines + 1] = glyphs.render(row, "rounded")
  end
  return lines
end

local function assert_valid(commits, opts)
  local rows, L = check.layout_all(commits, opts)
  local errs = check.check(commits, rows)
  if #errs > 0 then
    error(table.concat(errs, "\n") .. "\n\n" .. table.concat(render(rows), "\n"), 2)
  end
  return rows, L
end

T["shapes"] = MiniTest.new_set()

T["shapes"]["linear history is one straight lane"] = function()
  local rows = assert_valid(dag({ "c b", "b a", "a" }))
  eq(render(rows), { "●", "●", "●" })
end

T["shapes"]["branch and merge"] = function()
  -- m merges f into main: m(b, f), f(a), b(a), a
  local rows = assert_valid(dag({ "m b f", "f a", "b a", "a" }))
  -- The first parent continues in the commit's lane; lanes waiting for the same commit
  -- converge on that commit's own row.
  eq(render(rows), {
    "○",
    "├─╮",
    "│ ●",
    "● │",
    "●─╯",
  })
end

T["shapes"]["two tips converge on their fork point"] = function()
  local rows = assert_valid(dag({ "x a", "y a", "a" }))
  eq(render(rows), { "●", "│ ●", "●─╯" })
end

T["shapes"]["octopus merge draws every parent edge"] = function()
  assert_valid(dag({ "o a b c d", "d r", "c r", "b r", "a r", "r" }))
end

T["shapes"]["criss-cross merge"] = function()
  -- F(D, E); D(B, C); E(C, B); B(A); C(A); A
  assert_valid(dag({ "F D E", "E C B", "D B C", "C A", "B A", "A" }))
end

T["shapes"]["multiple roots and orphan branches"] = function()
  assert_valid(dag({ "m a x", "x y", "y", "a b", "b", "g h", "h" }))
end

T["shapes"]["parents that are never loaded keep their lane to the end"] = function()
  local commits = dag({ "c b missing1", "b missing2" })
  local rows = assert_valid(commits)
  -- The last row still has lines going down.
  local last = rows[#rows]
  local down = 0
  for _, c in pairs(last.cells) do
    if bit.band(c, layout.bits.DOWN) ~= 0 then
      down = down + 1
    end
  end
  eq(down >= 1, true)
end

T["shapes"]["freed middle lanes are compacted with diagonals"] = function()
  -- Three tips; the middle one ends at a root early, the right lane shifts left.
  local commits = dag({ "x a", "y q", "z a", "q", "a" })
  local rows = assert_valid(commits)
  local has_diag = false
  for _, row in ipairs(rows) do
    for _, c in pairs(row.cells) do
      if bit.band(c, layout.bits.DIAG) ~= 0 then
        has_diag = true
      end
    end
  end
  eq(has_diag, true)
end

T["shapes"]["merge commits and merges-in use distinct node bits"] = function()
  local rows = assert_valid(dag({ "m a b", "b a", "a" }))
  local node = rows[1].cells[1]
  eq(bit.band(node, layout.bits.MERGE) ~= 0, true)
  eq(bit.band(rows[#rows].cells[1], layout.bits.MERGE), 0)
end

T["properties"] = MiniTest.new_set()

T["properties"]["1000 random DAGs satisfy every invariant"] = function()
  local rand = check.prng(12345)
  for case = 1, 1000 do
    local n = 5 + math.floor(rand() * 60)
    local commits = check.random_dag(rand, n, {
      merge = rand() * 0.5,
      root = rand() * 0.08,
      missing = case % 5 == 0 and 0.15 or 0,
      octopus = 0.15,
    })
    local rows = check.layout_all(commits)
    local errs = check.check(commits, rows)
    if #errs > 0 then
      local lines = { ("case %d (n=%d):"):format(case, #commits) }
      for i, c in ipairs(commits) do
        local ps = vim.tbl_map(function(p)
          return p:sub(-4)
        end, c.parents)
        lines[#lines + 1] = ("  %d %s -> %s"):format(i, c.sha:sub(-4), table.concat(ps, " "))
      end
      vim.list_extend(lines, errs)
      vim.list_extend(lines, render(rows))
      error(table.concat(lines, "\n"))
    end
  end
end

T["properties"]["layout is deterministic and independent of push batching"] = function()
  local rand = check.prng(777)
  local commits = check.random_dag(rand, 300, { merge = 0.3 })
  local a = check.layout_all(commits)
  local b = check.layout_all(commits)
  eq(#a, #b)
  for i = 1, #a do
    eq(
      { a[i].kind, a[i].commit, a[i].cells, a[i].colors },
      { b[i].kind, b[i].commit, b[i].cells, b[i].colors }
    )
  end
  -- push_many in random chunk sizes gives the same rows.
  local L = layout.new({ debug = true })
  local rows, i = {}, 1
  while i <= #commits do
    local size = math.floor(rand() * 37) + 1
    local chunk = { unpack(commits, i, math.min(#commits, i + size - 1)) }
    vim.list_extend(rows, L:push_many(chunk, i))
    i = i + size
  end
  eq(#rows, #a)
  for k = 1, #a do
    eq({ rows[k].commit, rows[k].cells }, { a[k].commit, a[k].cells })
  end
end

T["properties"]["lane state stays bounded on long histories"] = function()
  local rand = check.prng(99)
  local commits = check.random_dag(
    rand,
    3000,
    { merge = 0.15, root = 0.005, window = 40, order = "newest_first" }
  )
  local _, L = check.layout_all(commits, { debug = false })
  eq(L:width() < 60, true)
end

T["non-debug rows have no tracks"] = function()
  local L = layout.new()
  local rows = L:push({ sha = ("a"):rep(40), parents = {} }, 1)
  eq(rows[1].tracks, nil)
end

return T
