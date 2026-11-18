-- T062 + T066: line range history (`git log -L`) and permalinks from file buffers.
local fixtures = require("tests.fixtures")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function wait_view(kind)
  return vim.wait(5000, function()
    return vim.b.trellis_view == kind
  end, 5)
end

T[":[range]Trellis history lists every commit of the range with its hunk"] = function()
  local r = fixtures.fresh("blame-chain")
  vim.cmd("edit " .. r.path .. "/src/api.lua")
  vim.cmd("4Trellis history")
  eq(wait_view("linehistory"), true)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local headers = vim.tbl_filter(function(l)
    return l:match("^%x%x%x%x%x%x%x ") ~= nil
  end, lines)
  eq(#headers, 7)
  eq(headers[1]:find("back to retry = 3", 1, true) ~= nil, true)
  eq(headers[7]:find("add api", 1, true) ~= nil, true)
  eq(vim.tbl_contains(lines, "+retry = 3"), true)
  eq(vim.tbl_contains(lines, "-retry = 6"), true)
  -- <CR> on a hunk line opens that commit.
  for i, l in ipairs(lines) do
    if l == "-retry = 6" then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      break
    end
  end
  vim.cmd("normal \r")
  eq(wait_view("commit"), true)
  eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "commit " .. r:rev("HEAD"))
end

T["visual range and uncommitted lines above the range are mapped to HEAD"] = function()
  local r = fixtures.fresh("blame-chain")
  local file = r.path .. "/src/api.lua"
  -- Two new lines at the top, saved: the retry line is now line 6 in the working copy.
  r:write({ ["src/api.lua"] = "-- new 1\n-- new 2\n" .. r:read("src/api.lua") })
  vim.cmd("edit " .. file)
  eq(vim.api.nvim_buf_get_lines(0, 5, 6, false)[1], "retry = 3")
  vim.cmd("6,6Trellis history")
  eq(wait_view("linehistory"), true)
  local headers = vim.tbl_filter(function(l)
    return l:match("^%x%x%x%x%x%x%x ") ~= nil
  end, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  eq(#headers, 7)
end

T["history of a function moved within the file"] = function()
  local r = fixtures.get("whitespace-moves")
  vim.cmd("edit " .. r.path .. "/m.lua")
  -- Block a (lines 5-7) at HEAD.
  vim.cmd("5,7Trellis history")
  eq(wait_view("linehistory"), true)
  local headers = vim.tbl_filter(function(l)
    return l:match("^%x%x%x%x%x%x%x ") ~= nil
  end, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  -- git log -L does not follow code moved within a file: the move shows as new lines, so the
  -- history is exactly what git reports.
  local git = vim.split(
    vim.trim(r:git({ "log", "-L", "5,7:m.lua", "--format=%x1e%s", "--no-patch" })),
    "",
    { trimempty = true }
  )
  eq(#headers, #vim.tbl_filter(function(x)
    return vim.trim(x) ~= ""
  end, git))
  eq(headers[1]:find("move a below b", 1, true) ~= nil, true)
end

T["permalinks for lines of a file and for a commit from the graph"] = function()
  local r = fixtures.fresh("remote-branches")
  r:git({ "config", "remote.origin.url", "git@github.com:example/demo.git" })
  vim.cmd("edit " .. r.path .. "/a.txt")
  local url
  require("trellis").permalink({ line1 = 1, line2 = 1 }, function(_, u)
    url = u
  end)
  eq(
    vim.wait(3000, function()
      return url ~= nil
    end),
    true
  )
  eq(url, "https://github.com/example/demo/blob/" .. r:rev("HEAD") .. "/a.txt#L1")
  eq(vim.fn.getreg('"'), url)

  local G = require("tests.helpers.graph")
  local v = G.open(r.path)
  eq(G.wait_loaded(v), true)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("normal gL")
  eq(
    vim.wait(3000, function()
      return vim.fn.getreg('"') == "https://github.com/example/demo/commit/" .. r:rev("HEAD")
    end),
    true
  )
end

return require("tests.helpers.child").run_in_child(T, "tests/integration/linehistory_spec.lua")
