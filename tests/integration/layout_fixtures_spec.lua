-- For fixtures: the layout engine satisfies every invariant on the
-- real `git log --topo-order` of every fixture repository and of a 20k-commit synthetic repo.
local fixtures = require("tests.fixtures")
local check = require("tests.helpers.graph_check")
local glyphs = require("trellis.graph.glyphs")
local Repo = require("tests.helpers.repo")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local REVS = { "--branches", "--remotes", "--tags", "HEAD" }

local function verify(commits)
  local rows = check.layout_all(commits)
  local errs = check.check(commits, rows)
  if #errs > 0 then
    local pic = vim.tbl_map(function(r)
      return (glyphs.render(r, "rounded"))
    end, rows)
    error(table.concat(errs, "\n") .. "\n" .. table.concat(pic, "\n"))
  end
  return rows
end

T["every fixture"] = MiniTest.new_set({
  parametrize = vim.tbl_map(function(n)
    return { n }
  end, fixtures.names()),
})

T["every fixture"]["satisfies the graph invariants"] = function(name)
  local r = fixtures.get(name)
  verify(r:topo(REVS))
  -- First-parent and date-order views are valid inputs too.
  verify(r:topo(vim.list_extend({ "--first-parent" }, REVS)))
end

T["date order (also topological) is laid out correctly"] = function()
  local r = fixtures.get("date-skew")
  local out = r:git({ "log", "--date-order", "--format=%H %P", "--branches", "HEAD" })
  local commits = {}
  for line in out:gmatch("[^\n]+") do
    local parts = vim.split(line, " ", { trimempty = true })
    commits[#commits + 1] = { sha = parts[1], parents = { unpack(parts, 2) } }
  end
  verify(commits)
end

T["20k-commit synthetic repository"] = function()
  local dir = require("tests.fixtures.fastimport.gen").build(
    Repo.root .. "/.tests/fixtures/synthetic-20k",
    { commits = 20000, merge_ratio = 0.1 }
  )
  local commits = Repo.open(dir):topo({ "--all" })
  eq(#commits, 20000)
  local rows = verify(commits)
  eq(#rows >= 20000, true)
end

return T
