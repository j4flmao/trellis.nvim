--- Conflict prediction for a plan without touching the worktree.
---
--- Exact (git ≥ 2.40): apply the plan in memory — for each commit, `git merge-tree
--- --write-tree --merge-base=<c>^ <tip> <c>` (a cherry-pick of c onto the simulated tip), then
--- `git commit-tree` the result to get the next tip. Exit 1 = conflict, with the paths. The
--- temporary objects are unreferenced (git's own gc removes them; trellis never runs gc).
--- Results are cached by (base, ordered prefix), so editing the end of a plan only re-runs
--- the end. After the first conflict, and beyond `rebase.predict_max` entries, or on older
--- git: a heuristic — reordered commits that touch overlapping lines of the same file.
local argv = require("trellis.git.argv")
local backup = require("trellis.safety.backup")
local diff = require("trellis.git.parse.diff")
local plan_mod = require("trellis.rebase.plan")

local M = {}

M.cache = {} ---@type table<string, { tip: string?, conflict: string[]? }>
M.hunk_cache = {} ---@type table<string, table<string, {integer, integer}[]>>

local function git(repo, inv)
  return backup.git(repo, inv)
end

--- Changed line ranges per path of a commit (old side), cached. Inside async.
local function ranges(repo, sha)
  if M.hunk_cache[sha] then
    return M.hunk_cache[sha]
  end
  local _, res = git(repo, argv.G45(sha))
  local out = {}
  for _, f in ipairs(diff.parse(res and res.stdout or "")) do
    local path = f.old_path or f.new_path
    if path then
      local list = {}
      for _, h in ipairs(f.hunks) do
        list[#list + 1] = { h.old_start, h.old_start + math.max(h.old_count, 1) - 1 }
      end
      out[path] = list
    end
  end
  M.hunk_cache[sha] = out
  return out
end

local function ranges_overlap(ra, rb)
  for _, x in ipairs(ra) do
    for _, y in ipairs(rb) do
      if x[1] <= y[2] + 1 and y[1] <= x[2] + 1 then
        return true
      end
    end
  end
  return false
end

local function overlap(a, b)
  local paths = {}
  for path, ra in pairs(a) do
    if b[path] and ranges_overlap(ra, b[path]) then
      paths[#paths + 1] = path
    end
  end
  table.sort(paths)
  return paths
end

--- Parse `merge-tree --write-tree --name-only -z` stdout: tree, conflicted paths.
function M.parse_merge_tree(out)
  local fields = vim.split(out, "\0", { plain = true })
  local tree = fields[1]
  local paths = {}
  for i = 2, #fields do
    if fields[i] == "" then
      break
    end
    paths[#paths + 1] = fields[i]
  end
  return tree, paths
end

---@class trellis.Risk
---@field level "conflict"|"possible"
---@field paths string[]
---@field exact boolean

--- Risks by entry index. Inside async.run. `token.cancelled` stops early (returns nil).
---@param repo trellis.Repository
---@param plan trellis.RebasePlanImpl
---@param entries trellis.PlanEntry[]
---@param token? { cancelled: boolean }
---@return table<integer, trellis.Risk>?
function M.predict(repo, plan, entries, token)
  token = token or {}
  local risks = {}
  local cfg = require("trellis.config").get().rebase
  local exact_until = 0
  if repo.features.merge_tree_base then
    local tip, prev_tip = plan.base, nil
    local prefix = plan.base
    local count = 0
    for i, e in ipairs(entries) do
      if token.cancelled then
        return nil
      end
      if plan_mod.COMMIT[e.action] and e.action ~= "drop" then
        count = count + 1
        if count > cfg.predict_max then
          break
        end
        local fold = plan_mod.FOLD[e.action]
        local key = prefix .. ";" .. (fold and "f" or "p") .. e.sha
        local r = M.cache[key]
        if not r then
          local err, res = git(repo, argv.G43(e.sha, tip))
          if res and res.code == 1 then
            local _, paths = M.parse_merge_tree(res.stdout)
            r = { conflict = paths }
          elseif err or not res then
            r = { error = err or "merge-tree failed" }
          else
            local tree = M.parse_merge_tree(res.stdout)
            local parent = fold and (prev_tip or plan.base) or tip
            local cerr, cres = git(repo, argv.G44(tree, parent))
            r = cerr and { error = cerr } or { tip = vim.trim(cres.stdout), parent = parent }
          end
          M.cache[key] = r
        end
        if r.conflict then
          risks[i] = { level = "conflict", paths = r.conflict, exact = true }
          exact_until = i
          break
        elseif r.error then
          break
        end
        if not fold then
          prev_tip = tip
        end
        tip = r.tip
        prefix = key
        exact_until = i
      end
    end
  end
  -- Heuristic for the rest: a commit now applied after one it originally preceded, touching
  -- the same lines.
  local index = {}
  for i, sha in ipairs(plan.original) do
    index[sha] = i
  end
  for i = exact_until + 1, #entries do
    if token.cancelled then
      return nil
    end
    local e = entries[i]
    if e.sha and plan_mod.COMMIT[e.action] and e.action ~= "drop" and not risks[i] then
      for j = 1, i - 1 do
        local p = entries[j]
        if
          p.sha
          and p.action ~= "drop"
          and index[p.sha]
          and index[e.sha]
          and index[p.sha] > index[e.sha]
        then
          local paths = overlap(ranges(repo, e.sha), ranges(repo, p.sha))
          if #paths > 0 then
            risks[i] = { level = "possible", paths = paths, exact = false }
            break
          end
        end
      end
    end
  end
  return risks
end

return M
