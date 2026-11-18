--- Helpers for US2 view tests (inside a child Neovim).
local M = {}

function M.repo(path)
  local repo
  require("trellis.git.repo").discover(path, function(err, r)
    assert(not err, err)
    repo = r
  end)
  assert(vim.wait(5000, function()
    return repo ~= nil
  end, 5))
  local done
  require("trellis.git.refs").load(repo, function()
    done = true
  end)
  vim.wait(5000, function()
    return done
  end, 5)
  return repo
end

--- Wait until the current buffer is a trellis view of `kind` (or `pred` holds).
function M.wait_view(kind, timeout)
  return vim.wait(timeout or 5000, function()
    return vim.b.trellis_view == kind and (kind ~= "filerev" or vim.b.trellis_loaded == true)
  end, 5)
end

function M.lines(buf)
  return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end

function M.find_line(pattern, buf)
  for i, l in ipairs(M.lines(buf)) do
    if l:find(pattern) then
      return i, l
    end
  end
end

--- Raw bytes git produces for a command (no text decoding).
function M.git_bytes(path, args)
  local cmd = { "git", "-C", path, "-c", "core.autocrlf=false" }
  vim.list_extend(cmd, args)
  return vim
    .system(cmd, { text = false, env = require("tests.helpers.repo").git_env })
    :wait().stdout
end

return M
