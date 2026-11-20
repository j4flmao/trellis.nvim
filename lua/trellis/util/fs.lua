--- File system helpers.
local M = {}

--- `mkdir -p` that is safe when another process creates the same directory at the same time
--- (vim.fn.mkdir then fails with E739 although the directory exists).
---@param path string
---@return boolean ok, string? err
function M.mkdirp(path)
  local ok, err = pcall(vim.fn.mkdir, path, "p")
  if vim.fn.isdirectory(path) == 1 then
    return true
  end
  return false, ok and ("cannot create " .. path) or tostring(err)
end

return M
