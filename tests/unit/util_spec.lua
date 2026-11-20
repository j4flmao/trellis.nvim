local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

-- async ---------------------------------------------------------------------------------------

T["async"] = MiniTest.new_set()

T["async"]["await returns callback values, sync and async"] = function()
  local async = require("trellis.util.async")
  local got
  async.run(function()
    local a, b = async.await(function(cb)
      cb(1, 2)
    end)
    local c = async.await(function(cb)
      vim.schedule(function()
        cb(a + b)
      end)
    end)
    return c * 10
  end, function(err, value)
    got = { err = err, value = value }
  end)
  vim.wait(1000, function()
    return got ~= nil
  end)
  eq(got, { value = 30 })
end

T["async"]["errors reach on_done with a traceback"] = function()
  local async = require("trellis.util.async")
  local got
  async.run(function()
    error("boom")
  end, function(err)
    got = err
  end)
  eq(type(got), "string")
  eq(got:find("boom", 1, true) ~= nil, true)
end

T["async"]["wrap and all"] = function()
  local async = require("trellis.util.async")
  local function add(a, b, cb)
    vim.schedule(function()
      cb(a + b)
    end)
  end
  local got
  async.run(function()
    return async.wrap(add)(2, 3)
  end, function(_, v)
    got = v
  end)
  vim.wait(1000, function()
    return got ~= nil
  end)
  eq(got, 5)

  local all
  async.all({
    function(cb)
      add(1, 1, cb)
    end,
    function(cb)
      cb("x", "y")
    end,
  }, function(results)
    all = results
  end)
  vim.wait(1000, function()
    return all ~= nil
  end)
  eq(all[1][1], 2)
  eq({ all[2][1], all[2][2] }, { "x", "y" })
end

-- debounce ------------------------------------------------------------------------------------

T["debounce"] = MiniTest.new_set()

T["debounce"]["coalesces calls and keeps the last arguments"] = function()
  local debounce = require("trellis.util.debounce")
  local calls = {}
  local d = debounce(30, function(v)
    calls[#calls + 1] = v
  end)
  for i = 1, 5 do
    d(i)
  end
  vim.wait(500, function()
    return #calls > 0
  end)
  vim.wait(60)
  eq(calls, { 5 })
  d:close()
end

T["debounce"]["cancel and flush"] = function()
  local debounce = require("trellis.util.debounce")
  local calls = {}
  local d = debounce(30, function(v)
    calls[#calls + 1] = v
  end)
  d("a")
  d:cancel()
  vim.wait(80)
  eq(calls, {})
  d("b")
  eq(d:pending(), true)
  d:flush()
  eq(calls, { "b" })
  vim.wait(80)
  eq(calls, { "b" })
  d:close()
end

-- time ----------------------------------------------------------------------------------------

T["time"] = MiniTest.new_set()

T["time"]["relative"] = function()
  local time = require("trellis.util.time")
  local now = 1700000000
  eq(time.relative(now, now), "just now")
  eq(time.relative(now - 60, now), "1 minute ago")
  eq(time.relative(now - 5 * 60, now), "5 minutes ago")
  eq(time.relative(now - 3 * 3600, now), "3 hours ago")
  eq(time.relative(now - 86400, now), "1 day ago")
  eq(time.relative(now - 15 * 86400, now), "2 weeks ago")
  eq(time.relative(now - 100 * 86400, now), "3 months ago")
  eq(time.relative(now - 800 * 86400, now), "2 years ago")
  eq(time.relative(now + 100, now), "in the future")
end

T["time"]["format"] = function()
  local time = require("trellis.util.time")
  eq(time.format(0, "%Y", 0) ~= "", true)
  eq(time.format(100, "relative", 100), "just now")
  eq(#time.format(1700000000, "iso"), 16)
end

-- events --------------------------------------------------------------------------------------

T["events"] = MiniTest.new_set()

T["events"]["emits User autocmds with data"] = function()
  local events = require("trellis.events")
  local got
  local id = vim.api.nvim_create_autocmd("User", {
    pattern = "TrellisRefsChanged",
    callback = function(ev)
      got = ev.data
    end,
  })
  events.emit("TrellisRefsChanged", { root = "/r", generation = 3 })
  vim.api.nvim_del_autocmd(id)
  eq(got, { root = "/r", generation = 3 })
end

T["events"]["unknown event is an error"] = function()
  MiniTest.expect.error(function()
    require("trellis.events").emit("TrellisNope")
  end, "unknown event")
end

T["fs"] = MiniTest.new_set()

T["fs"]["mkdirp: existing directories are fine, a file in the way is an error"] = function()
  local fs = require("trellis.util.fs")
  local base = vim.fn.tempname()
  eq(fs.mkdirp(base .. "/a/b"), true)
  eq(fs.mkdirp(base .. "/a/b"), true) -- again: already there (what a concurrent process sees)
  local f = assert(io.open(base .. "/file", "w"))
  f:close()
  local ok, err = fs.mkdirp(base .. "/file")
  eq(ok, false)
  eq(type(err), "string")
  vim.fn.delete(base, "rf")
end

-- async/debounce wait on the event loop: run every case in a child Neovim.
return require("tests.helpers.child").run_in_child(T, "tests/unit/util_spec.lua")
