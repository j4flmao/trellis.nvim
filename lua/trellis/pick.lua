--- Find a commit with the picker you already use: Snacks, Telescope or fzf-lua (`pick.backend`,
--- "auto" tries them in that order), else |vim.ui.select()|. Commits come from the same history
--- command as the graph (G10, newest first, at most `pick.limit`). Choosing one jumps to it in
--- the graph when the picker was opened from a graph, else opens its commit view.
local argv = require("trellis.git.argv")
local config = require("trellis.config")
local log = require("trellis.git.parse.log")
local query = require("trellis.graph.query")
local runner = require("trellis.git.runner")
local time = require("trellis.util.time")

local M = {}

---@class trellis.PickItem
---@field sha string
---@field subject string
---@field author string
---@field time integer
---@field text string  what pickers match and show: "<short sha> <subject>  <author>, <date>"

--- Picker items for parsed commits.
---@param commits trellis.LogCommit[]
---@return trellis.PickItem[]
function M.items(commits)
  local out = {}
  for i, c in ipairs(commits) do
    local subject = (c.subject or ""):gsub("%c", " ")
    local when = time.format(c.time, "relative")
    out[i] = {
      sha = c.sha,
      subject = subject,
      author = c.author or "",
      time = c.time or 0,
      text = ("%s %s  %s, %s"):format(c.sha:sub(1, 7), subject, c.author or "", when),
    }
  end
  return out
end

--- Commits of `repo` for the picker. `cb(err, items)`.
---@param repo trellis.Repository
---@param cb fun(err: string?, items: trellis.PickItem[]?)
function M.load(repo, cb)
  local cfg = config.for_repo(repo.root)
  local q = assert(query.parse({}, cfg))
  q.order = "default"
  q.max_count = cfg.pick.limit
  if repo.refs and not repo.refs.head.sha then -- unborn HEAD: `git log HEAD` would fail
    q.revs = vim.tbl_filter(function(r)
      return r ~= "HEAD"
    end, q.revs)
  end
  local inv = argv.G10(q)
  runner.run(repo.root, inv.args, { kind = inv.kind }, function(err, res)
    if err then
      return cb(err)
    end
    cb(nil, M.items(log.parse(res.stdout)))
  end)
end

local function has(mod)
  local ok = pcall(require, mod)
  return ok
end

--- The backend `pick.backend` resolves to on this setup.
---@return "snacks"|"telescope"|"fzf-lua"|"select"
function M.backend(name)
  name = name or config.get().pick.backend
  if name ~= "auto" then
    return name
  end
  local snacks = package.loaded.snacks
  if type(snacks) == "table" and snacks.picker then
    return "snacks"
  elseif has("telescope.pickers") then
    return "telescope"
  elseif has("fzf-lua") then
    return "fzf-lua"
  end
  return "select"
end

local backends = {}

function backends.snacks(items, title, choose)
  package.loaded.snacks.picker.pick({
    source = "trellis_commits",
    title = title,
    items = items,
    layout = { preset = "select" },
    format = function(item)
      return {
        { item.sha:sub(1, 7), "TrellisSha" },
        { " " .. item.subject },
        { "  " .. item.author .. ", " .. time.format(item.time, "relative"), "Comment" },
      }
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        choose(item)
      end
    end,
  })
end

function backends.telescope(items, title, choose)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local state = require("telescope.actions.state")
  pickers
    .new({}, {
      prompt_title = title,
      finder = finders.new_table({
        results = items,
        entry_maker = function(item)
          return { value = item, display = item.text, ordinal = item.text }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(bufnr)
        actions.select_default:replace(function()
          local entry = state.get_selected_entry()
          actions.close(bufnr)
          if entry then
            choose(entry.value)
          end
        end)
        return true
      end,
    })
    :find()
end

backends["fzf-lua"] = function(items, title, choose)
  local by_text = {}
  local lines = {}
  for i, item in ipairs(items) do
    lines[i] = item.text
    by_text[item.text] = item
  end
  require("fzf-lua").fzf_exec(lines, {
    prompt = title .. "> ",
    actions = {
      default = function(selected)
        local item = selected and by_text[selected[1]]
        if item then
          choose(item)
        end
      end,
    },
  })
end

function backends.select(items, title, choose)
  vim.ui.select(items, {
    prompt = title,
    format_item = function(item)
      return item.text
    end,
  }, function(item)
    if item then
      choose(item)
    end
  end)
end

--- Pick a commit of `repo`; `on_choose(sha)` defaults to "show it".
---@param repo trellis.Repository
---@param opts? { backend?: string, on_choose?: fun(sha: string), from_graph?: table }
function M.pick(repo, opts)
  opts = opts or {}
  local name = M.backend(opts.backend)
  local run = backends[name]
  if not run then
    return vim.notify("trellis: unknown pick.backend " .. tostring(name), vim.log.levels.ERROR)
  end
  M.load(repo, function(err, items)
    if err then
      return vim.notify("trellis: " .. err, vim.log.levels.ERROR)
    end
    if #items == 0 then
      return vim.notify("trellis: no commits")
    end
    local choose = opts.on_choose
      or function(sha)
        if opts.from_graph then
          require("trellis.view.graph").goto_sha(opts.from_graph, sha)
        else
          require("trellis.view.commit").open(repo, sha)
        end
      end
    run(items, "Commits", function(item)
      choose(item.sha)
    end)
  end)
end

return M
