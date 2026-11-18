--- Permalinks (T066): URLs to a commit or to lines of a file at a commit on the forge.
---
--- Built-in templates for GitHub, GitLab, Gitea/Forgejo/Codeberg and Bitbucket, chosen from
--- the remote's host; `permalink.patterns` adds `{ ["host pattern"] = template }` entries
--- (a string for files, or `{ file = ..., commit = ... }`). Placeholders: {base} (https://host
--- /owner/repo), {host}, {repo} (owner/repo), {sha}, {path}, {line1}, {line2}.
local M = {}

M.forges = {
  github = {
    file = "{base}/blob/{sha}/{path}#L{line1}-L{line2}",
    line = "{base}/blob/{sha}/{path}#L{line1}",
    commit = "{base}/commit/{sha}",
  },
  gitlab = {
    file = "{base}/-/blob/{sha}/{path}#L{line1}-{line2}",
    line = "{base}/-/blob/{sha}/{path}#L{line1}",
    commit = "{base}/-/commit/{sha}",
  },
  gitea = {
    file = "{base}/src/commit/{sha}/{path}#L{line1}-L{line2}",
    line = "{base}/src/commit/{sha}/{path}#L{line1}",
    commit = "{base}/commit/{sha}",
  },
  bitbucket = {
    file = "{base}/src/{sha}/{path}#lines-{line1}:{line2}",
    line = "{base}/src/{sha}/{path}#lines-{line1}",
    commit = "{base}/commits/{sha}",
  },
}

--- Remote URL → host and "owner/repo".
--- Handles https://host/owner/repo(.git), git@host:owner/repo(.git), ssh://git@host:22/owner/repo.
---@param url string
---@return { host: string, repo: string }?
function M.parse_remote(url)
  url = vim.trim(url)
  local host, path
  local rest = url:match("^%a[%w+.-]*://(.+)$")
  if rest then
    rest = rest:gsub("^[^@/]*@", "") -- user[:password]@
    host, path = rest:match("^([^/:]+):?%d*/(.+)$")
  else
    host, path = url:match("^[^@/]+@([^:/]+):(.+)$") -- scp-like git@host:owner/repo
  end
  if not host or not path then
    return nil
  end
  path = path:gsub("%.git/?$", ""):gsub("/$", "")
  return { host = host:lower(), repo = path }
end

local function forge_for(host, patterns)
  for pattern, tpl in pairs(patterns or {}) do
    if host:find(pattern) then
      return type(tpl) == "string" and { file = tpl, line = tpl, commit = tpl } or tpl
    end
  end
  if host:find("github") then
    return M.forges.github
  elseif host:find("gitlab") then
    return M.forges.gitlab
  elseif host:find("bitbucket") then
    return M.forges.bitbucket
  elseif host:find("gitea") or host:find("codeberg") or host:find("forgejo") then
    return M.forges.gitea
  end
end

local function encode_path(p)
  return (p:gsub("[^%w%-%._~/]", function(c)
    return ("%%%02X"):format(c:byte())
  end))
end

--- Build a URL. `o.path` nil → commit link.
---@param remote_url string
---@param o { sha: string, path?: string, line1?: integer, line2?: integer, patterns?: table }
---@return string? url, string? err
function M.build(remote_url, o)
  local r = M.parse_remote(remote_url)
  if not r then
    return nil, "cannot parse remote URL " .. remote_url
  end
  local forge = forge_for(r.host, o.patterns)
  if not forge then
    return nil, ("unknown forge %s: add it to permalink.patterns"):format(r.host)
  end
  local tpl
  if not o.path then
    tpl = forge.commit
  elseif o.line1 and o.line2 and o.line2 ~= o.line1 then
    tpl = forge.file
  else
    tpl = forge.line or forge.file
  end
  local values = {
    base = "https://" .. r.host .. "/" .. r.repo,
    host = r.host,
    repo = r.repo,
    sha = o.sha,
    path = o.path and encode_path(o.path) or "",
    line1 = tostring(o.line1 or 1),
    line2 = tostring(o.line2 or o.line1 or 1),
  }
  local url = tpl:gsub("{(%w+)}", function(k)
    return values[k] or ("{" .. k .. "}")
  end)
  if not o.line1 then
    url = url:gsub("#.*$", "")
  end
  return url
end

local function copy(url)
  vim.fn.setreg('"', url)
  pcall(vim.fn.setreg, "+", url)
  vim.notify("trellis: copied " .. url)
end

--- Permalink for a repository object; calls `cb(err, url)` and copies the URL.
---@param repo trellis.Repository
---@param o { sha: string, path?: string, line1?: integer, line2?: integer }
---@param cb? fun(err: string?, url: string?)
function M.for_repo(repo, o, cb)
  local cfg = require("trellis.config").for_repo(repo.root).permalink
  local inv = require("trellis.git.argv").G33(cfg.remote)
  require("trellis.git.runner").run(repo.root, inv.args, { kind = inv.kind }, function(err, res)
    if err then
      local msg = ("no remote %q"):format(cfg.remote)
      vim.notify("trellis: " .. msg, vim.log.levels.ERROR)
      return cb and cb(msg)
    end
    local url, berr = M.build(res.stdout, vim.tbl_extend("force", o, { patterns = cfg.patterns }))
    if not url then
      vim.notify("trellis: " .. berr, vim.log.levels.ERROR)
      return cb and cb(berr)
    end
    copy(url)
    if cb then
      cb(nil, url)
    end
  end)
end

--- Permalink for lines l1..l2 of the current buffer's file (`:Trellis permalink`).
--- Working copies link to HEAD, with lines mapped through uncommitted changes.
function M.current(l1, l2, cb)
  local target = require("trellis.view.target")
  target.current(function(err, t)
    if err then
      vim.notify("trellis: " .. err, vim.log.levels.ERROR)
      return cb and cb(err)
    end
    local function go(sha, a, b)
      M.for_repo(t.repo, { sha = sha, path = t.path, line1 = a, line2 = b }, cb)
    end
    if t.sha then
      return go(t.sha, l1, l2)
    end
    require("trellis.git.details").resolve(t.repo, "HEAD", function(rerr, head)
      if rerr then
        vim.notify("trellis: " .. rerr, vim.log.levels.ERROR)
        return cb and cb(rerr)
      end
      target.map_worktree_lines(t.repo, head, t.path, { l1, l2 }, function(m)
        go(head, m[1], math.max(m[1], m[2]))
      end)
    end)
  end)
end

return M
