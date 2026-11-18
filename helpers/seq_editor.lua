-- GIT_SEQUENCE_EDITOR helper (research R9, contracts/uri-and-buffers.md → Helpers).
--
--   GIT_SEQUENCE_EDITOR="<nvim> -l <helpers>/seq_editor.lua <planfile>"
--   git runs it as: ... seq_editor.lua <planfile> <todo-path>
--
-- Copies the planned todo over git's todo file. A missing plan file exits 1, so git aborts
-- the rebase cleanly before doing anything.
local planfile, todo = _G.arg[1], _G.arg[2]
if not planfile or not todo then
  io.stderr:write("trellis seq_editor: usage: seq_editor.lua <planfile> <todo-path>\n")
  os.exit(2)
end
local src = io.open(planfile, "rb")
if not src then
  io.stderr:write("trellis seq_editor: plan file not found: " .. planfile .. "\n")
  os.exit(1)
end
local text = src:read("*a")
src:close()
local dst = io.open(todo, "wb")
if not dst then
  io.stderr:write("trellis seq_editor: cannot write " .. todo .. "\n")
  os.exit(1)
end
dst:write(text)
dst:close()
os.exit(0)
