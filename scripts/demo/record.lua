-- Terminal recorder for README demos: spawns `nvim --embed`, attaches as an RGB linegrid UI,
-- replays a scenario of keys and writes timed frames (and key captions) as JSON lines.
--
--   nvim -l scripts/demo/record.lua <scenario.lua> <frames.jsonl> [cols] [rows]
--
-- Environment:
--   DEMO_CWD     working directory of the recorded Neovim (default: the current one)
--   DEMO_SHELL   1: the recorded Neovim is a clean one whose only window is a PowerShell
--                terminal, so the recording starts at a shell prompt and the user's own `nvim`
--                (with their config) runs inside it
--   DEMO_PROMPT  prompt text for that shell (default "PS > ")
--
-- Render with scripts/demo/render.py. Keys are sent through the UI protocol (nvim_input).
local scenario_path, out_path = arg[1], arg[2]
local COLS, ROWS = tonumber(arg[3] or 120), tonumber(arg[4] or 34)
local uv = vim.uv

local shell_args
if os.getenv("DEMO_SHELL") then
  local prompt = (os.getenv("DEMO_PROMPT") or "PS > "):gsub("'", "''")
  shell_args = {
    "--embed",
    "--clean",
    "-c",
    "set laststatus=0 cmdheight=0 noshowmode noruler shortmess+=F",
    "-c",
    (
      "lua vim.env.COLORTERM = 'truecolor'; vim.fn.jobstart({ 'powershell.exe', '-NoLogo', "
      .. "'-NoProfile', '-NoExit', '-Command', [[function prompt { '%s' }]] }, { term = true })"
    ):format(prompt),
    "-c",
    "startinsert",
  }
end

local stdin, stdout, stderr = uv.new_pipe(), uv.new_pipe(), uv.new_pipe()
local child = uv.spawn("nvim", {
  args = shell_args or { "--embed" },
  cwd = os.getenv("DEMO_CWD") or uv.cwd(),
  stdio = { stdin, stdout, stderr },
}, function() end)
assert(child, "could not start nvim")

local msgid, pending = 0, {}
local function request(method, params, cb)
  msgid = msgid + 1
  pending[msgid] = cb or function() end
  stdin:write(vim.mpack.encode({ 0, msgid, method, params }))
end

-- Grid state -----------------------------------------------------------------------------------
local grid, hls = {}, { [0] = {} }
local defaults = { fg = 0xc0caf5, bg = 0x1a1b26 }
local cursor = { 0, 0 }
local flushed = false

local function resize(cols, rows)
  COLS, ROWS = cols, rows
  for r = 0, rows - 1 do
    grid[r] = grid[r] or {}
    for c = 0, cols - 1 do
      grid[r][c] = grid[r][c] or { " ", 0 }
    end
  end
end
resize(COLS, ROWS)

local function isnil(v)
  return v == nil or v == vim.NIL
end

local handlers = {}
function handlers.grid_resize(_, cols, rows)
  resize(cols, rows)
end
function handlers.default_colors_set(fg, bg)
  if not isnil(fg) and fg >= 0 then
    defaults.fg = fg
  end
  if not isnil(bg) and bg >= 0 then
    defaults.bg = bg
  end
end
function handlers.hl_attr_define(id, rgb)
  hls[id] = rgb
end
function handlers.grid_clear()
  for r = 0, ROWS - 1 do
    for c = 0, COLS - 1 do
      grid[r][c] = { " ", 0 }
    end
  end
end
function handlers.grid_cursor_goto(_, row, col)
  cursor = { row, col }
end
function handlers.grid_line(_, row, col, cells)
  local line = grid[row]
  if not line then
    return
  end
  local hl = 0
  for _, cell in ipairs(cells) do
    if not isnil(cell[2]) then
      hl = cell[2]
    end
    local rep = isnil(cell[3]) and 1 or cell[3]
    for _ = 1, rep do
      line[col] = { cell[1], hl }
      col = col + 1
    end
  end
end
function handlers.grid_scroll(_, top, bot, left, right, rows)
  if rows > 0 then
    for r = top, bot - rows - 1 do
      for c = left, right - 1 do
        grid[r][c] = grid[r + rows][c]
      end
    end
  else
    for r = bot - 1, top - rows, -1 do
      for c = left, right - 1 do
        grid[r][c] = grid[r + rows][c]
      end
    end
  end
end
function handlers.flush()
  flushed = true
end

local unpacker = vim.mpack.Unpacker()
local buf = ""
stdout:read_start(function(err, data)
  assert(not err, err)
  if not data then
    return
  end
  buf = buf .. data
  local pos = 1
  while pos <= #buf do
    local obj, npos = unpacker(buf, pos)
    if obj == nil then
      pos = npos
      break
    end
    pos = npos
    if obj[1] == 1 then
      local cb = pending[obj[2]]
      pending[obj[2]] = nil
      if cb then
        cb(obj[3], obj[4])
      end
    elseif obj[1] == 2 and obj[2] == "redraw" then
      for _, ev in ipairs(obj[3]) do
        local h = handlers[ev[1]]
        if h then
          for i = 2, #ev do
            h(unpack(ev[i]))
          end
        end
      end
    end
  end
  buf = buf:sub(pos)
end)
stderr:read_start(function() end)

-- Frames ---------------------------------------------------------------------------------------
local out = assert(io.open(out_path, "w"))
local last_frame
local frames = 0

local function color(id)
  local a = hls[id] or {}
  local fg = isnil(a.foreground) and defaults.fg or a.foreground
  local bg = isnil(a.background) and defaults.bg or a.background
  if a.reverse then
    fg, bg = bg, fg
  end
  return fg,
    bg,
    (a.bold and 1 or 0) + (a.italic and 2 or 0) + ((a.underline or a.undercurl) and 4 or 0)
end

local function snapshot(ms)
  local rows = {}
  for r = 0, ROWS - 1 do
    local runs, cur = {}, nil
    for c = 0, COLS - 1 do
      local cell = grid[r][c]
      local fg, bg, attr = color(cell[2])
      if r == cursor[1] and c == cursor[2] then
        fg, bg = bg, fg
      end
      local key = fg .. ":" .. bg .. ":" .. attr
      if cur and cur.k == key then
        cur.t[#cur.t + 1] = cell[1]
      else
        cur = { k = key, t = { cell[1] }, fg = fg, bg = bg, a = attr }
        runs[#runs + 1] = cur
      end
    end
    for j, run in ipairs(runs) do
      runs[j] = { table.concat(run.t), run.fg, run.bg, run.a }
    end
    rows[#rows + 1] = runs
  end
  local s = vim.json.encode({ rows = rows, bg = defaults.bg })
  if s == last_frame then
    out:write(vim.json.encode({ extend = ms }) .. "\n")
  else
    out:write('{"ms":' .. ms .. ',"frame":' .. s .. "}\n")
    last_frame = s
    frames = frames + 1
  end
end

-- Scenario API ---------------------------------------------------------------------------------
local FRAME_MS = 80

local function wait(ms)
  local t = 0
  while t < ms do
    local step = math.min(FRAME_MS, ms - t)
    vim.wait(step, function()
      return false
    end, 5)
    t = t + step
    snapshot(step)
  end
end

local function input(keys)
  request("nvim_input", { keys })
end

local api = {
  wait = wait,
  --- Frames before the last mark are dropped by the renderer (setup the viewer should not see).
  mark = function()
    out:write('{"mark":true}\n')
    last_frame = nil
  end,
  --- Send keys at once, then wait.
  keys = function(keys, after)
    input(keys)
    wait(after or 400)
  end,
  --- Type text one character at a time (visible typing).
  type = function(text, per, after)
    for _, k in ipairs(vim.split(text, "", { plain = true })) do
      input(k == "<" and "<lt>" or k)
      wait(per or 70)
    end
    wait(after or 200)
  end,
  --- Show a key caption ("Space g T", "history graph"), send the keys one by one, wait.
  press = function(seq, shown, label, after)
    out:write(vim.json.encode({ cap = shown, label = label or "" }) .. "\n")
    for i, k in ipairs(seq) do
      input(k)
      if i < #seq then
        wait(350)
      end
    end
    wait(after or 1500)
  end,
  --- Caption only (for typed commands).
  cap = function(shown, label)
    out:write(vim.json.encode({ cap = shown, label = label or "" }) .. "\n")
  end,
}

request("nvim_ui_attach", { COLS, ROWS, { ext_linegrid = true, rgb = true } })
vim.wait(20000, function()
  return flushed
end, 10)
dofile(scenario_path)(api)
out:close()
request("nvim_command", { "qa!" })
vim.wait(1500, function()
  return false
end, 50)
pcall(function()
  child:kill(9)
end)
io.stdout:write(("frames=%d\n"):format(frames))
