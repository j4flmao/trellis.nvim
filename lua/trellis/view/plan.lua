--- Rebase plan buffer and its preview window.
---
--- The plan is an ordinary editable buffer (`buftype=acwrite`): reorder with `dd`/`p`, `:m`,
--- visual moves, macros or <M-j>/<M-k>; change actions by editing the word or with <M-…>
--- keys; Vim undo works. Every change is re-parsed (150 ms): diagnostics for invalid lines,
--- markers for published commits and predicted conflicts, and a preview graph of the result.
--- `:w` (or <C-CR>) executes after a summary confirmation.
local base = require("trellis.view.base")
local config = require("trellis.config")
local debounce = require("trellis.util.debounce")
local glyphs = require("trellis.graph.glyphs")
local hl = require("trellis.highlights")
local layout = require("trellis.graph.layout")
local plan_mod = require("trellis.rebase.plan")
local simulate = require("trellis.rebase.simulate")

local M = {}

M.ns = vim.api.nvim_create_namespace("trellis.plan")
M.diag_ns = vim.api.nvim_create_namespace("trellis.plan.diagnostics")
M.mark_ns = vim.api.nvim_create_namespace("trellis.plan.marks")
M.preview_ns = vim.api.nvim_create_namespace("trellis.plan.preview")

---@type table<integer, table> plan views by buffer
M.views = {}

local SEVERITY = {
  error = vim.diagnostic.severity.ERROR,
  warn = vim.diagnostic.severity.WARN,
  info = vim.diagnostic.severity.INFO,
}

-- Preview ------------------------------------------------------------------------------------

local function render_preview(v, sim)
  local buf = v.preview_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local L = layout.new()
  local style = glyphs.resolve_style(config.get().graph.style)
  local lines, marks = {}, {}
  local list = vim.deepcopy(sim.commits)
  list[#list + 1] = { id = v.plan.base, subject = "(base)", parents = {}, changed = false }
  for i, c in ipairs(list) do
    for _, row in ipairs(L:push({ sha = c.id, parents = c.parents }, i)) do
      local text = glyphs.render(row, style)
      if row.kind == "commit" then
        local label = c.id:match("^new:") and "new    " or c.id:sub(1, 7)
        local folded = #(c.from or {}) > 1 and ("  (+%d folded)"):format(#c.from - 1) or ""
        text = ("%s %s %s%s"):format(text, label, c.subject or "", folded)
        if c.changed then
          marks[#marks + 1] = #lines
        end
      end
      lines[#lines + 1] = text
    end
  end
  if #sim.dropped > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("dropped: %s"):format(table.concat(
      vim.tbl_map(function(s)
        return s:sub(1, 7)
      end, sim.dropped),
      " "
    ))
  end
  for ref, id in pairs(sim.moved_refs) do
    lines[#lines + 1] = ("moves %s → %s"):format(
      ref:gsub("^refs/heads/", ""),
      id:match("^new:") and "new" or id:sub(1, 7)
    )
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, M.preview_ns, 0, -1)
  for _, l in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(
      buf,
      M.preview_ns,
      l,
      0,
      { line_hl_group = "TrellisPreviewChanged" }
    )
  end
end

-- Parsing and markers -------------------------------------------------------------------------

local function header(v, counts)
  local plan = v.plan
  local branch = plan.head_ref and plan.head_ref:gsub("^refs/heads/", "") or "detached HEAD"
  return {
    {
      { ("Rebase %s onto %s"):format(branch, plan.base:sub(1, 7)), "Title" },
      {
        ("  ·  %d commits, %d folded, %d dropped"):format(
          counts.commits,
          counts.squash,
          counts.drop
        ),
        "Comment",
      },
    },
    {
      {
        ":w execute · <M-j>/<M-k> move · <M-s>quash <M-f>ixup <M-r>eword <M-e>dit <M-d>rop · <M-m> message · g? keys",
        "Comment",
      },
    },
  }
end

local predict_token

local function show_risks(v, entries, risks)
  if not vim.api.nvim_buf_is_valid(v.bufnr) then
    return
  end
  v.risks = risks
  local buf = v.bufnr
  vim.api.nvim_buf_clear_namespace(buf, M.mark_ns, 0, -1)
  local n = vim.api.nvim_buf_line_count(buf)
  for i, e in ipairs(entries) do
    local chunks = {}
    if e.sha and v.plan.published[e.sha] then
      chunks[#chunks + 1] = { " published", "TrellisPlanPublished" }
    end
    local r = risks and risks[i]
    if r then
      local what = r.level == "conflict" and "⚠ conflict" or "⚠ may conflict"
      chunks[#chunks + 1] = {
        (" %s in %s"):format(what, table.concat(r.paths, ", ")),
        r.level == "conflict" and "TrellisPlanConflict" or "TrellisPlanRisk",
      }
    end
    if e.sha and v.plan.messages[e.sha] then
      chunks[#chunks + 1] = { " ✎ message", "Comment" }
    end
    if #chunks > 0 and e.lnum and e.lnum <= n then
      vim.api.nvim_buf_set_extmark(
        buf,
        M.mark_ns,
        e.lnum - 1,
        0,
        { virt_text = chunks, virt_text_pos = "eol" }
      )
    end
    if e.action == "drop" and e.lnum and e.lnum <= n then
      vim.api.nvim_buf_set_extmark(
        buf,
        M.mark_ns,
        e.lnum - 1,
        0,
        { line_hl_group = "TrellisPlanDrop" }
      )
    end
  end
  vim.b[buf].trellis_risks = vim.tbl_count(risks or {})
end

--- Re-parse the buffer: diagnostics, header, preview, prediction (async).
function M.update(v)
  local buf = v.bufnr
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local entries, diags = plan_mod.parse_lines(v.plan, lines)
  v.entries, v.diags = entries, diags
  local dl = {}
  for _, d in ipairs(diags) do
    if d.lnum > 0 then
      dl[#dl + 1] = {
        lnum = d.lnum - 1,
        col = 0,
        severity = SEVERITY[d.severity],
        message = d.message,
        source = "trellis",
      }
    end
  end
  vim.diagnostic.set(M.diag_ns, buf, dl)
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, M.ns, 0, 0, {
    virt_lines = header(v, plan_mod.summary(v.plan, entries)),
    virt_lines_above = true,
  })
  for _, e in ipairs(entries) do
    if e.lnum then
      local word = (lines[e.lnum] or ""):match("^%s*%S+") or ""
      vim.api.nvim_buf_set_extmark(
        buf,
        M.ns,
        e.lnum - 1,
        0,
        { end_col = #word, hl_group = "TrellisPlanAction" }
      )
    end
  end
  local sim = simulate.run(v.plan, entries)
  v.sim = sim
  render_preview(v, sim)
  show_risks(v, entries, v.risks_for_entries == vim.inspect(entries) and v.risks or nil)
  v.draft()
  local has_error = false
  for _, d in ipairs(diags) do
    if d.severity == "error" then
      has_error = true
    end
  end
  if has_error or not config.get().rebase.predict then
    return
  end
  if predict_token then
    predict_token.cancelled = true
  end
  local token = { cancelled = false }
  predict_token = token
  v.predicting = true
  require("trellis.safety.ops").spawn(function()
    return require("trellis.rebase.predict").predict(v.repo, v.plan, entries, token)
  end, function(risks)
    v.predicting = false
    if token.cancelled or not risks then
      return
    end
    v.risks_for_entries = vim.inspect(entries)
    vim.schedule(function()
      show_risks(v, entries, risks)
    end)
  end)
end

-- Editing helpers ---------------------------------------------------------------------------

local ACTION_WORDS =
  { "pick", "reword", "edit", "squash", "fixup", "drop", "p", "r", "e", "s", "f", "d", "F" }

local function set_action(buf, lnum, word)
  local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  local rest
  local first = line:match("^%s*(%S+)")
  if first == "fixup" and line:match("^%s*fixup %-[Cc] ") then
    rest = line:gsub("^%s*fixup %-[Cc]%s+", "")
  elseif first and vim.tbl_contains(ACTION_WORDS, first) then
    rest = line:gsub("^%s*%S+%s+", "")
  else
    return false
  end
  vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum, false, { word .. " " .. rest })
  return true
end

local function move_line(buf, delta)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local target = lnum + delta
  local n = vim.api.nvim_buf_line_count(buf)
  if target < 1 or target > n then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  lines[lnum], lines[target] = lines[target], lines[lnum]
  vim.api.nvim_buf_set_lines(buf, math.min(lnum, target) - 1, math.max(lnum, target), false, {
    lines[math.min(lnum, target)],
    lines[math.max(lnum, target)],
  })
  vim.api.nvim_win_set_cursor(0, { target, vim.api.nvim_win_get_cursor(0)[2] })
end

local function entry_at(v, lnum)
  for i, e in ipairs(v.entries or {}) do
    if e.lnum == lnum then
      return e, i
    end
  end
end

--- Scratch buffer to edit the planned message of the commit on `lnum` (chain head for folds).
local function edit_message(v, lnum)
  local e, i = entry_at(v, lnum)
  if not e or not e.sha then
    return
  end
  local head = plan_mod.chain_head(v.entries, i) or e.sha
  local function open(text)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(
      buf,
      ("trellis://plan/%s/message/%s"):format(v.plan.id, head:sub(1, 7))
    )
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].filetype = "gitcommit"
    vim.bo[buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(
      buf,
      0,
      -1,
      false,
      vim.split(text:gsub("\n$", ""), "\n", { plain = true })
    )
    vim.bo[buf].modified = false
    vim.cmd("belowright split")
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_win_set_height(0, 8)
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer = buf,
      callback = function()
        local msg = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
        v.plan.messages[head] = msg
        vim.bo[buf].modified = false
        -- A planned message on a plain pick makes it a reword.
        local he = nil
        for _, x in ipairs(v.entries) do
          if x.sha == head then
            he = x
          end
        end
        if he and he.action == "pick" and he.lnum then
          set_action(v.bufnr, he.lnum, "reword")
        end
        vim.notify("trellis: planned message saved for " .. head:sub(1, 7))
        M.update(v)
      end,
    })
  end
  if v.plan.messages[head] then
    return open(v.plan.messages[head])
  end
  require("trellis.git.details").get(v.repo, head, nil, function(err, d)
    open(err and (v.plan.subjects[head] or "") or d.body)
  end)
end

local function execute(v)
  M.update(v)
  require("trellis.actions.ui").run(v.repo, function()
    return require("trellis.rebase.execute").run(v.repo, v.plan, v.entries, v.diags)
  end, function(op)
    if
      op
      and (op.status == "done" or op.status == "stopped")
      and vim.api.nvim_buf_is_valid(v.bufnr)
    then
      vim.bo[v.bufnr].modified = false
      M.close(v)
    end
  end)
end

function M.close(v)
  if v.preview_win and vim.api.nvim_win_is_valid(v.preview_win) then
    pcall(vim.api.nvim_win_close, v.preview_win, true)
  end
  if vim.api.nvim_buf_is_valid(v.bufnr) then
    pcall(vim.api.nvim_buf_delete, v.bufnr, { force = true })
  end
end

local function handlers(v)
  local buf = v.bufnr
  local function act(word)
    return function()
      set_action(buf, vim.api.nvim_win_get_cursor(0)[1], word)
    end
  end
  local function insert_below(text)
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    vim.api.nvim_buf_set_lines(buf, lnum, lnum, false, { text })
    vim.api.nvim_win_set_cursor(0, { lnum + 1, 0 })
  end
  return {
    move_down = function()
      move_line(buf, 1)
    end,
    move_up = function()
      move_line(buf, -1)
    end,
    pick = act("pick"),
    reword = act("reword"),
    edit = act("edit"),
    squash = act("squash"),
    fixup = act("fixup"),
    fixup_C = act("fixup -C"),
    drop = act("drop"),
    exec = function()
      vim.ui.input({ prompt = "exec: " }, function(cmd)
        if cmd and cmd ~= "" then
          insert_below("exec " .. cmd)
        end
      end)
    end,
    ["break"] = function()
      insert_below("break")
    end,
    open_commit = function()
      local e = entry_at(v, vim.api.nvim_win_get_cursor(0)[1])
      if e and e.sha then
        require("trellis.view.commit").open(v.repo, e.sha)
      end
    end,
    message = function()
      edit_message(v, vim.api.nvim_win_get_cursor(0)[1])
    end,
    fixup_into = function()
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      local me = entry_at(v, lnum)
      if not me or not me.sha then
        return
      end
      local targets = vim.tbl_filter(function(e)
        return e.sha and e.sha ~= me.sha and e.action ~= "drop" and not plan_mod.FOLD[e.action]
      end, v.entries)
      vim.ui.select(targets, {
        prompt = "Fixup " .. me.sha:sub(1, 7) .. " into",
        format_item = function(e)
          return e.sha:sub(1, 7) .. " " .. (v.plan.subjects[e.sha] or "")
        end,
      }, function(t)
        if not t then
          return
        end
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local line = table.remove(lines, lnum)
        -- Below the target and the folds already attached to it.
        local at = t.lnum < lnum and t.lnum or t.lnum - 1
        while
          lines[at + 1]
          and plan_mod.FOLD[(require("trellis.git.parse.todo").parse_line(
            lines[at + 1],
            { trellis_aliases = true }
          ).action or "")]
        do
          at = at + 1
        end
        table.insert(lines, at + 1, line)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        set_action(buf, at + 1, "fixup")
        vim.api.nvim_win_set_cursor(0, { at + 1, 0 })
      end)
    end,
    execute = function()
      execute(v)
    end,
    close = function()
      vim.bo[buf].modified = false
      M.close(v)
    end,
  }
end

--- Mouse drag reorders lines: press on a line, release on another.
local function setup_mouse(v)
  local buf = v.bufnr
  local from
  vim.keymap.set("n", "<LeftDrag>", function()
    local pos = vim.fn.getmousepos()
    if pos.winid == vim.api.nvim_get_current_win() and not from then
      from = pos.line
    end
  end, { buffer = buf, desc = "trellis: drag to reorder" })
  vim.keymap.set("n", "<LeftRelease>", function()
    local pos = vim.fn.getmousepos()
    if from and pos.line > 0 and pos.line ~= from then
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local line = table.remove(lines, from)
      table.insert(lines, math.min(pos.line, #lines + 1), line)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.api.nvim_win_set_cursor(0, { math.min(pos.line, #lines), 0 })
    end
    from = nil
  end, { buffer = buf, desc = "trellis: drop to reorder" })
end

---@param repo trellis.Repository
---@param plan trellis.RebasePlanImpl
---@param opts? { on_open?: fun(v: table) }
function M.open(repo, plan, opts)
  opts = opts or {}
  hl.setup()
  local buf = base.create_buf({
    name = "trellis://plan/" .. plan.id,
    kind = "plan",
    filetype = "trellisplan",
    buftype = "acwrite",
    modifiable = true,
    bufhidden = "wipe",
    vars = { plan_id = plan.id, base = plan.base, stale = false },
  }, repo)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, plan_mod.to_lines(plan))
  vim.bo[buf].modified = false
  vim.bo[buf].undolevels = vim.o.undolevels
  vim.cmd("tab split")
  vim.api.nvim_win_set_buf(0, buf)
  local plan_win = vim.api.nvim_get_current_win()
  vim.wo[plan_win].wrap = false
  vim.wo[plan_win].number = true
  -- Preview on the right.
  local preview_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(preview_buf, "trellis://plan/" .. plan.id .. "/preview")
  vim.bo[preview_buf].filetype = "trellispreview"
  vim.cmd("rightbelow vsplit")
  local preview_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(preview_win, preview_buf)
  vim.wo[preview_win].wrap = false
  vim.wo[preview_win].number = false
  vim.wo[preview_win].winbar = " preview: history after the rebase"
  vim.api.nvim_set_current_win(plan_win)

  local drafts = require("trellis.rebase.execute").plan_dir(repo, plan)
  local v = {
    kind = "plan",
    bufnr = buf,
    repo = repo,
    plan = plan,
    preview_buf = preview_buf,
    preview_win = preview_win,
    state = {},
  }
  v.draft = function()
    require("trellis.util.fs").mkdirp(drafts)
    local f = io.open(drafts .. "/draft", "wb")
    if f then
      f:write(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), "\n")
      f:close()
    end
  end
  v.dispose = function()
    M.views[buf] = nil
    if vim.api.nvim_buf_is_valid(preview_buf) then
      pcall(vim.api.nvim_buf_delete, preview_buf, { force = true })
    end
  end
  M.views[buf] = v
  base.register(v)
  base.apply_keymaps(buf, "plan", handlers(v))
  setup_mouse(v)
  local reparse = debounce(150, function()
    M.update(v)
  end)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function()
      reparse()
    end,
  })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      execute(v)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      reparse:close()
    end,
  })
  M.update(v)
  if opts.on_open then
    opts.on_open(v)
  end
  return v
end

--- `:Trellis rebase <base>` / `gr`: build the plan and open it.
---@param repo trellis.Repository
---@param base_rev string
---@param opts? table plan options and on_open
function M.start(repo, base_rev, opts)
  opts = opts or {}
  local cfg = config.for_repo(repo.root).rebase
  local function auto(value, git_key)
    if value ~= "auto" then
      return value == true
    end
    local _, res = require("trellis.git.runner").run_sync(
      repo.root,
      { "config", "--bool", git_key },
      { ok_codes = { 1 } }
    )
    return res and vim.trim(res.stdout) == "true"
  end
  local plan_opts = {
    rebase_merges = opts.rebase_merges or cfg.rebase_merges,
    update_refs = repo.features.update_refs
      and auto(opts.update_refs == nil and cfg.update_refs or opts.update_refs, "rebase.updateRefs"),
    autosquash = auto(
      opts.autosquash == nil and cfg.autosquash or opts.autosquash,
      "rebase.autoSquash"
    ),
    order = cfg.order,
  }
  require("trellis.safety.ops").spawn(function()
    local err = require("trellis.safety.preflight").in_progress(repo)
    if err then
      return nil, err
    end
    require("trellis.util.async").await(function(cb)
      require("trellis.git.refs").load(repo, cb)
    end)
    return plan_mod.from_range(repo, base_rev, plan_opts)
  end, function(plan, err)
    vim.schedule(function()
      if err then
        return vim.notify("trellis: " .. err, vim.log.levels.ERROR)
      end
      M.open(repo, plan, { on_open = opts.on_open })
    end)
  end)
end

return M
