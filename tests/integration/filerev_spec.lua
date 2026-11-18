-- T046: file-at-revision buffers — byte-for-byte content (incl. CRLF and eol filters),
-- filetype, binary/large guard, abbreviated sha resolution, :w refusal, ]r / [r stepping.
local fixtures = require("tests.fixtures")
local I = require("tests.helpers.inspect")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function open(name, rev, path)
  local r = fixtures.get(name)
  local repo = I.repo(r.path)
  require("trellis.view.filerev").open(repo, rev, path)
  eq(I.wait_view("filerev"), true)
  eq(
    vim.wait(5000, function()
      return vim.b.trellis and vim.b.trellis.path == path and vim.b.trellis_loaded == true
    end),
    true
  )
  return r, repo
end

local function content()
  return require("trellis.view.filerev").buffer_content(0)
end

T["content equals git's bytes for every file of several fixtures"] = function()
  for _, name in ipairs({ "demo", "unicode-messages", "rename-chain", "multiline-body" }) do
    local r = fixtures.get(name)
    local repo = I.repo(r.path)
    local files = vim.split(
      vim.trim(r:git({ "-c", "core.quotepath=off", "ls-tree", "-r", "--name-only", "HEAD" })),
      "\n"
    )
    for _, path in ipairs(files) do
      if not path:match("%.png$") then
        require("trellis.view.filerev").open(repo, "HEAD", path)
        eq(I.wait_view("filerev"), true)
        vim.wait(3000, function()
          return vim.b.trellis and vim.b.trellis.path == path and vim.b.trellis_loaded
        end)
        eq({
          name = name,
          path = path,
          same = content() == I.git_bytes(r.path, { "show", "HEAD:" .. path }),
        }, {
          name = name,
          path = path,
          same = true,
        })
        vim.cmd("bwipeout!")
      end
    end
  end
end

T["CRLF stored files and eol=crlf attributes"] = function()
  local r = open("crlf", "HEAD", "run.bat")
  eq(vim.bo.fileformat, "dos")
  eq(content(), I.git_bytes(r.path, { "show", "HEAD:run.bat" }))
  eq(I.lines()[1], "@echo off")
  vim.cmd("bwipeout!")
  -- notes.txt is stored with LF; `text eol=crlf` makes checkout (and cat-file --filters) CRLF.
  open("crlf", "HEAD", "notes.txt")
  eq(content(), "one\r\ntwo\r\n")
  eq(content(), I.git_bytes(r.path, { "cat-file", "--filters", "HEAD:notes.txt" }))
end

T["filetype from the path, read-only, named with the short sha"] = function()
  local r = open("demo", "HEAD", "src/api.lua")
  eq(vim.bo.filetype, "lua")
  eq(vim.bo.modifiable, false)
  eq(vim.bo.buftype, "acwrite") -- :w reaches BufWriteCmd, which refuses with a hint
  eq(vim.api.nvim_buf_get_name(0), "trellis://" .. r:rev("HEAD"):sub(1, 7) .. "/src/api.lua")
  eq(vim.b.trellis.sha, r:rev("HEAD"))
end

T[":w is refused with a hint"] = function()
  open("demo", "HEAD", "README.md")
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  vim.cmd("silent! write")
  vim.notify = orig
  eq(#msgs, 1)
  eq(msgs[1]:find(":Trellis restore", 1, true) ~= nil, true)
end

T["binary and large files show a metadata page; go opens anyway"] = function()
  open("binary-file", "HEAD", "assets/logo.png")
  eq(I.lines()[3]:match("^binary file, %d+ bytes$") ~= nil, true)
  eq(vim.b.trellis.guard, "binary")
  vim.cmd("normal go")
  eq(
    vim.wait(3000, function()
      return vim.b.trellis.guard == false
    end),
    true
  )
  vim.cmd("bwipeout!")
  open("large-file", "HEAD", "big.txt")
  eq(vim.b.trellis.guard, "large")
  eq(I.lines()[3]:find("large file, 6291456 bytes", 1, true) ~= nil, true)
end

T[":e trellis://<abbrev>/<path> typed by the user resolves the sha"] = function()
  local r = fixtures.get("demo")
  vim.cmd("cd " .. r.path)
  local short = r:rev("v1.0.0"):sub(1, 5)
  vim.cmd("edit trellis://" .. short .. "/src/api.lua")
  eq(
    vim.wait(5000, function()
      return vim.b.trellis_loaded == true
    end),
    true
  )
  eq(vim.b.trellis.sha, r:rev("v1.0.0"))
  eq(I.find_line("^retry = 5$") ~= nil, true)
  -- Index stage 0.
  vim.cmd("edit trellis://:0/README.md")
  eq(
    vim.wait(5000, function()
      return vim.b.trellis_loaded == true and vim.b.trellis.stage == 0
    end),
    true
  )
  eq(content(), I.git_bytes(r.path, { "show", ":0:README.md" }))
end

T["]r / [r step through history, following renames and keeping the line"] = function()
  local r = open("blame-chain", "HEAD~3", "src/api.lua")
  local function rev()
    return vim.b.trellis.sha
  end
  local retry_line = I.find_line("^retry = ")
  vim.api.nvim_win_set_cursor(0, { retry_line, 0 })
  vim.cmd("normal [r")
  eq(
    vim.wait(3000, function()
      return rev() == r:rev("HEAD~4") and vim.b.trellis_loaded
    end),
    true
  )
  eq(vim.api.nvim_get_current_line():match("^retry = "), "retry = ")
  vim.cmd("normal ]r")
  vim.wait(3000, function()
    return rev() == r:rev("HEAD~3")
  end)
  vim.cmd("normal ]r")
  eq(
    vim.wait(3000, function()
      return rev() == r:rev("HEAD~2")
    end),
    true
  )
  vim.cmd("bwipeout!")

  -- Across renames: from the newest version back to the oldest name.
  local rc = open("rename-chain", "HEAD", "src/renamed_thrice.lua")
  local paths = {}
  for _ = 1, 8 do
    paths[#paths + 1] = vim.b.trellis.path
    local before = rev()
    vim.cmd("normal [r")
    vim.wait(2000, function()
      return rev() ~= before and vim.b.trellis_loaded
    end)
    if rev() == before then
      break
    end
  end
  eq(paths[#paths], "src/old.lua")
  eq(vim.tbl_contains(paths, "src/mid.lua"), true)
  eq(rev(), rc:rev("HEAD~5"))
end

T[":Trellis show <rev>:<path>"] = function()
  local r = fixtures.get("demo")
  vim.cmd("cd " .. r.path)
  vim.cmd("Trellis show v1.0.0:src/api.lua")
  eq(I.wait_view("filerev"), true)
  eq(I.find_line("^retry = 5$") ~= nil, true)
end

return require("tests.helpers.child").run_in_child(T, "tests/integration/filerev_spec.lua")
