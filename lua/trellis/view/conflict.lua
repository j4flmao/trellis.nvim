--- Guided conflict panel (FR-044, T076), shared by cherry-pick, revert and (Phase 7) rebase.
---
---   cherry-pick stopped on a conflict while applying a1b2c3d "subject"
---   ours = HEAD (main) · theirs = a1b2c3d (the commit being applied)
---
---   Conflicted:
---    UU src/form.lua
---   Resolved / staged:
---    M  src/other.lua
---
--- <CR> open file · o ours · t theirs · a mark resolved · C continue · S skip · A abort · d 3-way
local argv = require("trellis.git.argv")
local backup = require("trellis.safety.backup")
local base = require("trellis.view.base")
local ops = require("trellis.safety.ops")
local preflight = require("trellis.safety.preflight")

local M = {}

M.ns = vim.api.nvim_create_namespace("trellis.conflict")
local MARKERS = [[\v^(\<{7}|\={7}|\>{7}|\|{7})( .*)?$]]

local function read_head_file(repo, name)
  local f = io.open(repo.gitdir .. "/" .. name, "r")
  if not f then
    return nil
  end
  local s = vim.trim(f:read("*a"))
  f:close()
  return s
end

--- Render the panel. Inside async.run.
local function render(v)
  local repo = v.repo
  local st = require("trellis.git.repo").refresh_state(repo)
  local _, entries = preflight.status(repo)
  local lines, items = {}, {}
  if st.kind == "clean" then
    lines = { "No operation in progress.", "", "q close" }
  else
    local applying = read_head_file(repo, "CHERRY_PICK_HEAD")
      or read_head_file(repo, "REVERT_HEAD")
      or (st.rebase and st.rebase.stopped_sha)
    local subject = ""
    if applying then
      local _, res = backup.git(repo, argv.G14({ applying }))
      subject = res and (res.stdout:match("%z([^\n]*)") or "") or ""
    end
    local _, head = backup.read_refs(repo, {})
    local ours = head.symbolic and head.symbolic:gsub("^refs/heads/", "")
      or (head.sha or "?"):sub(1, 7)
    lines[1] = ("%s stopped on a conflict%s"):format(
      st.kind,
      applying and (" while applying %s %q"):format(applying:sub(1, 7), subject) or ""
    )
    lines[2] = ("ours = HEAD (%s) · theirs = %s (the commit being %s)"):format(
      ours,
      applying and applying:sub(1, 7) or "?",
      st.kind == "revert" and "reverted" or "applied"
    )
    lines[3] = ""
    local conflicted, resolved = {}, {}
    for _, e in ipairs(entries) do
      if e.kind == "unmerged" then
        conflicted[#conflicted + 1] = e
      else
        resolved[#resolved + 1] = e
      end
    end
    lines[#lines + 1] = ("Conflicted (%d):"):format(#conflicted)
    for _, e in ipairs(conflicted) do
      lines[#lines + 1] = " " .. e.xy .. " " .. e.path
      items[#lines] = e
    end
    if #conflicted == 0 then
      lines[#lines + 1] = " (none: press C to continue)"
    end
    lines[#lines + 1] = ("Resolved / staged (%d):"):format(#resolved)
    for _, e in ipairs(resolved) do
      lines[#lines + 1] = " " .. e.xy .. " " .. e.path
      items[#lines] = e
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] =
      "<CR> open · o ours · t theirs · a mark resolved · C continue · S skip · A abort · d 3-way"
  end
  if not vim.api.nvim_buf_is_valid(v.bufnr) then
    return
  end
  vim.bo[v.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(v.bufnr, 0, -1, false, lines)
  vim.bo[v.bufnr].modifiable = false
  vim.api.nvim_buf_clear_namespace(v.bufnr, M.ns, 0, -1)
  vim.api.nvim_buf_set_extmark(
    v.bufnr,
    M.ns,
    0,
    0,
    { end_col = #lines[1], hl_group = "WarningMsg" }
  )
  for lnum, e in pairs(items) do
    vim.api.nvim_buf_set_extmark(v.bufnr, M.ns, lnum - 1, 1, {
      end_col = 3,
      hl_group = e.kind == "unmerged" and "DiagnosticError" or "DiagnosticOk",
    })
  end
  v.state.items = items
  v.state.kind = st.kind
end

local function refresh(v)
  ops.spawn(function()
    render(v)
  end)
end

local function item(v)
  return v.state.items and v.state.items[vim.api.nvim_win_get_cursor(0)[1]]
end

--- Open a conflicted file in the window above, with conflict markers highlighted.
local function open_file(v, path)
  vim.cmd("wincmd p")
  if vim.api.nvim_get_current_buf() == v.bufnr then
    vim.cmd("aboveleft split")
  end
  vim.cmd.edit(vim.fn.fnameescape(v.repo.root .. "/" .. path))
  if not vim.w.trellis_conflict_match then
    vim.w.trellis_conflict_match = vim.fn.matchadd("DiffText", MARKERS)
  end
  vim.fn.search("^<<<<<<<", "cw")
end

local function control(v, action)
  ops.spawn(function()
    local op, err = ops.control(v.repo, action)
    local st = require("trellis.git.repo").refresh_state(v.repo)
    if st.kind == "clean" then
      local msg = ("%s %s"):format(
        action == "abort" and "aborted" or "finished",
        op and op.title or ""
      )
      vim.notify(
        "trellis: " .. msg .. (action ~= "abort" and " — :Trellis undo reverts it" or "")
      )
      if vim.api.nvim_buf_is_valid(v.bufnr) then
        vim.api.nvim_buf_delete(v.bufnr, { force = true })
      end
    else
      render(v)
    end
    return op, err
  end)
end

local function handlers(v)
  local repo = v.repo
  return {
    close = function()
      if #vim.api.nvim_list_wins() > 1 then
        vim.cmd("close")
      else
        vim.api.nvim_buf_delete(v.bufnr, { force = true })
      end
    end,
    refresh = function()
      refresh(v)
    end,
    open = function()
      local e = item(v)
      if e then
        open_file(v, e.path)
      end
    end,
    ours = function()
      local e = item(v)
      if e and e.kind == "unmerged" then
        ops.spawn(function()
          local err = backup.git(repo, argv.W26("ours", e.path))
          render(v)
          return nil, err
        end)
      end
    end,
    theirs = function()
      local e = item(v)
      if e and e.kind == "unmerged" then
        ops.spawn(function()
          local err = backup.git(repo, argv.W26("theirs", e.path))
          render(v)
          return nil, err
        end)
      end
    end,
    resolved = function()
      local e = item(v)
      if not e then
        return
      end
      local buf = vim.fn.bufnr(repo.root .. "/" .. e.path)
      if buf ~= -1 and vim.bo[buf].modified then
        return vim.notify("trellis: save " .. e.path .. " first", vim.log.levels.WARN)
      end
      ops.spawn(function()
        local err = backup.git(repo, argv.W26("add", e.path))
        render(v)
        return nil, err
      end)
    end,
    continue = function()
      control(v, "continue")
    end,
    skip = function()
      control(v, "skip")
    end,
    abort = function()
      control(v, "abort")
    end,
    diff3 = function()
      local e = item(v)
      if e and e.kind == "unmerged" then
        -- Ours (:2) and theirs (:3) side by side; the base is trellis://:1/<path>.
        require("trellis.adapters.diff").builtin.open(repo, ":2", ":3", { path = e.path })
      end
    end,
  }
end

--- Open (or refresh) the conflict panel for `repo`.
---@param repo trellis.Repository
---@param opts? { on_open?: fun(v: table) }
function M.open(repo, opts)
  opts = opts or {}
  local buf = base.create_buf({
    name = "trellis://conflict/" .. vim.fs.basename(repo.root),
    kind = "conflict",
    filetype = "trellisconflict",
  }, repo)
  base.open_slot(buf, "horizontal", "conflict")
  vim.wo.wrap = false
  local v = { kind = "conflict", bufnr = buf, repo = repo, state = {} }
  base.register(v)
  base.apply_keymaps(buf, "conflict", handlers(v))
  ops.spawn(function()
    render(v)
    if opts.on_open then
      opts.on_open(v)
    end
  end)
  return v
end

return M
