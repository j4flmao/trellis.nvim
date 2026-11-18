--- Shared helpers for git output parsers (pure Lua, no Neovim API).
local M = {}

local ESCAPES = { a = "\a", b = "\b", t = "\t", n = "\n", v = "\v", f = "\f", r = "\r" }

--- Undo git's C-style path quoting (`"a\tb"`, `"\303\251"`). Unquoted input is returned as is.
---@param s string
---@return string
function M.unquote(s)
  if s:sub(1, 1) ~= '"' or s:sub(-1) ~= '"' or #s < 2 then
    return s
  end
  local body = s:sub(2, -2)
  return (
    body
      :gsub("\\(%d%d%d)", function(oct)
        return string.char(tonumber(oct, 8))
      end)
      :gsub("\\(.)", function(c)
        return ESCAPES[c] or c
      end)
  )
end

--- Split `s` on a plain separator.
---@param s string
---@param sep string
---@return string[]
function M.split(s, sep)
  local out, start = {}, 1
  while true do
    local i = s:find(sep, start, true)
    if not i then
      out[#out + 1] = s:sub(start)
      return out
    end
    out[#out + 1] = s:sub(start, i - 1)
    start = i + #sep
  end
end

--- Line splitter that keeps an incomplete last line between chunks.
---@return fun(chunk: string?): string[] push  pass nil to flush
function M.line_buffer()
  local pending = ""
  return function(chunk)
    local lines = {}
    if chunk == nil then
      if pending ~= "" then
        lines[1] = pending
        pending = ""
      end
      return lines
    end
    local data = pending .. chunk
    local start = 1
    while true do
      local i = data:find("\n", start, true)
      if not i then
        break
      end
      lines[#lines + 1] = data:sub(start, i - 1)
      start = i + 1
    end
    pending = data:sub(start)
    return lines
  end
end

return M
