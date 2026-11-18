--- Unified diff parser (G20, G31, G45). Expects `a/` and `b/` prefixes (pinned in argv.lua).
--- Combined diffs (`@@@`, merge `--cc`) are not handled here yet.
local util = require("trellis.git.parse.util")

local M = {}

---@class trellis.DiffHunk
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field header string   text after the closing @@ (function context)
---@field lines string[]  raw hunk lines including the leading ' ', '+', '-', '\'

---@class trellis.DiffFile
---@field old_path string?  nil for added files
---@field new_path string?  nil for deleted files
---@field status "A"|"M"|"D"|"R"|"C"|"T"
---@field similarity integer?
---@field binary boolean
---@field old_mode string?
---@field new_mode string?
---@field hunks trellis.DiffHunk[]

local function strip_prefix(p, prefix)
  if p == "/dev/null" then
    return nil
  end
  p = util.unquote(p)
  if p:sub(1, #prefix) == prefix then
    return p:sub(#prefix + 1)
  end
  return p
end

--- Paths from `diff --git a/x b/y` (only used when no ---/+++/rename lines follow).
local function paths_from_header(rest)
  if rest:sub(1, 1) == '"' then
    local a_end = rest:find('" ', 2, true)
    if a_end then
      return strip_prefix(rest:sub(1, a_end), "a/"), strip_prefix(rest:sub(a_end + 2), "b/")
    end
  end
  -- Unquoted and same path on both sides: "a/P b/P" has odd length with the split in the middle.
  local n = #rest
  if (n - 1) % 2 == 0 then
    local half = (n - 1) / 2
    local a, b = rest:sub(1, half), rest:sub(half + 2)
    if a:sub(3) == b:sub(3) then
      return strip_prefix(a, "a/"), strip_prefix(b, "b/")
    end
  end
  local i = rest:find(" b/", 1, true)
  if i then
    return strip_prefix(rest:sub(1, i - 1), "a/"), strip_prefix(rest:sub(i + 1), "b/")
  end
  return nil, nil
end

--- Parse "@@ -a,b +c,d @@ header".
---@return trellis.DiffHunk?
function M.parse_hunk_header(line)
  local os, oc, ns, nc, header = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@ ?(.*)$")
  if not os then
    return nil
  end
  return {
    old_start = tonumber(os),
    old_count = oc == "" and 1 or tonumber(oc),
    new_start = tonumber(ns),
    new_count = nc == "" and 1 or tonumber(nc),
    header = header,
    lines = {},
  }
end

---@param text string
---@return trellis.DiffFile[]
function M.parse(text)
  local files = {}
  local file ---@type trellis.DiffFile?
  local hunk ---@type trellis.DiffHunk?
  local old_left, new_left = 0, 0

  for _, line in ipairs(util.split(text, "\n")) do
    local consumed = false
    if hunk and (old_left > 0 or new_left > 0 or line:sub(1, 1) == "\\") then
      local c = line:sub(1, 1)
      -- An empty line is context too: some tools strip its leading space.
      if c == " " or line == "" then
        old_left, new_left = old_left - 1, new_left - 1
      elseif c == "-" then
        old_left = old_left - 1
      elseif c == "+" then
        new_left = new_left - 1
      elseif c ~= "\\" then -- "\ No newline at end of file" leaves the counts unchanged
        hunk = nil
      end
      if hunk then
        hunk.lines[#hunk.lines + 1] = line
        consumed = true
      end
    end

    if not consumed then
      hunk = nil
    end
    if not consumed and line:sub(1, 11) == "diff --git " then
      local a, b = paths_from_header(line:sub(12))
      file = { old_path = a, new_path = b, status = "M", binary = false, hunks = {} }
      files[#files + 1] = file
    elseif not consumed and file then
      local h = line:sub(1, 2) == "@@" and M.parse_hunk_header(line)
      if h then
        hunk = h
        old_left, new_left = h.old_count, h.new_count
        file.hunks[#file.hunks + 1] = h
      elseif line:sub(1, 4) == "--- " then
        file.old_path = strip_prefix(line:sub(5), "a/")
      elseif line:sub(1, 4) == "+++ " then
        file.new_path = strip_prefix(line:sub(5), "b/")
      elseif line:match("^new file mode ") then
        file.status, file.new_mode, file.old_path = "A", line:sub(15), nil
      elseif line:match("^deleted file mode ") then
        file.status, file.old_mode, file.new_path = "D", line:sub(19), nil
      elseif line:match("^old mode ") then
        file.old_mode = line:sub(10)
        if file.status == "M" then
          file.status = "T"
        end
      elseif line:match("^new mode ") then
        file.new_mode = line:sub(10)
      elseif line:match("^rename from ") then
        file.status, file.old_path = "R", util.unquote(line:sub(13))
      elseif line:match("^rename to ") then
        file.new_path = util.unquote(line:sub(11))
      elseif line:match("^copy from ") then
        file.status, file.old_path = "C", util.unquote(line:sub(11))
      elseif line:match("^copy to ") then
        file.new_path = util.unquote(line:sub(9))
      elseif line:match("^similarity index ") then
        file.similarity = tonumber(line:match("(%d+)%%"))
      elseif line:match("^Binary files ") or line == "GIT binary patch" then
        file.binary = true
      end
    end
  end

  for _, f in ipairs(files) do
    -- A mode-only change keeps "T" only when content is unchanged; with hunks it is "M".
    if f.status == "T" and #f.hunks > 0 then
      f.status = "M"
    end
  end
  return files
end

return M
