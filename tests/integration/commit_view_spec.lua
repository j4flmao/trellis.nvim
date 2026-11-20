-- Commit view — metadata, refs, parents (jumpable), merge parent choice, renames,
-- binary stats. Runs in a child Neovim per case.
local fixtures = require("tests.fixtures")
local I = require("tests.helpers.inspect")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function open(name, rev, opts)
  local r = fixtures.get(name)
  local repo = I.repo(r.path)
  require("trellis.view.commit").open(
    repo,
    rev,
    vim.tbl_extend("force", { split = "current" }, opts or {})
  )
  eq(I.wait_view("commit"), true)
  return r, repo
end

T["metadata, refs, message and files"] = function()
  local r = open("demo", "v1.0.0")
  local lines = I.lines()
  local sha = r:rev("v1.0.0")
  eq(lines[1], "commit " .. sha)
  eq(
    lines[2]:match("^Author:%s+Alice <alice@example.com>  %d%d%d%d%-%d%d%-%d%d %d%d:%d%d %+0000$")
      ~= nil,
    true
  )
  local _, refs = I.find_line("^Refs:")
  eq(refs, "Refs:       ~origin/main #v1.0.0")
  local _, parent = I.find_line("^Parent:")
  eq(parent, "Parent:     " .. r:rev("v1.0.0~1"):sub(1, 7) .. " Add renamed module")
  eq(I.find_line("^    Raise retry to 5$") ~= nil, true)
  local _, header = I.find_line("^Files")
  eq(header, "Files (1):")
  local _, file = I.find_line("src/api.lua")
  eq(file, " M  src/api.lua  +1 -1")
  -- Cursor starts on the first file; buffer is read-only and named after the commit.
  eq(vim.api.nvim_get_current_line(), file)
  eq(vim.bo.modifiable, false)
  eq(vim.api.nvim_buf_get_name(0), "trellis://commit/" .. sha:sub(1, 7))
end

T["renames, binaries and root commits"] = function()
  open("rename-chain", "HEAD")
  local _, f = I.find_line("→")
  eq(f, " R  lib/newer.lua → src/renamed_thrice.lua  +1 -1")
  vim.cmd("bwipeout")
  open("binary-file", "HEAD")
  eq(select(2, I.find_line("logo.png")), " M  assets/logo.png  binary")
  vim.cmd("bwipeout")
  open("single", "HEAD")
  eq(select(2, I.find_line("^Files")), "Files (1, root commit):")
  eq(I.find_line("^Parent") == nil, true)
end

T["merge commits: parents listed, choose a parent or combined"] = function()
  local r = open("simple-merge", "HEAD")
  local p1 = I.find_line("^Parent 1:")
  local p2 = I.find_line("^Parent 2:")
  eq(p1 ~= nil and p2 ~= nil, true)
  eq(select(2, I.find_line("^Files")):find("against parent 1", 1, true) ~= nil, true)
  -- First parent: the feature files arrive with the merge.
  eq(I.find_line("feature.txt") ~= nil, true)
  -- Choose parent 2 through vim.ui.select.
  local orig = vim.ui.select
  vim.ui.select = function(items, _, cb)
    cb(items[2])
  end
  vim.cmd("normal P")
  vim.ui.select = orig
  eq(
    vim.wait(3000, function()
      local _, h = I.find_line("^Files")
      return h and h:find("against parent 2", 1, true) ~= nil
    end),
    true
  )
  eq(I.find_line("m.txt") ~= nil, true)
  eq(I.find_line("feature.txt"), nil)
  -- Combined.
  vim.ui.select = function(items, _, cb)
    cb(items[#items])
  end
  vim.cmd("normal P")
  vim.ui.select = orig
  eq(
    vim.wait(3000, function()
      local _, h = I.find_line("^Files")
      return h and h:find("combined", 1, true) ~= nil
    end),
    true
  )
  eq(r ~= nil, true)
end

T["parents are jumpable"] = function()
  local r = open("linear", "HEAD")
  local lnum = I.find_line("^Parent:")
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  vim.cmd("normal \r")
  eq(
    vim.wait(3000, function()
      return I.lines()[1] == "commit " .. r:rev("HEAD~1")
    end),
    true
  )
  vim.cmd("normal p")
  eq(
    vim.wait(3000, function()
      return I.lines()[1] == "commit " .. r:rev("HEAD~2")
    end),
    true
  )
end

T["<CR> on a file opens its unified diff, o the file at the revision"] = function()
  local r = open("demo", "v1.0.0")
  local lnum = I.find_line("src/api.lua")
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  vim.cmd("normal \r")
  eq(
    vim.wait(3000, function()
      return vim.bo.filetype == "diff"
    end),
    true
  )
  eq(I.find_line("^%-retry = 1$") ~= nil and I.find_line("^%+retry = 5$") ~= nil, true)
  vim.cmd("normal q")
  eq(I.wait_view("commit"), true)
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  vim.cmd("normal o")
  eq(I.wait_view("filerev"), true)
  eq(vim.api.nvim_buf_get_name(0), "trellis://" .. r:rev("v1.0.0"):sub(1, 7) .. "/src/api.lua")
end

T["the diff replaces the commit view in its window; q comes back to the same line"] = function()
  open("demo", "v1.0.0")
  local wins = #vim.api.nvim_list_wins()
  local win, commit_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local lnum = I.find_line("src/api.lua")
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  vim.cmd("normal \r")
  eq(
    vim.wait(3000, function()
      return vim.bo.filetype == "diff"
    end),
    true
  )
  -- No extra window: the diff took the commit view's place.
  eq({ #vim.api.nvim_list_wins(), vim.api.nvim_get_current_win() }, { wins, win })
  local diff_buf = vim.api.nvim_get_current_buf()
  vim.cmd("normal q")
  eq(vim.api.nvim_get_current_buf(), commit_buf)
  eq(vim.api.nvim_win_get_cursor(0)[1], lnum)
  eq(#vim.api.nvim_list_wins(), wins)
  eq(
    vim.wait(1000, function()
      return not vim.api.nvim_buf_is_valid(diff_buf)
    end),
    true
  )
  -- The commit view is still a normal (wiped when hidden) trellis buffer.
  eq(vim.bo[commit_buf].bufhidden, "wipe")
end

T['views.diff.open = "split" keeps the old window per diff'] = function()
  require("trellis").setup({ views = { diff = { open = "split" } } })
  open("demo", "v1.0.0")
  local wins = #vim.api.nvim_list_wins()
  vim.api.nvim_win_set_cursor(0, { I.find_line("src/api.lua"), 0 })
  vim.cmd("normal \r")
  eq(
    vim.wait(3000, function()
      return vim.bo.filetype == "diff"
    end),
    true
  )
  eq(#vim.api.nvim_list_wins(), wins + 1)
end

T["issue and pull request references become links; <CR> opens them"] = function()
  local r = fixtures.fresh("demo") -- origin is https://github.com/example/trellis-demo.git
  r:commit({ msg = "Fix login crash (#42)\n\nCloses #7.\n", files = { ["x.txt"] = "x\n" } })
  local repo = I.repo(r.path)
  require("trellis.view.commit").open(repo, "HEAD", { split = "current" })
  eq(I.wait_view("commit"), true)
  local lnum, first = I.find_line("^Links:")
  eq(first, "Links:      #42  https://github.com/example/trellis-demo/issues/42")
  eq(I.lines()[lnum + 1], "            #7  https://github.com/example/trellis-demo/issues/7")
  local opened
  local orig = vim.ui.open
  vim.ui.open = function(url)
    opened = url
  end
  vim.api.nvim_win_set_cursor(0, { lnum + 1, 0 })
  vim.cmd("normal \r")
  vim.ui.open = orig
  eq(opened, "https://github.com/example/trellis-demo/issues/7")
  -- No remote: no links, the view still opens.
  vim.cmd("bwipeout")
  local plain = fixtures.fresh("linear")
  plain:commit({ msg = "Refs #1", files = { ["y.txt"] = "y\n" } })
  require("trellis.view.commit").open(I.repo(plain.path), "HEAD", { split = "current" })
  eq(I.wait_view("commit"), true)
  eq(I.find_line("^Links:"), nil)
end

T[":Trellis commit and the graph's <CR>"] = function()
  local r = fixtures.get("demo")
  vim.cmd("cd " .. r.path)
  vim.cmd("Trellis commit v1.0.0")
  eq(I.wait_view("commit"), true)
  eq(I.lines()[1], "commit " .. r:rev("v1.0.0"))
  vim.cmd("bwipeout")
  local G = require("tests.helpers.graph")
  local v = G.open(r.path)
  eq(G.wait_loaded(v), true)
  local m = v.shown.model
  vim.api.nvim_win_set_cursor(0, { m.row_of_commit[m.index[r:rev("main")]], 0 })
  vim.cmd("normal \r")
  eq(I.wait_view("commit"), true)
  eq(I.lines()[1], "commit " .. r:rev("main"))
  -- A second <CR> in the graph reuses the commit window instead of stacking splits.
  local wins = #vim.api.nvim_tabpage_list_wins(0)
  vim.cmd("wincmd p")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("normal \r")
  eq(
    vim.wait(3000, function()
      return I.lines()[1] == "commit " .. r:rev("feature/login")
    end),
    true
  )
  eq(#vim.api.nvim_tabpage_list_wins(0), wins)
end

T["unknown revision is reported"] = function()
  local r = fixtures.get("linear")
  local repo = I.repo(r.path)
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  require("trellis.view.commit").open(repo, "no-such-rev")
  vim.wait(2000, function()
    return #msgs > 0
  end)
  vim.notify = orig
  eq(msgs[1], 'trellis: unknown revision "no-such-rev"')
end

return require("tests.helpers.child").run_in_child(T, "tests/integration/commit_view_spec.lua")
