--- Spawning git: fixed global options and environment, never-run enforcement, command log.
--- Every git command trellis runs goes through `build()` (docs/git-commands.md).
local M = {}

--- Recent git invocations for `:Trellis log` (oldest first, capped).
---@class trellis.GitLogEntry
---@field argv string[]
---@field cwd string?
---@field kind "R"|"W"|"O"
---@field op_id string?
---@field started integer hrtime ns
---@field duration_ms number?
---@field code integer?
---@field stderr string?
---@type trellis.GitLogEntry[]
M.history = {}
M.max_history = 1000

--- Subcommands trellis must never run (Constitution I, docs/git-commands.md → Never run).
M.forbidden = {
  push = true,
  gc = true,
  prune = true,
  ["filter-branch"] = true,
  clean = true,
}

--- Index and name of the git subcommand in `args` (skipping global options).
---@param args string[]
---@return string? name, integer? index
function M.subcommand(args)
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "-c" or a == "-C" or a == "--git-dir" or a == "--work-tree" then
      i = i + 2
    elseif a:sub(1, 1) == "-" then
      i = i + 1
    else
      return a, i
    end
  end
end

--- Raise if `args` is on the never-run list.
---@param args string[]
---@param opts? { op_id?: string }
function M.check_allowed(args, opts)
  local sub, i = M.subcommand(args)
  if not sub then
    error("trellis: git invocation without a subcommand", 3)
  end
  local function refuse(what)
    error(("trellis: refusing to run `git %s` (never-run list, Constitution I)"):format(what), 3)
  end
  if M.forbidden[sub] then
    refuse(sub)
  end
  local next_arg = args[i + 1]
  if sub == "reflog" and (next_arg == "expire" or next_arg == "delete") then
    refuse("reflog " .. next_arg)
  end
  if sub == "stash" and (next_arg == "drop" or next_arg == "clear") then
    refuse("stash " .. next_arg)
  end
  if sub == "update-ref" then
    for k = i + 1, #args do
      if args[k] == "-d" then
        local ref = args[k + 1] or ""
        if not vim.startswith(ref, "refs/trellis/") and not (opts and opts.op_id) then
          refuse("update-ref -d " .. ref .. " outside a journaled operation")
        end
      end
    end
  end
end

---@class trellis.RunOpts
---@field kind? "R"|"W"|"O"  read-only (default), writes refs/index/worktree, writes objects only
---@field env? table<string, string>
---@field stdin? string
---@field timeout? integer ms; default config git.timeout_ms
---@field ok_codes? integer[] exit codes that are not errors (besides 0)
---@field op_id? string journaled operation this command belongs to
---@field cwd? string used when no root is given
---@field schedule? boolean run the callback on the main loop (default true)
---@field text? boolean decode output as text (default true); false keeps raw bytes

--- Full argv and environment overrides for a git command.
---@param root string? repository root (`git -C <root>`); nil for repo-less commands
---@param args string[]
---@param opts? trellis.RunOpts
---@return string[] argv, table<string, string> env
function M.build(root, args, opts)
  opts = opts or {}
  M.check_allowed(args, opts)
  local cmd = require("trellis.config").get().git.cmd
  local argv = { cmd }
  if root then
    argv[#argv + 1] = "-C"
    argv[#argv + 1] = root
  end
  vim.list_extend(argv, { "-c", "core.quotepath=off", "-c", "color.ui=false", "--no-pager" })
  vim.list_extend(argv, args)
  local env = { LC_ALL = "C", GIT_TERMINAL_PROMPT = "0", GIT_PAGER = "cat" }
  if (opts.kind or "R") == "R" then
    env.GIT_OPTIONAL_LOCKS = "0"
  else
    -- Writes never wait for an editor (cherry-pick --continue, revert, …): git runs these
    -- through sh, where ":" is a no-op, so the default message is kept. Callers that supply
    -- messages override them (rebase helpers).
    env.GIT_EDITOR = ":"
    env.GIT_SEQUENCE_EDITOR = ":"
  end
  for k, v in pairs(opts.env or {}) do
    env[k] = v
  end
  return argv, env
end

--- Append an entry to the command log.
---@param entry trellis.GitLogEntry
function M.record(entry)
  local h = M.history
  h[#h + 1] = entry
  if #h > M.max_history then
    table.remove(h, 1)
  end
end

local function first_line(s)
  s = s and vim.trim(s) or ""
  return s:match("^[^\n]*")
end

---@class trellis.RunResult
---@field code integer
---@field signal integer
---@field stdout string
---@field stderr string

--- Run a git command asynchronously. `cb(err, result)`: `err` is nil on success or
--- "git failed: <first stderr line>"; the result is always passed when the process ran.
---@param root string?
---@param args string[]
---@param opts? trellis.RunOpts
---@param cb? fun(err: string?, res: trellis.RunResult?)
---@return vim.SystemObj?
function M.run(root, args, opts, cb)
  opts = opts or {}
  local argv, env = M.build(root, args, opts)
  local entry = {
    argv = argv,
    cwd = root or opts.cwd,
    kind = opts.kind or "R",
    op_id = opts.op_id,
    started = vim.uv.hrtime(),
  }
  M.record(entry)

  local function deliver(err, res)
    if not cb then
      return
    end
    if opts.schedule == false then
      cb(err, res)
    else
      vim.schedule(function()
        cb(err, res)
      end)
    end
  end

  local ok, obj = pcall(vim.system, argv, {
    env = env,
    text = opts.text ~= false, -- false: raw bytes (file contents keep CRLF)
    stdin = opts.stdin or false,
    cwd = opts.cwd,
    timeout = opts.timeout or require("trellis.config").get().git.timeout_ms,
  }, function(res)
    entry.duration_ms = (vim.uv.hrtime() - entry.started) / 1e6
    entry.code = res.code
    entry.stderr = res.stderr
    local err
    if res.code ~= 0 and not vim.tbl_contains(opts.ok_codes or {}, res.code) then
      local line = first_line(res.stderr)
      err = "git failed: " .. (line ~= "" and line or ("exit code " .. res.code))
    end
    deliver(err, res)
  end)
  if not ok then
    entry.code = -1
    entry.stderr = tostring(obj)
    deliver("git could not be started: " .. tostring(obj), nil)
    return nil
  end
  return obj
end

--- Synchronous variant. Only for :checkhealth, tests and helpers — never on a UI path
--- (Constitution III: the main loop is never blocked by git I/O).
---@param root string?
---@param args string[]
---@param opts? trellis.RunOpts
---@return string? err, trellis.RunResult? res
function M.run_sync(root, args, opts)
  local done, err, res = false, nil, nil
  M.run(root, args, vim.tbl_extend("force", opts or {}, { schedule = false }), function(e, r)
    err, res, done = e, r, true
  end)
  vim.wait(opts and opts.timeout or 60000, function()
    return done
  end, 5)
  if not done then
    return "git timed out", nil
  end
  return err, res
end

return M
