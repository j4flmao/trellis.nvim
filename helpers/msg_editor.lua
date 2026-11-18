-- GIT_EDITOR helper for planned commit messages (research R9).
--
--   GIT_EDITOR="<nvim> -l <helpers>/msg_editor.lua <gitdir> <msgdir>"
--   git runs it as: ... msg_editor.lua <gitdir> <msgdir> <msg-path>
--
-- Finds the todo entry git is working on from <gitdir>/rebase-merge/done (the last command
-- line); for a squash/fixup chain, its head (the pick/reword/edit it folds into). If
-- <msgdir>/<head-sha>.txt exists, it becomes the message; otherwise git's default message is
-- left unchanged. Never reads stdin and never waits.
local gitdir, msgdir, msgpath = _G.arg[1], _G.arg[2], _G.arg[3]
if not gitdir or not msgdir or not msgpath then
  io.stderr:write("trellis msg_editor: usage: msg_editor.lua <gitdir> <msgdir> <msg-path>\n")
  os.exit(2)
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local done = read(gitdir .. "/rebase-merge/done") or ""
local entries = {}
for line in done:gmatch("[^\n]+") do
  local cmd, rest = line:match("^%s*(%S+)%s*(.*)$")
  if cmd and not cmd:match("^#") then
    local flag, sha = rest:match("^(%-[Cc])%s+(%x+)")
    if not sha then
      sha = rest:match("^(%x+)")
    end
    entries[#entries + 1] = { cmd = cmd, sha = sha, flag = flag }
  end
end

local FOLD = { squash = true, s = true, fixup = true, f = true }
local head
for i = #entries, 1, -1 do
  local e = entries[i]
  if e.sha and not FOLD[e.cmd] then
    head = e.sha
    break
  end
  if not e.sha then
    break -- exec/break/label: not part of a commit chain
  end
end

local message = head and (read(msgdir .. "/" .. head .. ".txt"))
if not message then
  -- Planned messages are keyed by the full sha; done may hold an abbreviated one.
  if head then
    local dir = vim and vim.uv and vim.uv.fs_scandir(msgdir)
    while dir do
      local name = vim.uv.fs_scandir_next(dir)
      if not name then
        break
      end
      if name:sub(1, #head) == head and name:match("%.txt$") then
        message = read(msgdir .. "/" .. name)
        break
      end
    end
  end
end
if message then
  local f = io.open(msgpath, "wb")
  if not f then
    os.exit(1)
  end
  f:write(message)
  f:close()
end
os.exit(0)
