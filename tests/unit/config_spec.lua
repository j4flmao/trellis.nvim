local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      -- Silence and capture notifications.
      _G.__notified = {}
      _G.__orig_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(_G.__notified, { msg = msg, level = level })
      end
    end,
    post_case = function()
      vim.notify = _G.__orig_notify
      require("trellis.config").setup()
    end,
  },
})
local eq = MiniTest.expect.equality
local config = require("trellis.config")

T["zero config equals defaults"] = function()
  eq(config.setup(), {})
  eq(config.get(), config.defaults)
end

T["merges valid options deeply"] = function()
  eq(
    config.setup({ graph = { style = "ascii", max_lanes = 10 }, blame = { detect_moves = false } }),
    {}
  )
  local cfg = config.get()
  eq(cfg.graph.style, "ascii")
  eq(cfg.graph.max_lanes, 10)
  eq(cfg.graph.order, "topo")
  eq(cfg.blame.detect_moves, false)
  eq(config.defaults.graph.style, "rounded")
end

T["invalid values keep defaults and are reported"] = function()
  local problems = config.setup({
    graph = { style = "fancy", max_lanes = "many" },
    rebase = { update_refs = "sometimes" },
    graph_columns = 1,
  })
  eq(#problems, 4)
  eq(config.get().graph.style, "rounded")
  eq(config.get().graph.max_lanes, 40)
  eq(config.get().rebase.update_refs, "auto")
  eq(#_G.__notified, 1)
end

T["unknown keys get suggestions"] = function()
  local problems = config.setup({ grpah = {}, graph = { stlye = "ascii" } })
  table.sort(problems)
  eq(problems, {
    "unknown option graph.stlye (did you mean graph.style?)",
    "unknown option grpah (did you mean graph?)",
  })
end

T["union and list fields"] = function()
  eq(config.setup({ keymaps = false }), {})
  eq(config.get().keymaps, false)
  eq(config.setup({ keymaps = { graph = { cherry_pick = "C" } } }), {})
  eq(config.get().keymaps.graph.cherry_pick, "C")
  eq(config.setup({ views = { filerev = { lsp = "readonly" } } }), {})
  eq(#config.setup({ graph = { columns = { "graph", "nope" } } }), 1)
  eq(config.setup({ graph = { default_revs = { "--all" } } }), {})
  eq(config.get().graph.default_revs, { "--all" })
  eq(config.setup({ permalink = { patterns = { ["git.example.com"] = "https://x/{path}" } } }), {})
end

T["per-repo overrides"] = function()
  config.setup({ graph = { style = "ascii" } })
  vim.g.trellis_repo_config = { ["/repo"] = { graph = { max_lanes = 5 } } }
  local cfg = config.for_repo("/repo")
  eq(cfg.graph.max_lanes, 5)
  eq(cfg.graph.style, "ascii")
  eq(config.for_repo("/other").graph.max_lanes, 40)
  vim.g.trellis_repo_config = nil
end

return T
