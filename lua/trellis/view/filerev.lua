--- File at a revision: `trellis://<sha>/<path>` and `trellis://:<n>/<path>` (FR-021/022/024).
---
--- Content comes from `git cat-file --filters` (what checkout would write: eol and smudge
--- filters applied). The buffer is read-only with the file's filetype; `:w` is refused with a
--- hint to `:Trellis restore`. Files above `views.filerev.max_size` or containing NUL bytes
--- show a metadata page instead, with `go` to open anyway. `]r` / `[r` step through the
--- file's history (following renames) and keep the cursor on the corresponding line.
local argv = require("trellis.git.argv")
local async = require("trellis.util.async")
local base = require("trellis.view.base")
local config = require("trellis.config")
local diff = require("trellis.git.parse.diff")
local filelog = require("trellis.git.parse.filelog")
local linemap = require("trellis.linemap")
local runner = require("trellis.git.runner")
local uri = require("trellis.uri")

local M = {}

local function run(repo, inv, extra)
  return async.await(function(cb)
    local opts = { kind = inv.kind, ok_codes = inv.ok_codes, stdin = inv.stdin }
    for k, v in pairs(extra or {}) do
      opts[k] = v
    end
    runner.run(repo.root, inv.args, opts, cb)
  end)
end

local function notify_err(msg)
  vim.notify("trellis: " .. msg, vim.log.levels.ERROR)
end

--- Split file content into buffer lines and the options that reproduce it byte for byte.
---@param content string
---@return string[] lines, { fileformat: string, eol: boolean }
function M.split_content(content)
  local eol = content:sub(-1) == "\n"
  local body = eol and content:sub(1, -2) or content
  local ff = "unix"
  if body:find("\r\n", 1, true) or content:sub(-2) == "\r\n" then
    -- Use dos only if every line ending is CRLF; mixed endings keep the \r in the text.
    local lf = select(2, content:gsub("\n", ""))
    local crlf = select(2, content:gsub("\r\n", ""))
    if lf == crlf then
      ff = "dos"
      body = body:gsub("\r$", "")
      body = body:gsub("\r\n", "\n")
    end
  end
  return vim.split(body, "\n", { plain = true }), { fileformat = ff, eol = eol }
end

--- Rebuild the bytes a buffer represents (tests, restore).
function M.buffer_content(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local nl = vim.bo[buf].fileformat == "dos" and "\r\n" or "\n"
  return table.concat(lines, nl) .. (vim.bo[buf].eol and nl or "")
end

local function set_content(buf, lines, fopts, filetype)
  local bo = vim.bo[buf]
  bo.readonly = false
  bo.modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  bo.fileformat = fopts.fileformat
  bo.eol = fopts.eol
  bo.fixeol = false
  bo.modified = false
  bo.modifiable = false
  -- Not 'readonly': :w must reach BufWriteCmd, which refuses with a :Trellis restore hint.
  bo.buftype = "acwrite"
  bo.swapfile = false
  bo.bufhidden = config.get().views.filerev.bufhidden or "hide"
  if filetype and filetype ~= "" and bo.filetype ~= filetype then
    bo.filetype = filetype
  end
end

local function guard_page(buf, vars, size, reason)
  local lines = {
    ("%s at %s"):format(vars.path, vars.stage and (":" .. vars.stage) or vars.sha:sub(1, 7)),
    "",
    reason == "binary" and ("binary file, %d bytes"):format(size)
      or ("large file, %d bytes (views.filerev.max_size = %d)"):format(
        size,
        config.get().views.filerev.max_size
      ),
    "",
    "Press go to open it anyway.",
  }
  set_content(buf, lines, { fileformat = "unix", eol = true }, "")
  vim.b[buf].trellis = vim.tbl_extend("force", vars, { guard = reason, size = size })
end

--- Load (or reload) the content of a filerev buffer whose `b:trellis` is set.
---@param buf integer
---@param repo trellis.Repository
---@param opts? { force?: boolean, cursor?: integer[] }
---@param cb? fun(err: string?)
function M.load(buf, repo, opts, cb)
  opts = opts or {}
  local vars = vim.b[buf].trellis
  local rev = vars.stage and (":" .. vars.stage) or vars.sha
  async.run(function()
    local err, res = run(repo, argv.G21(rev, vars.path))
    if err then
      return ("%s does not exist at %s"):format(vars.path, rev:sub(1, 7))
    end
    local size = tonumber(vim.trim(res.stdout)) or 0
    local max = config.get().views.filerev.max_size
    if size > max and not opts.force then
      return nil, "large", size
    end
    local cerr, cres = run(repo, argv.G22(rev, vars.path), { text = false })
    if cerr then
      return cerr
    end
    return nil, cres.stdout, size
  end, function(err, msg, content, size)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    err = err or msg
    if err then
      notify_err(err)
      return cb and cb(err)
    end
    vars = vim.tbl_extend("force", vim.b[buf].trellis, { guard = false })
    vim.b[buf].trellis = vars
    if content == "large" then
      guard_page(buf, vars, size, "large")
    elseif not opts.force and content:sub(1, 8000):find("\0", 1, true) then
      guard_page(buf, vars, size, "binary")
    else
      local lines, fopts = M.split_content(content)
      local ft = vim.filetype.match({ filename = vars.path, buf = buf }) or ""
      set_content(buf, lines, fopts, ft)
      if opts.cursor then
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
          local l = math.min(opts.cursor[1], vim.api.nvim_buf_line_count(buf))
          pcall(vim.api.nvim_win_set_cursor, win, { l, opts.cursor[2] or 0 })
        end
      end
    end
    vim.b[buf].trellis_loaded = true
    if cb then
      cb(nil)
    end
  end)
end

-- History stepping ----------------------------------------------------------------------------

--- File history (newest first) and the position of the buffer's revision in it.
local function history(repo, sha, path, cb)
  async.run(function()
    local _, eff = run(repo, argv.G25(sha, path))
    local effective = eff and vim.trim(eff.stdout) ~= "" and vim.trim(eff.stdout) or sha
    -- From HEAD when the path still exists there, so ]r can step forward too.
    for _, start in ipairs({ "HEAD", sha }) do
      local err, res = run(repo, argv.G23(path, start))
      if not err then
        local list = filelog.parse(res.stdout)
        for i, e in ipairs(list) do
          if e.sha == effective then
            return nil, list, i
          end
        end
      end
    end
    return "no history for " .. path
  end, function(err, msg, list, idx)
    cb(err or msg, list, idx)
  end)
end

--- Line in the target version that corresponds to `line` in the current one.
local function map_cursor(repo, from_sha, from_path, to_sha, to_path, line, cb)
  local inv =
    argv.G31(from_sha, to_sha, from_path == to_path and { from_path } or { from_path, to_path })
  runner.run(repo.root, inv.args, { kind = inv.kind }, function(err, res)
    if err then
      return cb(line)
    end
    local files = diff.parse(res.stdout)
    local hunks = {}
    for _, f in ipairs(files) do
      vim.list_extend(hunks, f.hunks)
    end
    cb(linemap.map_line(hunks, line))
  end)
end

--- Step `delta` revisions (-1 = newer, +1 = older) through the file's history.
function M.step(buf, repo, delta)
  local vars = vim.b[buf].trellis
  if vars.stage then
    return vim.notify("trellis: index stages have no history")
  end
  local function go(list, idx)
    local target = list[idx + delta]
    if not target then
      return vim.notify(
        "trellis: no " .. (delta < 0 and "newer" or "older") .. " revision of " .. vars.path
      )
    end
    if target.status == "D" then
      target = list[idx + 2 * delta]
      if not target then
        return vim.notify("trellis: the file is deleted after this revision")
      end
    end
    local cursor = vim.api.nvim_win_get_cursor(0)
    map_cursor(repo, vars.sha, vars.path, target.sha, target.path, cursor[1], function(line)
      M.open(repo, target.sha, target.path, {
        window = vim.api.nvim_get_current_win(),
        cursor = { line, cursor[2] },
        history = { list = list, index = idx + delta },
      })
    end)
  end
  local h = vars.history_list and M._histories[vars.history_list]
  if h then
    return go(h, vars.history_index)
  end
  history(repo, vars.sha, vars.path, function(err, list, idx)
    if err then
      return notify_err(err)
    end
    go(list, idx)
  end)
end

M._histories = {}
local history_id = 0

-- Opening -------------------------------------------------------------------------------------

local function handlers(buf, repo)
  return {
    next_rev = function()
      M.step(buf, repo, -1)
    end,
    prev_rev = function()
      M.step(buf, repo, 1)
    end,
    open_worktree = function()
      local vars = vim.b[buf].trellis
      local file = repo.root .. "/" .. vars.path
      if not vim.uv.fs_stat(file) then
        return vim.notify("trellis: " .. vars.path .. " does not exist in the working tree")
      end
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local inv = argv.G31(vars.sha, nil, { vars.path })
      runner.run(repo.root, inv.args, { kind = inv.kind }, function(_, res)
        local hunks = {}
        for _, f in ipairs(diff.parse(res and res.stdout or "")) do
          vim.list_extend(hunks, f.hunks)
        end
        vim.cmd.edit(vim.fn.fnameescape(file))
        pcall(vim.api.nvim_win_set_cursor, 0, { linemap.map_line(hunks, line), 0 })
      end)
    end,
    open_anyway = function()
      if vim.b[buf].trellis.guard then
        M.load(buf, repo, { force = true })
      end
    end,
    close = function()
      if #vim.api.nvim_list_wins() > 1 then
        vim.cmd("close")
      else
        vim.cmd("bdelete")
      end
    end,
  }
end

local function setup_buffer(buf, repo)
  if vim.b[buf].trellis_setup then
    return
  end
  vim.b[buf].trellis_setup = true
  base.apply_keymaps(buf, "filerev", handlers(buf, repo))
end

---@class trellis.FilerevOpenOpts
---@field window? integer        show in this window (default: current)
---@field split? string          "tab"|"vertical"|"horizontal"|"current"
---@field cursor? integer[]
---@field history? { list: trellis.FileLogEntry[], index: integer }
---@field on_load? fun(buf: integer)

--- Open `path` at `rev` (commit-ish, or ":<n>" for an index stage).
---@param repo trellis.Repository
---@param rev string
---@param path string
---@param opts? trellis.FilerevOpenOpts
function M.open(repo, rev, path, opts)
  opts = opts or {}
  local stage = rev:match("^:(%d)$")
  local function with_sha(sha)
    local name = stage and uri.stage(tonumber(stage), path) or uri.file(sha, path)
    local buf = vim.fn.bufnr(name)
    local fresh = buf == -1 or not vim.api.nvim_buf_is_loaded(buf)
    if buf == -1 then
      buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, name)
    end
    local vars = {
      view = "filerev",
      repo = repo.root,
      sha = sha,
      path = path,
      stage = stage and tonumber(stage) or nil,
    }
    if opts.history then
      history_id = history_id + 1
      M._histories[history_id] = opts.history.list
      vars.history_list = history_id
      vars.history_index = opts.history.index
    elseif vim.b[buf].trellis then
      vars.history_list = vim.b[buf].trellis.history_list
      vars.history_index = vim.b[buf].trellis.history_index
    end
    vim.b[buf].trellis = vars
    vim.b[buf].trellis_view = "filerev"
    vim.b[buf].trellis_loading = true
    if opts.split and opts.split ~= "current" then
      base.open(buf, opts.split)
    else
      local win = opts.window or vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
    end
    setup_buffer(buf, repo)
    local done = function()
      if opts.on_load then
        opts.on_load(buf)
      end
    end
    if fresh or not vim.b[buf].trellis_loaded then
      M.load(buf, repo, { cursor = opts.cursor }, done)
    else
      if opts.cursor then
        pcall(vim.api.nvim_win_set_cursor, 0, opts.cursor)
      end
      done()
    end
  end
  if stage then
    return with_sha(nil)
  end
  require("trellis.git.details").resolve(repo, rev, function(err, sha)
    if err then
      return notify_err(err)
    end
    with_sha(sha)
  end)
end

--- BufReadCmd for names typed or restored by the user (`:e trellis://abc1234/src/a.lua`).
---@param ev { buf: integer, match: string }
---@param parsed trellis.Uri
function M.read(ev, parsed)
  local buf = ev.buf
  local vars = vim.b[buf].trellis
  require("trellis.git.repo").discover((vars and vars.repo) or vim.fn.getcwd(), function(err, repo)
    if err then
      return notify_err(err)
    end
    local function go(sha)
      vim.b[buf].trellis = {
        view = "filerev",
        repo = repo.root,
        sha = sha,
        path = parsed.path,
        stage = parsed.stage,
      }
      vim.b[buf].trellis_view = "filerev"
      setup_buffer(buf, repo)
      M.load(buf, repo)
    end
    if parsed.kind == "stage" then
      return go(nil)
    end
    require("trellis.git.details").resolve(repo, parsed.rev, function(rerr, sha)
      if rerr then
        return notify_err(rerr)
      end
      go(sha)
    end)
  end)
end

--- BufWriteCmd: revisions are read-only.
function M.refuse_write(buf)
  local vars = vim.b[buf].trellis or {}
  vim.notify(
    ("trellis: %s at %s is read-only; use :Trellis restore to write this version to the working copy"):format(
      vars.path or "file",
      vars.stage and (":" .. vars.stage) or (vars.sha or "?"):sub(1, 7)
    ),
    vim.log.levels.ERROR
  )
end

return M
