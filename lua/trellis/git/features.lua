--- git version parsing and capability detection (Constitution: feature-detect newer git).
local M = {}

M.MIN = { 2, 30, 0 }

--- "git version 2.47.1" / "2.51.0.windows.1" / "2.39.3 (Apple Git-146)" → {2, 47, 1}
---@param s string
---@return integer[]?
function M.parse_version(s)
  local a, b, c = s:match("(%d+)%.(%d+)%.?(%d*)")
  if not a then
    return nil
  end
  return { tonumber(a), tonumber(b), tonumber(c) or 0 }
end

---@param v integer[]
---@param req integer[]
---@return boolean
function M.at_least(v, req)
  for i = 1, 3 do
    local x, y = v[i] or 0, req[i] or 0
    if x ~= y then
      return x > y
    end
  end
  return true
end

---@param v integer[]
---@return string
function M.version_string(v)
  return table.concat(v, ".")
end

local function exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

--- Build GitFeatures from the version and the repository's common dir.
---@param version integer[]
---@param commondir? string
---@param object_format? string
---@return trellis.GitFeatures
function M.detect(version, commondir, object_format)
  local objects = commondir and (commondir .. "/objects/info") or nil
  return {
    version = version,
    supported = M.at_least(version, M.MIN),
    merge_tree_base = M.at_least(version, { 2, 40 }),
    update_refs = M.at_least(version, { 2, 38 }),
    worktree_z = M.at_least(version, { 2, 36 }),
    commit_graph = objects ~= nil
      and (exists(objects .. "/commit-graph") or exists(objects .. "/commit-graphs")),
    sha256 = object_format == "sha256",
  }
end

return M
