--- Operation journal: `<commondir>/trellis/ops.jsonl` (research R11, data-model Operation).
---
--- Append-only JSON lines. Every write appends a full snapshot of one operation; readers fold
--- lines by `id` (last line wins), so a status change is an append, never a rewrite, and a
--- crash leaves at worst one torn trailing line, which readers skip. Appends are serialized
--- across processes and worktrees with `ops.lock` (O_EXCL create; stale locks of dead
--- processes older than 30 s are broken), because O_APPEND alone is not atomic on network
--- filesystems or Windows.
local uv = vim.uv

local M = {}

M.lock_timeout_ms = 5000 -- generous: on Windows a just-deleted lock can linger while the machine is busy
M.stale_lock_s = 30

function M.dir(repo)
  return repo.commondir .. "/trellis"
end

function M.path(repo)
  return M.dir(repo) .. "/ops.jsonl"
end

--- Time-sortable unique id: 20261117T153012-4f2a.
function M.new_id()
  -- libuv's CSPRNG: math.random is seeded identically in every LuaJIT process.
  local bytes = uv.random(2) or tostring(uv.hrtime()):sub(-2)
  return os.date("!%Y%m%dT%H%M%S") .. "-" .. ("%02x%02x"):format(bytes:byte(1, 2))
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function alive(pid)
  if type(pid) ~= "number" then
    return false
  end
  local ok, res = pcall(uv.kill, pid, 0)
  return ok and res == 0
end

--- Acquire the journal lock; returns a release function or nil + error.
---@return (fun())? release, string? err
function M.lock(repo)
  -- Two Neovims may create the directory at the same moment: that is not an error.
  local ok, merr = require("trellis.util.fs").mkdirp(M.dir(repo))
  if not ok then
    return nil, merr
  end
  local path = M.dir(repo) .. "/ops.lock"
  local deadline = uv.hrtime() + M.lock_timeout_ms * 1e6
  -- The timeout is for one holder that keeps the lock too long, not for the total wait: when
  -- the lock file changes (another append came and went), the clock restarts.
  local seen
  while true do
    local fd = uv.fs_open(path, "wx", 420)
    if fd then
      uv.fs_write(fd, vim.json.encode({ pid = uv.os_getpid(), time = os.time() }))
      uv.fs_close(fd)
      return function()
        -- On Windows a waiter that has the file open makes removal fail: retry until gone.
        for _ = 1, 500 do
          if os.remove(path) or not uv.fs_stat(path) then
            return
          end
          uv.sleep(2)
        end
      end
    end
    local stat = uv.fs_stat(path)
    if stat then
      local id = ("%s:%s:%s"):format(stat.ino, stat.mtime.sec, stat.mtime.nsec)
      if id ~= seen then
        seen = id
        deadline = uv.hrtime() + M.lock_timeout_ms * 1e6
      end
    end
    -- Only read the lock file when it may be stale: reading it while its owner tries to remove
    -- it would block the removal on Windows.
    if stat and os.time() - stat.mtime.sec > M.stale_lock_s then
      local ok, info = pcall(vim.json.decode, read_file(path) or "")
      local holder = ok and type(info) == "table" and info.pid or nil
      if not alive(holder) then
        os.remove(path) -- stale: its owner is gone
      elseif uv.hrtime() > deadline then
        return nil, ("journal is locked by pid %s"):format(holder)
      end
    elseif uv.hrtime() > deadline then
      local ok, info = pcall(vim.json.decode, read_file(path) or "")
      local holder = ok and type(info) == "table" and info.pid or nil
      return nil, ("journal is locked (%s)"):format(holder and ("pid " .. holder) or path)
    end
    -- Jitter, so a waiter is not always polling in step with a holder that re-locks at once.
    -- (math.random is unseeded: two processes would draw the same sequence; use the clock.)
    uv.sleep(2 + math.floor(uv.hrtime() / 1000) % 7)
  end
end

--- Append one operation snapshot.
---@param repo trellis.Repository
---@param op table
---@return boolean ok, string? err
function M.append(repo, op)
  local release, err = M.lock(repo)
  if not release then
    return false, err
  end
  local f, ferr = io.open(M.path(repo), "ab")
  if not f then
    release()
    return false, ferr
  end
  f:write(vim.json.encode(op), "\n")
  f:close()
  release()
  return true
end

--- All operations, oldest first, folded by id. Malformed lines are skipped and counted.
---@param repo trellis.Repository
---@return table[] ops, integer bad_lines
function M.read(repo)
  local text = read_file(M.path(repo)) or ""
  local order, by_id, bad = {}, {}, 0
  for line in text:gmatch("[^\n]+") do
    local ok, op = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(op) == "table" and type(op.id) == "string" then
      if not by_id[op.id] then
        order[#order + 1] = op.id
        by_id[op.id] = op
      else
        -- Later snapshots win field by field (a "pruned" marker only carries the id).
        for k, v in pairs(op) do
          by_id[op.id][k] = v
        end
      end
    else
      bad = bad + 1
    end
  end
  local ops = {}
  for i, id in ipairs(order) do
    ops[i] = by_id[id]
  end
  return ops, bad
end

---@return table?
function M.get(repo, id)
  for _, op in ipairs((M.read(repo))) do
    if op.id == id then
      return op
    end
  end
end

return M
