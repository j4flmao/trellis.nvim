--- Run a spec's cases inside a child Neovim.
---
--- Why: mini.test schedules every step of every case up front with vim.schedule. A case that
--- waits on the event loop in-process (vim.wait for a git callback, a timer, a stream) would let
--- later cases run re-entrantly inside that wait. Anything asynchronous therefore runs in a fresh
--- child Neovim per case, which also isolates module state between cases.
---
--- Usage at the end of a spec file:
---   return require("tests.helpers.child").run_in_child(T, "tests/integration/x_spec.lua")
--- Inside the child the spec file is loaded again and returns the plain set; the case function
--- is looked up by its path and called there, so case bodies are written as ordinary code.
--- Case hooks are not supported in such specs (each case already starts from a fresh child).
local M = {}

local CHILD_CODE = [[
  local spec, path, args = ...
  vim.g.trellis_test_child = true
  local node = dofile(spec)
  for _, k in ipairs(path) do
    node = node[k]
  end
  -- A case may skip itself (tests/helpers/gitver.lua) by raising { trellis_skip = reason };
  -- other errors keep their traceback.
  local ok, res = xpcall(function()
    return node(unpack(args))
  end, function(e)
    if type(e) == "table" and e.trellis_skip then
      return e
    end
    return debug.traceback(tostring(e), 2)
  end)
  if ok then
    return res
  end
  if type(res) == "table" then
    return res
  end
  error(res, 0)
]]

local function wrap(set, path, child, spec)
  local keys = {}
  for k in pairs(set) do
    keys[#keys + 1] = k
  end
  for _, k in ipairs(keys) do
    local v = set[k]
    local p = vim.list_extend(vim.deepcopy(path), { k })
    if type(v) == "function" then
      set[k] = function(...)
        child.restart({ "-u", "tests/minimal_init.lua" })
        local res = child.lua(CHILD_CODE, { spec, p, { ... } })
        if type(res) == "table" and res.trellis_skip then
          MiniTest.skip(res.trellis_skip)
        end
        return res
      end
    elseif type(v) == "table" then
      wrap(v, p, child, spec)
    end
  end
end

---@param T table MiniTest set
---@param spec string spec path relative to the repository root
---@return table
function M.run_in_child(T, spec)
  if vim.g.trellis_test_child then
    return T
  end
  local child = MiniTest.new_child_neovim()
  wrap(T, {}, child, spec)
  local outer = MiniTest.new_set({
    hooks = {
      post_once = function()
        child.stop()
      end,
    },
  })
  outer["child nvim"] = T
  return outer
end

return M
