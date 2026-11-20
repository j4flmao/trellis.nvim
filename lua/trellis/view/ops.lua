--- `:Trellis ops` (operation journal) and `:Trellis log` (git command log).
local base = require("trellis.view.base")
local journal = require("trellis.safety.journal")
local ops = require("trellis.safety.ops")

local M = {}

M.ns = vim.api.nvim_create_namespace("trellis.ops")

local STATUS_GROUP = {
  done = "DiagnosticOk",
  undone = "Comment",
  failed = "DiagnosticError",
  stopped = "DiagnosticWarn",
  aborted = "Comment",
  running = "DiagnosticWarn",
}

local function fmt_refs(before, after, refs, bh, ah)
  local out = {}
  for _, r in ipairs(refs or {}) do
    local b, a = before and before[r], after and after[r]
    if b ~= a then
      out[#out + 1] = ("      %s: %s → %s"):format(
        r,
        (b or "(none)"):sub(1, 7),
        (a or "(deleted)"):sub(1, 7)
      )
    end
  end
  if bh and ah and (bh.sha ~= ah.sha or bh.symbolic ~= ah.symbolic) then
    local function h(x)
      return x.symbolic and (x.symbolic:gsub("^refs/heads/", "") .. "@" .. (x.sha or "?"):sub(1, 7))
        or (x.sha or "?"):sub(1, 7)
    end
    out[#out + 1] = ("      HEAD: %s → %s"):format(h(bh), h(ah))
  end
  return out
end

--- `details`: also list the git commands of each operation and its id / backup location.
function M.render_ops(list, details)
  local lines, items, marks = {}, {}, {}
  for i = #list, 1, -1 do
    local op = list[i]
    local when = os.date("%Y-%m-%d %H:%M:%S", op.started_at or 0)
    local status = op.status or "?"
    local line = ("%s  %-8s %s%s"):format(
      when,
      status,
      op.title or op.kind,
      op.pruned and "  [backups pruned]" or ""
    )
    lines[#lines + 1] = line
    items[#lines] = op
    marks[#marks + 1] = { #lines - 1, 21, 21 + #status, STATUS_GROUP[status] or "Normal" }
    for _, l in ipairs(fmt_refs(op.before, op.after, op.refs, op.before_head, op.after_head)) do
      lines[#lines + 1] = l
      items[#lines] = op
    end
    if op.error then
      lines[#lines + 1] = "      error: " .. op.error
      items[#lines] = op
    end
    if details then
      lines[#lines + 1] = ("      id %s · backups refs/trellis/backup/%s/%s"):format(
        op.id,
        op.id,
        op.target and (" · target " .. op.target) or ""
      )
      items[#lines] = op
      for _, args in ipairs(op.argv or {}) do
        -- (stdin transactions contain newlines; buffer lines cannot)
        lines[#lines + 1] = "      $ git " .. (table.concat(args, " "):gsub("\n", " "))
        items[#lines] = op
      end
    end
  end
  if #lines == 0 then
    lines = { "No trellis operations in this repository yet." }
  end
  return lines, items, marks
end

local function show(buf, lines, marks)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for _, m in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
end

---@param repo trellis.Repository
function M.open(repo)
  local buf = base.create_buf(
    { name = "trellis://ops/" .. vim.fs.basename(repo.root), kind = "ops", filetype = "trellisops" },
    repo
  )
  base.open_slot(buf, "horizontal", "ops")
  vim.wo.wrap = false
  local items = {}
  local details = false
  local function refresh()
    local lines, it, marks = M.render_ops((journal.read(repo)), details)
    items = it
    show(buf, lines, marks)
  end
  refresh()
  base.apply_keymaps(buf, "ops", {
    close = function()
      if #vim.api.nvim_list_wins() > 1 then
        vim.cmd("close")
      else
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end,
    refresh = refresh,
    restore = function()
      local op = items[vim.api.nvim_win_get_cursor(0)[1]]
      if not op then
        return
      end
      require("trellis.actions.ui").run(repo, function()
        return ops.restore_op(repo, op.id)
      end, refresh)
    end,
    undo = function()
      require("trellis.actions.ui").run(repo, function()
        return ops.undo(repo)
      end, refresh)
    end,
    details = function()
      details = not details
      refresh()
    end,
    prune = function()
      require("trellis.actions.ui").run(repo, function()
        local n, err = ops.prune(repo)
        if not err then
          vim.schedule(function()
            vim.notify(("trellis: pruned backups of %d operation(s)"):format(n))
          end)
        end
        return nil, err
      end, refresh)
    end,
  })
  return buf
end

--- `:Trellis log`: every git command trellis ran this session (argv, duration, exit, stderr).
function M.open_log()
  local buf = base.create_buf({ name = "trellis://log", kind = "log", filetype = "trellislog" })
  base.open_slot(buf, "horizontal", "log")
  vim.wo.wrap = false
  local function refresh()
    local lines, marks = {}, {}
    for _, e in ipairs(require("trellis.git.runner").history) do
      local args = {}
      for i, a in ipairs(e.argv) do
        args[i] = a:find("[%s\"']") and ("%q"):format(a) or a
      end
      local head = ("[%s] %6s  exit %-3s %s%s"):format(
        e.kind,
        e.duration_ms and ("%.0fms"):format(e.duration_ms) or "…",
        e.code and tostring(e.code) or "-",
        table.concat(args, " "),
        e.op_id and ("  (op " .. e.op_id .. ")") or ""
      )
      lines[#lines + 1] = head:gsub("\n", "\\n")
      if e.code and e.code ~= 0 then
        marks[#marks + 1] = { #lines - 1, 0, #lines[#lines], "DiagnosticError" }
        local first = vim.trim(e.stderr or ""):match("^[^\n]*")
        if first and first ~= "" then
          lines[#lines + 1] = "      " .. first
        end
      end
    end
    if #lines == 0 then
      lines = { "No git commands yet." }
    end
    show(buf, lines, marks)
    vim.api.nvim_win_set_cursor(0, { #lines, 0 })
  end
  refresh()
  base.apply_keymaps(buf, "log", {
    close = function()
      if #vim.api.nvim_list_wins() > 1 then
        vim.cmd("close")
      else
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end,
    refresh = refresh,
  })
  return buf
end

return M
