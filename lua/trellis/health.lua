--- `:checkhealth trellis` (US7, FR-074, T110).
---
--- `gather()` collects facts (versions, features, the current repository, backups, journal);
--- `report(ctx)` turns them into health messages, so tests can feed fake contexts.
local M = {}

local function h()
  return vim.health
end

--- Facts about the environment and the repository of the current directory. Synchronous
--- (checkhealth only).
---@return table ctx
function M.gather()
  local features = require("trellis.git.features")
  local runner = require("trellis.git.runner")
  local ctx = {
    nvim = vim.version(),
    nvim_ok = vim.fn.has("nvim-0.11") == 1,
    ambiwidth = vim.o.ambiwidth,
    termguicolors = vim.o.termguicolors,
    mouse = vim.o.mouse,
    mac = vim.fn.has("mac") == 1,
    config_problems = require("trellis.config").problems or {},
  }
  local err, res = runner.run_sync(nil, { "version" }, { timeout = 5000 })
  if err or not res then
    ctx.git_error = err or "git not found"
  else
    ctx.git_version_text = vim.trim(res.stdout)
    ctx.git_version = features.parse_version(res.stdout)
  end
  if ctx.git_version then
    ctx.features = features.detect(ctx.git_version)
  end
  -- Repository of the current directory, if any.
  local repo, done = nil, false
  require("trellis.git.repo").discover(vim.fn.getcwd(), function(_, r)
    repo, done = r, true
  end)
  vim.wait(5000, function()
    return done
  end, 10)
  if repo then
    ctx.repo = {
      root = repo.root,
      commit_graph = repo.features.commit_graph,
      shallow = repo.shallow,
      state = repo.state.kind,
    }
    local _, cres = runner.run_sync(
      repo.root,
      { "rev-list", "--count", "--all" },
      { timeout = 10000 }
    )
    ctx.repo.commits = cres and tonumber(vim.trim(cres.stdout)) or nil
    local _, bres =
      runner.run_sync(repo.root, require("trellis.git.argv").G16("refs/trellis/backup/").args)
    local ids = {}
    for line in ((bres and bres.stdout) or ""):gmatch("[^\n]+") do
      local id = line:match("^refs/trellis/backup/([^/]+)/")
      if id then
        ids[id] = true
      end
    end
    ctx.backups =
      { refs = select(2, ((bres and bres.stdout) or ""):gsub("\n", "")), ops = vim.tbl_count(ids) }
    local ids_sorted = vim.tbl_keys(ids)
    table.sort(ids_sorted)
    ctx.backups.oldest = ids_sorted[1]
    local journal = require("trellis.safety.journal")
    local list, bad = journal.read(repo)
    ctx.journal = { ops = #list, bad_lines = bad, path = journal.path(repo) }
  end
  ctx.adapters = {}
  local adapters = require("trellis.adapters.diff")
  for _, ad in
    ipairs(
      vim.list_extend(
        vim.list_extend({}, adapters.registered),
        { adapters.diffview, adapters.builtin }
      )
    )
  do
    local ok, avail = pcall(ad.available)
    ctx.adapters[#ctx.adapters + 1] = { name = ad.name, available = ok and avail }
  end
  return ctx
end

--- Sample rows of a small merge in every glyph style.
function M.glyph_samples()
  local layout = require("trellis.graph.layout")
  local glyphs = require("trellis.graph.glyphs")
  local function sha(s)
    return (s .. ("_"):rep(40)):sub(1, 40)
  end
  local commits = {
    { sha = sha("m"), parents = { sha("b"), sha("f") } },
    { sha = sha("f"), parents = { sha("a") } },
    { sha = sha("b"), parents = { sha("a") } },
    { sha = sha("a"), parents = {} },
  }
  local out = {}
  for _, style in ipairs({ "ascii", "unicode", "rounded", "flog-symbols" }) do
    local L = layout.new()
    local parts = {}
    for i, c in ipairs(commits) do
      for _, row in ipairs(L:push(c, i)) do
        parts[#parts + 1] = glyphs.render(row, style)
      end
    end
    out[#out + 1] = ("%-13s %s"):format(style, table.concat(parts, "  "))
  end
  return out
end

---@param ctx table from gather()
function M.report(ctx)
  local H = h()
  local features = require("trellis.git.features")

  H.start("trellis: Neovim and git")
  if ctx.nvim_ok then
    H.ok(("Neovim %d.%d.%d"):format(ctx.nvim.major, ctx.nvim.minor, ctx.nvim.patch))
  else
    H.error("Neovim >= 0.11 is required", { "Update Neovim" })
  end
  if ctx.git_error then
    H.error(
      "git: " .. ctx.git_error,
      { "Install git >= 2.30 and put it on $PATH", "Or set git.cmd" }
    )
  elseif not features.at_least(ctx.git_version, features.MIN) then
    H.error(("%s: minimum version is 2.30"):format(ctx.git_version_text), { "Update git" })
  else
    H.ok(ctx.git_version_text)
    local f = ctx.features
    if f.merge_tree_base then
      H.ok("exact conflict prediction (git merge-tree --merge-base, git >= 2.40)")
    else
      H.warn(
        "git < 2.40: rebase conflicts are predicted heuristically (overlapping lines)",
        { "Update git for exact prediction" }
      )
    end
    if f.update_refs then
      H.ok("update-ref plans for stacked branches (git >= 2.38)")
    else
      H.info("git < 2.38: update-ref lines are not available in rebase plans")
    end
  end

  H.start("trellis: repository")
  if not ctx.repo then
    H.info(
      "the current directory is not in a git repository (open :checkhealth from one to check it)"
    )
  else
    H.info(
      "repository: "
        .. ctx.repo.root
        .. (ctx.repo.commits and (" (%d commits)"):format(ctx.repo.commits) or "")
    )
    if ctx.repo.commit_graph then
      H.ok("commit-graph present: the graph's first screen streams immediately")
    elseif (ctx.repo.commits or 0) > 20000 then
      H.warn("no commit-graph file: the first screen of the graph is slow on large histories", {
        "git commit-graph write --reachable",
        "or :Trellis commit-graph",
        "or set perf.write_commit_graph = true",
      })
    else
      H.info("no commit-graph file (fine for small repositories)")
    end
    if ctx.repo.shallow then
      H.info("shallow clone: the oldest commits are marked ^grafted")
    end
    if ctx.repo.state ~= "clean" then
      H.warn(("a %s is in progress"):format(ctx.repo.state), { ":Trellis continue | skip | abort" })
    end
    local b = ctx.backups or { refs = 0, ops = 0 }
    if b.ops > 0 then
      H.info(
        ("%d backup refs from %d operations (oldest %s)"):format(b.refs, b.ops, b.oldest or "?"),
        {
          ":Trellis ops prune removes backups beyond safety.backup_retention_days / backup_max_ops",
        }
      )
    else
      H.ok("no trellis backup refs")
    end
    if ctx.journal then
      if ctx.journal.bad_lines > 0 then
        H.warn(
          ("journal %s has %d unreadable line(s) (skipped)"):format(
            ctx.journal.path,
            ctx.journal.bad_lines
          ),
          {
            "Usually a crash during a write; the other entries are intact",
          }
        )
      else
        H.ok(("journal: %d operation(s)"):format(ctx.journal.ops))
      end
    end
  end

  H.start("trellis: display")
  for _, line in ipairs(M.glyph_samples()) do
    H.info(line)
  end
  if ctx.ambiwidth == "double" then
    H.warn("'ambiwidth' is double: box-drawing glyphs are two cells wide, the graph uses ascii")
  end
  if not ctx.termguicolors then
    H.info("'termguicolors' is off: ref kinds stay readable through their prefixes (@ ~ # & $ !)")
  end
  if not (ctx.mouse or ""):find("[na]") then
    H.info(
      "mouse is off for normal mode: dragging lines in the rebase plan needs 'mouse' with n or a"
    )
  end
  if ctx.mac then
    H.info(
      "macOS: plan keys use Alt (<M-…>); let the terminal send Option as Meta (iTerm2: Esc+, kitty: macos_option_as_alt)"
    )
  end

  H.start("trellis: integrations and configuration")
  for _, ad in ipairs(ctx.adapters or {}) do
    if ad.available then
      H.ok("diff adapter: " .. ad.name)
    else
      H.info("diff adapter not available: " .. ad.name)
    end
  end
  if #ctx.config_problems > 0 then
    for _, p in ipairs(ctx.config_problems) do
      H.warn("config: " .. p)
    end
  else
    H.ok("configuration valid")
  end
end

function M.check()
  M.report(M.gather())
end

return M
