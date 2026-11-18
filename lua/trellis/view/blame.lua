--- Blame column with time travel (US3, FR-030/031, research R8).
---
--- `:Trellis blame` opens a scroll- and cursor-bound column left of the file window, filled by
--- a streamed `git blame --incremental` (working copies blame the buffer text through
--- `--contents -`, so unsaved edits read "Not committed yet"). In the column, `[` re-blames the
--- file at the parent of the commit that last changed the cursor line, with the cursor on the
--- corresponding line; `]` goes forward again. The trail is shown in the file window's winbar.
local argv = require("trellis.git.argv")
local base = require("trellis.view.base")
local blame_parse = require("trellis.git.parse.blame")
local config = require("trellis.config")
local debounce = require("trellis.util.debounce")
local diff_parse = require("trellis.git.parse.diff")
local hl = require("trellis.highlights")
local linemap = require("trellis.linemap")
local runner = require("trellis.git.runner")
local stream = require("trellis.git.stream")
local time = require("trellis.util.time")

local M = {}

M.ns = vim.api.nvim_create_namespace("trellis.blame")
M.UNCOMMITTED = blame_parse.UNCOMMITTED
M.details = { "full", "summary", "author", "sha" }

---@class trellis.TravelFrame
---@field sha string?   nil = the working copy buffer
---@field path string
---@field line integer

---@class trellis.BlameSession
---@field repo trellis.Repository
---@field file_win integer
---@field blame_win integer
---@field blame_buf integer
---@field origin_buf integer  buffer the session started on
---@field origin_sha string?  sha when the session started on a trellis:// buffer
---@field frames trellis.TravelFrame[]
---@field pos integer
---@field lines table<integer, { sha: string, orig: integer, entry: trellis.BlameEntry }>
---@field commits table<string, trellis.BlameCommit>
---@field detail integer
---@field generation integer
---@field stream trellis.Stream?
---@field loaded boolean

---@type table<integer, trellis.BlameSession> by file window
local sessions = {}
M.sessions = sessions

local function session_of(win)
  win = win or vim.api.nvim_get_current_win()
  if sessions[win] then
    return sessions[win]
  end
  for _, s in pairs(sessions) do
    if s.blame_win == win then
      return s
    end
  end
end
M.session_of = session_of

-- Rendering ---------------------------------------------------------------------------------

local function trunc(s, w)
  if vim.fn.strdisplaywidth(s) <= w then
    return s .. (" "):rep(w - vim.fn.strdisplaywidth(s))
  end
  return vim.fn.strcharpart(s, 0, w - 1) .. "…"
end

local function line_text(s, info, width)
  if not info then
    return ""
  end
  if info.sha == M.UNCOMMITTED then
    return trunc("Not committed yet", width)
  end
  local c = s.commits[info.sha] or {}
  local sha7 = info.sha:sub(1, 7)
  local t = c["author-time"] or 0
  local detail = M.details[s.detail]
  local text
  if detail == "full" then
    text = ("%s %s %s"):format(sha7, os.date("%Y-%m-%d", t), c.author or "")
  elseif detail == "summary" then
    text = sha7 .. " " .. (c.summary or "")
  elseif detail == "author" then
    text = (c.author or "") .. ", " .. time.relative(t)
  else
    text = sha7
  end
  if c.boundary then
    text = "^" .. text
  end
  return trunc(text:find("%c") and vim.fn.strtrans(text) or text, width)
end

local function render(s)
  if not vim.api.nvim_buf_is_valid(s.blame_buf) then
    return
  end
  local cfg = config.get().blame
  local n = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(s.file_win))
  local width = cfg.width - 1
  local lines = {}
  for i = 1, n do
    lines[i] = line_text(s, s.lines[i], width)
  end
  vim.bo[s.blame_buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.blame_buf, 0, -1, false, lines)
  vim.bo[s.blame_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(s.blame_buf, M.ns, 0, -1)
  if not cfg.heat then
    return
  end
  local lo, hi
  for _, c in pairs(s.commits) do
    local t = c["author-time"]
    if t and c.sha ~= M.UNCOMMITTED then
      lo = math.min(lo or t, t)
      hi = math.max(hi or t, t)
    end
  end
  for i = 1, n do
    local info = s.lines[i]
    if info then
      local group
      if info.sha == M.UNCOMMITTED then
        group = "TrellisBlameUncommitted"
      else
        local t = (s.commits[info.sha] or {})["author-time"] or lo or 0
        local age = (hi and hi > lo) and (hi - t) / (hi - lo) or 0
        group = "TrellisBlameAge" .. math.min(4, math.floor(age * 5))
      end
      vim.api.nvim_buf_set_extmark(s.blame_buf, M.ns, i - 1, 0, {
        end_row = i - 1,
        end_col = #lines[i],
        hl_group = group,
      })
    end
  end
end

local render_later = function(s)
  if s.render_pending then
    return
  end
  s.render_pending = true
  vim.defer_fn(function()
    s.render_pending = false
    render(s)
  end, 30)
end

local function frame_label(s, i)
  local f = s.frames[i]
  if not f.sha then
    return "worktree"
  end
  return f.sha:sub(1, 7)
end

local function update_winbar(s)
  if not vim.api.nvim_win_is_valid(s.file_win) then
    return
  end
  local parts = {}
  for i = 1, #s.frames do
    local label = frame_label(s, i)
    parts[#parts + 1] = i == s.pos and ("%#TrellisHead#" .. label .. "%*") or label
  end
  vim.wo[s.file_win].winbar = " blame: " .. table.concat(parts, " → ")
end

-- Running blame -------------------------------------------------------------------------------

local function ignore_revs_file(repo)
  local opt = config.get().blame.ignore_revs_file
  if opt == "auto" then
    local p = repo.root .. "/.git-blame-ignore-revs"
    return vim.uv.fs_stat(p) and p or nil
  end
  return type(opt) == "string" and opt or nil
end

--- (Re)run blame for the current frame.
local function run_blame(s)
  if s.stream then
    s.stream.kill()
  end
  s.generation = s.generation + 1
  local gen = s.generation
  s.lines, s.commits, s.loaded = {}, {}, false
  local frame = s.frames[s.pos]
  local cfg = config.get().blame
  local contents
  if not frame.sha then
    local buf = vim.api.nvim_win_get_buf(s.file_win)
    local nl = vim.bo[buf].fileformat == "dos" and "\r\n" or "\n"
    contents = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), nl) .. nl
  end
  local inv = argv.G30({
    rev = frame.sha,
    path = frame.path,
    ignore_whitespace = cfg.ignore_whitespace,
    detect_moves = cfg.detect_moves,
    ignore_revs_file = ignore_revs_file(s.repo),
    contents = contents,
  })
  local parser = blame_parse.new_parser()
  s.commits = parser.commits
  local function apply(entries)
    if gen ~= s.generation then
      return
    end
    for _, e in ipairs(entries) do
      for k = 0, e.num_lines - 1 do
        s.lines[e.final_line + k] = { sha = e.sha, orig = e.orig_line + k, entry = e }
      end
    end
    render_later(s)
  end
  render(s)
  s.stream = stream.start(s.repo.root, inv.args, {
    kind = inv.kind,
    sep = "\n",
    stdin = inv.stdin,
    on_records = function(lines)
      apply(parser.push(table.concat(lines, "\n") .. "\n"))
    end,
    on_exit = function(code, stderr)
      apply(parser.finish())
      if gen ~= s.generation then
        return
      end
      s.loaded = true
      if code ~= 0 then
        vim.notify("trellis: blame failed: " .. vim.trim(stderr or ""), vim.log.levels.ERROR)
      end
      render(s)
    end,
  })
end

-- Windows -------------------------------------------------------------------------------------

local function bind(s)
  for _, w in ipairs({ s.file_win, s.blame_win }) do
    if vim.api.nvim_win_is_valid(w) then
      vim.wo[w].scrollbind = true
      vim.wo[w].cursorbind = true
    end
  end
  vim.api.nvim_win_call(s.file_win, function()
    vim.cmd("syncbind")
  end)
end

local function set_cursor(win, line)
  if vim.api.nvim_win_is_valid(win) then
    local n = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
    pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, math.min(line, n)), 0 })
  end
end

--- Show frame `s.pos` in the file window and blame it.
local function show_frame(s, cb)
  local f = s.frames[s.pos]
  s.loaded = false
  local function after()
    run_blame(s)
    bind(s)
    set_cursor(s.file_win, f.line)
    set_cursor(s.blame_win, f.line)
    update_winbar(s)
    if cb then
      cb()
    end
  end
  if not f.sha then
    vim.api.nvim_win_set_buf(s.file_win, s.origin_buf)
    return after()
  end
  require("trellis.view.filerev").open(s.repo, f.sha, f.path, {
    window = s.file_win,
    cursor = { f.line, 0 },
    on_load = function()
      after()
    end,
  })
end

--- Close the blame column of a session.
function M.close(s)
  sessions[s.file_win] = nil
  if s.stream then
    s.stream.kill()
  end
  if s.watch then
    s.watch:close()
    pcall(vim.api.nvim_del_augroup_by_id, s.augroup)
  end
  if vim.api.nvim_win_is_valid(s.file_win) then
    vim.wo[s.file_win].scrollbind = false
    vim.wo[s.file_win].cursorbind = false
    vim.wo[s.file_win].winbar = ""
  end
  if vim.api.nvim_win_is_valid(s.blame_win) then
    pcall(vim.api.nvim_win_close, s.blame_win, true)
  end
  if vim.api.nvim_buf_is_valid(s.blame_buf) then
    pcall(vim.api.nvim_buf_delete, s.blame_buf, { force = true })
  end
end

-- Time travel ---------------------------------------------------------------------------------

local function hunks_between(repo, from, to, paths, cb)
  local inv = argv.G31(from, to, paths)
  runner.run(repo.root, inv.args, { kind = inv.kind }, function(err, res)
    local hunks = {}
    if not err then
      for _, f in ipairs(diff_parse.parse(res.stdout)) do
        vim.list_extend(hunks, f.hunks)
      end
    end
    cb(hunks)
  end)
end

--- `[`: go to the parent of the commit that last changed the cursor line.
function M.step_back(s)
  local lnum = vim.api.nvim_win_get_cursor(s.blame_win)[1]
  local info = s.lines[lnum]
  if not info then
    return vim.notify("trellis: blame is still loading")
  end
  local frame = s.frames[s.pos]
  local function push(sha, path, line)
    frame.line = lnum
    for i = #s.frames, s.pos + 1, -1 do
      s.frames[i] = nil
    end
    s.frames[#s.frames + 1] = { sha = sha, path = path, line = line }
    s.pos = #s.frames
    show_frame(s)
  end
  local prev = info.entry.previous
  if info.sha == M.UNCOMMITTED then
    -- Not committed yet: step to HEAD, mapping the line through the working-copy diff.
    local path = prev and prev.path or frame.path
    hunks_between(s.repo, "HEAD", nil, { path }, function(hunks)
      push(prev and prev.sha or "HEAD", path, linemap.map_line(hunks, lnum, "backward"))
    end)
    return
  end
  if not prev then
    local c = s.commits[info.sha] or {}
    return vim.notify(
      ("trellis: this line was introduced in %s %s"):format(info.sha:sub(1, 7), c.summary or "")
    )
  end
  -- Line `info.orig` of the commit's version → the parent's version of the file.
  local paths = prev.path == info.entry.filename and { prev.path }
    or { prev.path, info.entry.filename }
  hunks_between(s.repo, prev.sha, info.sha, paths, function(hunks)
    push(prev.sha, prev.path, linemap.map_line(hunks, info.orig, "backward"))
  end)
end

--- `]`: forward again (frames are newest first: frame 1 is where the session started).
function M.step_forward(s)
  if s.pos <= 1 then
    return vim.notify("trellis: already at the newest step")
  end
  s.frames[s.pos].line = vim.api.nvim_win_get_cursor(s.blame_win)[1]
  s.pos = s.pos - 1
  show_frame(s)
end

-- Opening -------------------------------------------------------------------------------------

local function handlers(s)
  local function info()
    return s.lines[vim.api.nvim_win_get_cursor(s.blame_win)[1]]
  end
  return {
    step_back = function()
      M.step_back(s)
    end,
    step_forward = function()
      M.step_forward(s)
    end,
    open_commit = function()
      local i = info()
      if i and i.sha ~= M.UNCOMMITTED then
        vim.api.nvim_set_current_win(s.file_win)
        require("trellis.view.commit").open(s.repo, i.sha)
      end
    end,
    diff = function()
      local i = info()
      if not i or i.sha == M.UNCOMMITTED then
        return
      end
      local prev = i.entry.previous
      local parent = prev and prev.sha or argv.empty_tree(s.repo.features.sha256)
      vim.api.nvim_set_current_win(s.file_win)
      require("trellis.view.diff").open(s.repo, parent, i.sha, {
        path = i.entry.filename,
        old_path = prev and prev.path or nil,
      })
    end,
    cycle_detail = function()
      s.detail = s.detail % #M.details + 1
      render(s)
    end,
    close = function()
      M.close(s)
    end,
    help = nil,
  }
end

--- What the window shows: { repo_dir, sha?, path?, buf }.
local function target(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local vars = vim.b[buf].trellis
  if type(vars) == "table" and vars.view == "filerev" and vars.sha then
    return { dir = vars.repo, sha = vars.sha, path = vars.path, buf = buf }
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or vim.bo[buf].buftype ~= "" then
    return nil
  end
  local file = vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
  return { dir = vim.fs.dirname(file), file = file, buf = buf }
end

--- Toggle the blame column for the current window.
---@param opts? { on_open?: fun(s: trellis.BlameSession) }
function M.toggle(opts)
  opts = opts or {}
  local existing = session_of()
  if existing then
    return M.close(existing)
  end
  local file_win = vim.api.nvim_get_current_win()
  local t = target(file_win)
  if not t then
    return vim.notify("trellis: blame needs a file buffer", vim.log.levels.WARN)
  end
  require("trellis.git.repo").discover(t.dir, function(err, repo)
    if err then
      return vim.notify("trellis: " .. err, vim.log.levels.ERROR)
    end
    local path = t.path
    if not path then
      if t.file:sub(1, #repo.root + 1) ~= repo.root .. "/" then
        return vim.notify("trellis: file is outside the repository", vim.log.levels.ERROR)
      end
      path = t.file:sub(#repo.root + 2)
    end
    hl.setup()
    local cfg = config.get().blame
    local blame_buf = base.create_buf(
      { name = "trellis://blame/" .. path, kind = "blame", filetype = "trellisblame" },
      repo
    )
    vim.api.nvim_set_current_win(file_win)
    vim.cmd("leftabove vsplit")
    local blame_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(blame_win, blame_buf)
    vim.api.nvim_win_set_width(blame_win, cfg.width)
    local wo = vim.wo[blame_win]
    wo.winfixwidth = true
    wo.wrap = false
    wo.number = false
    wo.relativenumber = false
    wo.list = false
    wo.signcolumn = "no"
    wo.foldcolumn = "0"
    wo.foldenable = false
    wo.spell = false
    wo.cursorline = true
    wo.winbar = " "
    local line = vim.api.nvim_win_get_cursor(file_win)[1]
    ---@type trellis.BlameSession
    local s = {
      repo = repo,
      file_win = file_win,
      blame_win = blame_win,
      blame_buf = blame_buf,
      origin_buf = t.buf,
      frames = { { sha = t.sha, path = path, line = line } },
      pos = 1,
      lines = {},
      commits = {},
      detail = 1,
      generation = 0,
    }
    sessions[file_win] = s
    base.register({
      kind = "blame",
      bufnr = blame_buf,
      repo = repo,
      state = s,
      dispose = function()
        if sessions[file_win] == s then
          M.close(s)
        end
      end,
    })
    base.apply_keymaps(blame_buf, "blame", handlers(s))
    -- Working copies: re-blame on edits (unsaved text is blamed through --contents).
    if not t.sha then
      s.augroup = vim.api.nvim_create_augroup("trellis.blame." .. file_win, { clear = true })
      s.watch = debounce(400, function()
        if sessions[file_win] == s and s.frames[s.pos].sha == nil then
          run_blame(s)
        end
      end)
      vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
        group = s.augroup,
        buffer = t.buf,
        callback = function()
          s.watch()
        end,
      })
    end
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern = { tostring(file_win), tostring(blame_win) },
      once = true,
      callback = function()
        vim.schedule(function()
          if sessions[file_win] == s then
            M.close(s)
          end
        end)
      end,
    })
    -- Fill the column first (run_blame renders one placeholder line per file line): on an empty
    -- buffer the cursor would be clamped to line 1 and cursorbind would drag the file there.
    run_blame(s)
    bind(s)
    set_cursor(file_win, line)
    set_cursor(blame_win, line)
    update_winbar(s)
    if opts.on_open then
      opts.on_open(s)
    end
  end)
end

return M
