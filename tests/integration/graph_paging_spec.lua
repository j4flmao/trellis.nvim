-- T031: backpressure (rows loaded ≤ viewed + prefetch + in-flight batches), resume on scroll,
-- G loads everything, <C-c> cancels. Runs in a child Neovim per case.
local G = require("tests.helpers.graph")
local Repo = require("tests.helpers.repo")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local PREFETCH, PAGE = 600, 200

local function synthetic()
  return require("tests.fixtures.fastimport.gen").build(
    Repo.root .. "/.tests/fixtures/synthetic-20k",
    { commits = 20000, merge_ratio = 0.1 }
  )
end

local function open()
  local v = G.open(synthetic(), { perf = { prefetch_rows = PREFETCH, page_size = PAGE } })
  vim.wait(5000, function()
    return v.shown ~= nil and v.appended > 0 and v.loader.status == "paused"
  end, 5)
  -- Let in-flight batches land.
  vim.wait(200)
  return v
end

--- Rows one pipe read can add beyond the pause point (one batch ≈ one 64 KiB chunk).
local SLACK = 2000

T["the stream pauses after prefetch rows and loads on demand"] = function()
  local v = open()
  local l = v.loader
  eq(l.status, "paused")
  eq(l.model.loaded <= l.deepest + PREFETCH + SLACK, true)
  eq(l.model.loaded < 20000, true)
  local before = l.model.loaded
  vim.wait(300)
  eq(l.model.loaded, before)

  -- Scrolling near the end of the loaded rows resumes loading.
  vim.api.nvim_win_set_cursor(0, { v.appended, 0 })
  vim.cmd("redraw")
  vim.wait(3000, function()
    return l.model.loaded > before + PREFETCH / 2
  end, 5)
  eq(l.model.loaded > before, true)
  vim.wait(300)
  eq(l.model.loaded <= l.deepest + PREFETCH + SLACK, true)
end

T["G loads the whole history and jumps to the oldest commit"] = function()
  local v = open()
  vim.cmd("normal G")
  eq(
    vim.wait(20000, function()
      -- (+ v.top: the repository has no checkout, so the "uncommitted changes" line shows)
      return v.loader:done() and vim.api.nvim_win_get_cursor(0)[1] == v.appended + (v.top or 0)
    end, 10),
    true
  )
  eq(v.loader.status, "complete")
  eq(v.shown.model.n, 20000)
  eq(vim.api.nvim_buf_line_count(v.bufnr), v.shown.model.loaded + (v.top or 0))
  eq(vim.api.nvim_get_current_line():find("commit 1 on b1", 1, true) ~= nil, true)
end

T["<C-c> cancels loading and the winbar says history is truncated"] = function()
  local v = open()
  v.loader:load_all()
  vim.api.nvim_feedkeys(vim.keycode("<C-c>"), "x", false)
  eq(
    vim.wait(2000, function()
      return v.loader.status == "cancelled"
    end),
    true
  )
  local n = v.shown.model.n
  vim.wait(300)
  eq(v.shown.model.n, n)
  eq(
    vim.wait(1000, function()
      return vim.wo.winbar:find("truncated: cancelled", 1, true) ~= nil
    end),
    true
  )
end

T["closing the view stops the git process"] = function()
  local v = open()
  local stream = v.loader.stream
  vim.api.nvim_buf_delete(v.bufnr, { force = true })
  eq(
    vim.wait(3000, function()
      return stream.done()
    end),
    true
  )
end

return require("tests.helpers.child").run_in_child(T, "tests/integration/graph_paging_spec.lua")
