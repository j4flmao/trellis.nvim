--- Commit graph view: a real buffer filled by the loader in chunks, painted by a
--- decoration provider for visible lines only, refreshed by the repo watcher.
---
--- Buffer line `v.top + r` is model row r; `v.top` is 1 while the "uncommitted changes" line
--- is shown above the graph, else 0. Commit rows read
---   <graph> <short sha> [(<decorations>)] <subject>
--- with author and date as right-aligned virtual text, so `/` searches graph, sha, refs and
--- subject. Colors are never stored as extmarks: on_line computes them from the model.
local base = require("trellis.view.base")
local config = require("trellis.config")
local events = require("trellis.events")
local glyphs = require("trellis.graph.glyphs")
local hl = require("trellis.highlights")
local loader_mod = require("trellis.graph.loader")
local query_mod = require("trellis.graph.query")
local refs_mod = require("trellis.git.refs")
local repo_mod = require("trellis.git.repo")
local time = require("trellis.util.time")
local watch = require("trellis.git.watch")

local M = {}

M.ns = vim.api.nvim_create_namespace("trellis.graph")
local SHORT = 7
local instance = 0

---@class trellis.GraphView: trellis.View
---@field repo trellis.Repository
---@field query trellis.GraphQuery
---@field cfg trellis.Config
---@field style string
---@field loader trellis.Loader
---@field provisional trellis.Loader?
---@field shown trellis.Loader?  loader whose rows are in the buffer
---@field appended integer       model rows written to the buffer
---@field restore_sha string?
---@field grafted table<string, true>
---@field mark string?           marked sha for compare
---@field winbar_pending boolean
---@field watcher trellis.Watcher?
---@field ref_signature string
---@field message string?        replaces the buffer content (empty repo, errors)
---@field opened_at integer

---@type table<integer, trellis.GraphView>
local views = {}
M.views = views

-- Text building ---------------------------------------------------------------------------

local function sanitize(s)
  if s:find("%c") then
    return vim.fn.strtrans(s)
  end
  return s
end

--- Decoration parts for a commit: { text, group }[] in display order.
---@param v trellis.GraphView
---@param sha string
local function deco_parts(v, sha)
  local map = v.repo.refs
  local parts = {}
  if map then
    local opts =
      { show_backups = v.cfg.graph.show_backups, show_stashes = v.cfg.graph.show_stashes }
    for _, l in ipairs(refs_mod.labels(map, sha, opts)) do
      parts[#parts + 1] = { l.text, hl.ref_groups[l.kind] }
    end
  end
  if v.grafted[sha] then
    parts[#parts + 1] = { "^grafted", "TrellisGrafted" }
  end
  local max = v.cfg.graph.max_decorations
  if #parts > max then
    local extra = #parts - max
    for i = #parts, max + 1, -1 do
      parts[i] = nil
    end
    parts[#parts + 1] = { "+" .. extra, "TrellisBranchRemote" }
  end
  return parts
end

local function deco_text(parts)
  if #parts == 0 then
    return ""
  end
  local texts = {}
  for i, p in ipairs(parts) do
    texts[i] = p[1]
  end
  return "(" .. table.concat(texts, " ") .. ")"
end

--- Buffer line for model row r.
local function line_for(v, m, r)
  local graph = m.rows_text[r]
  if m.rows_kind[r] ~= 1 then
    return graph
  end
  local idx = m.rows_commit[r]
  local sha = m.sha[idx]
  local deco = deco_text(deco_parts(v, sha))
  local parts = { graph, " ", sha:sub(1, SHORT) }
  if deco ~= "" then
    parts[#parts + 1] = " "
    parts[#parts + 1] = deco
  end
  parts[#parts + 1] = " "
  parts[#parts + 1] = sanitize(m.subject[idx])
  return table.concat(parts)
end

-- Buffer filling -----------------------------------------------------------------------------

local function set_lines(v, first, last, lines)
  local buf = v.bufnr
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, first, last, false, lines)
  vim.bo[buf].modifiable = false
end

local update_winbar

local function cursor_to_row(v, r)
  for _, win in ipairs(vim.fn.win_findbuf(v.bufnr)) do
    pcall(vim.api.nvim_win_set_cursor, win, { r + (v.top or 0), 0 })
  end
end

--- Write pending model rows to the buffer, `page_size` per main-loop tick.
local function flush(v)
  v.flush_scheduled = false
  local l = v.shown
  if not l or not vim.api.nvim_buf_is_valid(v.bufnr) then
    return
  end
  local m = l.model
  local from = v.appended + 1
  local to = math.min(m.loaded, v.appended + v.cfg.perf.page_size)
  if to < from then
    return
  end
  -- At most page_size lines, and stop early when the 4 ms budget is spent (at least 200 lines,
  -- so the first screen fills in one go).
  local lines = {}
  local deadline = vim.uv.hrtime() + 4e6
  for r = from, to do
    lines[#lines + 1] = line_for(v, m, r)
    if #lines >= 200 and #lines % 50 == 0 and vim.uv.hrtime() > deadline then
      to = r
      break
    end
  end
  local top = v.top or 0
  if v.appended == 0 then
    set_lines(v, top, -1, lines)
  else
    set_lines(v, top + v.appended, top + v.appended, lines)
  end
  v.appended = to
  if v.restore_sha then
    local idx = m.index[v.restore_sha]
    if idx and m.row_of_commit[idx] and m.row_of_commit[idx] <= to then
      cursor_to_row(v, m.row_of_commit[idx])
      v.restore_sha = nil
    end
  end
  if not v.first_screen_ms then
    v.first_screen_ms = (vim.uv.hrtime() - v.opened_at) / 1e6
  end
  events.emit("TrellisGraphLoaded", { bufnr = v.bufnr, rows = to, complete = m.complete })
  update_winbar(v)
  if to < m.loaded then
    v.flush_scheduled = true
    -- A timer, not vim.schedule: queued scheduled callbacks run back to back, a timer lets
    -- input and redraws in between.
    vim.defer_fn(function()
      flush(v)
    end, 0)
  elseif v.after_flush then
    local cb = v.after_flush
    v.after_flush = nil
    cb()
  end
end

local function schedule_flush(v)
  if not v.flush_scheduled then
    v.flush_scheduled = true
    vim.defer_fn(function()
      flush(v)
    end, 0)
  end
end

local function show_message(v, text)
  v.message = text
  v.appended = 0
  v.top, v.uncommitted = 0, nil
  set_lines(v, 0, -1, { text })
  update_winbar(v)
end

-- Winbar -------------------------------------------------------------------------------------

local function esc(s)
  return (s:gsub("%%", "%%%%"))
end

local STATUS_TEXT = {
  loading = "loading…",
  paused = "",
  complete = "",
  cancelled = "history truncated: cancelled",
  error = "history truncated: git error",
  provisional_stopped = "provisional view (waiting for topological order)",
}

update_winbar = function(v)
  if v.winbar_pending then
    return
  end
  v.winbar_pending = true
  vim.defer_fn(function()
    v.winbar_pending = false
    if not vim.api.nvim_buf_is_valid(v.bufnr) then
      return
    end
    local parts = { " " .. esc(vim.fs.basename(v.repo.root)) }
    for _, chip in ipairs(query_mod.describe(v.query)) do
      parts[#parts + 1] = "%#TrellisFilter#[" .. esc(chip) .. "]%*"
    end
    local l = v.shown or v.loader
    if l then
      local n = l.model.n
      local status = l.status
      if v.provisional and v.shown == v.provisional then
        status = "provisional_stopped"
        if v.provisional.status == "loading" or v.provisional.status == "paused" then
          status = "loading"
        end
      end
      local count = l.model.complete and ("%d commits"):format(n) or ("%d+ commits"):format(n)
      parts[#parts + 1] = "%=" .. count
      local s = v.error_text or STATUS_TEXT[status]
      if s and s ~= "" then
        parts[#parts + 1] = " · " .. esc(s)
      end
    end
    if v.suggest_commit_graph then
      parts[#parts + 1] = " · %#WarningMsg#no commit-graph: :Trellis commit-graph%*"
    end
    local text = table.concat(parts, " ")
    for _, win in ipairs(vim.fn.win_findbuf(v.bufnr)) do
      vim.wo[win].winbar = text
    end
  end, 50)
end

-- Loading --------------------------------------------------------------------------------------

local start_loading

local function ref_signature(map)
  local names = vim.tbl_keys(map.by_name)
  table.sort(names)
  local parts = { "HEAD=" .. tostring(map.head.sha) .. ":" .. tostring(map.head.ref) }
  for _, n in ipairs(names) do
    parts[#parts + 1] = n .. "=" .. map.by_name[n].target
  end
  return table.concat(parts, "\n")
end

local function read_grafted(repo)
  local set = {}
  if repo.shallow then
    local f = io.open(repo.gitdir .. "/shallow", "r") or io.open(repo.commondir .. "/shallow", "r")
    if f then
      for line in f:lines() do
        set[vim.trim(line)] = true
      end
      f:close()
    end
  end
  return set
end

local function effective_query(v)
  local q = vim.deepcopy(v.query)
  local map = v.repo.refs
  if map and not map.head.sha then
    -- Unborn HEAD: `git log HEAD` would fail.
    q.revs = vim.tbl_filter(function(r)
      return r ~= "HEAD"
    end, q.revs)
  end
  return q
end

local function new_loader(v, q, extra)
  local opts = {
    prefetch_rows = v.cfg.perf.prefetch_rows,
    style = v.style,
    max_lanes = v.cfg.graph.max_lanes,
    head_sha = v.repo.refs and v.repo.refs.head.sha,
  }
  for k, val in pairs(extra) do
    opts[k] = val
  end
  return loader_mod.new(v.repo, q, opts)
end

-- Uncommitted changes line ------------------------------------------------------------------

--- Show the line only for graphs that include HEAD, unfiltered (|trellis-uncommitted|).
local function wants_uncommitted(v, q)
  if not v.cfg.graph.uncommitted then
    return false
  end
  local map = v.repo.refs
  if not (map and map.head.sha) or #q.paths > 0 or query_mod.has_commit_filters(q) then
    return false
  end
  for _, r in ipairs(q.revs) do
    if r == "HEAD" or r == "@" or r == "--all" or (map.head.ref and r == map.head.ref) then
      return true
    end
  end
  return false
end

--- Insert, update or remove line 1 (the buffer shifts; cursors stay on the same commit).
---@param u? { staged: integer, unstaged: integer, conflicted: integer, entries: table[] }
local function set_uncommitted(v, u)
  if not vim.api.nvim_buf_is_valid(v.bufnr) or v.message then
    return
  end
  local text
  if u then
    local parts = {}
    if u.conflicted > 0 then
      parts[#parts + 1] = u.conflicted .. " conflicted"
    end
    if u.staged > 0 then
      parts[#parts + 1] = u.staged .. " staged"
    end
    if u.unstaged > 0 then
      parts[#parts + 1] = u.unstaged .. " unstaged"
    end
    text = "◌ uncommitted changes: " .. table.concat(parts, ", ")
  end
  local top = v.top or 0
  v.uncommitted = u
  if text and top == 1 then
    if vim.api.nvim_buf_get_lines(v.bufnr, 0, 1, false)[1] ~= text then
      set_lines(v, 0, 1, { text })
    end
    return
  end
  if (text and top == 1) or (not text and top == 0) then
    return
  end
  local wins = vim.fn.win_findbuf(v.bufnr)
  local cursors = {}
  for i, w in ipairs(wins) do
    cursors[i] = vim.api.nvim_win_get_cursor(w)
  end
  if text then
    set_lines(v, 0, 0, { text })
    v.top = 1
  else
    set_lines(v, 0, 1, {})
    v.top = 0
  end
  local shift = v.top - top
  for i, w in ipairs(wins) do
    local line = math.max(1, cursors[i][1] + shift)
    pcall(vim.api.nvim_win_set_cursor, w, { line, cursors[i][2] })
  end
end

--- Ask git for the working tree state (G07) and update the line. Runs beside the history
--- stream, so it never delays the first screen.
local function refresh_uncommitted(v)
  local q = effective_query(v)
  if not wants_uncommitted(v, q) then
    return set_uncommitted(v, nil)
  end
  local inv = require("trellis.git.argv").G07()
  v.uncommitted_gen = (v.uncommitted_gen or 0) + 1
  local gen = v.uncommitted_gen
  require("trellis.git.runner").run(v.repo.root, inv.args, { kind = inv.kind }, function(err, res)
    vim.schedule(function()
      if gen ~= v.uncommitted_gen or not views[v.bufnr] then
        return
      end
      if err then
        return set_uncommitted(v, nil)
      end
      local u = { staged = 0, unstaged = 0, conflicted = 0, entries = {} }
      for _, e in ipairs(require("trellis.git.parse.status").parse(res.stdout)) do
        if e.kind == "unmerged" then
          u.conflicted = u.conflicted + 1
          u.entries[#u.entries + 1] = e
        elseif e.kind == "changed" or e.kind == "renamed" then
          local x, y = e.xy:sub(1, 1), e.xy:sub(2, 2)
          if x ~= "." then
            u.staged = u.staged + 1
          end
          if y ~= "." then
            u.unstaged = u.unstaged + 1
          end
          u.entries[#u.entries + 1] = e
        end
      end
      set_uncommitted(v, #u.entries > 0 and u or nil)
    end)
  end)
end
M.refresh_uncommitted = refresh_uncommitted

--- (Re)start loading into the view. Keeps the buffer content until new rows arrive.
start_loading = function(v)
  for _, l in ipairs({ v.loader, v.provisional }) do
    if l then
      l:cancel()
    end
  end
  v.loader, v.provisional, v.error_text = nil, nil, nil
  local map = v.repo.refs
  local q = effective_query(v)
  if map and not map.head.sha and next(map.by_name) == nil then
    v.shown = nil
    return show_message(v, "no commits yet")
  end
  if #q.revs == 0 then
    v.shown = nil
    return show_message(v, "nothing to show")
  end

  local main
  -- Commit filters (author, grep, pickaxe, dates): git does not rewrite parents, so commits
  -- stream in without edges and the graph is laid out again once the result set is complete.
  local filtered = query_mod.has_commit_filters(q)
  main = new_loader(v, q, {
    strip_parents = filtered,
    on_rows = function()
      if v.loader ~= main then
        return
      end
      if v.shown ~= main then
        -- First real rows: replace whatever is shown (provisional view or previous history),
        -- keeping the cursor on the same commit.
        if v.shown and not v.restore_sha then
          local idx = M.cursor_commit(v)
          v.restore_sha = idx and v.shown.model.sha[idx] or nil
        end
        v.shown = main
        v.appended = 0
        if v.message then
          -- The buffer showed a message: the uncommitted line could not be added then.
          v.message = nil
          refresh_uncommitted(v)
        end
        if v.provisional then
          v.provisional:cancel()
        end
      end
      schedule_flush(v)
    end,
    on_done = function(status, err)
      if v.loader ~= main then
        return
      end
      if status == "error" then
        v.error_text = "history truncated: " .. (err or "git error")
        if main.model.n == 0 then
          v.shown = nil
          show_message(v, "git log failed: " .. (err or "unknown error"))
        end
      elseif status == "complete" and main.model.n == 0 then
        v.shown = nil
        show_message(v, "no commits match")
      elseif status == "complete" and filtered and v.shown == main then
        local idx = M.cursor_commit(v)
        v.restore_sha = v.restore_sha or (idx and main.model.sha[idx]) or nil
        main:relayout()
        v.appended = 0
      end
      if v.shown == main then
        schedule_flush(v)
      end
      update_winbar(v)
    end,
  })
  v.loader = main

  local fast = v.cfg.perf.fast_first_screen
    and not v.repo.features.commit_graph
    and q.order == "topo"
    and not query_mod.has_filters(q)
  if fast then
    local pq = vim.deepcopy(q)
    pq.order = "default"
    pq.max_count = v.cfg.perf.page_size
    local prov
    prov = new_loader(v, pq, {
      check_topo = true,
      on_rows = function()
        if v.provisional == prov and v.shown ~= main then
          if v.shown ~= prov then
            v.shown = prov
            v.appended = 0
          end
          schedule_flush(v)
        end
      end,
      on_done = function()
        update_winbar(v)
      end,
    })
    v.provisional = prov
    prov:start()
  end
  main:start()
  if filtered then
    main:load_all() -- result sets are small; the relayout needs all of them
  end
  refresh_uncommitted(v)
  update_winbar(v)
end

-- Navigation -------------------------------------------------------------------------------

--- Model row under the cursor (0 on the "uncommitted changes" line).
local function cur_row(v)
  local win = vim.fn.bufwinid(v.bufnr)
  if win == -1 then
    return 1
  end
  return vim.api.nvim_win_get_cursor(win)[1] - (v.top or 0)
end

--- True when the cursor is on the "uncommitted changes" line.
local function on_uncommitted(v)
  return (v.top or 0) > 0 and cur_row(v) < 1
end

--- Commit index under the cursor (nearest commit row above a connector row).
function M.cursor_commit(v)
  local l = v.shown
  if not l then
    return nil
  end
  local m = l.model
  local r = m:next_commit_row(math.min(cur_row(v), v.appended), -1)
  return r and m.rows_commit[r], r
end

local function jump(v, pred, dir)
  local l = v.shown
  if not l then
    return
  end
  local m = l.model
  local count = math.max(1, vim.v.count)
  local r = cur_row(v)
  local target
  while count > 0 do
    r = r + dir
    while r >= 1 and r <= v.appended and not (m.rows_kind[r] == 1 and pred(m, r)) do
      r = r + dir
    end
    if r < 1 or r > v.appended then
      break
    end
    target = r
    count = count - 1
  end
  if target then
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { target + (v.top or 0), 0 })
  end
end

local function has_refs(v)
  return function(m, r)
    return #deco_parts(v, m.sha[m.rows_commit[r]]) > 0
  end
end

local function always()
  return true
end

local function copy(text)
  vim.fn.setreg('"', text)
  pcall(vim.fn.setreg, "+", text)
  vim.notify("trellis: copied " .. text)
end

local function handlers(v)
  return {
    close = function()
      if #vim.api.nvim_list_wins() > 1 then
        vim.cmd("close")
      end
      if vim.api.nvim_buf_is_valid(v.bufnr) then
        vim.api.nvim_buf_delete(v.bufnr, { force = true })
      end
    end,
    cancel = function()
      for _, l in ipairs({ v.loader, v.provisional }) do
        if l then
          l:cancel()
        end
      end
      update_winbar(v)
    end,
    refresh = function()
      M.refresh(v, { force = true })
    end,
    next_commit = function()
      jump(v, always, 1)
    end,
    prev_commit = function()
      jump(v, always, -1)
    end,
    next_ref = function()
      jump(v, has_refs(v), 1)
    end,
    prev_ref = function()
      jump(v, has_refs(v), -1)
    end,
    goto_head = function()
      local head = v.repo.refs and v.repo.refs.head.sha
      if head then
        M.goto_sha(v, head)
      end
    end,
    load_all_end = function()
      if vim.v.count > 0 then
        vim.cmd("normal! " .. vim.v.count .. "G")
        return
      end
      vim.cmd("normal! m'")
      M.load_all(v, function()
        vim.cmd("normal! G")
      end)
    end,
    yank_sha = function()
      local idx = M.cursor_commit(v)
      if idx then
        copy(v.shown.model.sha[idx]:sub(1, SHORT))
      end
    end,
    yank_full_sha = function()
      local idx = M.cursor_commit(v)
      if idx then
        copy(v.shown.model.sha[idx])
      end
    end,
    open_commit = function()
      if on_uncommitted(v) then
        return M.open_uncommitted(v)
      end
      local sha = M.cursor_sha(v)
      if sha then
        require("trellis.view.commit").open(v.repo, sha, { split = v.cfg.views.commit.split })
      end
    end,
    toggle_preview = function()
      M.toggle_preview(v)
    end,
    pick = function()
      require("trellis.pick").pick(v.repo, { from_graph = v })
    end,
    open_file = function()
      local sha = M.cursor_sha(v)
      if not sha then
        return
      end
      require("trellis.git.details").get(v.repo, sha, nil, function(err, d)
        if err then
          return vim.notify("trellis: " .. err, vim.log.levels.ERROR)
        end
        local files = vim.tbl_filter(function(f)
          return f.status ~= "D"
        end, d.files)
        if #files == 0 then
          return vim.notify("trellis: no files to open in " .. sha:sub(1, SHORT))
        end
        local function open(f)
          require("trellis.view.filerev").open(
            v.repo,
            sha,
            f.path,
            { split = v.cfg.views.commit.split }
          )
        end
        if #files == 1 then
          return open(files[1])
        end
        vim.ui.select(files, {
          prompt = "Open file at " .. sha:sub(1, SHORT),
          format_item = function(f)
            return f.status .. "  " .. f.path
          end,
        }, function(f)
          if f then
            open(f)
          end
        end)
      end)
    end,
    diff = function()
      if on_uncommitted(v) then
        return M.open_uncommitted(v)
      end
      local idx = M.cursor_commit(v)
      if not idx then
        return
      end
      local m = v.shown.model
      local parent = m.parents[idx][1]
        or require("trellis.git.argv").empty_tree(v.repo.features.sha256)
      require("trellis.view.diff").open(v.repo, parent, m.sha[idx])
    end,
    toggle_mark = function()
      M.toggle_mark(v)
    end,
    cherry_pick = function()
      local shas = M.selected_shas(v)
      if #shas > 0 then
        M.act(v, function(a)
          return a.cherry_pick(v.repo, shas)
        end)
      end
    end,
    revert = function()
      local sha = M.cursor_sha(v)
      if sha then
        M.act(v, function(a)
          return a.revert(v.repo, sha)
        end)
      end
    end,
    checkout = function()
      local sha = M.cursor_sha(v)
      if not sha then
        return
      end
      local branches = {}
      for _, r in ipairs(v.repo.refs and v.repo.refs.by_sha[sha] or {}) do
        if r.kind == "local" then
          branches[#branches + 1] = r.short
        end
      end
      local function go(rev)
        M.act(v, function(a)
          return a.checkout(v.repo, rev)
        end)
      end
      if #branches == 0 then
        return go(sha)
      end
      table.insert(branches, sha:sub(1, SHORT) .. " (detached)")
      vim.ui.select(branches, { prompt = "Checkout" }, function(choice)
        if choice then
          go(choice:match("^(%x+) %(detached%)$") or choice)
        end
      end)
    end,
    branch_create = function()
      local sha = M.cursor_sha(v)
      if not sha then
        return
      end
      vim.ui.input({ prompt = "New branch at " .. sha:sub(1, SHORT) .. ": " }, function(name)
        if name and name ~= "" then
          M.act(v, function(a)
            return a.branch_create(v.repo, name, sha)
          end)
        end
      end)
    end,
    tag_create = function()
      local sha = M.cursor_sha(v)
      if not sha then
        return
      end
      vim.ui.input({ prompt = "New tag at " .. sha:sub(1, SHORT) .. ": " }, function(name)
        if not name or name == "" then
          return
        end
        vim.ui.input({ prompt = "Message (empty: lightweight tag): " }, function(msg)
          M.act(v, function(a)
            return a.tag_create(v.repo, name, sha, { message = (msg and msg ~= "") and msg or nil })
          end)
        end)
      end)
    end,
    reset = function()
      local sha = M.cursor_sha(v)
      if not sha then
        return
      end
      vim.ui.select(
        { "soft", "mixed", "hard" },
        { prompt = "Reset to " .. sha:sub(1, SHORT) },
        function(mode)
          if mode then
            M.act(v, function(a)
              return a.reset(v.repo, sha, mode)
            end)
          end
        end
      )
    end,
    filters = function()
      M.edit_filters(v)
    end,
    search_all = function()
      require("trellis.view.search").prompt(v)
    end,
    rebase = function()
      local sha = M.cursor_sha(v)
      if sha then
        require("trellis.view.plan").start(v.repo, sha)
      end
    end,
    undo = function()
      M.act(v, function()
        return require("trellis.safety.ops").undo(v.repo)
      end)
    end,
    yank_permalink = function()
      local sha = M.cursor_sha(v)
      if sha then
        require("trellis.permalink").for_repo(v.repo, { sha = sha })
      end
    end,
    compare = function()
      local sha = M.cursor_sha(v)
      if not v.mark then
        return vim.notify("trellis: mark a commit first (M, see g?)")
      end
      if sha then
        require("trellis.view.diff").open(v.repo, v.mark, sha)
      end
    end,
  }
end

M.preview_ns = vim.api.nvim_create_namespace("trellis.graph.preview")
M.mark_ns = vim.api.nvim_create_namespace("trellis.graph.mark")

--- `F`: edit the graph's query as :Trellis arguments; the cursor stays on its commit when
--- that commit still matches.
function M.edit_filters(v, text)
  local function apply(input)
    if input == nil then
      return
    end
    local q, err = query_mod.parse(query_mod.split_args(input), v.cfg)
    if not q then
      return vim.notify("trellis: " .. err, vim.log.levels.ERROR)
    end
    local idx = M.cursor_commit(v)
    v.restore_sha = idx and v.shown.model.sha[idx] or nil
    v.query = q
    local vars = vim.b[v.bufnr].trellis or {}
    vars.query = q
    vim.b[v.bufnr].trellis = vars
    start_loading(v)
  end
  if text then
    return apply(text)
  end
  vim.ui.input(
    { prompt = "Filter (git log arguments): ", default = query_mod.to_args(v.query) },
    apply
  )
end

--- Run a history action from the graph (the watcher refreshes the graph afterwards).
function M.act(v, fn)
  require("trellis.actions.ui").run(v.repo, function()
    return fn(require("trellis.actions"))
  end)
end

--- Commits of the visual selection (or the cursor commit), in graph order (newest first).
function M.selected_shas(v)
  local mode = vim.fn.mode()
  if not mode:match("^[vV\22]") then
    local sha = M.cursor_sha(v)
    return sha and { sha } or {}
  end
  local a, b = vim.fn.line("v"), vim.fn.line(".")
  if a > b then
    a, b = b, a
  end
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  local m = v.shown.model
  local out = {}
  a, b = a - (v.top or 0), b - (v.top or 0)
  for r = math.max(a, 1), math.min(b, v.appended) do
    if m.rows_kind[r] == 1 then
      out[#out + 1] = m.sha[m.rows_commit[r]]
    end
  end
  return out
end

--- Full sha of the commit under the cursor.
function M.cursor_sha(v)
  local idx = M.cursor_commit(v)
  return idx and v.shown.model.sha[idx] or nil
end

--- <CR> / d on the uncommitted line: staged and unstaged changes against HEAD (G20).
function M.open_uncommitted(v)
  require("trellis.view.diff").open(v.repo, "HEAD", nil, { split = v.cfg.views.commit.split })
end

local XY = { M = "M", A = "A", D = "D", R = "R", C = "C", T = "T", U = "U" }

--- <Tab> on the uncommitted line: its files, "staged/unstaged" letters like `git status -s`.
local function toggle_uncommitted_preview(v)
  v.previews = v.previews or {}
  if v.previews.uncommitted then
    pcall(vim.api.nvim_buf_del_extmark, v.bufnr, M.preview_ns, v.previews.uncommitted)
    v.previews.uncommitted = nil
    return
  end
  local u = v.uncommitted
  if not u then
    return
  end
  local vl = {}
  for _, e in ipairs(u.entries) do
    local x, y = e.xy:sub(1, 1), e.xy:sub(2, 2)
    local name = e.orig_path and (e.orig_path .. " → " .. e.path) or e.path
    vl[#vl + 1] = { { "  " .. (XY[x] or " ") .. (XY[y] or " ") .. " " .. name, "TrellisPreview" } }
  end
  v.previews.uncommitted =
    vim.api.nvim_buf_set_extmark(v.bufnr, M.preview_ns, 0, 0, { virt_lines = vl })
end

--- <Tab>: files and stats of the commit as virtual lines under its row.
function M.toggle_preview(v)
  if on_uncommitted(v) then
    return toggle_uncommitted_preview(v)
  end
  local idx, row = M.cursor_commit(v)
  if not idx then
    return
  end
  local sha = v.shown.model.sha[idx]
  v.previews = v.previews or {}
  if v.previews[sha] then
    pcall(vim.api.nvim_buf_del_extmark, v.bufnr, M.preview_ns, v.previews[sha])
    v.previews[sha] = nil
    return
  end
  require("trellis.git.details").get(v.repo, sha, nil, function(err, d)
    if err or not vim.api.nvim_buf_is_valid(v.bufnr) then
      return
    end
    local indent = (" "):rep(vim.fn.strdisplaywidth(v.shown.model.rows_text[row]) + 1)
    local vl = {}
    for _, f in ipairs(d.files) do
      local stat = f.binary and "binary"
        or (f.added and ("+%d -%d"):format(f.added, f.removed) or "")
      local name = f.old_path and (f.old_path .. " → " .. f.path) or f.path
      vl[#vl + 1] = { { indent .. f.status .. " " .. name .. "  " .. stat, "TrellisPreview" } }
    end
    if #vl == 0 then
      vl[1] = { { indent .. "(no changes)", "TrellisPreview" } }
    end
    v.previews[sha] = vim.api.nvim_buf_set_extmark(
      v.bufnr,
      M.preview_ns,
      row - 1 + (v.top or 0),
      0,
      { virt_lines = vl }
    )
  end)
end

--- M: mark the commit under the cursor for `=` (compare). Again to unmark.
function M.toggle_mark(v)
  local sha, _ = M.cursor_sha(v), nil
  if not sha then
    return
  end
  vim.api.nvim_buf_clear_namespace(v.bufnr, M.mark_ns, 0, -1)
  if v.mark == sha then
    v.mark = nil
    return
  end
  v.mark = sha
  local _, row = M.cursor_commit(v)
  vim.api.nvim_buf_set_extmark(
    v.bufnr,
    M.mark_ns,
    row - 1 + (v.top or 0),
    0,
    { line_hl_group = "TrellisMarked" }
  )
  vim.notify("trellis: marked " .. sha:sub(1, SHORT) .. " — press = on another commit to compare")
end

--- Load to EOF, then run `cb` once the buffer has every row.
function M.load_all(v, cb)
  local l = v.loader
  if not l then
    return cb and cb()
  end
  local function after()
    if l:done() and v.appended >= l.model.loaded then
      if cb then
        cb()
      end
      return true
    end
  end
  if after() then
    return
  end
  l:load_all()
  local poll
  poll = function()
    if not vim.api.nvim_buf_is_valid(v.bufnr) or v.loader ~= l then
      return
    end
    if not after() then
      vim.defer_fn(poll, 30)
    end
  end
  poll()
end

--- Move the cursor to the commit `sha`, loading more history if needed.
function M.goto_sha(v, sha)
  local function try()
    local l = v.shown
    local m = l and l.model
    local idx = m and m.index[sha]
    local r = idx and m.row_of_commit[idx]
    if r and r <= v.appended then
      vim.cmd("normal! m'")
      cursor_to_row(v, r)
      return true
    end
  end
  if try() then
    return
  end
  v.restore_sha = sha
  M.load_all(v, function()
    if not try() then
      vim.notify("trellis: commit " .. sha:sub(1, SHORT) .. " is not in this graph")
    end
  end)
end

-- Refresh ----------------------------------------------------------------------------------

--- Reload refs; restart the history stream if tips or HEAD changed (or `force`).
---@param v trellis.GraphView
---@param opts? { force?: boolean }
function M.refresh(v, opts)
  repo_mod.refresh_state(v.repo)
  refs_mod.load(v.repo, function(err, map)
    if err or not vim.api.nvim_buf_is_valid(v.bufnr) then
      return
    end
    local sig = ref_signature(map)
    if sig == v.ref_signature and not (opts and opts.force) then
      return
    end
    v.ref_signature = sig
    events.emit("TrellisRefsChanged", { root = v.repo.root, generation = map.generation })
    local idx = M.cursor_commit(v)
    v.restore_sha = idx and v.shown.model.sha[idx] or map.head.sha
    start_loading(v)
  end)
end

-- Decoration provider ----------------------------------------------------------------------

local char_pattern = "[^\128-\191][\128-\191]*"

local function paint_graph(buf, row0, text, colors)
  local pos, x = 1, 1
  local run_color, run_start = 0, 0
  local n = #text
  while pos <= n do
    local s, e = text:find(char_pattern, pos)
    if not s then
      break
    end
    local c = colors:byte(x) or 0
    if c ~= run_color then
      if run_color > 0 then
        vim.api.nvim_buf_set_extmark(buf, M.ns, row0, run_start, {
          end_col = s - 1,
          hl_group = "TrellisGraph" .. ((run_color - 1) % hl.lane_colors + 1),
          ephemeral = true,
        })
      end
      run_color, run_start = c, s - 1
    end
    pos, x = e + 1, x + 1
  end
  if run_color > 0 then
    vim.api.nvim_buf_set_extmark(buf, M.ns, row0, run_start, {
      end_col = n,
      hl_group = "TrellisGraph" .. ((run_color - 1) % hl.lane_colors + 1),
      ephemeral = true,
    })
  end
end

local function on_line(_, win, buf, row0)
  local v = views[buf]
  local l = v and v.shown
  if not l or v.message then
    return
  end
  local top = v.top or 0
  if row0 < top then
    vim.api.nvim_buf_set_extmark(buf, M.ns, row0, 0, {
      end_row = row0 + 1,
      hl_group = "TrellisUncommitted",
      hl_eol = false,
      ephemeral = true,
    })
    return
  end
  local r = row0 + 1 - top -- model row (row0 stays the buffer row for extmarks)
  local m = l.model
  if r > v.appended or not m.rows_text[r] then
    return
  end
  local text = m.rows_text[r]
  paint_graph(buf, row0, text, m.rows_colors[r])
  if m.rows_kind[r] ~= 1 then
    return
  end
  local idx = m.rows_commit[r]
  local col = #text + 1
  local set = vim.api.nvim_buf_set_extmark
  set(buf, M.ns, row0, col, { end_col = col + SHORT, hl_group = "TrellisSha", ephemeral = true })
  col = col + SHORT + 1
  local parts = deco_parts(v, m.sha[idx])
  if #parts > 0 then
    col = col + 1 -- "("
    for _, p in ipairs(parts) do
      set(buf, M.ns, row0, col, { end_col = col + #p[1], hl_group = p[2], ephemeral = true })
      col = col + #p[1] + 1
    end
    col = col + 1 -- ") "
  end
  -- Author and date are right-aligned virtual text, which would cover the subject in a narrow
  -- window: show both when they fit, else only the date, else nothing.
  local author = sanitize(m.author[idx])
  local date = time.format(m.time[idx], v.cfg.graph.date_format)
  local avail = (v.text_width or {})[win]
  local virt = { { author, "TrellisAuthor" }, { "  " .. date, "TrellisDate" } }
  if avail then
    local line = vim.api.nvim_buf_get_lines(buf, row0, row0 + 1, false)[1] or ""
    local used = vim.api.nvim_strwidth(line) + 2
    local dw = vim.api.nvim_strwidth(date)
    if used + vim.api.nvim_strwidth(author) + 2 + dw > avail then
      virt = used + dw <= avail and { { date, "TrellisDate" } } or nil
    end
  end
  if virt then
    set(buf, M.ns, row0, 0, {
      virt_text = virt,
      virt_text_pos = "right_align",
      hl_mode = "combine",
      ephemeral = true,
    })
  end
end

local provider_installed = false
local function install_provider()
  if provider_installed then
    return
  end
  provider_installed = true
  -- Writing a file of a repository updates the "uncommitted changes" line of its graphs.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = vim.api.nvim_create_augroup("trellis.graph.uncommitted", { clear = true }),
    callback = function(ev)
      local file = vim.fs.normalize(vim.fn.fnamemodify(ev.file, ":p"))
      for _, v in pairs(views) do
        if file:sub(1, #v.repo.root + 1) == v.repo.root .. "/" and not v.uncommitted_pending then
          v.uncommitted_pending = true
          vim.defer_fn(function()
            v.uncommitted_pending = false
            if views[v.bufnr] then
              refresh_uncommitted(v)
            end
          end, 150)
        end
      end
    end,
  })
  vim.api.nvim_set_decoration_provider(M.ns, {
    on_win = function(_, win, buf, _, botline)
      local v = views[buf]
      if not v then
        return false
      end
      -- Text columns of this window (without number/sign/fold columns), for on_line.
      local info = vim.fn.getwininfo(win)[1]
      v.text_width = v.text_width or {}
      v.text_width[win] = info and (info.width - info.textoff) or nil
      -- Viewing near the end of loaded rows keeps the stream going (backpressure).
      local l = v.loader
      local seen = botline + 1 - (v.top or 0)
      if l and v.shown == l and seen > l.deepest then
        local want = seen
        vim.schedule(function()
          l:want(want)
        end)
      end
      return true
    end,
    on_line = on_line,
  })
end

-- Opening ----------------------------------------------------------------------------------

---@class trellis.GraphOpenOpts
---@field cwd? string
---@field args? string[]               :Trellis arguments
---@field query? trellis.GraphQuery
---@field split? "tab"|"vertical"|"horizontal"|"current"
---@field on_open? fun(v: trellis.GraphView)

--- Open a graph view (async: repository discovery and refs first).
---@param opts? trellis.GraphOpenOpts
function M.open(opts)
  opts = opts or {}
  local cwd = opts.cwd
  if not cwd then
    local name = vim.api.nvim_buf_get_name(0)
    cwd = (name ~= "" and vim.bo.buftype == "" and vim.fs.dirname(name)) or vim.fn.getcwd()
  end
  local opened_at = vim.uv.hrtime()
  repo_mod.discover(cwd, function(err, repo)
    if err then
      return vim.notify("trellis: " .. err, vim.log.levels.ERROR)
    end
    local cfg = config.for_repo(repo.root)
    local q = opts.query
    if not q then
      local qerr
      q, qerr = query_mod.parse(opts.args or {}, cfg)
      if not q then
        return vim.notify("trellis: " .. qerr, vim.log.levels.ERROR)
      end
    end
    refs_mod.load(repo, function(rerr, map)
      if rerr then
        return vim.notify("trellis: " .. rerr, vim.log.levels.ERROR)
      end
      hl.setup()
      install_provider()
      instance = instance + 1
      local buf = base.create_buf({
        name = "trellis://graph/" .. instance,
        kind = "graph",
        filetype = "trellisgraph",
        undolevels = -1,
        vars = { query = q },
      }, repo)
      local win = base.open(buf, opts.split or cfg.graph.open)
      local wo = vim.wo[win]
      wo.wrap = false
      wo.number = false
      wo.relativenumber = false
      wo.cursorline = true
      wo.signcolumn = "no"
      wo.foldcolumn = "0"
      wo.list = false
      wo.spell = false

      ---@type trellis.GraphView
      local v = {
        kind = "graph",
        bufnr = buf,
        repo = repo,
        query = q,
        cfg = cfg,
        style = glyphs.resolve_style(cfg.graph.style),
        appended = 0,
        restore_sha = map.head.sha,
        grafted = read_grafted(repo),
        ref_signature = ref_signature(map),
        opened_at = opened_at,
        state = {},
      }
      v.suggest_commit_graph = false -- set by maybe_suggest_commit_graph when it matters
      v.dispose = function()
        views[buf] = nil
        for _, l in ipairs({ v.loader, v.provisional }) do
          if l then
            l:cancel()
          end
        end
        if v.watcher then
          v.watcher.close()
        end
      end
      views[buf] = v
      base.register(v)
      base.apply_keymaps(buf, "graph", handlers(v))
      set_lines(v, 0, -1, { "loading…" })
      v.watcher = watch.watch(repo, function()
        M.refresh(v)
      end)
      events.emit("TrellisGraphOpened", { bufnr = buf, root = repo.root })
      M.maybe_auto_prune(repo, cfg)
      start_loading(v)
      if not repo.features.commit_graph and repo.shallow == false then
        M.maybe_suggest_commit_graph(v)
      end
      if opts.on_open then
        opts.on_open(v)
      end
    end)
  end)
end

local suggested = {}
local auto_pruned = {}

--- `safety.auto_prune = true`: prune old backups once per repository and session,
--- without asking (the option is the consent).
function M.maybe_auto_prune(repo, cfg)
  if not cfg.safety.auto_prune or auto_pruned[repo.commondir] then
    return
  end
  auto_pruned[repo.commondir] = true
  require("trellis.safety.ops").spawn(function()
    return require("trellis.safety.ops").prune(repo, { yes = true })
  end, function() end)
end

--- Suggest writing a commit-graph once per repository, when history is large enough to matter
--- (Constitution: never written automatically unless perf.write_commit_graph = true).
function M.maybe_suggest_commit_graph(v)
  local key = v.repo.commondir
  if suggested[key] then
    return
  end
  vim.defer_fn(function()
    local l = v.loader
    if not l or suggested[key] or not vim.api.nvim_buf_is_valid(v.bufnr) then
      return
    end
    -- Only worth it when the first topological rows were slow.
    if not l.first_rows_at or (l.first_rows_at - l.started_at) / 1e6 > 300 then
      suggested[key] = true
      if v.cfg.perf.write_commit_graph then
        -- Opted in: write it (objects only, no refs) instead of suggesting.
        local inv = require("trellis.git.argv").W27()
        require("trellis.git.runner").run(v.repo.root, inv.args, { kind = inv.kind }, function(err)
          if not err then
            v.repo.features.commit_graph = true
            vim.notify("trellis: wrote a commit-graph (perf.write_commit_graph = true)")
          end
        end)
        return
      end
      v.suggest_commit_graph = true
      update_winbar(v)
      vim.notify(
        "trellis: this repository has no commit-graph, so the graph loads slowly. Write one with\n"
          .. "  git commit-graph write --reachable\n(or :Trellis commit-graph)",
        vim.log.levels.INFO
      )
    end
  end, 1000)
end

--- View for a buffer.
---@return trellis.GraphView?
function M.get(buf)
  return views[buf or vim.api.nvim_get_current_buf()]
end

M._line_for = line_for

return M
