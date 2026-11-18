-- Every Lua file of the project compiles. A spec with a syntax error otherwise makes the
-- child-Neovim runner hang instead of failing (seen once in Phase 9).
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["all Lua files compile"] = function()
  local root = vim.fn.getcwd()
  local files = {}
  for _, dir in ipairs({ "lua", "plugin", "helpers", "tests" }) do
    vim.list_extend(files, vim.fn.globpath(root .. "/" .. dir, "**/*.lua", true, true))
  end
  eq(#files > 50, true)
  for _, f in ipairs(files) do
    local _, err = loadfile(f)
    eq({ file = f:sub(#root + 2), err = err }, { file = f:sub(#root + 2), err = nil })
  end
end

return T
