--- Ref map (G04, G05): decorations by commit, kinds, HEAD.
local argv = require("trellis.git.argv")
local async = require("trellis.util.async")
local runner = require("trellis.git.runner")

local M = {}

--- Display order of decorations on one commit.
M.kind_rank = { head = 1, ["local"] = 2, worktree = 3, remote = 4, tag = 5, stash = 6, backup = 7 }

--- Prefix symbols so kinds are distinguishable without color (Constitution V).
M.symbols = {
  head = "@",
  ["local"] = "",
  worktree = "&",
  remote = "~",
  tag = "#",
  stash = "$",
  backup = "!",
}

local PREFIXES = {
  { "refs/heads/", "local" },
  { "refs/remotes/", "remote" },
  { "refs/tags/", "tag" },
  { "refs/trellis/backup/", "backup" },
}

---@param refname string
---@return trellis.RefKind? kind, string? short
function M.classify(refname)
  if refname == "refs/stash" then
    return "stash", "stash"
  end
  for _, p in ipairs(PREFIXES) do
    if refname:sub(1, #p[1]) == p[1] then
      return p[2], refname:sub(#p[1] + 1)
    end
  end
end

local function sort_refs(list)
  table.sort(list, function(a, b)
    local ra, rb = M.kind_rank[a.kind], M.kind_rank[b.kind]
    if ra ~= rb then
      return ra < rb
    end
    if a.current ~= b.current then
      return a.current
    end
    return a.short < b.short
  end)
end

--- Parse G04 output plus HEAD info into a RefMap.
---@param out string for-each-ref output (records end with RS + "\n")
---@param head { detached: boolean, sha: string?, ref: string? }
---@param opts? { generation?: integer, worktrees?: trellis.Worktree[] }
---@return trellis.RefMap
function M.parse(out, head, opts)
  opts = opts or {}
  local by_sha, by_name = {}, {}
  local function add(ref)
    by_name[ref.name] = ref
    local list = by_sha[ref.target]
    if not list then
      list = {}
      by_sha[ref.target] = list
    end
    list[#list + 1] = ref
  end

  local start, n = 1, #out
  while start <= n do
    local stop = out:find("\30", start, true) or (n + 1)
    local rec = out:sub(start, stop - 1)
    start = stop + 1
    if rec:sub(1, 1) == "\n" then
      rec = rec:sub(2)
    end
    if rec ~= "" then
      local obj, peeled, refname, upstream, headmark =
        rec:match("^(%x*)%z(%x*)%z([^%z]*)%z([^%z]*)%z(.*)$")
      local kind, short = M.classify(refname or "")
      -- refs/remotes/<r>/HEAD is a symbolic alias of a remote branch: not a decoration.
      if kind and obj ~= "" and not (kind == "remote" and short:match("/HEAD$")) then
        add({
          name = refname,
          short = short,
          kind = kind,
          target = peeled ~= "" and peeled or obj,
          upstream = upstream ~= "" and upstream or nil,
          current = headmark == "*",
        })
      end
    end
  end

  if head.sha then
    add({ name = "HEAD", short = "HEAD", kind = "head", target = head.sha, current = true })
  end
  for _, wt in ipairs(opts.worktrees or {}) do
    if not wt.current and wt.head then
      add({
        name = "worktree:" .. wt.path,
        short = vim.fs.basename(wt.path),
        kind = "worktree",
        target = wt.head,
        current = false,
      })
    end
  end
  for _, list in pairs(by_sha) do
    sort_refs(list)
  end
  return {
    by_sha = by_sha,
    by_name = by_name,
    head = head,
    generation = (opts.generation or 0) + 1,
  }
end

--- Decorations to show for a commit (backups/stashes hidden unless enabled).
---@param map trellis.RefMap
---@param sha string
---@param opts? { show_backups?: boolean, show_stashes?: boolean }
---@return trellis.Ref[]
function M.decorations(map, sha, opts)
  local list = map.by_sha[sha]
  if not list then
    return {}
  end
  opts = opts or {}
  local out = {}
  for _, r in ipairs(list) do
    if (r.kind ~= "backup" or opts.show_backups) and (r.kind ~= "stash" or opts.show_stashes) then
      out[#out + 1] = r
    end
  end
  return out
end

--- Display labels for a commit's refs: `{ text, kind }[]`, HEAD folded into its branch
--- ("@main"), or "@HEAD" when detached.
---@param map trellis.RefMap
---@param sha string
---@param opts? { show_backups?: boolean, show_stashes?: boolean }
---@return { text: string, kind: trellis.RefKind }[]
function M.labels(map, sha, opts)
  local out = {}
  local head = map.head
  local attached = head and not head.detached and head.ref
  for _, r in ipairs(M.decorations(map, sha, opts)) do
    if r.kind == "head" and attached then
      -- shown on the branch
    elseif r.kind == "local" and r.name == attached then
      out[#out + 1] = { text = M.symbols.head .. r.short, kind = "head" }
    else
      out[#out + 1] = { text = M.symbols[r.kind] .. r.short, kind = r.kind }
    end
  end
  return out
end

--- Load refs for a repository (async); stores the result in `repo.refs`.
---@param repo trellis.Repository
---@param cb fun(err: string?, map: trellis.RefMap?)
function M.load(repo, cb)
  local function job(inv)
    return function(done)
      runner.run(repo.root, inv.args, { kind = inv.kind, ok_codes = inv.ok_codes }, done)
    end
  end
  async.all({ job(argv.G04()), job(argv.G05("symbolic")), job(argv.G05("sha")) }, function(r)
    local refs_err, refs_res = r[1][1], r[1][2]
    if refs_err then
      return cb(refs_err)
    end
    local sym = r[2][2] and r[2][2].code == 0 and vim.trim(r[2][2].stdout) or nil
    local sha = r[3][2] and r[3][2].code == 0 and vim.trim(r[3][2].stdout) or nil
    local head = { detached = sym == nil and sha ~= nil, sha = sha, ref = sym }
    local map = M.parse(refs_res.stdout, head, {
      generation = repo.refs and repo.refs.generation or 0,
      worktrees = repo.worktrees,
    })
    repo.refs = map
    cb(nil, map)
  end)
end

return M
