-- External changes refresh the graph within 1 s, the cursor stays on the same commit,
-- bursts are debounced, and unrelated changes do not reload history.
local fixtures = require("tests.fixtures")
local G = require("tests.helpers.graph")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function setup(cfg)
  local r = fixtures.fresh("two-branches")
  local v = G.open(r.path, cfg)
  eq(G.wait_loaded(v), true)
  local refreshes = 0
  vim.api.nvim_create_autocmd("User", {
    pattern = "TrellisRefsChanged",
    callback = function()
      refreshes = refreshes + 1
    end,
  })
  return r, v, function()
    return refreshes
  end
end

local function cursor_sha(v)
  local idx = require("trellis.view.graph").cursor_commit(v)
  return v.shown.model.sha[idx]
end

T["external commit refreshes within 1 s and keeps the cursor on its commit"] = function()
  local r, v, count = setup()
  -- Put the cursor on feature's tip.
  local feature = r:rev("feature")
  local m = v.shown.model
  vim.api.nvim_win_set_cursor(0, { m.row_of_commit[m.index[feature]], 0 })
  local t0 = vim.uv.hrtime()
  r:commit({ msg = "external", files = { ["m.txt"] = "external\n" } })
  eq(
    vim.wait(3000, function()
      return v.shown.model.index[r:rev("main")] ~= nil and G.wait_loaded(v, 1)
    end, 10),
    true
  )
  local ms = (vim.uv.hrtime() - t0) / 1e6
  eq({ within_1s = ms < 1000, ms = math.floor(ms) }, { within_1s = true, ms = math.floor(ms) })
  eq(count(), 1)
  eq(G.subjects(v)[1], "external")
  eq(cursor_sha(v), feature)
end

T["branches, tags, checkout and detaching are picked up"] = function()
  local r, v, count = setup()
  r:branch("new-branch", "main~1")
  eq(
    vim.wait(2000, function()
      return table.concat(G.lines(v), "\n"):find("new-branch", 1, true) ~= nil
    end, 10),
    true
  )
  r:tag("v9")
  eq(
    vim.wait(2000, function()
      return table.concat(G.lines(v), "\n"):find("#v9", 1, true) ~= nil
    end, 10),
    true
  )
  r:switch("feature")
  eq(
    vim.wait(2000, function()
      return table.concat(G.lines(v), "\n"):find("(@feature)", 1, true) ~= nil
    end, 10),
    true
  )
  eq(count() >= 3, true)
end

T["a burst of changes is debounced; index-only changes are ignored"] = function()
  local r, v, count = setup({ graph = { max_decorations = 10 } })
  for i = 1, 5 do
    r:update_refs({ ("create refs/heads/burst%d %s"):format(i, r:rev("main")) })
  end
  eq(
    vim.wait(2000, function()
      return table.concat(G.lines(v), "\n"):find("burst5", 1, true) ~= nil
    end, 10),
    true
  )
  vim.wait(400)
  eq(count() <= 2, true)
  local before = count()
  -- Staging only touches the index: no history reload.
  r:write({ ["a.txt"] = "staged\n" })
  r:git({ "add", "a.txt" })
  vim.wait(700)
  eq(count(), before)
end

T["the watcher stops when the view is closed"] = function()
  local r, v = setup()
  local w = v.watcher
  vim.api.nvim_buf_delete(v.bufnr, { force = true })
  r:commit({ msg = "after close" })
  vim.wait(500)
  eq(require("trellis.view.graph").get(v.bufnr), nil)
  eq(w ~= nil, true)
end

T["fs_poll fallback notices external commits"] = function()
  local r = fixtures.fresh("linear")
  local repo
  require("trellis.git.repo").discover(r.path, function(_, x)
    repo = x
  end)
  vim.wait(3000, function()
    return repo
  end)
  local fired = 0
  local w = require("trellis.git.watch").watch(repo, function()
    fired = fired + 1
  end, { force_poll = true, poll_ms = 100, debounce_ms = 50 })
  eq(w.mode, "poll")
  vim.wait(300)
  r:commit({ msg = "polled", files = { ["a.txt"] = "polled\n" } })
  eq(
    vim.wait(3000, function()
      return fired > 0
    end, 20),
    true
  )
  w.close()
end

T["ambiwidth=double falls back to ascii glyphs"] = function()
  vim.o.ambiwidth = "double"
  local v = G.open(fixtures.get("simple-merge").path, { graph = { style = "rounded" } })
  eq(G.wait_loaded(v), true)
  eq(v.style, "ascii")
  local text = table.concat(G.lines(v), "\n")
  eq(text:find("│", 1, true), nil)
  eq(text:find("+-.", 1, true) ~= nil, true)
end

T["ops view: details show commands, P prunes after asking"] = function()
  local r = fixtures.fresh("linear")
  local S = require("tests.helpers.safety")
  local repo = S.repo(r.path)
  S.auto_confirm(true)
  S.run(function()
    return require("trellis.actions").tag_create(repo, "x1")
  end)
  require("trellis.view.ops").open(repo)
  vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "x", false)
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  eq(text:find("$ git tag x1", 1, true) ~= nil, true)
  eq(text:find("refs/trellis/backup/", 1, true) ~= nil, true)
  require("trellis").setup({ safety = { backup_max_ops = 0 } })
  vim.api.nvim_feedkeys("P", "x", false)
  eq(
    vim.wait(5000, function()
      return r:git({ "for-each-ref", "refs/trellis/" }) == ""
    end),
    true
  )
  eq(S.asked[#S.asked].title:find("Delete the backup refs", 1, true) ~= nil, true)
end

T["ignored paths"] = function()
  local ignored = require("trellis.git.watch")._ignored
  eq(ignored("index"), true)
  eq(ignored("refs/heads/main.lock"), true)
  eq(ignored("objects/ab/cdef"), true)
  eq(ignored("trellis/ops.jsonl"), true)
  eq(ignored("HEAD"), false)
  eq(ignored("refs\\heads\\main"), false)
end

return require("tests.helpers.child").run_in_child(T, "tests/integration/watch_spec.lua")
