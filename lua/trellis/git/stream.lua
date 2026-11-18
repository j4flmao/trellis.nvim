--- Long-running git process with record splitting and pipe backpressure (research R2).
---
--- `pause()` stops reading stdout; once the OS pipe buffer fills, git blocks on write, so a
--- paused stream costs no CPU and memory only grows with what the consumer asked for.
local runner = require("trellis.git.runner")

local M = {}

---@class trellis.StreamOpts: trellis.RunOpts
---@field sep? string record separator (default "\30"); records are delivered without it
---@field on_records fun(records: string[])
---@field on_exit? fun(code: integer, stderr: string)
---@field schedule? boolean deliver callbacks on the main loop (default true)

---@class trellis.Stream
---@field pause fun()
---@field resume fun()
---@field kill fun()
---@field paused fun(): boolean
---@field done fun(): boolean
---@field pid integer?

local function env_list(overrides)
  local env = vim.fn.environ()
  for k, v in pairs(overrides) do
    env[k] = v
  end
  local list = {}
  for k, v in pairs(env) do
    list[#list + 1] = k .. "=" .. v
  end
  return list
end

--- Start a streaming git command. Must be called on the main loop.
---@param root string?
---@param args string[]
---@param opts trellis.StreamOpts
---@return trellis.Stream? stream, string? err
function M.start(root, args, opts)
  local uv = vim.uv
  local sep = opts.sep or "\30"
  local argv, env = runner.build(root, args, opts)
  local entry = {
    argv = argv,
    cwd = root,
    kind = opts.kind or "R",
    op_id = opts.op_id,
    started = uv.hrtime(),
  }
  runner.record(entry)

  local wrap = opts.schedule == false and function(f)
    return f
  end or vim.schedule_wrap

  local on_records = wrap(opts.on_records)
  local on_exit = opts.on_exit and wrap(opts.on_exit) or function() end

  local stdout = assert(uv.new_pipe(false))
  local stderr = assert(uv.new_pipe(false))
  local pending = ""
  local err_chunks = {}
  local paused, reading, eof, exited, finished = false, false, false, false, false
  local exit_code = 0
  local handle

  local function finish()
    if finished or not (eof and exited) then
      return
    end
    finished = true
    entry.duration_ms = (uv.hrtime() - entry.started) / 1e6
    entry.code = exit_code
    entry.stderr = table.concat(err_chunks)
    for _, pipe in ipairs({ stdout, stderr }) do
      if not pipe:is_closing() then
        pipe:close()
      end
    end
    if handle and not handle:is_closing() then
      handle:close()
    end
    on_exit(exit_code, entry.stderr)
  end

  local function on_read(err, chunk)
    if err or not chunk then
      eof = true
      if pending ~= "" then
        local last = pending
        pending = ""
        on_records({ last })
      end
      finish()
      return
    end
    local data = pending .. chunk
    local records, start = {}, 1
    while true do
      local s = data:find(sep, start, true)
      if not s then
        break
      end
      records[#records + 1] = data:sub(start, s - 1)
      start = s + #sep
    end
    pending = data:sub(start)
    if #records > 0 then
      on_records(records)
    end
  end

  local function start_reading()
    if not reading and not eof and not stdout:is_closing() then
      reading = true
      stdout:read_start(on_read)
    end
  end

  local stdin = opts.stdin and assert(uv.new_pipe(false)) or nil
  local spawn_err
  handle, spawn_err = uv.spawn(argv[1], {
    args = { unpack(argv, 2) },
    stdio = { stdin, stdout, stderr },
    env = env_list(env),
    cwd = opts.cwd,
    hide = true,
  }, function(code)
    exit_code = code
    exited = true
    finish()
  end)

  if stdin then
    if handle then
      stdin:write(opts.stdin)
      stdin:shutdown(function()
        if not stdin:is_closing() then
          stdin:close()
        end
      end)
    else
      stdin:close()
    end
  end

  if not handle then
    stdout:close()
    stderr:close()
    entry.code = -1
    entry.stderr = tostring(spawn_err)
    return nil, "git could not be started: " .. tostring(spawn_err)
  end

  stderr:read_start(function(_, chunk)
    if chunk then
      err_chunks[#err_chunks + 1] = chunk
    end
  end)
  start_reading()

  ---@type trellis.Stream
  local stream = { pid = handle:get_pid() }

  function stream.pause()
    if reading and not eof then
      stdout:read_stop()
      reading = false
    end
    paused = true
  end

  function stream.resume()
    paused = false
    start_reading()
  end

  function stream.paused()
    return paused
  end

  function stream.done()
    return finished
  end

  function stream.kill()
    if finished then
      return
    end
    if not handle:is_closing() then
      handle:kill("sigterm")
    end
    -- Drop remaining output: the consumer asked to stop.
    pending = ""
    on_records = function() end
    start_reading()
  end

  return stream
end

return M
