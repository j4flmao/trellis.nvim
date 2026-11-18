--- Commit view (US2, FR-020): metadata, refs, parents (jumpable), message, changed files.
local base = require("trellis.view.base")
local config = require("trellis.config")
local details = require("trellis.git.details")
local events = require("trellis.events")
local hl = require("trellis.highlights")
local refs_mod = require("trellis.git.refs")

local M = {}

M.ns = vim.api.nvim_create_namespace("trellis.commit")

local function fmt_person(p)
  local date = os.date("%Y-%m-%d %H:%M", p.time) .. (p.tz and (" " .. p.tz) or "")
  return ("%s <%s>  %s"):format(p.name, p.email, date)
end

local function sanitize(s)
  return s:find("%c") and vim.fn.strtrans(s) or s
end

--- Build lines, per-line items and highlights for a commit.
---@param repo trellis.Repository
---@param d trellis.CommitDetails
---@param parent_subjects table<string, string>
---@return string[] lines, table<integer, table> items, table[] marks
function M.render(repo, d, parent_subjects)
  local lines, items, marks = {}, {}, {}
  local function add(text, item)
    lines[#lines + 1] = text
    if item then
      items[#lines] = item
    end
    return #lines
  end
  local function mark(lnum, s, e, group)
    marks[#marks + 1] = { lnum - 1, s, e, group }
  end

  local l = add("commit " .. d.sha)
  mark(l, 7, 7 + #d.sha, "TrellisSha")
  add("Author:     " .. fmt_person(d.author))
  if d.committer.name ~= d.author.name or d.committer.time ~= d.author.time then
    add("Committer:  " .. fmt_person(d.committer))
  end
  local labels = repo.refs and refs_mod.labels(repo.refs, d.sha, { show_stashes = true }) or {}
  if #labels > 0 then
    local text = "Refs:       "
    l = #lines + 1
    local col = #text
    local parts = {}
    for _, lab in ipairs(labels) do
      marks[#marks + 1] = { l - 1, col, col + #lab.text, hl.ref_groups[lab.kind] }
      parts[#parts + 1] = lab.text
      col = col + #lab.text + 1
    end
    add(text .. table.concat(parts, " "))
  end
  for i, p in ipairs(d.parents) do
    local label = #d.parents > 1 and ("Parent %d:   "):format(i) or "Parent:     "
    l = add(
      label .. p:sub(1, 7) .. " " .. sanitize(parent_subjects[p] or ""),
      { kind = "parent", sha = p, index = i }
    )
    mark(l, #label, #label + 7, "TrellisSha")
  end
  if d.signature then
    add(
      "Signature:  "
        .. d.signature.status
        .. (d.signature.signer and (" " .. d.signature.signer) or "")
    )
  end
  add("")
  for _, body_line in ipairs(vim.split(d.body, "\n", { plain = true })) do
    add("    " .. sanitize(body_line))
  end
  add("")

  local against
  if d.against == "cc" then
    against = "combined, against all parents"
  elseif d.against then
    local idx = 0
    for i, p in ipairs(d.parents) do
      if p == d.against then
        idx = i
      end
    end
    against = ("against parent %d %s"):format(idx, d.against:sub(1, 7))
  elseif #d.parents == 0 then
    against = "root commit"
  end
  local header = ("Files (%d%s):"):format(#d.files, against and (", " .. against) or "")
  l = add(header)
  mark(l, 0, #header, "Title")

  local width = 0
  for _, f in ipairs(d.files) do
    local name = f.old_path and (f.old_path .. " → " .. f.path) or f.path
    width = math.max(width, vim.fn.strdisplaywidth(name))
  end
  for _, f in ipairs(d.files) do
    local name = f.old_path and (f.old_path .. " → " .. f.path) or f.path
    local stat
    if f.binary then
      stat = "binary"
    elseif f.added then
      stat = ("+%d -%d"):format(f.added, f.removed)
    else
      stat = ""
    end
    local pad = (" "):rep(width - vim.fn.strdisplaywidth(name))
    local text = (" %s  %s%s  %s"):format(f.status, name, pad, stat)
    l = add(text, { kind = "file", file = f })
    local group = ({
      A = "DiffAdd",
      D = "DiffDelete",
      M = "DiffChange",
      R = "DiffText",
      C = "DiffText",
    })[f.status]
    if group then
      mark(l, 1, 2, group)
    end
  end
  if #d.files == 0 then
    add(" (no changes)")
  end
  return lines, items, marks
end

local function item_under_cursor(v)
  return v.state.items[vim.api.nvim_win_get_cursor(0)[1]]
end

--- First file item (for keys used outside a file line).
local function file_item(v)
  local it = item_under_cursor(v)
  if it and it.kind == "file" then
    return it.file
  end
end

local function handlers(v)
  local repo, d = v.repo, v.state.details
  local function rev_before(file)
    local parent = d.against ~= "cc" and d.against or d.parents[1]
    return parent, file.old_path or file.path
  end
  return {
    close = function()
      if #vim.api.nvim_list_wins() > 1 then
        vim.cmd("close")
      else
        vim.api.nvim_buf_delete(v.bufnr, { force = true })
      end
    end,
    refresh = function()
      M.open(repo, d.sha, { against = d.against, reuse = true })
    end,
    open_diff = function()
      local it = item_under_cursor(v)
      if it and it.kind == "parent" then
        return M.open(repo, it.sha, { reuse = true })
      end
      local f = file_item(v)
      if f then
        local parent = rev_before(f)
        local argv = require("trellis.git.argv")
        require("trellis.view.diff").open(
          repo,
          parent or argv.empty_tree(repo.features.sha256),
          d.sha,
          {
            path = f.path,
            old_path = f.old_path,
          }
        )
      end
    end,
    side_by_side = function()
      local f = file_item(v)
      if f then
        local parent, old = rev_before(f)
        require("trellis.view.diff").side_by_side(
          repo,
          parent,
          d.sha,
          { path = f.path, old_path = old }
        )
      end
    end,
    open_file = function()
      local f = file_item(v)
      if f then
        if f.status == "D" then
          local parent, old = rev_before(f)
          return require("trellis.view.filerev").open(repo, parent, old)
        end
        require("trellis.view.filerev").open(repo, d.sha, f.path)
      end
    end,
    parent = function()
      local it = item_under_cursor(v)
      local sha = (it and it.kind == "parent") and it.sha or d.parents[1]
      if sha then
        M.open(repo, sha, { reuse = true })
      end
    end,
    rebase = function()
      require("trellis.view.plan").start(repo, d.sha)
    end,
    choose_parent = function()
      if #d.parents < 2 then
        return vim.notify("trellis: not a merge commit")
      end
      local choices = {}
      for i, p in ipairs(d.parents) do
        choices[#choices + 1] = { label = ("parent %d  %s"):format(i, p:sub(1, 7)), against = p }
      end
      choices[#choices + 1] = { label = "combined (all parents)", against = "cc" }
      vim.ui.select(choices, {
        prompt = "Diff merge against",
        format_item = function(c)
          return c.label
        end,
      }, function(c)
        if c then
          M.open(repo, d.sha, { against = c.against, reuse = true })
        end
      end)
    end,
  }
end

---@class trellis.CommitOpenOpts
---@field against? string parent sha or "cc"
---@field split? string
---@field reuse? boolean   show in the current window (navigation inside commit views)
---@field on_open? fun(v: trellis.View)

--- Open the commit view for `sha` (full or abbreviated) in `repo`.
---@param repo trellis.Repository
---@param rev string
---@param opts? trellis.CommitOpenOpts
function M.open(repo, rev, opts)
  opts = opts or {}
  details.resolve(repo, rev, function(rerr, sha)
    if rerr then
      return vim.notify("trellis: " .. rerr, vim.log.levels.ERROR)
    end
    details.get(repo, sha, opts.against, function(err, d)
      if err then
        return vim.notify("trellis: " .. err, vim.log.levels.ERROR)
      end
      -- Parent subjects for the "Parent:" lines (one short command, only when there are parents).
      local subjects = {}
      local function show()
        hl.setup()
        local buf = base.create_buf({
          name = "trellis://commit/"
            .. sha:sub(1, 7)
            .. (opts.against and ("@" .. opts.against:sub(1, 7)) or ""),
          kind = "commit",
          filetype = "trelliscommit",
          vars = { sha = sha, parent_index = 1 },
        }, repo)
        local lines, items, marks = M.render(repo, d, subjects)
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
        local cfg = config.for_repo(repo.root)
        if opts.reuse then
          vim.api.nvim_win_set_buf(0, buf)
        else
          base.open_slot(buf, opts.split or cfg.views.commit.split, "commit")
        end
        vim.wo.wrap = false
        vim.wo.number = false
        local v =
          { kind = "commit", bufnr = buf, repo = repo, state = { details = d, items = items } }
        base.register(v)
        base.apply_keymaps(buf, "commit", handlers(v))
        -- Cursor on the first file.
        for lnum = 1, #lines do
          if items[lnum] and items[lnum].kind == "file" then
            vim.api.nvim_win_set_cursor(0, { lnum, 0 })
            break
          end
        end
        events.emit("TrellisCommitOpened", { bufnr = buf, sha = sha })
        if opts.on_open then
          opts.on_open(v)
        end
      end
      if #d.parents == 0 then
        return show()
      end
      local inv = require("trellis.git.argv").G14(d.parents)
      require("trellis.git.runner").run(repo.root, inv.args, { kind = inv.kind }, function(_, res)
        for line in ((res and res.stdout) or ""):gmatch("[^\n]+") do
          local h, s = line:match("^(%x+)%z(.*)$")
          if h then
            subjects[h] = s
          end
        end
        show()
      end)
    end)
  end)
end

return M
