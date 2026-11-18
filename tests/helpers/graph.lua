--- Helpers for graph view tests (run inside a child Neovim: they wait on the event loop).
local M = {}

--- Open the graph for `path` in the current window; returns the view.
---@param path string
---@param cfg? table extra trellis config
---@param args? string[] :Trellis arguments
function M.open(path, cfg, args)
  require("trellis").setup(vim.tbl_deep_extend("force", {
    graph = { date_format = "iso", open = "current" },
  }, cfg or {}))
  local view
  require("trellis.view.graph").open({
    cwd = path,
    args = args,
    on_open = function(v)
      view = v
    end,
  })
  assert(
    vim.wait(10000, function()
      return view ~= nil
    end, 5),
    "graph did not open"
  )
  return view
end

--- Wait until the real (topological) loader is done and every row is in the buffer.
function M.wait_loaded(v, timeout)
  return vim.wait(timeout or 20000, function()
    local l = v.loader
    if v.message then
      return true
    end
    return l ~= nil and v.shown == l and l:done() and v.appended == l.model.loaded
  end, 5)
end

function M.lines(v)
  return vim.api.nvim_buf_get_lines(v.bufnr, 0, -1, false)
end

--- Lines with the graph prefix and short sha removed: "<deco> <subject>" for commit rows.
function M.subjects(v)
  local out = {}
  local m = v.shown.model
  for r = 1, v.appended do
    if m.rows_kind[r] == 1 then
      local idx = m.rows_commit[r]
      out[#out + 1] = m.subject[idx]
    end
  end
  return out
end

return M
