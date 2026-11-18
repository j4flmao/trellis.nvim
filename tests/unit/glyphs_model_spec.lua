-- T022 glyphs (styles, widths, overflow) and T023 model (struct-of-arrays, memory budget).
local check = require("tests.helpers.graph_check")
local layout = require("trellis.graph.layout")
local glyphs = require("trellis.graph.glyphs")
local model = require("trellis.graph.model")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function sha(s)
  return (s .. ("_"):rep(40)):sub(1, 40)
end

-- m(b, f) f(a) b(a) a, plus x(q) q to force compaction
local SAMPLE = {
  { sha = sha("m"), parents = { sha("b"), sha("f") } },
  { sha = sha("x"), parents = { sha("q") } },
  { sha = sha("f"), parents = { sha("a") } },
  { sha = sha("q"), parents = {} },
  { sha = sha("b"), parents = { sha("a") } },
  { sha = sha("a"), parents = {} },
}

local function render_all(style, opts)
  local rows = check.layout_all(SAMPLE)
  return vim.tbl_map(function(r)
    return (glyphs.render(r, style, opts))
  end, rows)
end

T["styles"] = MiniTest.new_set()

T["styles"]["snapshots"] = function()
  eq(
    render_all("rounded"),
    { "○", "├─╮", "│ │ ●", "│ ● │", "│ │ ●", "● │", "●─╯" }
  )
  eq(
    render_all("unicode"),
    { "○", "├─┐", "│ │ ●", "│ ● │", "│ │ ●", "● │", "●─┘" }
  )
  eq(render_all("ascii"), { "o", "+-.", "| | *", "| * |", "| | *", "* |", "*-'" })
end

T["styles"]["every glyph is one display cell, two per lane"] = function()
  for style in pairs(glyphs.styles) do
    for _, r in ipairs(check.layout_all(SAMPLE)) do
      local text, width = glyphs.render(r, style)
      eq(vim.fn.strdisplaywidth(text) <= width, true)
      eq(vim.fn.strchars(text), vim.fn.strdisplaywidth(text))
    end
  end
end

T["styles"]["head node and compaction diagonal"] = function()
  local L = layout.new()
  local rows = {}
  for i, c in ipairs({
    { sha = sha("x"), parents = { sha("a") } },
    { sha = sha("y"), parents = { sha("q") } },
    { sha = sha("z"), parents = { sha("a") } },
    { sha = sha("q"), parents = {} }, -- frees the middle lane: z's lane shifts left
    { sha = sha("a"), parents = {} },
  }) do
    vim.list_extend(rows, L:push(c, i))
  end
  eq(glyphs.render(rows[1], "rounded", { head = true }), "◉")
  local diag = vim.tbl_filter(function(r)
    return glyphs.render(r, "rounded"):find("╱", 1, true) ~= nil
  end, rows)
  eq(#diag, 1)
  eq(glyphs.render(diag[1], "ascii"), "|  /")
end

T["styles"]["lanes beyond max_lanes collapse into one overflow column"] = function()
  local commits = {}
  for i = 1, 12 do
    commits[#commits + 1] = { sha = sha("t" .. i), parents = { sha("root") } }
  end
  commits[#commits + 1] = { sha = sha("root"), parents = {} }
  local rows = check.layout_all(commits)
  -- Tip 12 sits in lane 12, beyond max_lanes = 4: its node shows in the overflow column.
  local text = glyphs.render(rows[12], "rounded", { max_lanes = 4 })
  eq(text, "│ │ │ │ ●")
  -- The root row: node in lane 1, the converging lines beyond lane 4 collapse into "…".
  local root = glyphs.render(rows[13], "rounded", { max_lanes = 4 })
  eq(root, "●─┴─┴─┴ …")
  eq(vim.fn.strdisplaywidth(text) <= 2 * 4 + 1, true)
end

T["styles"]["ascii fallback for ambiwidth=double"] = function()
  local old = vim.o.ambiwidth
  vim.o.ambiwidth = "double"
  eq(glyphs.resolve_style("rounded"), "ascii")
  vim.o.ambiwidth = old
  eq(glyphs.resolve_style("unicode"), "unicode")
  eq(glyphs.resolve_style("nope"), "rounded")
end

T["model"] = MiniTest.new_set()

T["model"]["stores commits and rows; navigation helpers"] = function()
  local m = model.new()
  local L = layout.new()
  for _, c in ipairs(SAMPLE) do
    local idx = m:add_commit(c)
    m:add_rows(L:push(c, idx))
  end
  eq(m.n, 6)
  eq(m.loaded, 7)
  eq(m:index_of(sha("f")), 3)
  eq(m:commit(3).parents, { sha("a") })
  eq(m:commit(99), nil)
  eq(m.rows_text[2], "├─╮")
  eq(m:commit_at_row(2), nil)
  eq(m:commit_at_row(m.row_of_commit[3]), 3)
  eq(m:next_commit_row(2, 1), 3)
  eq(m:next_commit_row(2, -1), 1)
  -- Packed colors: one byte per column, lane colors stable.
  eq(#m.rows_colors[2], 3)
  eq(m.rows_colors[2]:byte(1), m.rows_colors[1]:byte(1))
end

T["model"]["50k commits stay within the memory budget (< 60 MB)"] = function()
  local rand = check.prng(4242)
  local commits = check.random_dag(
    rand,
    50000,
    { merge = 0.15, root = 0.002, window = 60, order = "newest_first" }
  )
  for _, c in ipairs(commits) do
    c.author = "Author Name"
    c.time = 1700000000
    c.subject = "A typical commit subject line of moderate length"
  end
  collectgarbage("collect")
  local before = collectgarbage("count")
  local m = model.new()
  local L = layout.new()
  local t0 = vim.uv.hrtime()
  for _, c in ipairs(commits) do
    local idx = m:add_commit(c)
    m:add_rows(L:push(c, idx))
  end
  local ms = (vim.uv.hrtime() - t0) / 1e6
  collectgarbage("collect")
  local lua_kb = collectgarbage("count") - before
  -- Buffer text estimate: graph prefix + short sha + subject per row (research R4 line layout).
  local buf_bytes = 0
  for r = 1, m.loaded do
    buf_bytes = buf_bytes + #m.rows_text[r] + 10 + (m.rows_kind[r] == 1 and 50 or 0)
  end
  local total_mb = (lua_kb * 1024 + buf_bytes) / (1024 * 1024)
  -- Note: the commit tables themselves (input) are part of `before`; the model only holds
  -- references to their strings and parent arrays.
  eq(m.n, #commits)
  eq(
    { under_budget = total_mb < 60, mb = math.floor(total_mb) },
    { under_budget = true, mb = math.floor(total_mb) }
  )
  -- Layout + render throughput sanity (not a budget; budgets live in tests/bench).
  eq(ms < 20000, true)
end

return T
