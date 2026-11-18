-- T030: graph view on fixtures — rows, decorations without color, special repositories,
-- motions. Every case runs in its own child Neovim.
local fixtures = require("tests.fixtures")
local G = require("tests.helpers.graph")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function open(name, cfg, args)
  local r = fixtures.get(name)
  local v = G.open(r.path, cfg, args)
  eq(G.wait_loaded(v), true)
  return v, r
end

T["rows match git log --topo-order and the layout model"] = function()
  local v, r = open("demo")
  local topo = r:topo({ "--branches", "--remotes", "--tags", "HEAD" })
  local m = v.shown.model
  eq(m.n, #topo)
  for i, c in ipairs(topo) do
    eq(m.sha[i], c.sha)
  end
  local lines = G.lines(v)
  eq(#lines, m.loaded)
  -- Commit rows: graph, short sha, decorations, subject.
  local head = r:rev("HEAD")
  local head_row = m.row_of_commit[m.index[head]]
  eq(lines[head_row], "◉ " .. head:sub(1, 7) .. " (@main) Bump version")
  local tag_row = m.row_of_commit[m.index[r:rev("v1.0.0")]]
  eq(lines[tag_row]:match("%((.-)%)"), "~origin/main #v1.0.0")
  -- Connector rows hold only graph glyphs.
  for row = 1, m.loaded do
    if m.rows_kind[row] == 0 then
      eq(lines[row]:match("^[│─├┤┬┴┼╭╮╰╯╱ ]+$") ~= nil, true)
    end
  end
  -- Cursor starts on HEAD.
  eq(vim.api.nvim_win_get_cursor(0)[1], head_row)
  eq(vim.bo[v.bufnr].modifiable, false)
  eq(vim.bo[v.bufnr].filetype, "trellisgraph")
  eq(vim.b[v.bufnr].trellis.view, "graph")
end

T["ref kinds are distinguishable without color"] = function()
  local v, r = open("remote-branches")
  local lines = table.concat(G.lines(v), "\n")
  eq(lines:find("(@main)", 1, true) ~= nil, true)
  eq(lines:find("~origin/main", 1, true) ~= nil, true)
  eq(lines:find("~origin/HEAD", 1, true), nil)

  local t = open("tags")
  local text = table.concat(G.lines(t), "\n")
  eq(text:find("#v1.0.0", 1, true) ~= nil, true)
  eq(text:find("#v0.2-annotated", 1, true) ~= nil, true)

  local d = open("detached-head")
  eq(table.concat(G.lines(d), "\n"):find("(@HEAD)", 1, true) ~= nil, true)
  eq(r ~= nil, true)
end

T["max_decorations collapses with +N; backups and stashes hidden by default"] = function()
  local v = open("branch-names", { graph = { max_decorations = 2 } })
  local root_line = G.lines(v)[#G.lines(v)]
  eq(root_line:match("%+%d+%)") ~= nil, true)

  local b = open("backup-refs")
  eq(table.concat(G.lines(b), "\n"):find("!", 1, true), nil)
  local s = open("stash")
  eq(table.concat(G.lines(s), "\n"):find("$stash", 1, true), nil)
end

T["unicode, control characters and long subjects are displayed safely"] = function()
  local v = open("control-chars")
  local text = table.concat(G.lines(v), "\n")
  -- Control bytes are shown in caret notation, never raw.
  eq(text:find("\27", 1, true), nil)
  eq(text:find("\30", 1, true), nil)
  eq(text:find("escape ^[[31mred^[[0m", 1, true) ~= nil, true)
  local u = open("unicode-messages")
  eq(table.concat(G.lines(u), "\n"):find("Sửa lỗi đăng nhập 🐛", 1, true) ~= nil, true)
end

T["empty, shallow and orphan repositories"] = function()
  local e = open("unborn")
  eq(G.lines(e), { "no commits yet" })
  local s = open("shallow")
  local text = table.concat(G.lines(s), "\n")
  eq(text:find("^grafted", 1, true) ~= nil, true)
  local o = open("orphan-unmerged")
  eq(#G.subjects(o), 4)
end

T["filters and revisions from :Trellis arguments"] = function()
  local v = open("merge-sequence", nil, { "b2" })
  eq(G.subjects(v), { "b2 2", "b2 1", "root" })
  local p = open("merge-sequence", nil, { "--", "b1.txt" })
  eq(#G.subjects(p), 2)
  local f = open("merge-sequence", nil, { "--first-parent", "main" })
  eq(G.subjects(f)[1], "Merge b3")
  eq(#G.subjects(f), 4)
  eq(
    vim.wait(1000, function()
      return vim.wo.winbar:find("first%-parent") ~= nil
    end),
    true
  )
end

T["motions: J/K, ]b/[b, gH, G"] = function()
  local v, r = open("demo")
  local m = v.shown.model
  local function row()
    return vim.api.nvim_win_get_cursor(0)[1]
  end
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  -- Find a connector row and step over it with J.
  local merge_row
  for row_ = 1, m.loaded do
    if m.rows_kind[row_] == 1 and m.subject[m.rows_commit[row_]] == "Merge branch 'docs'" then
      merge_row = row_
    end
  end
  vim.api.nvim_win_set_cursor(0, { merge_row, 0 })
  vim.cmd("normal J")
  eq(m.rows_kind[row()], 1)
  eq(row() > merge_row + 1, true)
  vim.cmd("normal K")
  eq(row(), merge_row)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  -- Row 1 has (feature/login); ]b moves to the next decorated commit.
  vim.cmd("normal ]b")
  eq(row(), m.row_of_commit[m.index[r:rev("main")]])
  vim.cmd("normal [b")
  eq(row(), 1)
  vim.cmd("normal gH")
  eq(row(), m.row_of_commit[m.index[r:rev("HEAD")]])
  vim.cmd("normal G")
  vim.wait(2000, function()
    return row() == m.loaded
  end)
  eq(row(), m.loaded)
  vim.cmd("normal 3G")
  eq(row(), 3)
end

T["copying shas, help float and closing"] = function()
  local v, r = open("linear")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("normal gy")
  eq(vim.fn.getreg('"'), r:rev("HEAD"):sub(1, 7))
  vim.cmd("normal gY")
  eq(vim.fn.getreg('"'), r:rev("HEAD"))
  -- Built-in yank still works on the line text.
  vim.cmd("normal yy")
  eq(vim.fn.getreg('"'):find(r:rev("HEAD"):sub(1, 7), 1, true) ~= nil, true)
  vim.cmd("normal g?")
  local float = vim.api.nvim_get_current_win()
  eq(vim.api.nvim_win_get_config(float).relative, "editor")
  vim.cmd("normal q")
  eq(vim.api.nvim_get_current_buf(), v.bufnr)
  local buf = v.bufnr
  vim.cmd("normal q")
  eq(vim.api.nvim_buf_is_valid(buf), false)
end

T["/ search finds subjects and refs in the buffer text"] = function()
  local v = open("demo")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.fn.search("Merge branch")
  local line = vim.api.nvim_get_current_line()
  eq(line:find("Merge branch 'docs'", 1, true) ~= nil, true)
  vim.fn.search("#v1.0.0")
  eq(vim.api.nvim_get_current_line():find("Raise retry to 5", 1, true) ~= nil, true)
  eq(v ~= nil, true)
end

T["fast first screen: provisional view without commit-graph, replaced by topo order"] = function()
  -- Fixtures have no commit-graph; date-skew makes commit-date order non-topological.
  local r = fixtures.get("date-skew")
  local v = G.open(r.path)
  eq(G.wait_loaded(v), true)
  eq(v.shown == v.loader, true)
  local topo = r:topo({ "--branches", "--remotes", "--tags", "HEAD" })
  for i, c in ipairs(topo) do
    eq(v.shown.model.sha[i], c.sha)
  end
end

return require("tests.helpers.child").run_in_child(T, "tests/integration/graph_view_spec.lua")
