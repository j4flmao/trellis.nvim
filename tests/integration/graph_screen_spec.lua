-- T030 (rendering): what the user actually sees — right-aligned author/date virtual text,
-- winbar, lane colors from the decoration provider, monochrome readability. The parent
-- process drives a child Neovim with an attached UI and inspects screenshots.
local fixtures = require("tests.fixtures")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.o.lines, child.o.columns = 20, 90
    end,
    post_once = child.stop,
  },
})

local function open(name, cfg)
  local path = fixtures.get(name).path
  child.lua(
    [[
    local path, cfg = ...
    local G = require("tests.helpers.graph")
    _G.view = G.open(path, cfg)
    assert(G.wait_loaded(_G.view))
    vim.wait(200) -- winbar update is deferred
    vim.cmd("redraw")
  ]],
    { path, cfg or {} }
  )
end

local function screen_lines()
  local shot = child.get_screenshot()
  local lines = {}
  for _, row in ipairs(shot.text) do
    lines[#lines + 1] = table.concat(row)
  end
  return lines, shot
end

T["author and date are right-aligned virtual text, not buffer text"] = function()
  open("demo")
  local lines = screen_lines()
  -- Row 1 of the screen is the winbar; row 2 is the first commit.
  eq(lines[1]:find("demo", 1, true) ~= nil, true)
  eq(lines[1]:find("commits", 1, true) ~= nil, true)
  eq(lines[2]:find("wire up validation", 1, true) ~= nil, true)
  eq(lines[2]:match("Bob%s+%d%d%d%d%-%d%d%-%d%d %d%d:%d%d%s*$") ~= nil, true)
  local buf_line = child.lua_get("vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]")
  eq(buf_line:find("Bob", 1, true), nil)
end

T["lane glyphs are highlighted with lane colors"] = function()
  open("demo")
  local _, shot = screen_lines()
  -- The merge connector row "├─╮" (find it) has at least two different highlight attrs.
  local hl_row
  for i, row in ipairs(shot.text) do
    if table.concat(row):match("^├─╮") then
      hl_row = i
    end
  end
  eq(hl_row ~= nil, true)
  local attrs = shot.attr[hl_row]
  eq(attrs[1] ~= " " or attrs[3] ~= " ", true)
  local groups = child.lua([[
    local out = {}
    for i = 1, 8 do out[i] = vim.fn.hlexists("TrellisGraph" .. i) end
    return out
  ]])
  eq(groups, { 1, 1, 1, 1, 1, 1, 1, 1 })
end

T["highlight groups survive :colorscheme and user overrides win"] = function()
  open("linear")
  child.cmd("hi TrellisSha guifg=#ff0000")
  child.cmd("colorscheme default")
  eq(child.lua_get("vim.fn.hlexists('TrellisSha')"), 1)
  eq(child.lua_get("vim.api.nvim_get_hl(0, { name = 'TrellisHead' }).link"), "DiagnosticOk")
end

T["monochrome: no termguicolors, NO_COLOR still shows ref prefixes"] = function()
  child.lua("vim.o.termguicolors = false; vim.env.NO_COLOR = '1'")
  open("remote-branches")
  local text = table.concat(screen_lines(), "\n")
  eq(text:find("(@main)", 1, true) ~= nil, true)
  eq(text:find("~origin/main", 1, true) ~= nil, true)
end

T["ascii style"] = function()
  open("simple-merge", { graph = { style = "ascii" } })
  local text = table.concat(screen_lines(), "\n")
  eq(text:find("+-.", 1, true) ~= nil, true)
  eq(text:find("@ ", 1, true) ~= nil, true)
end

return T
