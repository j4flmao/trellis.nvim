-- Budgets on the 200k-commit synthetic repository (commit-graph present):
-- first screen < 300 ms, p95 redraw while scrolling < 16 ms, memory < 60 MB for 50k commits.
-- A child Neovim with an attached UI (this process) does real redraws.
local Repo = require("tests.helpers.repo")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.o.lines, child.o.columns = 50, 160
    end,
    post_once = child.stop,
  },
})

-- TRELLIS_BENCH_REPO: a real repository instead (scripts/bench_kernel.sh, the Linux kernel).
local REAL = vim.env.TRELLIS_BENCH_REPO
local function repo_dir()
  if REAL and REAL ~= "" then
    return REAL
  end
  return require("tests.fixtures.fastimport.gen").build(
    vim.env.TRELLIS_BENCH_REPO_200K or (Repo.root .. "/.tests/fixtures/synthetic-200k"),
    { commits = 200000, merge_ratio = 0.15 }
  )
end

local function report(name, value, unit)
  io.stdout:write(("\n  bench %-28s %10.2f %s"):format(name, value, unit))
end

T["first screen"] = function()
  local dir = repo_dir()
  local ms = child.lua(
    [[
    local dir = ...
    require("trellis").setup({ graph = { open = "current" } })
    local view
    local t0 = vim.uv.hrtime()
    require("trellis.view.graph").open({ cwd = dir, on_open = function(v) view = v end })
    vim.wait(10000, function() return view and view.first_screen_ms ~= nil end, 1)
    -- Measured from the :Trellis call: discovery, refs, stream start, first chunk in the buffer.
    return (vim.uv.hrtime() - t0) / 1e6
  ]],
    { dir }
  )
  report("first screen", ms, "ms")
  eq({ under_300ms = ms < 300 }, { under_300ms = true })
end

T["scrolling redraw p95"] = function()
  local dir = repo_dir()
  local res = child.lua(
    [[
    local dir = ...
    require("trellis").setup({ graph = { open = "current" } })
    local view
    require("trellis.view.graph").open({ cwd = dir, on_open = function(v) view = v end })
    vim.wait(10000, function() return view and view.appended > 2000 end, 1)
    local times = {}
    for _ = 1, 300 do
      local t0 = vim.uv.hrtime()
      vim.cmd("normal! \4")
      vim.cmd("redraw")
      times[#times + 1] = (vim.uv.hrtime() - t0) / 1e6
      -- Let loader batches land between keystrokes, as they would while holding <C-d>.
      vim.wait(0)
    end
    table.sort(times)
    return { p95 = times[math.ceil(#times * 0.95)], max = times[#times], rows = view.appended }
  ]],
    { dir }
  )
  report("redraw p95", res.p95, "ms")
  report("redraw max", res.max, "ms")
  eq({ p95_under_16ms = res.p95 < 16 }, { p95_under_16ms = true })
end

T["full history load (G) stays responsive"] = function()
  local dir = repo_dir()
  local res = child.lua(
    [[
    local dir = ...
    require("trellis").setup({ graph = { open = "current" } })
    local view
    require("trellis.view.graph").open({ cwd = dir, on_open = function(v) view = v end })
    vim.wait(10000, function() return view and view.appended > 0 end, 1)
    local t0 = vim.uv.hrtime()
    local max_gap, last = 0, vim.uv.hrtime()
    -- A repeating timer measures how long the main loop is blocked while everything loads.
    local timer = vim.uv.new_timer()
    timer:start(0, 5, vim.schedule_wrap(function()
      local now = vim.uv.hrtime()
      max_gap = math.max(max_gap, (now - last) / 1e6)
      last = now
    end))
    require("trellis.view.graph").load_all(view, function() end)
    vim.wait(120000, function()
      return view.loader:done() and view.appended == view.loader.model.loaded
    end, 5)
    timer:stop()
    timer:close()
    return {
      ms = (vim.uv.hrtime() - t0) / 1e6,
      n = view.loader.model.n,
      max_gap = max_gap,
      rss = vim.uv.resident_set_memory() / 1048576,
    }
  ]],
    { dir }
  )
  report("full load", res.ms / 1000, "s")
  report("full load commits", res.n, "")
  report("longest main-loop block", res.max_gap, "ms")
  report("RSS after full load", res.rss, "MB")
  if REAL then
    -- The kernel budgets: full history < 20 s, the whole Neovim < 300 MB after it.
    eq({ under_300mb = res.rss < 300 }, { under_300mb = true })
  else
    eq(res.n, 200000)
  end
  -- Asks < 20 s for the kernel (1.3M); 200k must be far below.
  eq({ under_20s = res.ms < 20000 }, { under_20s = true })
  -- Loading is time-sliced (4 ms of parsing/layout per turn); occasional longer gaps are GC.
  eq({ responsive = res.max_gap < 200 }, { responsive = true })
end

T["memory for 50k commits"] = function()
  local dir = repo_dir()
  local res = child.lua(
    [[
    local dir = ...
    require("trellis").setup({ graph = { open = "current" }, perf = { prefetch_rows = 59500 } })
    collectgarbage("collect")
    local rss0 = vim.uv.resident_set_memory()
    local lua0 = collectgarbage("count")
    local view
    require("trellis.view.graph").open({ cwd = dir, on_open = function(v) view = v end })
    -- ~1.19 rows per commit here: the stream pauses near 50k commits; wait until it has.
    vim.wait(60000, function()
      local l = view and view.loader
      return l and l.status == "paused" and l:_pending() == 0 and view.appended >= l.model.loaded
    end, 5)
    view.loader:cancel()
    collectgarbage("collect")
    return {
      n = view.loader.model.n,
      rss_mb = (vim.uv.resident_set_memory() - rss0) / 1048576,
      lua_mb = (collectgarbage("count") - lua0) / 1024,
      buf_mb = vim.api.nvim_buf_get_offset(view.bufnr, vim.api.nvim_buf_line_count(view.bufnr)) / 1048576,
    }
  ]],
    { dir }
  )
  report("commits loaded", res.n, "")
  report("RSS growth", res.rss_mb, "MB")
  report("RSS growth per 50k commits", res.rss_mb * 50000 / res.n, "MB")
  report("Lua heap growth", res.lua_mb, "MB")
  report("buffer text", res.buf_mb, "MB")
  -- Rows per commit depend on the history's shape: ~50k commits on the synthetic repository.
  eq(res.n >= (REAL and 20000 or 40000) and res.n <= 60000, true)
  eq({ under_60mb = res.rss_mb * 50000 / res.n < 60 }, { under_60mb = true })
end

return T
