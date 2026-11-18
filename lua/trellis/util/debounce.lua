--- Trailing-edge debounce on a libuv timer. The wrapped function runs on the main loop.
---
--- ```lua
--- local d = debounce(200, function(path) refresh(path) end)
--- d("refs/heads/main")   -- call
--- d:cancel()  d:flush()  d:close()
--- ```
---@class trellis.Debounced
---@field cancel fun(self: trellis.Debounced)
---@field flush fun(self: trellis.Debounced)
---@field close fun(self: trellis.Debounced)
---@field pending fun(self: trellis.Debounced): boolean

---@param ms integer
---@param fn function
---@return trellis.Debounced
return function(ms, fn)
  local timer = assert(vim.uv.new_timer())
  local args ---@type table?
  local generation = 0
  local obj = {}

  local function fire(gen)
    if gen ~= generation or not args then
      return
    end
    local a = args
    args = nil
    fn(unpack(a, 1, a.n))
  end

  function obj:pending()
    return args ~= nil
  end

  function obj:cancel()
    generation = generation + 1
    args = nil
    timer:stop()
  end

  function obj:flush()
    if args then
      timer:stop()
      generation = generation + 1
      fire(generation)
    end
  end

  function obj:close()
    self:cancel()
    if not timer:is_closing() then
      timer:close()
    end
  end

  return setmetatable(obj, {
    __call = function(_, ...)
      args = vim.F.pack_len(...)
      generation = generation + 1
      local gen = generation
      timer:stop()
      timer:start(ms, 0, function()
        vim.schedule(function()
          fire(gen)
        end)
      end)
    end,
  })
end
