-- Reflog view (lost commits, getting one back), stash view (show, apply, undo, redo) and the
-- commit picker backends. Runs in a child Neovim per case.
local fixtures = require("tests.fixtures")
local I = require("tests.helpers.inspect")
local S = require("tests.helpers.safety")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function wait(pred, ms)
  return vim.wait(ms or 5000, pred, 10)
end

local function tracked(r)
  return vim.split(vim.trim(r:out({ "ls-files" })), "\n")[1]
end

T["reflog"] = MiniTest.new_set()

T["reflog"]["lists where HEAD has been and marks lost commits; gb gets one back"] = function()
  local r = fixtures.fresh("linear")
  local lost = r:rev("HEAD")
  local lost_subject = r:out({ "log", "-1", "--format=%s" })
  r:git({ "reset", "-q", "--hard", "HEAD~2" })
  local repo = S.repo(r.path)
  local buf, entries
  require("trellis.view.reflog").open(repo, {
    split = "current",
    on_open = function(b, e)
      buf, entries = b, e
    end,
  })
  eq(
    wait(function()
      return buf ~= nil
    end),
    true
  )
  eq(vim.b.trellis_view, "reflog")
  -- Newest first: the reset, then the commit it left behind (lost).
  eq(entries[1].action:find("reset: moving to HEAD~2", 1, true) ~= nil, true)
  local lnum
  for i, e in ipairs(entries) do
    if e.sha == lost then
      lnum = lnum or i
    end
  end
  eq(entries[lnum].lost, true)
  local line = I.lines(buf)[lnum]
  eq(line:find(lost:sub(1, 7), 1, true) ~= nil, true)
  eq(line:find(lost_subject, 1, true) ~= nil, true)
  eq(line:match("lost$") ~= nil, true)
  -- The current HEAD is not lost.
  eq(entries[1].lost, nil)

  -- gb: a branch on the lost commit (through the safety pipeline: undoable).
  S.auto_confirm(true)
  local orig = vim.ui.input
  vim.ui.input = function(_, cb)
    cb("rescued")
  end
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  vim.cmd("normal gb")
  vim.ui.input = orig
  eq(
    wait(function()
      local out = r:git(
        { "rev-parse", "-q", "--verify", "refs/heads/rescued" },
        { allow_fail = true }
      )
      return vim.trim(out or "") == lost
    end, 10000),
    true
  )
  -- The view refreshes: no longer lost.
  eq(
    wait(function()
      return not I.lines(buf)[lnum]:match("lost$")
    end),
    true
  )
  local _, uerr = S.run(function()
    return require("trellis.safety.ops").undo(repo)
  end)
  eq(uerr, nil)
  eq(r:out({ "branch", "--list", "rescued" }), "")
end

T["reflog"]["<CR> opens the commit; a ref without reflog is reported"] = function()
  local r = fixtures.fresh("linear")
  local repo = S.repo(r.path)
  local buf
  require("trellis.view.reflog").open(repo, {
    split = "current",
    on_open = function(b)
      buf = b
    end,
  })
  eq(
    wait(function()
      return buf ~= nil
    end),
    true
  )
  vim.cmd("normal \r")
  eq(I.wait_view("commit"), true)
  eq(I.lines()[1], "commit " .. r:rev("HEAD"))
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  require("trellis.view.reflog").open(repo, { ref = "refs/heads/no-such-branch" })
  wait(function()
    return #msgs > 0
  end)
  vim.notify = orig
  eq(
    msgs[1] ~= nil
      and (msgs[1]:find("no reflog", 1, true) or msgs[1]:find("trellis:", 1, true)) ~= nil,
    true
  )
end

T["stash"] = MiniTest.new_set()

T["stash"]["show and apply an entry; undo puts the worktree back, redo applies again"] = function()
  local r = fixtures.fresh("linear")
  local file = tracked(r)
  r:write({ [file] = "stashed change\n" })
  r:git({ "stash", "push", "-q", "-m", "work in progress" })
  local clean = S.state(r)
  local repo = S.repo(r.path)
  local buf, entries
  require("trellis.view.stash").open(repo, {
    split = "current",
    on_open = function(b, e)
      buf, entries = b, e
    end,
  })
  eq(
    wait(function()
      return buf ~= nil
    end),
    true
  )
  eq(#entries, 1)
  eq(entries[1].selector, "stash@{0}")
  eq(I.lines(buf)[1]:find("On main: work in progress", 1, true) ~= nil, true)
  -- <CR>: the stash's changes.
  vim.cmd("normal \r")
  eq(
    wait(function()
      return vim.bo.filetype == "diff"
    end),
    true
  )
  eq(I.find_line("^%+stashed change$") ~= nil, true)

  -- a: apply (clean worktree), the entry stays.
  S.auto_confirm(true)
  local op, err = S.run(function()
    return require("trellis.actions").stash_apply(repo, entries[1])
  end)
  eq(
    { err = err, status = op.status, kind = op.kind },
    { err = nil, status = "done", kind = "stash-apply" }
  )
  eq(r:out({ "show", ":" .. file }) ~= "stashed change", true)
  eq(vim.trim(table.concat(vim.fn.readfile(r.path .. "/" .. file), "\n")), "stashed change")
  eq(#vim.split(r:out({ "stash", "list" }), "\n"), 1)

  -- Undo: the worktree is clean again; the applied changes are kept in a backup stash.
  local u, uerr = S.run(function()
    return require("trellis.safety.ops").undo(repo)
  end)
  eq(uerr, nil)
  eq(u.status, "done")
  eq(S.state(r), clean)
  eq(u.stash ~= nil, true)
  eq(r:out({ "show", u.stash .. ":" .. file }), "stashed change")

  -- Redo: applied again.
  local _, rerr = S.run(function()
    return require("trellis.safety.ops").redo(repo)
  end)
  eq(rerr, nil)
  eq(vim.trim(table.concat(vim.fn.readfile(r.path .. "/" .. file), "\n")), "stashed change")
end

T["stash"]["apply refuses a dirty worktree; trellis never drops entries"] = function()
  local r = fixtures.fresh("linear")
  local file = tracked(r)
  r:write({ [file] = "a\n" })
  r:git({ "stash", "push", "-q" })
  r:write({ [file] = "dirty\n" })
  local repo = S.repo(r.path)
  local entries
  require("trellis.view.stash").load(repo, function(_, e)
    entries = e
  end)
  wait(function()
    return entries ~= nil
  end)
  S.auto_confirm(true)
  local op, err = S.run(function()
    return require("trellis.actions").stash_apply(repo, entries[1])
  end)
  eq(op, nil)
  eq(err:find("clean worktree", 1, true) ~= nil, true)
  eq(require("trellis.git.runner").check_allowed ~= nil, true)
  eq(pcall(require("trellis.git.runner").build, r.path, { "stash", "drop" }), false)
end

T["pick"] = MiniTest.new_set()

local function picked_with(backend, setup)
  local r = fixtures.fresh("linear")
  local repo = S.repo(r.path)
  setup()
  local chosen
  require("trellis.pick").pick(repo, {
    backend = backend,
    on_choose = function(sha)
      chosen = sha
    end,
  })
  wait(function()
    return chosen ~= nil
  end)
  return chosen, r
end

T["pick"]["items read sha, subject, author and age"] = function()
  local items = require("trellis.pick").items({
    { sha = ("a"):rep(40), subject = "fix\tthings", author = "Ann", time = os.time() - 120 },
  })
  eq(items[1].text, "aaaaaaa fix things  Ann, 2 minutes ago")
end

T["pick"]["vim.ui.select"] = function()
  local orig = vim.ui.select
  local seen
  local chosen, r = picked_with("select", function()
    vim.ui.select = function(items, opts, cb)
      seen = { n = #items, prompt = opts.prompt, first = opts.format_item(items[1]) }
      cb(items[2])
    end
  end)
  vim.ui.select = orig
  eq(chosen, r:rev("HEAD~1"))
  eq(seen.prompt, "Commits")
  eq(seen.n, tonumber(r:out({ "rev-list", "--count", "HEAD" })))
  eq(seen.first:find(r:rev("HEAD"):sub(1, 7), 1, true), 1)
end

T["pick"]["Snacks.picker"] = function()
  local opts_seen
  local chosen, r = picked_with("snacks", function()
    _G.Snacks = {
      picker = {
        pick = function(o)
          opts_seen = o
          o.confirm({ close = function() end }, o.items[3])
        end,
      },
    }
  end)
  eq(chosen, r:rev("HEAD~2"))
  eq(opts_seen.title, "Commits")
  eq(type(opts_seen.format(opts_seen.items[1])), "table")
  eq(require("trellis.pick").backend("auto"), "snacks")
end

T["pick"]["Telescope"] = function()
  local chosen, r = picked_with("telescope", function()
    local selected
    package.loaded["telescope.pickers"] = {
      new = function(_, spec)
        return {
          find = function()
            local results = spec.finder.results
            selected = spec.finder.entry_maker(results[1])
            local replaced
            spec.attach_mappings(0)
            replaced = package.loaded["telescope.actions"].select_default.fn
            replaced()
          end,
        }
      end,
    }
    package.loaded["telescope.finders"] = {
      new_table = function(t)
        return t
      end,
    }
    package.loaded["telescope.config"] = { values = { generic_sorter = function() end } }
    package.loaded["telescope.actions"] = {
      close = function() end,
      select_default = {
        replace = function(self, fn)
          self.fn = fn
        end,
      },
    }
    package.loaded["telescope.actions.state"] = {
      get_selected_entry = function()
        return selected
      end,
    }
  end)
  eq(chosen, r:rev("HEAD"))
end

T["pick"]["fzf-lua"] = function()
  local chosen, r = picked_with("fzf-lua", function()
    package.loaded["fzf-lua"] = {
      fzf_exec = function(lines, o)
        o.actions.default({ lines[2] })
      end,
    }
  end)
  eq(chosen, r:rev("HEAD~1"))
end

return require("tests.helpers.child").run_in_child(T, "tests/integration/history_tools_spec.lua")
