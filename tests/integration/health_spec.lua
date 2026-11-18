-- T111: :checkhealth trellis with mocked facts, plus a real run on a fixture.
local fixtures = require("tests.fixtures")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local health = require("trellis.health")

--- Capture vim.health calls as "level: message".
local function capture(fn)
  local out = {}
  local orig = vim.health
  vim.health = {
    start = function(s)
      out[#out + 1] = "## " .. s
    end,
    ok = function(m)
      out[#out + 1] = "ok: " .. m
    end,
    info = function(m)
      out[#out + 1] = "info: " .. m
    end,
    warn = function(m, advice)
      out[#out + 1] = "warn: " .. m .. (advice and (" | " .. table.concat(advice, " | ")) or "")
    end,
    error = function(m, advice)
      out[#out + 1] = "error: " .. m .. (advice and (" | " .. table.concat(advice, " | ")) or "")
    end,
  }
  local ok, err = pcall(fn)
  vim.health = orig
  assert(ok, err)
  return out
end

local function has(lines, pattern)
  for _, l in ipairs(lines) do
    if l:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function ctx(overrides)
  local features = require("trellis.git.features")
  local base = {
    nvim = vim.version(),
    nvim_ok = true,
    ambiwidth = "single",
    termguicolors = true,
    mouse = "a",
    mac = false,
    config_problems = {},
    git_version_text = "git version 2.47.0",
    git_version = { 2, 47, 0 },
    adapters = { { name = "builtin", available = true } },
  }
  base.features = features.detect(base.git_version)
  for k, v in pairs(overrides or {}) do
    base[k] = v
  end
  if overrides and overrides.git_version then
    base.features = features.detect(overrides.git_version)
  end
  return base
end

T["git 2.25 is an error with the minimum version"] = function()
  local out = capture(function()
    health.report(ctx({ git_version_text = "git version 2.25.1", git_version = { 2, 25, 1 } }))
  end)
  eq(has(out, "error: git version 2.25.1: minimum version is 2.30"), true)
end

T["git 2.39: heuristic prediction warned, update-ref ok"] = function()
  local out = capture(function()
    health.report(ctx({ git_version_text = "git version 2.39.0", git_version = { 2, 39, 0 } }))
  end)
  eq(has(out, "warn: git < 2.40: rebase conflicts are predicted heuristically"), true)
  eq(has(out, "ok: update-ref plans"), true)
end

T["large repository without commit-graph suggests the fix; small ones do not nag"] = function()
  local big = capture(function()
    health.report(ctx({
      repo = { root = "/r", commit_graph = false, commits = 500000, state = "clean" },
      backups = { refs = 0, ops = 0 },
    }))
  end)
  eq(has(big, "warn: no commit-graph file"), true)
  eq(has(big, "git commit-graph write --reachable"), true)
  local small = capture(function()
    health.report(ctx({
      repo = { root = "/r", commit_graph = false, commits = 50, state = "clean" },
      backups = { refs = 0, ops = 0 },
    }))
  end)
  eq(has(small, "info: no commit-graph file"), true)
end

T["backups, journal integrity, in-progress operation, config problems"] = function()
  local out = capture(function()
    health.report(ctx({
      repo = { root = "/r", commit_graph = true, commits = 10, state = "rebase" },
      backups = { refs = 6, ops = 2, oldest = "20261101T000000-0000" },
      journal = { ops = 2, bad_lines = 1, path = "/r/.git/trellis/ops.jsonl" },
      config_problems = { "unknown option grpah (did you mean graph?)" },
    }))
  end)
  eq(has(out, "info: 6 backup refs from 2 operations (oldest 20261101T000000-0000)"), true)
  eq(has(out, "warn: journal /r/.git/trellis/ops.jsonl has 1 unreadable line(s)"), true)
  eq(has(out, "warn: a rebase is in progress"), true)
  eq(has(out, "warn: config: unknown option grpah"), true)
end

T["display hints: glyph samples, ambiwidth, monochrome, mouse, macOS Meta"] = function()
  local out = capture(function()
    health.report(ctx({ ambiwidth = "double", termguicolors = false, mouse = "", mac = true }))
  end)
  eq(has(out, "info: ascii"), true)
  eq(has(out, "info: rounded       ○  ├─╮  │ ●  ● │  ●─╯"), true)
  eq(has(out, "warn: 'ambiwidth' is double"), true)
  eq(has(out, "'termguicolors' is off"), true)
  eq(has(out, "mouse is off"), true)
  eq(has(out, "Option as Meta"), true)
end

T["real run on a fixture repository"] = function()
  local r = fixtures.get("backup-refs")
  vim.cmd("cd " .. r.path)
  local c = health.gather()
  eq(c.git_error, nil)
  eq(c.repo.root, r.path)
  eq(c.backups.ops, 1)
  eq(c.backups.refs, 2)
  local out = capture(function()
    health.report(c)
  end)
  eq(has(out, "ok: Neovim"), true)
  eq(has(out, "## trellis: repository"), true)
  -- :checkhealth finds the module.
  vim.cmd("checkhealth trellis")
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  eq(text:find("trellis: Neovim and git", 1, true) ~= nil, true)
end

return require("tests.helpers.child").run_in_child(T, "tests/integration/health_spec.lua")
