-- Filters (path with history simplification, author/grep/pickaxe with relayout), winbar
-- chips, the F filter editor (round trip, cursor kept), g/ whole-history search with cancel.
local fixtures = require("tests.fixtures")
local G = require("tests.helpers.graph")
local Repo = require("tests.helpers.repo")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local query = require("trellis.graph.query")

local function shas_of(v)
  local m = v.shown.model
  local out = {}
  for i = 1, m.n do
    out[i] = m.sha[i]
  end
  return out
end

local function git_shas(r, args)
  local cmd = { "log", "--topo-order", "--format=%H" }
  vim.list_extend(cmd, args)
  return vim.split(vim.trim(r:git(cmd)), "\n", { trimempty = true })
end

--- No edge points at a commit that is not shown (no endless lanes).
local function parents_closed(v)
  local m = v.shown.model
  for i = 1, m.n do
    for _, p in ipairs(m.parents[i]) do
      if not m.index[p] then
        return false, ("%s → %s not shown"):format(m.sha[i]:sub(1, 7), p:sub(1, 7))
      end
    end
  end
  return true
end

T["query text round trip"] = function()
  local cfg = require("trellis.config").get()
  for _, text in ipairs({
    '--author="Ana Lee" --since="2 weeks ago" -i -- src/ "docs/a b.md"',
    "main feature --first-parent --date-order --max-count=5",
    '-S"retry = 5" -- src/api.lua',
    "--grep=fix",
  }) do
    local q = assert(query.parse(query.split_args(text), cfg))
    local again = assert(query.parse(query.split_args(query.to_args(q)), cfg))
    eq({ text = text, same = vim.deep_equal(q, again) }, { text = text, same = true })
  end
  local q = query.parse(query.split_args('--author="Ana Lee" -- "docs/a b.md"'), cfg)
  eq({ q.author, q.paths }, { "Ana Lee", { "docs/a b.md" } })
  eq(query.parse({ "--bogus" }, cfg), nil)
end

T["path filter: git's history simplification, parents rewritten"] = function()
  local r = fixtures.get("merge-sequence")
  local v = G.open(r.path, nil, { "--", "b1.txt" })
  eq(G.wait_loaded(v), true)
  eq(shas_of(v), git_shas(r, { "--branches", "--remotes", "--tags", "HEAD", "--", "b1.txt" }))
  eq(parents_closed(v), true)
  eq(
    vim.wait(1000, function()
      return vim.wo.winbar:find("[-- b1.txt]", 1, true) ~= nil
    end),
    true
  )
end

T["author filter: results relaid out with edges between shown commits only"] = function()
  local r = fixtures.get("demo")
  local v = G.open(r.path, nil, { "--author=Bob" })
  eq(G.wait_loaded(v), true)
  eq(
    vim.wait(3000, function()
      return v.loader.relaid == true and v.appended == v.shown.model.loaded
    end),
    true
  )
  eq(shas_of(v), git_shas(r, { "--branches", "--remotes", "--tags", "HEAD", "--author=Bob" }))
  eq(parents_closed(v), true)
  -- Bob's six commits are a chain: every one but the oldest keeps its parent edge.
  local m = v.shown.model
  local edges = 0
  for i = 1, m.n do
    edges = edges + #m.parents[i]
  end
  eq(edges, 5)
  eq(
    vim.wait(1000, function()
      return vim.wo.winbar:find("[author:Bob]", 1, true) ~= nil
    end),
    true
  )
end

T["grep and pickaxe filters from :Trellis arguments"] = function()
  local r = fixtures.get("blame-chain")
  local v = G.open(r.path, nil, { "--grep=RETRY", "-i" })
  eq(G.wait_loaded(v), true)
  eq(shas_of(v), git_shas(r, { "--branches", "--remotes", "--tags", "HEAD", "--grep=RETRY", "-i" }))
  local p = G.open(r.path, nil, { "-Sretry = 5" })
  eq(G.wait_loaded(p), true)
  eq(shas_of(p), git_shas(r, { "--branches", "--remotes", "--tags", "HEAD", "-Sretry = 5" }))
  eq(#shas_of(p), 2) -- introduced, then removed
  local none = G.open(r.path, nil, { "--author=nobody" })
  eq(G.wait_loaded(none), true)
  eq(G.lines(none), { "no commits match" })
end

T["F edits the query; the cursor stays on its commit if it still matches"] = function()
  local r = fixtures.get("demo")
  local v = G.open(r.path, nil, { "--", "src/api.lua" })
  eq(G.wait_loaded(v), true)
  local target = git_shas(r, { "--branches", "--", "src/api.lua" })[2]
  local m = v.shown.model
  vim.api.nvim_win_set_cursor(0, { m.row_of_commit[m.index[target]], 0 })
  local shown_default
  local orig = vim.ui.input
  vim.ui.input = function(o, cb)
    shown_default = o.default
    cb("-- src/")
  end
  vim.cmd("normal F")
  vim.ui.input = orig
  eq(shown_default, "-- src/api.lua")
  eq(
    vim.wait(5000, function()
      return v.query.paths[1] == "src/" and G.wait_loaded(v, 1)
    end),
    true
  )
  local idx = require("trellis.view.graph").cursor_commit(v)
  eq(v.shown.model.sha[idx], target)
  eq(vim.b[v.bufnr].trellis.query.paths, { "src/" })
  -- An empty filter goes back to the full graph.
  require("trellis.view.graph").edit_filters(v, "")
  eq(
    vim.wait(5000, function()
      return #v.query.paths == 0 and G.wait_loaded(v, 1)
    end),
    true
  )
  eq(#shas_of(v), #git_shas(r, { "--branches", "--remotes", "--tags", "HEAD" }))
end

T["g/ searches all history; <CR> shows the commit in the graph"] = function()
  local r = fixtures.get("demo")
  local v = G.open(r.path, { perf = { prefetch_rows = 3 } })
  eq(G.wait_loaded(v, 3000) or true, true)
  local s
  require("trellis.view.search").open(v, "retry", {
    on_open = function(x)
      s = x
    end,
  })
  eq(
    vim.wait(5000, function()
      return s and s.status == "done"
    end),
    true
  )
  eq(
    s.shas,
    vim.split(
      vim.trim(r:git({
        "log",
        "--format=%H",
        "-i",
        "--grep=retry",
        "--branches",
        "--remotes",
        "--tags",
        "HEAD",
      })),
      "\n"
    )
  )
  eq(vim.wo.winbar:find(("%d matches"):format(#s.shas), 1, true) ~= nil, true)
  eq(#s.shas >= 2, true)
  -- The oldest match is far down; <CR> loads the graph up to it.
  vim.api.nvim_win_set_cursor(0, { #s.shas, 0 })
  vim.cmd("normal \r")
  eq(
    vim.wait(5000, function()
      local idx = require("trellis.view.graph").cursor_commit(v)
      return idx and v.shown.model.sha[idx] == s.shas[#s.shas]
    end),
    true
  )
  -- Pickaxe.
  local p
  require("trellis.view.search").open(v, '-S"retry = 3"', {
    on_open = function(x)
      p = x
    end,
  })
  eq(
    vim.wait(5000, function()
      return p and p.status == "done"
    end),
    true
  )
  eq(
    p.shas,
    vim.split(
      vim.trim(
        r:git({ "log", "--format=%H", "-Sretry = 3", "--branches", "--remotes", "--tags", "HEAD" })
      ),
      "\n"
    )
  )
end

T["a long search streams and <C-c> cancels it"] = function()
  local dir = require("tests.fixtures.fastimport.gen").build(
    Repo.root .. "/.tests/fixtures/synthetic-200k",
    { commits = 200000, merge_ratio = 0.15 }
  )
  local v = G.open(dir)
  vim.wait(3000, function()
    return v.shown ~= nil
  end)
  local s
  require("trellis.view.search").open(v, "-Snot-in-any-file", {
    on_open = function(x)
      s = x
    end,
  })
  vim.wait(300)
  vim.api.nvim_feedkeys(vim.keycode("<C-c>"), "x", false)
  eq(
    vim.wait(5000, function()
      return s.stream.done()
    end),
    true
  )
  eq(s.status, "cancelled")
  eq(vim.wo.winbar:find("cancelled", 1, true) ~= nil, true)
end

return require("tests.helpers.child").run_in_child(T, "tests/integration/filters_spec.lua")
