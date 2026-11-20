--- Configuration: defaults, validation, suggestions.
local M = {}

---@class trellis.Config
M.defaults = {
  git = {
    cmd = "git",
    timeout_ms = 30000,
  },
  graph = {
    style = "rounded",
    order = "topo",
    default_revs = { "--branches", "--remotes", "--tags", "HEAD" },
    show_stashes = false,
    show_backups = false,
    max_lanes = 40,
    date_format = "relative",
    max_decorations = 3,
    open = "tab",
    uncommitted = true,
  },
  perf = {
    page_size = 2000,
    prefetch_rows = 3000,
    fast_first_screen = true,
    write_commit_graph = false,
    details_cache = 512,
  },
  views = {
    commit = { split = "vertical" },
    diff = { side_by_side = "auto", open = "replace" },
    filerev = { max_size = 5 * 1024 * 1024 },
  },
  blame = {
    ignore_whitespace = true,
    detect_moves = "file",
    ignore_revs_file = "auto",
    width = 40,
    heat = true,
  },
  rebase = {
    order = "oldest_first",
    rebase_merges = false,
    update_refs = "auto",
    autosquash = "auto",
    predict = true,
    predict_max = 200,
    keep_drafts_days = 7,
  },
  safety = {
    confirm = "destructive",
    autostash = "ask",
    backup_retention_days = 30,
    backup_max_ops = 200,
    auto_prune = false,
  },
  permalink = {
    remote = "origin",
    patterns = {},
  },
  pick = {
    backend = "auto",
    limit = 20000,
  },
  keymaps = true,
}

--- Fields whose accepted values are not simply "same type as the default".
--- `types`: accepted Lua types; `enum`: accepted values (for strings); `free`: any table content.
local schema = {
  ["graph.style"] = { enum = { "ascii", "unicode", "rounded", "flog-symbols" } },
  ["graph.order"] = { enum = { "topo", "date" } },
  ["graph.open"] = { enum = { "tab", "vertical", "horizontal", "current" } },
  ["graph.uncommitted"] = { types = { "boolean" } },
  ["graph.default_revs"] = { list_of = "string" },
  ["views.commit.split"] = { enum = { "vertical", "horizontal", "tab", "current" } },
  ["views.diff.side_by_side"] = { types = { "string" } }, -- "auto" | "never" | adapter name
  ["views.diff.open"] = { types = { "string" }, enum = { "replace", "split" } },
  ["blame.detect_moves"] = { types = { "boolean", "string" }, enum = { false, "file", "copies" } },
  ["blame.ignore_revs_file"] = { types = { "string", "boolean" } },
  ["rebase.order"] = { enum = { "oldest_first", "newest_first" } },
  ["rebase.update_refs"] = { types = { "boolean", "string" }, enum = { true, false, "auto" } },
  ["rebase.autosquash"] = { types = { "boolean", "string" }, enum = { true, false, "auto" } },
  ["safety.confirm"] = { enum = { "always", "destructive", "never" } },
  ["safety.autostash"] = { enum = { "ask", "always", "never" } },
  ["permalink.patterns"] = { free = true },
  ["pick.backend"] = { enum = { "auto", "snacks", "telescope", "fzf-lua", "select" } },
  ["keymaps"] = { types = { "boolean", "table" }, free = true },
}

---@type trellis.Config
local current = vim.deepcopy(M.defaults)

--- Levenshtein distance, for "did you mean" suggestions.
local function distance(a, b)
  local prev = {}
  for j = 0, #b do
    prev[j] = j
  end
  for i = 1, #a do
    local cur = { [0] = i }
    for j = 1, #b do
      local cost = a:sub(i, i) == b:sub(j, j) and 0 or 1
      cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
    end
    prev = cur
  end
  return prev[#b]
end

local function suggest(key, candidates)
  local best, best_d
  for cand in pairs(candidates) do
    local d = distance(key, cand)
    if not best_d or d < best_d or (d == best_d and cand < best) then
      best, best_d = cand, d
    end
  end
  if best and best_d <= math.max(2, math.floor(#key / 3)) then
    return best
  end
end

local function fmt_value(v)
  return type(v) == "string" and ("%q"):format(v) or tostring(v)
end

local function check_value(path, value, default, problems)
  local rule = schema[path]
  local ok_type
  if rule and rule.types then
    ok_type = vim.tbl_contains(rule.types, type(value))
  else
    ok_type = type(value) == type(default)
  end
  if not ok_type then
    local expected = rule and rule.types and table.concat(rule.types, "|") or type(default)
    problems[#problems + 1] = ("%s: expected %s, got %s"):format(path, expected, type(value))
    return false
  end
  if rule and rule.list_of then
    for i, item in ipairs(value) do
      if type(item) ~= rule.list_of or (rule.enum and not vim.tbl_contains(rule.enum, item)) then
        problems[#problems + 1] = ("%s[%d]: invalid value %s"):format(path, i, fmt_value(item))
        return false
      end
    end
    return true
  end
  if rule and rule.enum and type(value) ~= "table" and not vim.tbl_contains(rule.enum, value) then
    local names = vim.tbl_map(fmt_value, rule.enum)
    problems[#problems + 1] = ("%s: expected one of %s, got %s"):format(
      path,
      table.concat(names, ", "),
      fmt_value(value)
    )
    return false
  end
  if type(value) == "number" and value < 0 then
    problems[#problems + 1] = ("%s: must not be negative"):format(path)
    return false
  end
  return true
end

--- Merge `opts` over `base` following `defaults`, collecting problems. Invalid values keep the
--- default; unknown keys are dropped with a suggestion.
local function merge(base, opts, defaults, prefix, problems)
  for key, value in pairs(opts) do
    local path = prefix == "" and key or (prefix .. "." .. key)
    local default = defaults[key]
    if default == nil then
      local hint = type(key) == "string" and suggest(key, defaults)
      problems[#problems + 1] = ("unknown option %s%s"):format(
        path,
        hint and (" (did you mean %s?)"):format(prefix == "" and hint or (prefix .. "." .. hint))
          or ""
      )
    elseif
      type(default) == "table"
      and not vim.islist(default)
      and not (schema[path] and schema[path].free)
      and next(default) ~= nil
    then
      if type(value) ~= "table" then
        problems[#problems + 1] = ("%s: expected table, got %s"):format(path, type(value))
      else
        merge(base[key], value, default, path, problems)
      end
    elseif check_value(path, value, default, problems) then
      base[key] = type(value) == "table" and vim.deepcopy(value) or value
    end
  end
end

--- Validate and merge user options. Returns the list of problems (also notified).
---@param opts? table
---@return string[] problems
function M.setup(opts)
  local cfg = vim.deepcopy(M.defaults)
  local problems = {}
  if opts ~= nil and type(opts) ~= "table" then
    problems[1] = "setup(): expected a table, got " .. type(opts)
  elseif opts then
    merge(cfg, opts, M.defaults, "", problems)
  end
  current = cfg
  M.problems = problems -- reported again by :checkhealth trellis
  if #problems > 0 then
    vim.notify(
      "trellis: configuration problems (defaults used):\n  " .. table.concat(problems, "\n  "),
      vim.log.levels.WARN
    )
  end
  return problems
end

--- Current configuration (do not mutate).
---@return trellis.Config
function M.get()
  return current
end

--- Configuration for a repository: `vim.g.trellis_repo_config[root]` merged over `get()`.
---@param root string
---@return trellis.Config
function M.for_repo(root)
  local per_repo = vim.g.trellis_repo_config
  local overrides = type(per_repo) == "table" and per_repo[root]
  if type(overrides) ~= "table" then
    return current
  end
  local cfg = vim.deepcopy(current)
  local problems = {}
  merge(cfg, overrides, M.defaults, "", problems)
  if #problems > 0 then
    vim.notify(
      ("trellis: vim.g.trellis_repo_config[%q]:\n  %s"):format(root, table.concat(problems, "\n  ")),
      vim.log.levels.WARN
    )
  end
  return cfg
end

return M
