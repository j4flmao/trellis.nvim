--- `:Trellis` subcommands, completion, and the `trellis://` BufReadCmd entry point.
--- Subcommands whose story is not implemented yet say so (and which milestone brings them).
local M = {}

---@class trellis.Subcommand
---@field milestone string   release that brings it
---@field run? fun(args: string[], cmd: table)

--- Subcommand that runs a history action through the safety pipeline (actions/ui.lua).
local function M_action(name, fn)
  return {
    milestone = "v0.4.0",
    run = function(args)
      M.with_repo(function(repo, rel)
        require("trellis.actions.ui").run(repo, function()
          return fn(require("trellis.actions"), repo, args, rel)
        end)
      end)
    end,
  }
end

---@type table<string, trellis.Subcommand>
M.subcommands = {
  graph = {
    milestone = "v0.1.0",
    run = function(args)
      require("trellis.view.graph").open({ args = args })
    end,
  },
  ["commit-graph"] = {
    milestone = "v0.1.0",
    run = function()
      require("trellis.commands").commit_graph()
    end,
  },
  commit = {
    milestone = "v0.2.0",
    run = function(args)
      M.with_repo(function(repo)
        require("trellis.view.commit").open(repo, args[1] or "HEAD")
      end)
    end,
  },
  diff = {
    milestone = "v0.2.0",
    run = function(args)
      local revs, path = M.split_paths(args)
      if #revs == 0 then
        return vim.notify(
          "trellis: usage: :Trellis diff <a> [<b>] [-- <path>]",
          vim.log.levels.ERROR
        )
      end
      M.with_repo(function(repo)
        require("trellis.view.diff").open(repo, revs[1], revs[2], { path = path })
      end)
    end,
  },
  show = {
    milestone = "v0.2.0",
    run = function(args)
      local rev, path = (args[1] or ""):match("^(.-):(.+)$")
      if not rev then
        return vim.notify("trellis: usage: :Trellis show <rev>:<path>", vim.log.levels.ERROR)
      end
      M.with_repo(function(repo)
        require("trellis.view.filerev").open(repo, rev == "" and ":0" or rev, path)
      end)
    end,
  },
  file = {
    milestone = "v0.2.0",
    run = function(args)
      M.with_repo(function(repo, rel)
        local path = args[1] or rel
        if not path then
          return vim.notify("trellis: no file: use :Trellis file <path>", vim.log.levels.ERROR)
        end
        require("trellis.view.filehistory").open(repo, path)
      end)
    end,
  },
  blame = {
    milestone = "v0.3.0",
    run = function()
      require("trellis.view.blame").toggle()
    end,
  },
  history = {
    milestone = "v0.3.0",
    run = function(_, cmd)
      local l1, l2 = M.range(cmd)
      require("trellis.view.linehistory").open(l1, l2)
    end,
  },
  permalink = {
    milestone = "v0.3.0",
    run = function(_, cmd)
      local l1, l2 = M.range(cmd)
      require("trellis.permalink").current(l1, l2)
    end,
  },
  checkout = M_action("checkout", function(a, repo, args)
    if not args[1] then
      return nil, "usage: :Trellis checkout <rev>"
    end
    return a.checkout(repo, args[1])
  end),
  branch = M_action("branch", function(a, repo, args)
    if args[1] == "-m" and args[2] and args[3] then
      return a.branch_rename(repo, args[2], args[3])
    elseif (args[1] == "-D" or args[1] == "-d") and args[2] then
      return a.branch_delete(repo, args[2])
    elseif args[1] and not args[1]:match("^%-") then
      return a.branch_create(repo, args[1], args[2])
    end
    return nil, "usage: :Trellis branch <name> [<rev>] | -m <old> <new> | -D <name>"
  end),
  tag = M_action("tag", function(a, repo, args)
    if args[1] == "-d" and args[2] then
      return a.tag_delete(repo, args[2])
    end
    local name, rev, msg = nil, nil, nil
    local i = 1
    while i <= #args do
      if args[i] == "-m" then
        msg = table.concat({ unpack(args, i + 1) }, " ")
        break
      elseif not name then
        name = args[i]
      else
        rev = args[i]
      end
      i = i + 1
    end
    if not name then
      return nil, "usage: :Trellis tag <name> [<rev>] [-m <message>] | -d <name>"
    end
    return a.tag_create(repo, name, rev, { message = msg })
  end),
  ["cherry-pick"] = M_action("cherry-pick", function(a, repo, args)
    local x = vim.tbl_contains(args, "-x")
    local revs = vim.tbl_filter(function(r)
      return r ~= "-x"
    end, args)
    if #revs == 0 then
      return nil, "usage: :Trellis cherry-pick [-x] <rev...>"
    end
    return a.cherry_pick(repo, revs, { x = x })
  end),
  revert = M_action("revert", function(a, repo, args)
    if not args[1] then
      return nil, "usage: :Trellis revert <rev>"
    end
    return a.revert(repo, args[1])
  end),
  reset = M_action("reset", function(a, repo, args)
    local mode, rev = "mixed", nil
    for _, x in ipairs(args) do
      local m = x:match("^%-%-(%a+)$")
      if m == "soft" or m == "mixed" or m == "hard" then
        mode = m
      else
        rev = x
      end
    end
    if not rev then
      return nil, "usage: :Trellis reset --soft|--mixed|--hard <rev>"
    end
    return a.reset(repo, rev, mode)
  end),
  restore = M_action("restore", function(a, repo, args, rel)
    local revs, path = M.split_paths(args)
    local vars = vim.b.trellis
    local rev = revs[1]
    if not rev and type(vars) == "table" and vars.view == "filerev" then
      rev, path = vars.sha, vars.path
    end
    path = path or rel
    if not rev or not path then
      return nil, "usage: :Trellis restore <rev> [-- <path>] (or from a trellis:// file buffer)"
    end
    return a.restore_file(repo, rev, path)
  end),
  undo = M_action("undo", function(_, repo)
    return require("trellis.safety.ops").undo(repo)
  end),
  redo = M_action("redo", function(_, repo)
    return require("trellis.safety.ops").redo(repo)
  end),
  continue = M_action("continue", function(_, repo)
    return require("trellis.safety.ops").control(repo, "continue")
  end),
  skip = M_action("skip", function(_, repo)
    return require("trellis.safety.ops").control(repo, "skip")
  end),
  abort = M_action("abort", function(_, repo)
    return require("trellis.safety.ops").control(repo, "abort")
  end),
  log = {
    milestone = "v0.4.0",
    run = function()
      require("trellis.view.ops").open_log()
    end,
  },
  ops = {
    milestone = "v0.4.0",
    run = function(args)
      M.with_repo(function(repo)
        if args[1] == "prune" then
          require("trellis.actions.ui").run(repo, function()
            local n, err = require("trellis.safety.ops").prune(repo)
            if not err then
              vim.schedule(function()
                vim.notify(("trellis: pruned backups of %d operation(s)"):format(n))
              end)
            end
            return nil, err
          end)
        else
          require("trellis.view.ops").open(repo)
        end
      end)
    end,
  },
  rebase = {
    milestone = "v0.5.0",
    run = function(args)
      if not args[1] then
        return vim.notify("trellis: usage: :Trellis rebase <base>", vim.log.levels.ERROR)
      end
      M.with_repo(function(repo)
        require("trellis.view.plan").start(repo, args[1])
      end)
    end,
  },
}

--- `:Trellis commit-graph`: asks, then runs W27 (never automatic, Constitution / FR spec US7).
function M.commit_graph()
  require("trellis.git.repo").discover(vim.fn.getcwd(), function(err, repo)
    if err then
      return vim.notify("trellis: " .. err, vim.log.levels.ERROR)
    end
    vim.ui.select({ "Write commit-graph", "Cancel" }, {
      prompt = "Run `git commit-graph write --reachable` in " .. repo.root .. "?",
    }, function(choice)
      if choice ~= "Write commit-graph" then
        return
      end
      local inv = require("trellis.git.argv").W27()
      require("trellis.git.runner").run(repo.root, inv.args, { kind = inv.kind }, function(e)
        if e then
          return vim.notify("trellis: " .. e, vim.log.levels.ERROR)
        end
        repo.features = require("trellis.git.features").detect(
          repo.features.version,
          repo.commondir,
          repo.features.sha256 and "sha256" or "sha1"
        )
        vim.notify("trellis: commit-graph written")
      end)
    end)
  end)
end

---@return string[]
function M.names()
  local names = vim.tbl_keys(M.subcommands)
  table.sort(names)
  return names
end

--- Split `:Trellis` arguments into subcommand and the rest. Arguments that look like a graph
--- query (options, revisions, `--`) mean `graph`.
---@param fargs string[]
---@return string sub, string[] args
function M.parse(fargs)
  local first = fargs[1]
  if not first then
    return "graph", {}
  end
  if M.subcommands[first] then
    return first, { unpack(fargs, 2) }
  end
  return "graph", fargs
end

local function notify(msg, level)
  vim.notify("trellis: " .. msg, level or vim.log.levels.INFO)
end

---@param cmd { fargs: string[], line1?: integer, line2?: integer, range?: integer, bang?: boolean }
function M.run(cmd)
  local sub, args = M.parse(cmd.fargs or {})
  local spec = M.subcommands[sub]
  if spec.run then
    return spec.run(args, cmd)
  end
  notify(
    ("`:Trellis %s` is not implemented yet (planned for %s)"):format(sub, spec.milestone),
    vim.log.levels.WARN
  )
end

--- Completion: subcommand names for the first argument.
---@param arglead string
---@param line string
---@return string[]
function M.complete(arglead, line)
  local words = vim.split(line, "%s+", { trimempty = true })
  local n = #words - (line:match("%s$") and 0 or 1)
  if n <= 1 then
    return vim.tbl_filter(function(name)
      return vim.startswith(name, arglead)
    end, M.names())
  end
  return {}
end

--- BufReadCmd for trellis:// names.
---@param ev { buf: integer, match: string }
function M.read_uri(ev)
  local uri, err = require("trellis.uri").parse(ev.match)
  if not uri then
    notify(err, vim.log.levels.ERROR)
    return
  end
  if uri.kind == "file" or uri.kind == "stage" then
    return require("trellis.view.filerev").read(ev, uri)
  end
  notify(
    ("%s buffers are opened from trellis views, not with :edit"):format(uri.kind),
    vim.log.levels.WARN
  )
end

--- BufWriteCmd for trellis:// names: revisions are read-only.
---@param ev { buf: integer, match: string }
function M.write_uri(ev)
  -- Plan and message buffers have their own buffer-local BufWriteCmd; only file-at-revision
  -- buffers are refused here.
  local uri = require("trellis.uri").parse(ev.match)
  local view = vim.b[ev.buf].trellis_view
  if view == "filerev" or (uri and (uri.kind == "file" or uri.kind == "stage")) then
    return require("trellis.view.filerev").refuse_write(ev.buf)
  end
end

--- Line range of a command: the given range, or the cursor line.
---@return integer l1, integer l2
function M.range(cmd)
  if cmd and cmd.range and cmd.range > 0 then
    return cmd.line1, cmd.line2
  end
  local l = vim.api.nvim_win_get_cursor(0)[1]
  return l, l
end

--- Split arguments at "--": revisions before, first path after.
---@return string[] revs, string? path
function M.split_paths(args)
  local revs, path, after = {}, nil, false
  for _, a in ipairs(args) do
    if after then
      path = path or a
    elseif a == "--" then
      after = true
    else
      revs[#revs + 1] = a
    end
  end
  return revs, path
end

--- Repository of the current buffer (trellis buffer, file buffer, or cwd), plus the current
--- file's repo-relative path when there is one.
---@param cb fun(repo: trellis.Repository, rel: string?)
function M.with_repo(cb)
  local vars = vim.b.trellis
  local name = vim.api.nvim_buf_get_name(0)
  local dir, file
  if type(vars) == "table" and vars.repo then
    dir = vars.repo
  elseif name ~= "" and vim.bo.buftype == "" then
    file = vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
    dir = vim.fs.dirname(file)
  else
    dir = vim.fn.getcwd()
  end
  require("trellis.git.repo").discover(dir, function(err, repo)
    if err then
      return notify(err, vim.log.levels.ERROR)
    end
    local rel
    if type(vars) == "table" and vars.path then
      rel = vars.path
    elseif file and file:sub(1, #repo.root + 1) == repo.root .. "/" then
      rel = file:sub(#repo.root + 2)
    end
    cb(repo, rel)
  end)
end

return M
