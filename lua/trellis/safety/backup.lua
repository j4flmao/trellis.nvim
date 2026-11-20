--- Snapshots and backup refs.
---
--- Before an operation moves refs, trellis records their raw values and writes
--- `refs/trellis/backup/<op-id>/<refname without "refs/">` (plus `/HEAD` and, when uncommitted
--- changes would be discarded, `/stash` from `git stash create`) in one atomic
--- `update-ref --stdin` transaction. Refs keep the objects alive and can be inspected with
--- plain git.
local argv = require("trellis.git.argv")
local async = require("trellis.util.async")
local runner = require("trellis.git.runner")

local M = {}

M.prefix = "refs/trellis/backup/"

--- Run an invocation inside async.run; returns err, result.
function M.git(repo, inv, extra)
  return async.await(function(cb)
    local opts = { kind = inv.kind, ok_codes = inv.ok_codes, stdin = inv.stdin }
    for k, v in pairs(extra or {}) do
      opts[k] = v
    end
    runner.run(repo.root, inv.args, opts, cb)
  end)
end

---@class trellis.HeadState
---@field sha string?       nil on an unborn branch
---@field symbolic string?  refs/heads/x when attached

--- Current values of `refnames` (absent refs are missing from the map) and HEAD. Async.
---@param repo trellis.Repository
---@param refnames string[]
---@return table<string, string> values, trellis.HeadState head
function M.read_refs(repo, refnames)
  local values = {}
  if #refnames > 0 then
    local _, res = M.git(repo, argv.G09(refnames))
    for line in ((res and res.stdout) or ""):gmatch("[^\n]+") do
      local name, sha = line:match("^(.-)%z(%x+)$")
      -- for-each-ref patterns also match prefixes (refs/heads/a matches refs/heads/a/b).
      if name and vim.tbl_contains(refnames, name) then
        values[name] = sha
      end
    end
  end
  local _, sym = M.git(repo, argv.G05("symbolic"))
  local _, sha = M.git(repo, argv.G05("sha"))
  return values,
    {
      symbolic = sym and sym.code == 0 and vim.trim(sym.stdout) or nil,
      sha = sha and sha.code == 0 and vim.trim(sha.stdout) or nil,
    }
end

--- `git stash create`: a stash commit of uncommitted tracked changes, without touching the
--- worktree. Returns nil when there is nothing to save. Async.
---@return string? sha, string? err
function M.stash_create(repo)
  local err, res = M.git(repo, argv.W02())
  if err then
    return nil, err
  end
  local sha = vim.trim(res.stdout)
  return sha ~= "" and sha or nil
end

--- Backup ref name for `refname` of operation `id`.
function M.ref_for(id, refname)
  if refname == "HEAD" or refname == "stash" then
    return M.prefix .. id .. "/" .. refname
  end
  return M.prefix .. id .. "/" .. refname:gsub("^refs/", "")
end

--- Write backup refs for an operation's "before" state. Async.
---@param op table with id, before, before_head, stash
---@return string? err
function M.write(repo, op)
  local lines = { "start" }
  for refname, sha in pairs(op.before) do
    lines[#lines + 1] = ("create %s %s"):format(M.ref_for(op.id, refname), sha)
  end
  if op.before_head.sha then
    lines[#lines + 1] = ("create %s %s"):format(M.ref_for(op.id, "HEAD"), op.before_head.sha)
  end
  if op.stash then
    lines[#lines + 1] = ("create %s %s"):format(M.ref_for(op.id, "stash"), op.stash)
  end
  if #lines == 1 then
    return nil
  end
  lines[#lines + 1] = "commit"
  local err = M.git(repo, argv.W01(lines), { op_id = op.id })
  return err
end

--- Backup refs of an operation (for prune). Async.
---@return string[]
function M.list(repo, id)
  local _, res = M.git(repo, argv.G16(M.prefix .. id .. "/"))
  local out = {}
  for line in ((res and res.stdout) or ""):gmatch("[^\n]+") do
    out[#out + 1] = line
  end
  return out
end

--- Delete trellis backup refs (only ever under refs/trellis/backup/). Async.
---@return string? err
function M.delete(repo, refnames)
  local lines = { "start" }
  for _, r in ipairs(refnames) do
    assert(vim.startswith(r, M.prefix), "trellis: refusing to delete non-backup ref " .. r)
    lines[#lines + 1] = "delete " .. r
  end
  if #lines == 1 then
    return nil
  end
  lines[#lines + 1] = "commit"
  return (M.git(repo, argv.W01(lines)))
end

return M
