-- T026 / Constitution III: sourcing plugin/trellis.lua costs < 1 ms and loads no trellis module.
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["plugin file startup cost"] = function()
  local root = vim.fn.getcwd()
  local file = root .. "/plugin/trellis.lua"
  -- Warm up the file cache, then measure the median of 30 runs.
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
  local median = times[math.ceil(#times / 2)]
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
