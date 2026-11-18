--- Line range history (US3, FR-032): `:[range]Trellis history` lists every commit that changed
--- the selected lines (`git log -L`), each with the hunk for that range.
local argv = require("trellis.git.argv")
local base = require("trellis.view.base")
local linelog = require("trellis.git.parse.linelog")
local runner = require("trellis.git.runner")
local target = require("trellis.view.target")

local M = {}

M.ns = vim.api.nvim_create_namespace("trellis.linehistory")

local function sanitize(s)
  return s:find("%c") and vim.fn.strtrans(s) or s
end

---@param entries trellis.LineLogEntry[]
---@return string[] lines, table<integer, { entry: trellis.LineLogEntry, path: string?, line: integer? }> items, table[] marks
function M.render(entries)
  local lines, items, marks = {}, {}, {}
  for _, e in ipairs(entries) do
    local header = ("%s %s %s  %s"):format(
      e.sha:sub(1, 7),
      os.date("%Y-%m-%d", e.time),
      e.author,
      sanitize(e.subject)
    )
    lines[#lines + 1] = header
    items[#lines] = { entry = e, header = true }
    marks[#marks + 1] = { #lines - 1, 0, 7, "TrellisSha" }
    marks[#marks + 1] = { #lines - 1, 8, #header, "Title" }
    for _, f in ipairs(e.files) do
      for _, h in ipairs(f.hunks) do
        local hdr = ("@@ -%d,%d +%d,%d @@"):format(
          h.old_start,
          h.old_count,
          h.new_start,
          h.new_count
        )
        lines[#lines + 1] = hdr
        items[#lines] = { entry = e, path = f.new_path or f.old_path, line = h.new_start }
        local new_line = h.new_start
        for _, l in ipairs(h.lines) do
          lines[#lines + 1] = l
          items[#lines] =
            { entry = e, path = f.new_path or f.old_path, line = math.max(1, new_line) }
          if l:sub(1, 1) ~= "-" and l:sub(1, 1) ~= "\\" then
            new_line = new_line + 1
          end
        end
      end
    end
    lines[#lines + 1] = ""
  end
  return lines, items, marks
end

--- foldexpr: one fold per commit (header line starts with a sha).
function M.foldexpr(lnum)
  local line = vim.fn.getline(lnum)
  if line:match("^%x%x%x%x%x%x%x ") then
    return ">1"
  end
  return "="
end

--- History of lines `l1`..`l2` of the file in the current buffer.
---@param l1 integer
---@param l2 integer
---@param opts? { on_open?: fun(buf: integer, entries: trellis.LineLogEntry[]) }
function M.open(l1, l2, opts)
  opts = opts or {}
  target.current(function(err, t)
    if err then
      return vim.notify("trellis: " .. err, vim.log.levels.ERROR)
    end
    local function run(rev, s, e)
      local inv = argv.G32(s, e, t.path, rev)
      runner.run(t.repo.root, inv.args, { kind = inv.kind }, function(gerr, res)
        if gerr then
          return vim.notify("trellis: " .. gerr, vim.log.levels.ERROR)
        end
        local entries = linelog.parse(res.stdout)
        local buf = base.create_buf({
          name = ("trellis://linehistory/%s:%d-%d"):format(t.path, s, e),
          kind = "linehistory",
          vars = { path = t.path, range = { s, e } },
        }, t.repo)
        local lines, items, marks = M.render(entries)
        if #entries == 0 then
          lines = { "(no history for these lines)" }
        end
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
        vim.bo[buf].filetype = "diff"
        for _, m in ipairs(marks) do
          pcall(
            vim.api.nvim_buf_set_extmark,
            buf,
            M.ns,
            m[1],
            m[2],
            { end_col = m[3], hl_group = m[4] }
          )
        end
        base.open_slot(buf, "horizontal", "linehistory")
        vim.wo.foldmethod = "expr"
        vim.wo.foldexpr = "v:lua.require'trellis.view.linehistory'.foldexpr(v:lnum)"
        vim.wo.foldlevel = 99
        vim.wo.wrap = false
        local function item()
          return items[vim.api.nvim_win_get_cursor(0)[1]]
        end
        base.apply_keymaps(buf, "linehistory", {
          close = function()
            if #vim.api.nvim_list_wins() > 1 then
              vim.cmd("close")
            else
              vim.api.nvim_buf_delete(buf, { force = true })
            end
          end,
          open_commit = function()
            local it = item()
            if it then
              require("trellis.view.commit").open(t.repo, it.entry.sha)
            end
          end,
          open_file = function()
            local it = item()
            if it and it.path then
              vim.cmd("wincmd p")
              require("trellis.view.filerev").open(
                t.repo,
                it.entry.sha,
                it.path,
                { cursor = { it.line or 1, 0 } }
              )
            end
          end,
        })
        if opts.on_open then
          opts.on_open(buf, entries)
        end
      end)
    end
    if t.sha then
      return run(t.sha, l1, l2)
    end
    -- Working copy: the range refers to the buffer; map it to HEAD first.
    target.map_worktree_lines(t.repo, "HEAD", t.path, { l1, l2 }, function(m)
      run("HEAD", m[1], math.max(m[1], m[2]))
    end)
  end)
end

return M
