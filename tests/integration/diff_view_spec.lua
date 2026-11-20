-- Unified diff view (folds, navigation), side-by-side adapters (builtin
-- :diffthis fallback), file history view with renames.
local fixtures = require("tests.fixtures")
local I = require("tests.helpers.inspect")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["unified diff with one fold per file"] = function()
  local r = fixtures.get("demo")
  local repo = I.repo(r.path)
  require("trellis.view.diff").open(repo, r:rev("main~12"), r:rev("main"), { split = "current" })
  eq(
    vim.wait(3000, function()
      return vim.bo.filetype == "diff"
    end),
    true
  )
  eq(vim.wo.foldmethod, "expr")
  local files = 0
  for _, l in ipairs(I.lines()) do
    if l:sub(1, 11) == "diff --git " then
      files = files + 1
    end
  end
  eq(files > 3, true)
  -- One closed fold per file.
  vim.cmd("normal zM")
  local closed, lnum = 0, 1
  while lnum <= vim.api.nvim_buf_line_count(0) do
    local fe = vim.fn.foldclosedend(lnum)
    if fe > 0 then
      closed = closed + 1
      lnum = fe + 1
    else
      lnum = lnum + 1
    end
  end
  eq(closed, files)
  vim.cmd("normal zR")
  -- `o` on a hunk line opens the new version at that line.
  local lnum2 = I.find_line("^%+retry = 3$")
  if lnum2 then
    vim.api.nvim_win_set_cursor(0, { lnum2, 0 })
    vim.cmd("normal o")
    eq(I.wait_view("filerev"), true)
    eq(vim.api.nvim_get_current_line(), "retry = 3")
  end
end

T["diff against the working tree and :Trellis diff"] = function()
  local r = fixtures.fresh("linear")
  r:write({ ["a.txt"] = "changed\n" })
  vim.cmd("cd " .. r.path)
  vim.cmd("Trellis diff HEAD -- a.txt")
  eq(
    vim.wait(3000, function()
      return vim.bo.filetype == "diff"
    end),
    true
  )
  eq(I.find_line("^%+changed$") ~= nil, true)
end

T["builtin side-by-side uses :diffthis on two trellis:// buffers"] = function()
  local r = fixtures.get("demo")
  local repo = I.repo(r.path)
  require("trellis.view.diff").side_by_side(
    repo,
    r:rev("v1.0.0~1"),
    r:rev("v1.0.0"),
    { path = "src/api.lua" }
  )
  eq(
    vim.wait(5000, function()
      local wins = vim.api.nvim_tabpage_list_wins(0)
      return #wins == 2 and vim.wo[wins[1]].diff and vim.wo[wins[2]].diff
    end),
    true
  )
  local names = vim.tbl_map(function(w)
    return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
  end, vim.api.nvim_tabpage_list_wins(0))
  table.sort(names)
  eq(names[1]:match("^trellis://%x+/src/api.lua$") ~= nil, true)
  eq(names[2]:match("^trellis://%x+/src/api.lua$") ~= nil, true)
end

T["side-by-side for added files has an empty left side"] = function()
  local r = fixtures.get("demo")
  local repo = I.repo(r.path)
  require("trellis.view.diff").side_by_side(
    repo,
    r:rev("main~1"),
    r:rev("main"),
    { path = "VERSION", added = true }
  )
  eq(
    vim.wait(5000, function()
      local wins = vim.api.nvim_tabpage_list_wins(0)
      return #wins == 2 and vim.wo[wins[2]].diff
    end),
    true
  )
end

T["file history follows renames; o opens the old path; d diffs"] = function()
  local r = fixtures.get("rename-chain")
  vim.cmd("cd " .. r.path)
  vim.cmd("Trellis file src/renamed_thrice.lua")
  eq(
    vim.wait(3000, function()
      return vim.b.trellis_view == "filehistory"
    end),
    true
  )
  local lines = I.lines()
  -- 6 commits touch the file: add, edit, rename, edit, rename, rename+edit.
  eq(#lines, 6)
  eq(lines[1]:find("(lib/newer.lua → src/renamed_thrice.lua)", 1, true) ~= nil, true)
  -- Oldest entry: the file under its first name.
  vim.api.nvim_win_set_cursor(0, { #lines, 0 })
  vim.cmd("normal o")
  eq(I.wait_view("filerev"), true)
  eq(vim.b.trellis.path, "src/old.lua")
  eq(vim.b.trellis.sha, r:rev("HEAD~5"))
  -- ]r from here walks forward through the shared history.
  vim.cmd("normal ]r")
  eq(
    vim.wait(3000, function()
      return vim.b.trellis.sha == r:rev("HEAD~4")
    end),
    true
  )
end

T[":Trellis file without argument uses the current file"] = function()
  local r = fixtures.fresh("blame-chain")
  vim.cmd("edit " .. r.path .. "/src/api.lua")
  vim.cmd("Trellis file")
  eq(
    vim.wait(3000, function()
      return vim.b.trellis_view == "filehistory"
    end),
    true
  )
  eq(#I.lines(), 7)
end

T["graph keys: d, M + =, <Tab>, o"] = function()
  local r = fixtures.get("demo")
  local G = require("tests.helpers.graph")
  local v = G.open(r.path)
  eq(G.wait_loaded(v), true)
  local m = v.shown.model
  local function goto_sha(sha)
    vim.api.nvim_set_current_win(vim.fn.bufwinid(v.bufnr))
    vim.api.nvim_win_set_cursor(0, { m.row_of_commit[m.index[sha]], 0 })
  end
  -- <Tab>: inline file list as virtual lines.
  local function press(keys)
    vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
  end
  goto_sha(r:rev("v1.0.0"))
  press("<Tab>")
  eq(
    vim.wait(3000, function()
      return #vim.api.nvim_buf_get_extmarks(
        v.bufnr,
        require("trellis.view.graph").preview_ns,
        0,
        -1,
        {}
      ) == 1
    end),
    true
  )
  press("<Tab>")
  eq(
    #vim.api.nvim_buf_get_extmarks(v.bufnr, require("trellis.view.graph").preview_ns, 0, -1, {}),
    0
  )
  -- d: the commit's diff.
  vim.cmd("normal d")
  eq(
    vim.wait(3000, function()
      return vim.bo.filetype == "diff"
    end),
    true
  )
  eq(I.find_line("^%+retry = 5$") ~= nil, true)
  -- M then =: compare two commits.
  goto_sha(r:rev("main~1"))
  press("M")
  eq(v.mark, r:rev("main~1"))
  goto_sha(r:rev("main"))
  vim.cmd("normal =")
  eq(
    vim.wait(3000, function()
      return vim.bo.filetype == "diff" and I.find_line("VERSION") ~= nil
    end),
    true
  )
  -- o: single file commit opens it directly.
  goto_sha(r:rev("main"))
  vim.cmd("normal o")
  eq(I.wait_view("filerev"), true)
  eq(vim.b.trellis.path, "VERSION")
end

return require("tests.helpers.child").run_in_child(T, "tests/integration/diff_view_spec.lua")
