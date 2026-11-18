--- `:Trellis` arguments ↔ GraphQuery (data-model.md). Git-compatible option spelling.
local M = {}

---@class trellis.GraphQuery
---@field revs string[]
---@field paths string[]
---@field author? string
---@field since? string
---@field until? string
---@field grep? string
---@field pickaxe? { mode: "S"|"G", value: string }
---@field first_parent boolean
---@field order "topo"|"date"|"default"
---@field max_count? integer
---@field default_revs boolean  revs came from config.graph.default_revs

local VALUE_OPTS = { author = "author", since = "since", ["until"] = "until", grep = "grep" }

--- Parse `:Trellis [graph] ...` arguments.
---@param args string[]
---@param cfg trellis.Config
---@return trellis.GraphQuery? query, string? err
function M.parse(args, cfg)
  local q = {
    revs = {},
    paths = {},
    first_parent = false,
    order = cfg.graph.order == "date" and "date" or "topo",
    default_revs = false,
  }
  local i, after_dd = 1, false
  while i <= #args do
    local a = args[i]
    if after_dd then
      q.paths[#q.paths + 1] = a
    elseif a == "--" then
      after_dd = true
    elseif a == "--first-parent" then
      q.first_parent = true
    elseif a == "--date-order" then
      q.order = "date"
    elseif a == "--topo-order" then
      q.order = "topo"
    elseif a == "-i" or a == "--regexp-ignore-case" then
      q.ignore_case = true
    elseif a:match("^%-[SG]") then
      local mode, value = a:sub(2, 2), a:sub(3)
      if value == "" then
        i = i + 1
        value = args[i]
        if not value then
          return nil, ("%s needs a value"):format(a)
        end
      end
      q.pickaxe = { mode = mode, value = (value:gsub('^"(.*)"$', "%1")) }
    elseif a:match("^%-%-max%-count=%d+$") then
      q.max_count = tonumber(a:match("=(%d+)$"))
    elseif a == "-n" then
      i = i + 1
      q.max_count = tonumber(args[i])
      if not q.max_count then
        return nil, "-n needs a number"
      end
    elseif a:match("^%-%-[%w-]+=") then
      local name, value = a:match("^%-%-([%w-]+)=(.*)$")
      local field = VALUE_OPTS[name]
      if not field then
        return nil, ("unknown option --%s"):format(name)
      end
      q[field] = value
    elseif a:sub(1, 1) == "-" then
      return nil, ("unknown option %s"):format(a)
    else
      q.revs[#q.revs + 1] = a
    end
    i = i + 1
  end
  if #q.revs == 0 then
    q.revs = vim.deepcopy(cfg.graph.default_revs)
    q.default_revs = true
  end
  return q
end

--- Filters that drop commits without git rewriting parents (author, dates, grep, pickaxe,
--- max count): their %P points at commits that may not be shown.
---@param q trellis.GraphQuery
function M.has_commit_filters(q)
  return q.author ~= nil
    or q.since ~= nil
    or q["until"] ~= nil
    or q.grep ~= nil
    or q.pickaxe ~= nil
    or q.max_count ~= nil
end

local function quote(s)
  if s:find("[%s\"']") then
    return '"' .. s:gsub('"', '\\"') .. '"'
  end
  return s
end

--- Back to `:Trellis` argument text (the F filter editor shows it).
---@param q trellis.GraphQuery
---@return string
function M.to_args(q)
  local parts = {}
  if not q.default_revs then
    vim.list_extend(parts, vim.tbl_map(quote, q.revs))
  end
  for _, k in ipairs({ "author", "since", "until", "grep" }) do
    if q[k] then
      parts[#parts + 1] = "--" .. k .. "=" .. quote(q[k])
    end
  end
  if q.pickaxe then
    parts[#parts + 1] = "-" .. q.pickaxe.mode .. quote(q.pickaxe.value)
  end
  if q.ignore_case then
    parts[#parts + 1] = "-i"
  end
  if q.first_parent then
    parts[#parts + 1] = "--first-parent"
  end
  if q.order == "date" then
    parts[#parts + 1] = "--date-order"
  end
  if q.max_count then
    parts[#parts + 1] = "--max-count=" .. q.max_count
  end
  if #q.paths > 0 then
    parts[#parts + 1] = "--"
    vim.list_extend(parts, vim.tbl_map(quote, q.paths))
  end
  return table.concat(parts, " ")
end

--- Split filter text like a shell would for these arguments (double quotes group words).
---@param text string
---@return string[]
function M.split_args(text)
  local args, cur, inq, have = {}, {}, false, false
  local i = 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == "\\" and inq and text:sub(i + 1, i + 1) == '"' then
      cur[#cur + 1] = '"'
      i = i + 1
    elseif c == '"' then
      inq = not inq
      have = true
    elseif c:match("%s") and not inq then
      if have or #cur > 0 then
        args[#args + 1] = table.concat(cur)
      end
      cur, have = {}, false
    else
      cur[#cur + 1] = c
    end
    i = i + 1
  end
  if have or #cur > 0 then
    args[#args + 1] = table.concat(cur)
  end
  return args
end

--- True when anything narrows history beyond revisions.
---@param q trellis.GraphQuery
function M.has_filters(q)
  return #q.paths > 0
    or q.author ~= nil
    or q.since ~= nil
    or q["until"] ~= nil
    or q.grep ~= nil
    or q.pickaxe ~= nil
    or q.first_parent
    or q.max_count ~= nil
end

--- Short labels for the winbar ("chips").
---@param q trellis.GraphQuery
---@return string[]
function M.describe(q)
  local chips = {}
  if not q.default_revs then
    chips[#chips + 1] = table.concat(q.revs, " ")
  end
  for _, k in ipairs({ "author", "since", "until", "grep" }) do
    if q[k] then
      chips[#chips + 1] = k .. ":" .. q[k]
    end
  end
  if q.pickaxe then
    chips[#chips + 1] = "-" .. q.pickaxe.mode .. q.pickaxe.value
  end
  if q.first_parent then
    chips[#chips + 1] = "first-parent"
  end
  if q.ignore_case then
    chips[#chips + 1] = "ignore-case"
  end
  if q.order == "date" then
    chips[#chips + 1] = "date-order"
  end
  if q.max_count then
    chips[#chips + 1] = "max:" .. q.max_count
  end
  if #q.paths > 0 then
    chips[#chips + 1] = "-- " .. table.concat(q.paths, " ")
  end
  return chips
end

return M
