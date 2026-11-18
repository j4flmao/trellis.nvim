--- File history view (FR-022, `:Trellis file`): every commit that changed a file, following
--- renames. <CR> opens the commit, `o` the file at that revision, `d` the commit's diff of it.
local argv = require("trellis.git.argv")
local base = require("trellis.view.base")
local filelog = require("trellis.git.parse.filelog")
local runner = require("trellis.git.runner")

local M = {}

M.ns = vim.api.nvim_create_namespace("trellis.filehistory")

local function sanitize(s)
  return s:find("%c") and vim.fn.strtrans(s) or s
end

---@param entries trellis.FileLogEntry[]
---@return string[] lines, table[] marks
function M.render(entries)
  local lines, marks = {}, {}
  local wa = 0
  for _, e in ipairs(entries) do
    wa = math.max(wa, vim.fn.strdisplaywidth(e.author))
  end
  for i, e in ipairs(entries) do
    local date = os.date("%Y-%m-%d", e.time)
    local author = e.author .. (" "):rep(wa - vim.fn.strdisplaywidth(e.author))
    local line = ("%s %s %s %s  %s"):format(
      e.sha:sub(1, 7),
      e.status or " ",
      date,
      author,
      sanitize(e.subject)
    )
    if e.old_path then
      line = line .. ("  (%s → %s)"):format(e.old_path, e.path)
    end
    lines[i] = line
    marks[#marks + 1] = { i - 1, 0, 7, "TrellisSha" }
    marks[#marks + 1] = { i - 1, 11, 21, "TrellisDate" }
  end
  return lines, marks
end

--- Open the history of `path` (repo-relative) as of `rev` (default HEAD).
---@param repo trellis.Repository
---@param path string
---@param opts? { rev?: string, split?: string, on_open?: fun(buf: integer, entries: trellis.FileLogEntry[]) }
function M.open(repo, path, opts)
  opts = opts or {}
  local inv = argv.G23(path, opts.rev)
  runner.run(repo.root, inv.args, { kind = inv.kind }, function(err, res)
    if err then
      return vim.notify("trellis: " .. err, vim.log.levels.ERROR)
    end
    local entries = filelog.parse(res.stdout)
    if #entries == 0 then
      return vim.notify("trellis: no history for " .. path)
    end
    local buf = base.create_buf({
      name = "trellis://history/" .. path,
      kind = "filehistory",
      filetype = "trellisfilehistory",
      vars = { path = path },
    }, repo)
    local lines, marks = M.render(entries)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
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
    base.open_slot(buf, opts.split or "horizontal", "filehistory")
    vim.wo.wrap = false
    local function entry()
      return entries[vim.api.nvim_win_get_cursor(0)[1]], vim.api.nvim_win_get_cursor(0)[1]
    end
    base.apply_keymaps(buf, "filehistory", {
      close = function()
        if #vim.api.nvim_list_wins() > 1 then
          vim.cmd("close")
        else
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end,
      open_commit = function()
        local e = entry()
        if e then
          require("trellis.view.commit").open(repo, e.sha)
        end
      end,
      open_file = function()
        local e, i = entry()
        if not e then
          return
        end
        if e.status == "D" then
          return vim.notify("trellis: the file is deleted in this commit")
        end
        vim.cmd("wincmd p")
        require("trellis.view.filerev").open(repo, e.sha, e.path, {
          history = { list = entries, index = i },
        })
      end,
      diff = function()
        local e = entry()
        if not e then
          return
        end
        local parent = e.parents[1] or argv.empty_tree(repo.features.sha256)
        require("trellis.view.diff").open(
          repo,
          parent,
          e.sha,
          { path = e.path, old_path = e.old_path }
        )
      end,
    })
    if opts.on_open then
      opts.on_open(buf, entries)
    end
  end)
end

return M
