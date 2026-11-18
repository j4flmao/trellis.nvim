--- Rebase todo files: parse (git's `git-rebase-todo`, the plan buffer) and serialize.
local M = {}

local ALIASES = {
  p = "pick",
  pick = "pick",
  r = "reword",
  reword = "reword",
  e = "edit",
  edit = "edit",
  s = "squash",
  squash = "squash",
  f = "fixup",
  fixup = "fixup",
  d = "drop",
  drop = "drop",
  x = "exec",
  exec = "exec",
  b = "break",
  ["break"] = "break",
  l = "label",
  label = "label",
  t = "reset",
  reset = "reset",
  m = "merge",
  merge = "merge",
  u = "update_ref",
  ["update-ref"] = "update_ref",
}

--- Actions that take "<sha> <subject>".
M.commit_actions = {
  pick = true,
  reword = true,
  edit = true,
  squash = true,
  fixup = true,
  fixup_C = true,
  fixup_c = true,
  drop = true,
}

---@class trellis.TodoLine
---@field kind "entry"|"comment"|"blank"|"error"
---@field action? trellis.PlanAction
---@field sha? string
---@field subject? string
---@field arg? string           exec command, label/reset name, update-ref target, merge label
---@field merge_flag? "-C"|"-c"
---@field text? string          comment text / offending line
---@field message? string       error description

--- Parse one line. `opts.trellis_aliases` accepts `F` (= fixup -C) from the plan buffer.
---@param line string
---@param opts? { trellis_aliases?: boolean }
---@return trellis.TodoLine
function M.parse_line(line, opts)
  if line:match("^%s*$") then
    return { kind = "blank" }
  end
  if line:match("^%s*#") then
    return { kind = "comment", text = line }
  end
  local cmd, rest = line:match("^%s*(%S+)%s*(.-)%s*$")
  local action = ALIASES[cmd]
  if not action and cmd == "F" and opts and opts.trellis_aliases then
    action = "fixup_C"
  end
  if not action then
    return { kind = "error", text = line, message = ("unknown action %q"):format(cmd) }
  end
  if action == "fixup" then
    local flag, r2 = rest:match("^%-([Cc])%s+(.*)$")
    if flag then
      action = flag == "C" and "fixup_C" or "fixup_c"
      rest = r2
    end
  end
  if M.commit_actions[action] then
    local sha, subject = rest:match("^(%x+)%s*(.*)$")
    if not sha or #sha < 4 then
      return { kind = "error", text = line, message = action .. ": missing commit" }
    end
    subject = subject:gsub("^# ", "")
    return { kind = "entry", action = action, sha = sha, subject = subject }
  elseif action == "exec" then
    if rest == "" then
      return { kind = "error", text = line, message = "exec: missing command" }
    end
    return { kind = "entry", action = "exec", arg = rest }
  elseif action == "break" then
    return { kind = "entry", action = "break" }
  elseif action == "merge" then
    local flag, sha, r2 = rest:match("^(%-[Cc])%s+(%x+)%s+(.*)$")
    local label, subject = (r2 or rest):match("^(.-)%s*#%s?(.*)$")
    label = label or (r2 or rest)
    return {
      kind = "entry",
      action = "merge",
      merge_flag = flag,
      sha = sha,
      arg = label,
      subject = subject,
    }
  else -- label, reset, update_ref
    if rest == "" then
      return { kind = "error", text = line, message = action .. ": missing argument" }
    end
    return { kind = "entry", action = action, arg = rest }
  end
end

--- Parse a whole todo. Returns entries (with `lnum`) and errors (with `lnum`).
---@param text string
---@param opts? { trellis_aliases?: boolean }
---@return (trellis.TodoLine|{lnum: integer})[] entries, (trellis.TodoLine|{lnum: integer})[] errors
function M.parse(text, opts)
  local entries, errors = {}, {}
  local lnum = 0
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    lnum = lnum + 1
    local t = M.parse_line(line, opts)
    t.lnum = lnum
    if t.kind == "entry" then
      entries[#entries + 1] = t
    elseif t.kind == "error" then
      errors[#errors + 1] = t
    end
  end
  return entries, errors
end

--- Serialize entries to a todo git understands (full command names).
---@param entries trellis.TodoLine[]
---@return string
function M.serialize(entries)
  local out = {}
  for _, e in ipairs(entries) do
    local a = e.action
    local line
    if M.commit_actions[a] then
      local cmd = a == "fixup_C" and "fixup -C" or a == "fixup_c" and "fixup -c" or a
      line = cmd .. " " .. e.sha .. ((e.subject and e.subject ~= "") and (" " .. e.subject) or "")
    elseif a == "exec" then
      line = "exec " .. e.arg
    elseif a == "break" then
      line = "break"
    elseif a == "merge" then
      line = "merge "
        .. (e.merge_flag and (e.merge_flag .. " " .. e.sha .. " ") or "")
        .. e.arg
        .. ((e.subject and e.subject ~= "") and (" # " .. e.subject) or "")
    elseif a == "update_ref" then
      line = "update-ref " .. e.arg
    else
      line = a .. " " .. e.arg
    end
    out[#out + 1] = line
  end
  return table.concat(out, "\n") .. "\n"
end

return M
