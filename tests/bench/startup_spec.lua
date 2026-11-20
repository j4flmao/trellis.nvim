-- Constitution III: sourcing plugin/trellis.lua costs < 1 ms and loads no trellis module.
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

--- Median time (ms) of sourcing `file` 30 times (after one warm-up).
local function median_source_ms(file)
  local times = {}
  for i = 1, 31 do
    vim.g.loaded_trellis = nil
    local t0 = vim.uv.hrtime()
    vim.cmd.source(file)
    local dt = (vim.uv.hrtime() - t0) / 1e6
    if i > 1 then
      times[#times + 1] = dt
    end
  end
  table.sort(times)
  return times[math.ceil(#times / 2)]
end

T["plugin file startup cost"] = function()
  local root = vim.fn.getcwd()
  -- What trellis adds: sourcing plugin/trellis.lua minus sourcing an empty Lua file (the
  -- fixed cost of :source itself, which shared CI runners make larger and noisier).
  local empty = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "-- empty" }, empty)
  local base = median_source_ms(empty)
  local median = median_source_ms(root .. "/plugin/trellis.lua") - base
  vim.fn.delete(empty)
  io.stdout:write(
    ("\n  bench %-28s %10.3f ms (+ %.3f ms for :source)"):format("plugin startup", median, base)
  )
  eq({ under_1ms = median < 1, median_ms = math.floor(median * 1000) / 1000 }, {
    under_1ms = true,
    median_ms = math.floor(median * 1000) / 1000,
  })
end

T["sourcing the plugin requires no trellis module"] = function()
  -- Child process: a clean module cache.
  local child = MiniTest.new_child_neovim()
  child.restart({ "-u", "tests/minimal_init.lua" })
  local loaded = child.lua([[
    local out = {}
    for name in pairs(package.loaded) do
      if name:match("^trellis") then out[#out + 1] = name end
    end
    return out
  ]])
  eq(child.lua_get("vim.fn.exists(':Trellis')"), 2)
  child.stop()
  eq(loaded, {})
end

return T
