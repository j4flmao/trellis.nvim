--- `:Trellis stash`: the stash list. <CR> shows an entry's changes, `a` applies it to a clean
--- worktree (the entry stays on the list; :Trellis undo puts the worktree back). trellis never
--- drops stash entries.
local argv = require("trellis.git.argv")
local base = require("trellis.view.base")
local parse = require("trellis.git.parse.reflog")
local runner = require("trellis.git.runner")
local time = require("trellis.util.time")

local M = {}

M.ns = vim.api.nvim_create_namespace("trellis.stash")

local function sanitize(s)
  return s:find("%c") and vim.fn.strtrans(s) or s
end

---@param entries trellis.StashEntry[]
---@return string[] lines, table[] marks
function M.render(entries)
  local lines, marks = {}, {}
  local ws = 0
  for _, e in ipairs(entries) do
    ws = math.max(ws, #e.selector)
  end
  for i, e in ipairs(entries) do
    local sel = e.selector .. (" "):rep(ws - #e.selector)
    lines[i] = ("%s  %s  %s  (%s)"):format(
      sel,
      e.sha:sub(1, 7),
      sanitize(e.message),
      time.format(e.time, "relative")
    )
    marks[#marks + 1] = { i - 1, #sel + 2, #sel + 9, "TrellisSha" }
  end
  return lines, marks
end

---@param repo trellis.Repository
---@param cb fun(err: string?, entries: trellis.StashEntry[]?)
function M.load(repo, cb)
  local inv = argv.G48()
  runner.run(repo.root, inv.args, { kind = inv.kind }, function(err, res)
    if err then
      return cb(err)
    end
    cb(nil, parse.parse_stash(res.stdout))
  end)
end

---@param repo trellis.Repository
---@param opts? { split?: string, on_open?: fun(buf: integer, entries: trellis.StashEntry[]) }
function M.open(repo, opts)
  opts = opts or {}
  M.load(repo, function(err, entries)
    if err then
      return vim.notify("trellis: " .. err, vim.log.levels.ERROR)
    end
    if #entries == 0 then
      return vim.notify("trellis: no stash entries")
    end
    local buf = base.create_buf({
      name = "trellis://stash",
      kind = "stash",
      filetype = "trellisstash",
    }, repo)
    local function fill()
      local lines, marks = M.render(entries)
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false
      vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
      for _, m in ipairs(marks) do
        pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, m[1], m[2], {
          end_col = m[3],
          hl_group = m[4],
        })
      end
    end
    fill()
    base.open_slot(buf, opts.split or "horizontal", "stash")
    vim.wo.wrap = false
    local function entry()
      return entries[vim.api.nvim_win_get_cursor(0)[1]]
    end
    base.apply_keymaps(buf, "stash", {
      close = function()
        if #vim.api.nvim_list_wins() > 1 then
          vim.cmd("close")
        else
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end,
      refresh = function()
        M.load(repo, function(lerr, fresh)
          if not lerr and #fresh > 0 then
            vim.schedule(function()
              entries = fresh
              fill()
            end)
          end
        end)
      end,
      show = function()
        local e = entry()
        if e then
          -- The stash commit against the commit it was made on: the worktree changes it holds.
          require("trellis.view.diff").open(repo, e.sha .. "^1", e.sha)
        end
      end,
      apply = function()
        local e = entry()
        if e then
          require("trellis.actions.ui").run(repo, function()
            return require("trellis.actions").stash_apply(repo, e)
          end)
        end
      end,
    })
    if opts.on_open then
      opts.on_open(buf, entries)
    end
  end)
end

return M
