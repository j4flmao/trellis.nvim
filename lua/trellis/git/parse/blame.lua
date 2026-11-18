--- Streaming parser for `git blame --incremental` (G30).
---
--- Each entry starts with "<sha> <orig_line> <final_line> <num_lines>" and ends with
--- "filename <path>". Commit headers (author, summary, …) appear only the first time a commit
--- is seen; "previous <sha> <path>" and "filename" are repeated for every entry.
local util = require("trellis.git.parse.util")

local M = {}

M.UNCOMMITTED = ("0"):rep(40)

---@class trellis.BlameEntry
---@field sha string
---@field orig_line integer
---@field final_line integer
---@field num_lines integer
---@field filename string
---@field previous { sha: string, path: string }?

---@class trellis.BlameCommit
---@field sha string
---@field author string?
---@field ["author-mail"] string?
---@field ["author-time"] integer?
---@field ["author-tz"] string?
---@field committer string?
---@field ["committer-time"] integer?
---@field summary string?
---@field boundary boolean?

local NUMERIC = { ["author-time"] = true, ["committer-time"] = true }

---@class trellis.BlameParser
---@field push fun(chunk: string): trellis.BlameEntry[]
---@field finish fun(): trellis.BlameEntry[]
---@field commits table<string, trellis.BlameCommit>
---@field errors string[]

---@return trellis.BlameParser
function M.new_parser()
  local lines = util.line_buffer()
  local commits = {}
  local cur ---@type trellis.BlameEntry?
  local parser = { commits = commits, errors = {} }

  local function handle(line, out)
    if line == "" then
      return
    end
    if not cur then
      local sha, o, f, n = line:match("^(%x+) (%d+) (%d+) (%d+)$")
      if not sha then
        parser.errors[#parser.errors + 1] = line
        return
      end
      cur = {
        sha = sha,
        orig_line = tonumber(o),
        final_line = tonumber(f),
        num_lines = tonumber(n),
      } --[[@as trellis.BlameEntry]]
      commits[sha] = commits[sha] or { sha = sha }
      return
    end
    local key, val = line:match("^(%S+) ?(.*)$")
    if key == "filename" then
      cur.filename = util.unquote(val)
      out[#out + 1] = cur
      cur = nil
    elseif key == "previous" then
      local s, path = val:match("^(%x+) (.*)$")
      if s then
        cur.previous = { sha = s, path = util.unquote(path) }
      end
    elseif key == "boundary" then
      commits[cur.sha].boundary = true
    elseif key then
      commits[cur.sha][key] = NUMERIC[key] and tonumber(val) or val
    end
  end

  function parser.push(chunk)
    local out = {}
    for _, line in ipairs(lines(chunk)) do
      handle(line, out)
    end
    return out
  end

  function parser.finish()
    local out = {}
    for _, line in ipairs(lines(nil)) do
      handle(line, out)
    end
    return out
  end

  return parser
end

--- Parse complete output.
---@return trellis.BlameEntry[] entries, table<string, trellis.BlameCommit> commits
function M.parse(text)
  local p = M.new_parser()
  local out = p.push(text)
  vim.list_extend(out, p.finish())
  return out, p.commits
end

return M
