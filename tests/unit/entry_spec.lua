-- Command, URIs and view base. Synchronous; runs in the test process.
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["uri"] = MiniTest.new_set()

T["uri"]["parse and build round trip"] = function()
  local uri = require("trellis.uri")
  local sha = ("a1b2c3d4"):rep(5)
  eq(
    uri.parse(uri.file(sha, "src/api/client.ts")),
    { kind = "file", rev = "a1b2c3d", path = "src/api/client.ts" }
  )
  eq(uri.parse("trellis://a1b2c3d/dir with space/ü.lua").path, "dir with space/ü.lua")
  eq(uri.parse(uri.stage(3, "a.lua")), { kind = "stage", stage = 3, path = "a.lua" })
  eq(uri.parse(uri.commit(sha)), { kind = "commit", sha = "a1b2c3d" })
  eq(
    uri.parse(uri.diff(sha, sha, "x/y")),
    { kind = "diff", a = "a1b2c3d", b = "a1b2c3d", path = "x/y" }
  )
  eq(uri.parse("trellis://diff/abcd..ef01"), { kind = "diff", a = "abcd", b = "ef01" })
  eq(uri.parse(uri.graph(2)), { kind = "graph", n = 2 })
  eq(
    uri.parse("trellis://plan/20261117T153012-4f2a"),
    { kind = "plan", id = "20261117T153012-4f2a" }
  )
  eq(uri.parse("trellis://blame/src/a.lua"), { kind = "blame", path = "src/a.lua" })
end

T["uri"]["rejects malformed names"] = function()
  local uri = require("trellis.uri")
  for _, bad in ipairs({
    "file:///x",
    "trellis://",
    "trellis://abc1234",
    "trellis://zzz/x",
    "trellis://commit/xyz",
    "trellis://:1/",
  }) do
    local u, err = uri.parse(bad)
    eq(
      { bad = bad, uri = u, has_err = type(err) == "string" },
      { bad = bad, uri = nil, has_err = true }
    )
  end
end

T["commands"] = MiniTest.new_set()

T["commands"]["argument parsing and completion"] = function()
  local commands = require("trellis.commands")
  eq({ commands.parse({}) }, { "graph", {} })
  eq({ commands.parse({ "blame" }) }, { "blame", {} })
  eq(
    { commands.parse({ "--author=alice", "--", "src/" }) },
    { "graph", { "--author=alice", "--", "src/" } }
  )
  eq({ commands.parse({ "rebase", "HEAD~3" }) }, { "rebase", { "HEAD~3" } })
  eq(
    commands.complete("re", "Trellis re"),
    { "rebase", "redo", "reflog", "reset", "restore", "revert" }
  )
  eq(commands.complete("", "Trellis rebase "), {})
  -- Every subcommand of the contract is known.
  for _, name in ipairs({
    "graph",
    "commit",
    "diff",
    "show",
    "file",
    "blame",
    "history",
    "rebase",
    "continue",
    "skip",
    "abort",
    "checkout",
    "branch",
    "tag",
    "cherry-pick",
    "revert",
    "reset",
    "restore",
    "undo",
    "redo",
    "ops",
    "log",
    "permalink",
    "commit-graph",
  }) do
    eq({ name = name, known = commands.subcommands[name] ~= nil }, { name = name, known = true })
  end
end

T["commands"][":Trellis is defined by the plugin file and reports unimplemented subcommands"] = function()
  eq(vim.fn.exists(":Trellis"), 2)
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  -- Every subcommand is implemented now; check the mechanism with a placeholder.
  local commands = require("trellis.commands")
  commands.subcommands["future-thing"] = { milestone = "v9.0.0" }
  vim.cmd("Trellis future-thing")
  commands.subcommands["future-thing"] = nil
  vim.notify = orig
  eq(msgs, { "trellis: `:Trellis future-thing` is not implemented yet (planned for v9.0.0)" })
  for name, spec in pairs(commands.subcommands) do
    eq({ name = name, implemented = spec.run ~= nil }, { name = name, implemented = true })
  end
end

T["view base"] = MiniTest.new_set()

T["view base"]["buffers, registry, keymaps and help"] = function()
  local base = require("trellis.view.base")
  local buf = base.create_buf(
    { name = "trellis://graph/99", kind = "graph", filetype = "trellisgraph", undolevels = -1 },
    { root = "/r" }
  )
  eq(vim.bo[buf].buftype, "nofile")
  eq(vim.bo[buf].modifiable, false)
  eq(vim.bo[buf].undolevels, -1)
  eq(vim.b[buf].trellis, { view = "graph", repo = "/r" })
  local disposed = false
  base.register({
    kind = "graph",
    bufnr = buf,
    dispose = function()
      disposed = true
    end,
  })
  eq(base.get(buf).kind, "graph")

  local called = {}
  local applied = base.apply_keymaps(buf, "graph", {
    cherry_pick = function()
      called[#called + 1] = "cp"
    end,
    close = function() end,
  })
  local names = vim.tbl_map(function(s)
    return s.name
  end, applied)
  table.sort(names)
  eq(names, { "cherry_pick", "close", "help" })
  local function find(maps, lhs)
    for _, m in ipairs(maps) do
      if m.lhs == lhs then
        return m
      end
    end
  end
  eq(find(vim.api.nvim_buf_get_keymap(buf, "n"), "c").desc, "trellis: Cherry-pick")
  eq(find(vim.api.nvim_buf_get_keymap(buf, "x"), "c") ~= nil, true)
  -- No global mappings were created.
  for _, mode in ipairs({ "n", "x" }) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      eq((m.desc or ""):match("^trellis:"), nil)
    end
  end

  local win = base.show_help("graph", applied)
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
  eq(#lines, 3)
  eq(vim.tbl_contains(lines, "c   Cherry-pick"), true)
  eq(lines[1], "g?  Show keymaps")
  vim.api.nvim_win_close(win, true)

  vim.api.nvim_buf_delete(buf, { force = true })
  eq(disposed, true)
  eq(base.get(buf), nil)
end

T["view base"]["open modes"] = function()
  local base = require("trellis.view.base")
  local tabs = #vim.api.nvim_list_tabpages()
  local buf = base.create_buf({ name = "trellis://graph/98", kind = "graph" })
  local win = base.open(buf, "tab")
  eq(#vim.api.nvim_list_tabpages(), tabs + 1)
  eq(vim.api.nvim_win_get_buf(win), buf)
  vim.cmd("tabclose")
  local wins = #vim.api.nvim_list_wins()
  local buf2 = base.create_buf({ name = "trellis://graph/97", kind = "graph" })
  base.open(buf2, "vertical")
  eq(#vim.api.nvim_list_wins(), wins + 1)
  vim.cmd("close")
end

T["setup and current() through the public API"] = function()
  local trellis = require("trellis")
  eq(trellis.setup({}), {})
  eq(trellis.current(), nil)
end

return T
