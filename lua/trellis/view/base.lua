--- View registry, buffer/window factory, buffer-local keymaps and the `g?` help float.
local M = {}

---@type table<integer, trellis.View>
M.views = {}

---@class trellis.BufSpec
---@field name string
---@field kind trellis.ViewKind
---@field buftype? string    default "nofile"
---@field filetype? string
---@field modifiable? boolean default false
---@field bufhidden? string   default "wipe"
---@field undolevels? integer
---@field vars? table          extra `b:trellis` fields

--- Create a scratch buffer for a view.
---@param spec trellis.BufSpec
---@param repo? trellis.Repository
---@return integer bufnr
function M.create_buf(spec, repo)
  local existing = vim.fn.bufnr(spec.name)
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    vim.api.nvim_buf_delete(existing, { force = true })
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, spec.name)
  local bo = vim.bo[buf]
  bo.buftype = spec.buftype or "nofile"
  bo.bufhidden = spec.bufhidden or "wipe"
  bo.swapfile = false
  if spec.undolevels then
    bo.undolevels = spec.undolevels
  end
  if spec.filetype then
    bo.filetype = spec.filetype
  end
  bo.modifiable = spec.modifiable == true
  local vars =
    vim.tbl_extend("force", { view = spec.kind, repo = repo and repo.root }, spec.vars or {})
  vim.b[buf].trellis = vars
  vim.b[buf].trellis_view = spec.kind
  return buf
end

--- Register a view object for `bufnr`; it is disposed when the buffer is wiped.
---@param view trellis.View
function M.register(view)
  M.views[view.bufnr] = view
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = view.bufnr,
    once = true,
    callback = function()
      M.views[view.bufnr] = nil
      if view.dispose then
        pcall(view.dispose)
      end
    end,
  })
end

---@param bufnr? integer
---@return trellis.View?
function M.get(bufnr)
  return M.views[bufnr or vim.api.nvim_get_current_buf()]
end

--- Show `buf` according to `mode`; returns the window.
---@param buf integer
---@param mode "tab"|"vertical"|"horizontal"|"current"
---@return integer win
function M.open(buf, mode)
  if mode == "tab" then
    vim.cmd("tab split")
  elseif mode == "vertical" then
    vim.cmd("vsplit")
  elseif mode == "horizontal" then
    vim.cmd("split")
  end
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  return win
end

local slots = {} ---@type table<string, integer> tabpage .. slot -> window

--- Show `buf` in this tab's window for `slot` (e.g. "commit") if it is still open, otherwise
--- open a new window with `mode` and remember it. Keeps repeated <CR> in the graph from
--- stacking splits.
---@param buf integer
---@param mode "tab"|"vertical"|"horizontal"|"current"
---@param slot string
---@return integer win
function M.open_slot(buf, mode, slot)
  local key = vim.api.nvim_get_current_tabpage() .. ":" .. slot
  local win = slots[key]
  if
    win
    and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
  then
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_buf(win, buf)
    return win
  end
  win = M.open(buf, mode)
  slots[key] = win
  return win
end

--- Apply the effective keymaps of `view_kind` to `buf`. `handlers[name]` are functions; actions
--- without a handler are skipped (and omitted from help). Returns the applied specs.
---@param buf integer
---@param view_kind string
---@param handlers table<string, function>
---@return trellis.KeymapSpec[]
function M.apply_keymaps(buf, view_kind, handlers)
  local keymaps = require("trellis.keymaps")
  local specs, problems = keymaps.resolve(view_kind, require("trellis.config").get().keymaps)
  if #problems > 0 then
    vim.notify("trellis: " .. table.concat(problems, "; "), vim.log.levels.WARN)
  end
  local applied = {}
  handlers = vim.tbl_extend("keep", handlers, {
    help = function()
      M.show_help(view_kind, applied)
    end,
  })
  for _, s in ipairs(specs) do
    local fn = handlers[s.name]
    if fn then
      vim.keymap.set(
        s.mode,
        s.key,
        fn,
        { buffer = buf, desc = "trellis: " .. s.desc, nowait = true }
      )
      applied[#applied + 1] = s
    end
  end
  vim.b[buf].trellis_keymaps = vim.tbl_map(function(s)
    return { s.key, s.desc }
  end, applied)
  return applied
end

--- Help lines for applied keymaps.
---@param specs trellis.KeymapSpec[]
---@return string[]
function M.help_lines(specs)
  local width = 0
  for _, s in ipairs(specs) do
    width = math.max(width, vim.fn.strdisplaywidth(s.key))
  end
  local lines = {}
  for _, s in ipairs(specs) do
    lines[#lines + 1] = ("%s%s  %s"):format(
      s.key,
      (" "):rep(width - vim.fn.strdisplaywidth(s.key)),
      s.desc
    )
  end
  return lines
end

--- Floating help window; closes with q / <Esc> / leaving it.
---@param view_kind string
---@param specs trellis.KeymapSpec[]
---@return integer win
function M.show_help(view_kind, specs)
  local lines = M.help_lines(specs)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = math.max(20, width + 2),
    height = math.max(1, #lines),
    row = math.max(0, math.floor((vim.o.lines - #lines) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " trellis " .. view_kind .. " ",
  })
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      pcall(vim.api.nvim_win_close, win, true)
    end, { buffer = buf, nowait = true })
  end
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      pcall(vim.api.nvim_win_close, win, true)
    end,
  })
  return win
end

return M
