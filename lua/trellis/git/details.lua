--- Commit details (G11–G13) with an LRU cache (`perf.details_cache`, data-model CommitDetails).
local argv = require("trellis.git.argv")
local async = require("trellis.util.async")
local runner = require("trellis.git.runner")
local show = require("trellis.git.parse.show")

local M = {}

local cache = {} ---@type table<string, trellis.CommitDetails>
local order = {} ---@type string[]

local function key(repo, sha, against)
  return repo.commondir .. "\0" .. sha .. "\0" .. tostring(against)
end

local function remember(k, d)
  cache[k] = d
  order[#order + 1] = k
  local cap = require("trellis.config").get().perf.details_cache
  while #order > cap do
    cache[table.remove(order, 1)] = nil
  end
end

local function touch(k)
  for i = #order, 1, -1 do
    if order[i] == k then
      table.remove(order, i)
      break
    end
  end
  order[#order + 1] = k
end

local function run(repo, inv)
  return async.await(function(cb)
    runner.run(repo.root, inv.args, { kind = inv.kind, ok_codes = inv.ok_codes }, cb)
  end)
end

--- Details of `sha`, with files changed against `against` (nil = first parent / root;
--- a parent sha; "cc" = combined against all parents).
---@param repo trellis.Repository
---@param sha string full sha
---@param against? string
---@param cb fun(err: string?, d: trellis.CommitDetails?)
function M.get(repo, sha, against, cb)
  local k = key(repo, sha, against)
  if cache[k] then
    touch(k)
    return cb(nil, cache[k])
  end
  async.run(function()
    local err, res = run(repo, argv.G11(sha))
    if err then
      return err
    end
    local d = show.parse_details(res.stdout)
    if not d then
      return "cannot parse commit " .. sha
    end
    local vs = against
    if vs == nil and #d.parents > 1 then
      vs = d.parents[1]
    end
    local e1, numstat = run(repo, argv.G12(sha, vs))
    local e2, names = run(repo, argv.G13(sha, vs))
    if e1 or e2 then
      return e1 or e2
    end
    d.against = vs
    d.files =
      show.merge_changes(show.parse_numstat(numstat.stdout), show.parse_name_status(names.stdout))
    remember(k, d)
    return nil, d
  end, function(err, msg, d)
    cb(err or msg, d)
  end)
end

--- Resolve a revision to a full commit sha (G24).
---@param repo trellis.Repository
---@param rev string
---@param cb fun(err: string?, sha: string?)
function M.resolve(repo, rev, cb)
  local inv = argv.G24(rev)
  runner.run(repo.root, inv.args, { kind = inv.kind, ok_codes = inv.ok_codes }, function(err, res)
    local sha = res and res.code == 0 and vim.trim(res.stdout) or nil
    if err or not sha or sha == "" then
      return cb(("unknown revision %q"):format(rev))
    end
    cb(nil, sha)
  end)
end

function M._clear()
  cache, order = {}, {}
end

return M
