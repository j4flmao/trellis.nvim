--- Small coroutine helpers over callback-style APIs (vim.system, vim.uv).
---
--- ```lua
--- async.run(function()
---   local err, res = async.await(function(cb) runner.run(root, args, nil, cb) end)
--- end, function(err, ...) end)
--- ```
local M = {}

local function report(err)
  vim.schedule(function()
    vim.notify("trellis: " .. tostring(err), vim.log.levels.ERROR)
  end)
end

--- Run `fn` as a coroutine. `on_done(err, ...)` receives an error (with traceback) or the
--- function's return values. Without `on_done`, errors are reported with vim.notify.
---@param fn fun(...): ...
---@param on_done? fun(err: string?, ...)
function M.run(fn, on_done)
  local co = coroutine.create(fn)
  local step
  step = function(...)
    local res = vim.F.pack_len(coroutine.resume(co, ...))
    if not res[1] then
      local err = debug.traceback(co, tostring(res[2]))
      if on_done then
        on_done(err)
      else
        report(err)
      end
      return
    end
    if coroutine.status(co) == "dead" then
      if on_done then
        on_done(nil, unpack(res, 2, res.n))
      end
      return
    end
    local start = res[2]
    local called = false
    start(function(...)
      if called then
        return
      end
      called = true
      step(...)
    end)
  end
  step()
end

--- Inside `async.run`: start async work and wait for its callback; returns the callback's args.
---@param start fun(cb: fun(...))
---@return ...
function M.await(start)
  assert(coroutine.running(), "trellis.util.async.await called outside async.run")
  return coroutine.yield(start)
end

--- Wrap `fn(..., cb)` into a function that awaits the callback inside `async.run`.
---@param fn function
---@return function
function M.wrap(fn)
  return function(...)
    local args = vim.F.pack_len(...)
    return M.await(function(cb)
      args[args.n + 1] = cb
      fn(unpack(args, 1, args.n + 1))
    end)
  end
end

--- Run several callback-style jobs concurrently; `cb(results)` gets one packed arg list per job.
---@param jobs (fun(cb: fun(...)))[]
---@param cb fun(results: table[])
function M.all(jobs, cb)
  local results, pending = {}, #jobs
  if pending == 0 then
    return cb(results)
  end
  for i, job in ipairs(jobs) do
    job(function(...)
      results[i] = vim.F.pack_len(...)
      pending = pending - 1
      if pending == 0 then
        cb(results)
      end
    end)
  end
end

return M
