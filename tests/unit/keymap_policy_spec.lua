-- T029: no default buffer-local map shadows a protected built-in (Constitution IV keymap policy,
-- contracts/commands-keymaps-config.md).
local keymaps = require("trellis.keymaps")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function lhs(spec)
  return spec.key
end

T["protected keys are never mapped in any view"] = function()
  for view in pairs(keymaps.defaults) do
    if view ~= "common" then
      local specs = keymaps.resolve(view, true)
      for _, s in ipairs(specs) do
        for _, p in ipairs(keymaps.protected) do
          -- Exact key or a sequence starting with it (e.g. "y" would also shadow "yy").
          local shadows = s.key == p
            or (vim.startswith(s.key, p) and #p > 0 and not s.key:match("^<"))
          eq(
            { view = view, key = s.key, shadows = shadows },
            { view = view, key = s.key, shadows = false }
          )
        end
      end
    end
  end
end

T["editable views only use <M-…> keys or listed exceptions"] = function()
  for view in pairs(keymaps.editable) do
    for _, s in ipairs(keymaps.resolve(view, true)) do
      local ok = vim.startswith(s.key, "<M-") or keymaps.editable_exceptions[s.key] == true
      eq({ view = view, key = s.key, ok = ok }, { view = view, key = s.key, ok = true })
    end
    -- q (macro recording), R (Replace mode) and g? (rot13) stay built-in in the plan.
    local keys = vim.tbl_map(lhs, keymaps.resolve(view, true))
    for _, k in ipairs({ "q", "R", "g?" }) do
      eq(vim.tbl_contains(keys, k), false)
    end
  end
end

T["keys are unique within a view"] = function()
  for view in pairs(keymaps.defaults) do
    if view ~= "common" then
      local seen = {}
      for _, s in ipairs(keymaps.resolve(view, true)) do
        local modes = type(s.mode) == "table" and s.mode or { s.mode }
        for _, m in ipairs(modes) do
          local k = m .. " " .. s.key
          eq(
            { view = view, dup = seen[k] ~= nil, key = s.key },
            { view = view, dup = false, key = s.key }
          )
          seen[k] = true
        end
      end
    end
  end
end

T["user overrides remap, disable, and report unknown actions"] = function()
  local specs, problems =
    keymaps.resolve("graph", { graph = { cherry_pick = "C", revert = false, nope = "z" } })
  local by_name = {}
  for _, s in ipairs(specs) do
    by_name[s.name] = s.key
  end
  eq(by_name.cherry_pick, "C")
  eq(by_name.revert, nil)
  eq(by_name.help, "g?")
  eq(problems, { "keymaps.graph.nope: unknown action" })
  eq(#keymaps.resolve("graph", false), 0)
end

return T
