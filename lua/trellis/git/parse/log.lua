--- Parser for `git log --format=%H%x00%P%x00%an%x00%at%x00%s%x1e` (G10, G23 header part).
---
--- Records arrive split on RS (\x1e). git terminates every record with RS followed by "\n", so
--- every record after the first starts with "\n". A subject may itself contain RS; the fragment
--- after it then does NOT start with "\n" and is glued back onto the previous subject.
local M = {}

---@class trellis.LogCommit
---@field sha string
---@field parents string[]
---@field author string
---@field time integer
---@field subject string

local EMPTY = {}

---@param rec string record without the leading "\n"
---@return trellis.LogCommit?
local function parse_fields(rec)
  local sha, parents, author, time, subject = rec:match("^(%x+)%z([%x ]*)%z([^%z]*)%z(%d*)%z(.*)$")
  if not sha then
    return nil
  end
  local plist = EMPTY
  if parents ~= "" then
    plist = {}
    for p in parents:gmatch("%x+") do
      plist[#plist + 1] = p
    end
  end
  return {
    sha = sha,
    parents = plist,
    author = author,
    time = tonumber(time) or 0,
    subject = subject,
  }
end

---@class trellis.LogParser
---@field push fun(fragments: string[]): trellis.LogCommit[]
---@field finish fun(): trellis.LogCommit[]
---@field errors string[]

--- Streaming parser. A commit is released once the next fragment proves its subject complete.
---@return trellis.LogParser
function M.new_parser()
  local first = true
  local pending ---@type trellis.LogCommit?
  local parser = { errors = {} }

  function parser.push(fragments)
    local out = {}
    for _, frag in ipairs(fragments) do
      local starts_record = first or frag:sub(1, 1) == "\n"
      if starts_record then
        local body = first and frag or frag:sub(2)
        first = false
        if body ~= "" then
          local c = parse_fields(body)
          if c then
            if pending then
              out[#out + 1] = pending
            end
            pending = c
          else
            parser.errors[#parser.errors + 1] = body:sub(1, 200)
          end
        end
      elseif pending then
        pending.subject = pending.subject .. "\30" .. frag
      else
        parser.errors[#parser.errors + 1] = frag:sub(1, 200)
      end
    end
    return out
  end

  function parser.finish()
    local out = {}
    if pending then
      out[1] = pending
      pending = nil
    end
    return out
  end

  return parser
end

--- Parse a complete output string.
---@param text string
---@return trellis.LogCommit[] commits, string[] errors
function M.parse(text)
  local p = M.new_parser()
  local frags = require("trellis.git.parse.util").split(text, "\30")
  local out = p.push(frags)
  vim.list_extend(out, p.finish())
  return out, p.errors
end

return M
