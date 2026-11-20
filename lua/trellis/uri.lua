--- `trellis://` buffer names. Pure: parse and build only.
local M = {}

M.scheme = "trellis://"

---@class trellis.Uri
---@field kind "file"|"stage"|"commit"|"diff"|"graph"|"blame"|"plan"|"history"|"empty"
---@field rev? string     file: commit-ish (hex, possibly abbreviated)
---@field stage? integer  stage: 0..3
---@field path? string
---@field sha? string     commit
---@field a? string       diff
---@field b? string       diff
---@field n? integer      graph instance
---@field id? string      plan id

---@param name string
---@return trellis.Uri? uri, string? err
function M.parse(name)
  if name:sub(1, #M.scheme) ~= M.scheme then
    return nil, "not a trellis:// name"
  end
  local rest = name:sub(#M.scheme + 1):gsub("\\", "/")
  local head, tail = rest:match("^([^/]+)/?(.*)$")
  if not head then
    return nil, "empty trellis:// name"
  end
  if head == "commit" then
    if tail:match("^%x+$") then
      return { kind = "commit", sha = tail }
    end
    return nil, "trellis://commit/<sha>: bad sha"
  elseif head == "diff" then
    local a, b, path = tail:match("^(%x+)%.%.(%x+)/?(.*)$")
    if not a then
      return nil, "trellis://diff/<a>..<b>[/<path>]: bad range"
    end
    return { kind = "diff", a = a, b = b, path = path ~= "" and path or nil }
  elseif head == "graph" then
    return { kind = "graph", n = tonumber(tail) or 1 }
  elseif head == "history" then
    return { kind = "history", path = tail }
  elseif head == "empty" then
    return { kind = "empty", path = tail }
  elseif head == "blame" then
    return { kind = "blame", path = tail }
  elseif head == "plan" then
    return { kind = "plan", id = tail }
  end
  local stage = head:match("^:(%d)$")
  if stage then
    if tail == "" then
      return nil, "trellis://:<n>/<path>: missing path"
    end
    return { kind = "stage", stage = tonumber(stage), path = tail }
  end
  if head:match("^%x+$") and #head >= 4 then
    if tail == "" then
      return nil, "trellis://<sha>/<path>: missing path"
    end
    return { kind = "file", rev = head, path = tail }
  end
  return nil, ("unknown trellis:// name %q"):format(name)
end

--- File at a revision. `abbrev` shortens the sha (default 7).
---@param sha string
---@param path string repo-relative, "/" separated
---@param abbrev? integer
function M.file(sha, path, abbrev)
  return M.scheme .. sha:sub(1, abbrev or 7) .. "/" .. path
end

function M.stage(n, path)
  return ("%s:%d/%s"):format(M.scheme, n, path)
end

function M.commit(sha, abbrev)
  return M.scheme .. "commit/" .. sha:sub(1, abbrev or 7)
end

function M.diff(a, b, path, abbrev)
  local s = M.scheme .. "diff/" .. a:sub(1, abbrev or 7) .. ".." .. b:sub(1, abbrev or 7)
  return path and (s .. "/" .. path) or s
end

function M.graph(n)
  return M.scheme .. "graph/" .. n
end

return M
