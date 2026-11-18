--- Helpers for safety/action tests (inside a child Neovim).
local M = {}

M.asked = {}

--- Answer every confirmation with `answer` (true/false) and record the questions.
function M.auto_confirm(answer)
  M.asked = {}
  require("trellis.safety.preflight").ui = function(spec, cb)
    M.asked[#M.asked + 1] = spec
    cb(answer ~= false)
  end
end

function M.repo(path)
  local repo
  require("trellis.git.repo").discover(path, function(err, r)
    assert(not err, err)
    repo = r
  end)
  assert(vim.wait(5000, function()
    return repo ~= nil
  end, 5))
  return repo
end

--- Run `fn` (returns op, err) in the safety coroutine and wait for it.
function M.run(fn)
  local done, op, err = false, nil, nil
  require("trellis.safety.ops").spawn(fn, function(o, e)
    op, err, done = o, e, true
  end)
  assert(
    vim.wait(20000, function()
      return done
    end, 5),
    "operation did not finish"
  )
  return op, err
end

--- Everything a user could lose: refs (except trellis backups and the stash list), HEAD,
--- index, and tracked worktree content.
function M.state(r)
  local refs = {}
  for line in r:git({ "for-each-ref", "--format=%(refname) %(objectname)" }):gmatch("[^\n]+") do
    if not line:match("^refs/trellis/") and not line:match("^refs/stash ") then
      refs[#refs + 1] = line
    end
  end
  local _, sym = r:git({ "symbolic-ref", "-q", "HEAD" }, { allow_fail = true })
  return {
    refs = refs,
    head = vim.trim(r:git({ "rev-parse", "HEAD" })),
    symbolic = vim.trim(sym.stdout or ""),
    index = r:git({ "diff", "--cached", "--no-color", "HEAD" }),
    worktree = r:git({ "diff", "--no-color" }),
    status = r:git({ "status", "--porcelain=v2", "--untracked-files=no" }),
  }
end

function M.backup_refs(r, id)
  local out = {}
  for line in
    r:git({ "for-each-ref", "--format=%(refname)", "refs/trellis/backup/" .. id .. "/" })
      :gmatch("[^\n]+")
  do
    out[#out + 1] = line
  end
  return out
end

--- A repository where `topic`'s commit conflicts with main.
function M.conflict_repo()
  local Repo = require("tests.helpers.repo")
  local r = Repo.new()
  r:commit({ msg = "base", files = { ["f.txt"] = "base\n", ["g.txt"] = "g\n" } })
  r:branch("topic")
  r:commit({ msg = "main change", files = { ["f.txt"] = "main\n" } })
  r:switch("topic")
  r:commit({ msg = "topic change", files = { ["f.txt"] = "topic\n" } })
  r:commit({ msg = "topic other", files = { ["g.txt"] = "g2\n" } })
  r:switch("main")
  return r
end

return M
