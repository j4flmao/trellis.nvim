--- Parsers for commit details (G11) and changed files (G12 numstat, G13 name-status).
local util = require("trellis.git.parse.util")

local M = {}

local function person(name, email, time, raw_date)
  return {
    name = name or "",
    email = email or "",
    time = tonumber(time) or 0,
    tz = raw_date and raw_date:match("([+-]%d%d%d%d)$") or nil,
  }
end

--- Parse `git show -s --date=raw --format=<argv.SHOW_FORMAT>`.
---@param out string
---@return trellis.CommitDetails?
function M.parse_details(out)
  local f = util.split(out, "\0")
  if #f < 13 or not f[1]:match("^%x+$") then
    return nil
  end
  -- The body is last and cannot contain NUL, but join defensively.
  local body = table.concat(f, "\0", 13)
  body = body:gsub("\n+$", "")
  local status = f[11] ~= "" and f[11] or "N"
  return {
    sha = f[1],
    parents = vim.split(f[2], " ", { trimempty = true }),
    author = person(f[3], f[4], f[5], f[6]),
    committer = person(f[7], f[8], f[9], f[10]),
    signature = status ~= "N" and { status = status, signer = f[12] ~= "" and f[12] or nil } or nil,
    body = body,
    files = {},
  }
end

--- Parse `diff-tree -z --numstat`. Renames/copies use an empty path field followed by
--- `old\0new\0`. Binary files report `-` for both counts.
---@param s string
---@return { path: string, old_path: string?, added: integer?, removed: integer?, binary: boolean }[]
function M.parse_numstat(s)
  local out, pos, n = {}, 1, #s
  while pos <= n do
    local a, r, rest = s:match("^([%d%-]+)\t([%d%-]+)\t()", pos)
    if not a then
      break
    end
    local e = { added = tonumber(a), removed = tonumber(r), binary = a == "-" }
    pos = rest
    if s:sub(pos, pos) == "\0" then
      local n1 = s:find("\0", pos + 1, true)
      local n2 = n1 and s:find("\0", n1 + 1, true)
      if not n2 then
        break
      end
      e.old_path = s:sub(pos + 1, n1 - 1)
      e.path = s:sub(n1 + 1, n2 - 1)
      pos = n2 + 1
    else
      local n1 = s:find("\0", pos, true) or (n + 1)
      e.path = s:sub(pos, n1 - 1)
      pos = n1 + 1
    end
    out[#out + 1] = e
  end
  return out
end

--- Parse `diff-tree -z --name-status`: `M\0path\0`, `R100\0old\0new\0`, `C75\0old\0new\0`.
---@param s string
---@return { status: string, score: integer?, path: string, old_path: string? }[]
function M.parse_name_status(s)
  local f = util.split(s, "\0")
  local out, i = {}, 1
  while i <= #f do
    local code = f[i]
    if code == "" then
      i = i + 1
    else
      local letter, score = code:sub(1, 1), tonumber(code:sub(2))
      if letter == "R" or letter == "C" then
        out[#out + 1] = { status = letter, score = score, old_path = f[i + 1], path = f[i + 2] }
        i = i + 3
      else
        out[#out + 1] = { status = letter, path = f[i + 1] }
        i = i + 2
      end
    end
  end
  return out
end

--- Combine numstat and name-status into FileChange[] (order of name-status).
---@return trellis.FileChange[]
function M.merge_changes(numstat, name_status)
  local stats = {}
  for _, e in ipairs(numstat) do
    stats[e.path] = e
  end
  local out = {}
  for _, ns in ipairs(name_status) do
    local st = stats[ns.path] or {}
    out[#out + 1] = {
      status = ns.status,
      path = ns.path,
      old_path = ns.old_path,
      added = st.added,
      removed = st.removed,
      binary = st.binary or false,
    }
  end
  return out
end

return M
