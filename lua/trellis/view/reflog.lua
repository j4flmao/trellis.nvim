--- `:Trellis reflog [{ref}]`: where HEAD (or a ref) has been, newest first. Commits that no
--- branch, tag, remote-tracking branch or HEAD reaches any more are marked "lost": `gb` puts a
--- branch on one to get it back, `gco` checks it out (both are undoable operations).
local argv = require("trellis.git.argv")
local base = require("trellis.view.base")
local parse = require("trellis.git.parse.reflog")
local runner = require("trellis.git.runner")
local time = require("trellis.util.time")

local M = {}

M.ns = vim.api.nvim_create_namespace("trellis.reflog")

local function sanitize(s)
  return s:find("%c") and vim.fn.strtrans(s) or s
end

---@param entries trellis.ReflogEntry[]
---@return string[] lines, table[] marks
function M.render(entries)
  local lines, marks = {}, {}
  local ws = 0
  for _, e in ipairs(entries) do
    ws = math.max(ws, #e.selector)
  end
  for i, e in ipairs(entries) do
    local sel = e.selector .. (" "):rep(ws - #e.selector)
    local when = time.format(e.time, "relative")
    local prefix = ("%s  %s  "):format(sel, e.sha:sub(1, 7))
    local line = prefix .. sanitize(e.action)
    if e.subject ~= "" and not e.action:find(e.subject, 1, true) then
      line = line .. "  · " .. sanitize(e.subject)
    end
    line = line .. "  (" .. when .. ")"
    if e.lost then
      line = line .. "  lost"
      marks[#marks + 1] = { i - 1, #line - 4, #line, "TrellisReflogLost" }
    end
    lines[i] = line
    marks[#marks + 1] = { i - 1, #sel + 2, #sel + 9, "TrellisSha" }
  end
  return lines, marks
end

local function copy(s)
  vim.fn.setreg('"', s)
  pcall(vim.fn.setreg, "+", s)
  vim.notify("trellis: copied " .. s)
end

--- Read the reflog of `ref` and mark lost commits. `cb(err, entries)`.
---@param repo trellis.Repository
---@param ref? string
---@param cb fun(err: string?, entries: trellis.ReflogEntry[]?)
function M.load(repo, ref, cb)
  local inv = argv.G46(ref)
  runner.run(repo.root, inv.args, { kind = inv.kind, ok_codes = inv.ok_codes }, function(err, res)
    if err then
      return cb(err)
    end
    local entries = parse.parse_reflog(res.stdout)
    if #entries == 0 then
      return cb(nil, entries)
    end
    local shas, seen = {}, {}
    for _, e in ipairs(entries) do
      if not seen[e.sha] then
        seen[e.sha] = true
        shas[#shas + 1] = e.sha
      end
    end
    local linv = argv.G47(shas)
    runner.run(repo.root, linv.args, { kind = linv.kind, stdin = linv.stdin }, function(lerr, lres)
      if not lerr then
        parse.mark_lost(entries, lres.stdout)
      end
      cb(nil, entries)
    end)
  end)
end

---@param repo trellis.Repository
---@param opts? { ref?: string, split?: string, on_open?: fun(buf: integer, entries: trellis.ReflogEntry[]) }
function M.open(repo, opts)
  opts = opts or {}
  local ref = opts.ref or "HEAD"
  M.load(repo, ref, function(err, entries)
    if err then
      return vim.notify("trellis: " .. err, vim.log.levels.ERROR)
    end
    if #entries == 0 then
      return vim.notify("trellis: " .. ref .. " has no reflog")
    end
    local buf = base.create_buf({
      name = "trellis://reflog/" .. ref,
      kind = "reflog",
      filetype = "trellisreflog",
      vars = { ref = ref },
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
    base.open_slot(buf, opts.split or "horizontal", "reflog")
    vim.wo.wrap = false
    local function entry()
      return entries[vim.api.nvim_win_get_cursor(0)[1]]
    end
    local function act(fn)
      require("trellis.actions.ui").run(repo, function()
        return fn(require("trellis.actions"))
      end, function(op)
        if op and op.status == "done" and vim.api.nvim_buf_is_valid(buf) then
          M.load(repo, ref, function(lerr, fresh)
            if not lerr then
              vim.schedule(function()
                entries = fresh
                fill()
              end)
            end
          end)
        end
      end)
    end
    base.apply_keymaps(buf, "reflog", {
      close = function()
        if #vim.api.nvim_list_wins() > 1 then
          vim.cmd("close")
        else
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end,
      refresh = function()
        M.load(repo, ref, function(lerr, fresh)
          if not lerr then
            vim.schedule(function()
              entries = fresh
              fill()
            end)
          end
        end)
      end,
      open_commit = function()
        local e = entry()
        if e then
          require("trellis.view.commit").open(repo, e.sha)
        end
      end,
      yank_sha = function()
        local e = entry()
        if e then
          copy(e.sha:sub(1, 7))
        end
      end,
      checkout = function()
        local e = entry()
        if e then
          act(function(a)
            return a.checkout(repo, e.sha)
          end)
        end
      end,
      branch_create = function()
        local e = entry()
        if not e then
          return
        end
        vim.ui.input({ prompt = "New branch at " .. e.sha:sub(1, 7) .. ": " }, function(name)
          if name and name ~= "" then
            act(function(a)
              return a.branch_create(repo, name, e.sha)
            end)
          end
        end)
      end,
    })
    if opts.on_open then
      opts.on_open(buf, entries)
    end
  end)
end

return M
