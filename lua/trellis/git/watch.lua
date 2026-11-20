--- Repository change detection.
---
--- Watches the git dir (HEAD, packed-refs, …) and the refs directories with libuv fs events;
--- where recursive watching is unavailable (Linux inotify) every refs subdirectory gets its own
--- watcher and new directories are picked up on the next event. If fs events cannot be started
--- at all, a 2 s fs_poll on the key files takes over. Events are debounced (200 ms).
local debounce = require("trellis.util.debounce")

local M = {}

--- File names whose changes never affect history views.
local IGNORE = {
  index = true,
  ["index.lock"] = true,
  COMMIT_EDITMSG = true,
  ["gc.log"] = true,
  FETCH_HEAD = true,
}

local function ignored(name)
  if not name then
    return false
  end
  name = name:gsub("\\", "/")
  local base = name:match("[^/]+$") or name
  return IGNORE[base]
    or base:match("%.lock$") ~= nil
    or name:match("^objects/") ~= nil
    or name:match("^trellis/") ~= nil
end

local function dirs_under(root)
  local out = { root }
  local i = 1
  while i <= #out do
    local handle = vim.uv.fs_scandir(out[i])
    while handle do
      local name, typ = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if typ == "directory" then
        out[#out + 1] = out[i] .. "/" .. name
      end
    end
    i = i + 1
  end
  return out
end

---@class trellis.Watcher
---@field close fun()
---@field mode "events"|"poll"
---@field paths string[]

--- Start watching `repo`; `on_change()` runs on the main loop after changes settle.
---@param repo trellis.Repository
---@param on_change fun()
---@param opts? { debounce_ms?: integer, poll_ms?: integer, force_poll?: boolean } force_poll: skip fs events (tests, network filesystems)
---@return trellis.Watcher
function M.watch(repo, on_change, opts)
  opts = opts or {}
  local uv = vim.uv
  local handles = {}
  local closed = false
  local fire = debounce(opts.debounce_ms or 200, function()
    if not closed then
      on_change()
    end
  end)
  local watched = {}
  local watcher = { mode = "events", paths = {} }

  local function add(path, recursive)
    if watched[path] then
      return true
    end
    local h = uv.new_fs_event()
    if not h then
      return false
    end
    local ok = h:start(path, { recursive = recursive }, function(err, filename)
      if err or closed then
        return
      end
      if not ignored(filename) then
        fire()
      end
      if not recursive then
        -- New ref directories (refs/heads/feature/…) need their own watcher.
        vim.schedule(function()
          if not closed then
            watcher.rescan()
          end
        end)
      end
    end)
    if not ok then
      h:close()
      return false
    end
    watched[path] = true
    handles[#handles + 1] = h
    watcher.paths[#watcher.paths + 1] = path
    return true
  end

  local refs_dir = repo.commondir .. "/refs"
  local recursive = vim.fn.has("linux") == 0 -- inotify has no recursive watches

  function watcher.rescan()
    if recursive then
      return
    end
    for _, d in ipairs(dirs_under(refs_dir)) do
      add(d, false)
    end
  end

  local ok = false
  if not opts.force_poll then
    ok = add(repo.gitdir, false)
    if repo.commondir ~= repo.gitdir then
      ok = add(repo.commondir, false) and ok
    end
    if recursive then
      ok = add(refs_dir, true) and ok
    else
      watcher.rescan()
    end
  end

  if not ok then
    for _, h in ipairs(handles) do
      h:close()
    end
    handles = {}
    watcher.mode = "poll"
    watcher.paths = {}
    for _, p in ipairs({
      repo.gitdir .. "/HEAD",
      repo.commondir .. "/packed-refs",
      repo.commondir .. "/logs/HEAD",
      refs_dir,
    }) do
      local h = uv.new_fs_poll()
      if h then
        h:start(p, opts.poll_ms or 2000, function()
          if not closed then
            fire()
          end
        end)
        handles[#handles + 1] = h
        watcher.paths[#watcher.paths + 1] = p
      end
    end
  end

  function watcher.close()
    if closed then
      return
    end
    closed = true
    fire:close()
    for _, h in ipairs(handles) do
      if not h:is_closing() then
        h:stop()
        h:close()
      end
    end
  end

  return watcher
end

M._ignored = ignored

return M
