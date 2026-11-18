-- T061: blame column — alignment with git's own blame, uncommitted lines, scrollbind,
-- time travel through a known 6-step edit chain, forward again, renames, -w/-M options.
-- Runs in a child Neovim per case.
local fixtures = require("tests.fixtures")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local blame = require("trellis.view.blame")

local function open_blame(file, cfg)
  require("trellis").setup(cfg or {})
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  local s
  blame.toggle({
    on_open = function(x)
      s = x
    end,
  })
  assert(
    vim.wait(5000, function()
      return s ~= nil and s.loaded
    end, 5),
    "blame did not load"
  )
  return s
end

local function wait_loaded(s, pred)
  return vim.wait(5000, function()
    return s.loaded and (not pred or pred())
  end, 5)
end

--- git's own blame of the same file: line → sha.
local function git_blame(r, args, rev, path)
  local cmd = { "blame", "--porcelain" }
  vim.list_extend(cmd, args)
  if rev then
    cmd[#cmd + 1] = rev
  end
  vim.list_extend(cmd, { "--", path })
  local out = r:git(cmd)
  local by_line = {}
  for sha, final in out:gmatch("\n?(%x+) %d+ (%d+)") do
    if #sha >= 40 then
      by_line[tonumber(final)] = sha
    end
  end
  return by_line
end

T["column is aligned with git blame, bound to the file window"] = function()
  local r = fixtures.get("demo")
  local s = open_blame(r.path .. "/src/api.lua")
  local expected = git_blame(r, { "-w", "-M" }, nil, "src/api.lua")
  local n = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(s.file_win))
  eq(vim.api.nvim_buf_line_count(s.blame_buf), n)
  for i = 1, n do
    eq({ line = i, sha = s.lines[i].sha }, { line = i, sha = expected[i] })
  end
  local text = vim.api.nvim_buf_get_lines(s.blame_buf, 3, 4, false)[1]
  eq(text:match("^%x%x%x%x%x%x%x %d%d%d%d%-%d%d%-%d%d Alice") ~= nil, true)
  eq(vim.wo[s.file_win].scrollbind and vim.wo[s.blame_win].scrollbind, true)
  eq(vim.wo[s.file_win].cursorbind and vim.wo[s.blame_win].cursorbind, true)
  eq(vim.api.nvim_win_get_width(s.blame_win), require("trellis.config").get().blame.width)
  eq(vim.api.nvim_get_current_win(), s.blame_win)
  -- Heat highlights exist.
  eq(#vim.api.nvim_buf_get_extmarks(s.blame_buf, blame.ns, 0, -1, {}) > 0, true)
  -- t cycles the detail level.
  vim.cmd("normal t")
  eq(vim.api.nvim_buf_get_lines(s.blame_buf, 3, 4, false)[1]:find("retry", 1, true) ~= nil, true)
  -- Toggling closes and unbinds.
  vim.cmd("Trellis blame")
  eq(vim.api.nvim_win_is_valid(s.blame_win), false)
  eq(vim.wo[s.file_win].scrollbind, false)
end

T["opens on the cursor line of the file"] = function()
  local r = fixtures.get("demo")
  require("trellis").setup({})
  vim.cmd("edit " .. vim.fn.fnameescape(r.path .. "/src/api.lua"))
  local n = vim.api.nvim_buf_line_count(0)
  local line = math.max(2, math.floor(n / 2))
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  local s
  blame.toggle({
    on_open = function(x)
      s = x
    end,
  })
  assert(
    vim.wait(5000, function()
      return s ~= nil
    end, 5),
    "blame did not open"
  )
  -- As soon as the column opens (blame may still be running): both windows are on `line`.
  eq(vim.api.nvim_win_get_cursor(s.blame_win)[1], line)
  eq(vim.api.nvim_win_get_cursor(s.file_win)[1], line)
  assert(wait_loaded(s), "blame did not load")
  eq(vim.api.nvim_win_get_cursor(s.blame_win)[1], line)
  eq(vim.api.nvim_win_get_cursor(s.file_win)[1], line)
end

T["unsaved edits are blamed as not committed yet"] = function()
  local r = fixtures.fresh("blame-chain")
  local s = open_blame(r.path .. "/src/api.lua")
  local buf = vim.api.nvim_win_get_buf(s.file_win)
  vim.api.nvim_buf_set_lines(buf, 3, 4, false, { "retry = 99" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  eq(
    vim.wait(3000, function()
      return s.loaded and s.lines[4] and s.lines[4].sha == blame.UNCOMMITTED
    end, 5),
    true
  )
  eq(vim.trim(vim.api.nvim_buf_get_lines(s.blame_buf, 3, 4, false)[1]), "Not committed yet")
  eq(s.lines[3].sha ~= blame.UNCOMMITTED, true)
end

T["[ walks back through a line's 6-step history to its creation, ] comes back"] = function()
  local r = fixtures.fresh("blame-chain")
  local s = open_blame(r.path .. "/src/api.lua")
  -- The file line at the blame cursor (cursorbind only syncs on cursor events).
  local function file_line()
    local lnum = vim.api.nvim_win_get_cursor(s.blame_win)[1]
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(s.file_win), lnum - 1, lnum, false)[1]
  end
  vim.api.nvim_win_set_cursor(s.blame_win, { 4, 0 })
  eq(file_line(), "retry = 3")
  -- HEAD = "back to retry = 3"; each [ goes to the parent of the commit that changed the line.
  local expected = { "retry = 6", "retry = 5", "retry = 4", "retry = 3", "retry = 2", "retry = 1" }
  for step, want in ipairs(expected) do
    vim.api.nvim_set_current_win(s.blame_win)
    vim.cmd("normal [")
    eq(
      wait_loaded(s, function()
        local vars = vim.b[vim.api.nvim_win_get_buf(s.file_win)].trellis
        return s.pos == step + 1 and vars and vars.sha == s.frames[s.pos].sha
      end),
      true
    )
    eq({ step = step, line = file_line() }, { step = step, line = want })
    eq(s.frames[s.pos].sha, r:rev("HEAD~" .. step))
  end
  -- At the creation commit there is no further step.
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  vim.cmd("normal [")
  vim.notify = orig
  eq(msgs[1]:find("introduced in " .. r:rev("HEAD~6"):sub(1, 7), 1, true) ~= nil, true)
  -- Winbar trail.
  eq(vim.wo[s.file_win].winbar:find("worktree", 1, true) ~= nil, true)
  eq(select(2, vim.wo[s.file_win].winbar:gsub("→", "")), 6)
  -- ] forward again, all the way to the working copy.
  for _ = 1, 6 do
    vim.cmd("normal ]")
    wait_loaded(s)
  end
  eq(s.pos, 1)
  eq(vim.api.nvim_win_get_buf(s.file_win), s.origin_buf)
  eq(file_line(), "retry = 3")
end

T["time travel follows renames"] = function()
  local r = fixtures.get("rename-chain")
  local s = open_blame(r.path .. "/src/renamed_thrice.lua")
  vim.api.nvim_win_set_cursor(s.blame_win, { 3, 0 })
  local paths = {}
  for _ = 1, 4 do
    local before = s.pos
    vim.cmd("normal [")
    wait_loaded(s, function()
      return s.pos ~= before and vim.b[vim.api.nvim_win_get_buf(s.file_win)].trellis_loaded
    end)
    if s.pos == before then
      break
    end
    paths[#paths + 1] = s.frames[s.pos].path
  end
  eq(vim.tbl_contains(paths, "lib/newer.lua"), true)
  eq(vim.tbl_contains(paths, "src/mid.lua"), true)
  eq(paths[#paths], "src/old.lua")
end

T["blame options are passed to git (-w, -M, -C)"] = function()
  local r = fixtures.get("whitespace-moves")
  for _, opt in ipairs({
    { cfg = { ignore_whitespace = false, detect_moves = false }, args = {} },
    { cfg = { ignore_whitespace = true, detect_moves = "file" }, args = { "-w", "-M" } },
    { cfg = { ignore_whitespace = true, detect_moves = "copies" }, args = { "-w", "-C" } },
  }) do
    local s = open_blame(r.path .. "/m.lua", { blame = opt.cfg })
    local expected = git_blame(r, opt.args, nil, "m.lua")
    for i, sha in pairs(expected) do
      eq(
        { args = opt.args, line = i, sha = s.lines[i].sha },
        { args = opt.args, line = i, sha = sha }
      )
    end
    blame.close(s)
  end
end

T["blame of a trellis:// revision buffer, <CR> and d"] = function()
  local r = fixtures.get("demo")
  local repo
  require("trellis.git.repo").discover(r.path, function(_, x)
    repo = x
  end)
  vim.wait(3000, function()
    return repo
  end)
  require("trellis.view.filerev").open(repo, "v1.0.0", "src/api.lua")
  vim.wait(3000, function()
    return vim.b.trellis_loaded
  end)
  local s
  blame.toggle({
    on_open = function(x)
      s = x
    end,
  })
  eq(
    vim.wait(5000, function()
      return s and s.loaded
    end),
    true
  )
  eq(s.frames[1].sha, r:rev("v1.0.0"))
  eq(s.lines[4].sha, r:rev("v1.0.0"))
  vim.api.nvim_win_set_cursor(s.blame_win, { 4, 0 })
  vim.cmd("normal d")
  eq(
    vim.wait(3000, function()
      return vim.bo.filetype == "diff"
    end),
    true
  )
  vim.cmd("close")
  vim.api.nvim_set_current_win(s.blame_win)
  vim.cmd("normal \r")
  eq(
    vim.wait(3000, function()
      return vim.b.trellis_view == "commit"
    end),
    true
  )
end

return require("tests.helpers.child").run_in_child(T, "tests/integration/blame_spec.lua")
