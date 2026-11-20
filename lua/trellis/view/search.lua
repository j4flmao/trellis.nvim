--- `g/` in the graph: search the whole history, not just the loaded rows.
---
--- Text searches commit messages (`--grep`, smart case); `-S<string>` / `-G<regex>` search
--- content changes (pickaxe). Results stream into a buffer with progress in its winbar;
--- <C-c> stops the search. <CR> jumps to the commit in the graph (loading history up to it).
local argv = require("trellis.git.argv")
local base = require("trellis.view.base")
local log = require("trellis.git.parse.log")
local stream = require("trellis.git.stream")

local M = {}

M.ns = vim.api.nvim_create_namespace("trellis.search")
local counter = 0

--- GraphQuery for a search typed in the prompt, scoped to the graph's revisions and paths.
---@param gq trellis.GraphQuery
---@param text string
---@return trellis.GraphQuery
function M.query_for(gq, text)
  local q = {
    revs = vim.deepcopy(gq.revs),
    paths = vim.deepcopy(gq.paths),
    first_parent = gq.first_parent,
    order = "default", -- results do not need topological order: stream them as found
  }
  local mode, value = text:match("^%-([SG])(.+)$")
  if mode then
    q.pickaxe = { mode = mode, value = (value:gsub('^"(.*)"$', "%1")) }
  else
    q.grep = text
    q.ignore_case = not text:find("%u") -- smart case
  end
  return q
end

local function sanitize(s)
  return s:find("%c") and vim.fn.strtrans(s) or s
end

---@param v trellis.GraphView graph the search was started from
---@param text string
---@param opts? { on_open?: fun(s: table) }
function M.open(v, text, opts)
  opts = opts or {}
  counter = counter + 1
  local q = M.query_for(v.query, text)
  local buf = base.create_buf({
    name = ("trellis://search/%d/%s"):format(counter, text),
    kind = "search",
    filetype = "trellissearch",
  }, v.repo)
  base.open_slot(buf, "horizontal", "search")
  local win = vim.api.nvim_get_current_win()
  vim.wo[win].wrap = false
  local s = { bufnr = buf, graph = v, shas = {}, status = "searching", text = text }
  local function winbar()
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    local status = s.status == "searching" and "searching…"
      or s.status == "cancelled" and "cancelled"
      or s.status == "error" and ("failed: " .. (s.error or ""))
      or "done"
    vim.wo[win].winbar = (" search %q · %d match%s · %s"):format(
      text:gsub("%%", "%%%%"),
      #s.shas,
      #s.shas == 1 and "" or "es",
      status
    )
  end
  local function set_lines(lines)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    vim.bo[buf].modifiable = true
    local first = #s.shas - #lines
    vim.api.nvim_buf_set_lines(
      buf,
      first == 0 and 0 or first,
      first == 0 and -1 or first,
      false,
      lines
    )
    vim.bo[buf].modifiable = false
    for i = first, #s.shas - 1 do
      vim.api.nvim_buf_set_extmark(buf, M.ns, i, 0, { end_col = 7, hl_group = "TrellisSha" })
    end
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "searching…" })
  vim.bo[buf].modifiable = false
  winbar()

  local parser = log.new_parser()
  local function add(commits)
    if #commits == 0 then
      return
    end
    local lines = {}
    for _, c in ipairs(commits) do
      s.shas[#s.shas + 1] = c.sha
      lines[#lines + 1] = ("%s %s %s  %s"):format(
        c.sha:sub(1, 7),
        os.date("%Y-%m-%d", c.time),
        sanitize(c.author),
        sanitize(c.subject)
      )
    end
    set_lines(lines)
    winbar()
  end
  local inv = argv.G10(q)
  s.stream = stream.start(v.repo.root, inv.args, {
    kind = inv.kind,
    on_records = function(recs)
      add(parser.push(recs))
    end,
    on_exit = function(code, stderr)
      add(parser.finish())
      if s.status == "searching" then
        s.status = code == 0 and "done" or "error"
        s.error = vim.trim(stderr or ""):match("^[^\n]*")
      end
      if #s.shas == 0 and vim.api.nvim_buf_is_valid(buf) then
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(
          buf,
          0,
          -1,
          false,
          { s.status == "cancelled" and "(cancelled)" or "(no matches)" }
        )
        vim.bo[buf].modifiable = false
      end
      winbar()
    end,
  })
  local function sha_at()
    return s.shas[vim.api.nvim_win_get_cursor(0)[1]]
  end
  local view = {
    kind = "search",
    bufnr = buf,
    repo = v.repo,
    state = s,
    dispose = function()
      if s.stream then
        s.stream.kill()
      end
    end,
  }
  base.register(view)
  base.apply_keymaps(buf, "search", {
    close = function()
      if #vim.api.nvim_list_wins() > 1 then
        vim.cmd("close")
      else
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end,
    cancel = function()
      if s.status == "searching" then
        s.status = "cancelled"
        s.stream.kill()
        winbar()
      end
    end,
    show_in_graph = function()
      local sha = sha_at()
      if not sha then
        return
      end
      local gwin = vim.fn.bufwinid(v.bufnr)
      if gwin == -1 then
        return vim.notify("trellis: the graph of this search is closed")
      end
      vim.api.nvim_set_current_win(gwin)
      require("trellis.view.graph").goto_sha(v, sha)
    end,
    open_commit = function()
      local sha = sha_at()
      if sha then
        require("trellis.view.commit").open(v.repo, sha)
      end
    end,
  })
  if opts.on_open then
    opts.on_open(s)
  end
  return s
end

--- Ask for the search text, then open the results.
function M.prompt(v)
  vim.ui.input(
    { prompt = "Search all history (message text, or -S<string> / -G<regex>): " },
    function(text)
      if text and text ~= "" then
        M.open(v, text)
      end
    end
  )
end

return M
