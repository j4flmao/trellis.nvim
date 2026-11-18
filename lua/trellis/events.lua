--- `User` autocmd events (contracts/lua-api.md → User events).
local M = {}

M.names = {
  TrellisGraphOpened = true,
  TrellisGraphLoaded = true,
  TrellisCommitOpened = true,
  TrellisOperationStarted = true,
  TrellisOperationFinished = true,
  TrellisConflict = true,
  TrellisRefsChanged = true,
}

--- Fire `User <name>` with `data`. Unknown names are a programming error.
---@param name string
---@param data? table
function M.emit(name, data)
  if not M.names[name] then
    error("trellis: unknown event " .. tostring(name), 2)
  end
  vim.api.nvim_exec_autocmds("User", { pattern = name, data = data or {}, modeline = false })
end

return M
