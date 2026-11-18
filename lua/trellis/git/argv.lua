--- Builders for every git invocation in contracts/git-commands.md, keyed by contract ID.
--- Each builder returns a `trellis.GitInvocation`; `runner.build()` adds the global options.
--- tests/unit/git_argv_spec.lua checks that this table and the contract stay in sync.
local M = {}

---@class trellis.GitInvocation
---@field id string        contract ID, e.g. "G10"
---@field args string[]
---@field kind "R"|"W"|"O"
---@field stdin? string
---@field ok_codes? integer[]

M.LOG_FORMAT = "%H%x00%P%x00%an%x00%at%x00%s%x1e"
M.SHOW_FORMAT =
  "%H%x00%P%x00%an%x00%ae%x00%at%x00%ad%x00%cn%x00%ce%x00%ct%x00%cd%x00%G?%x00%GS%x00%B"
M.REFS_FORMAT = "%(objectname)%00%(*objectname)%00%(refname)%00%(upstream)%00%(HEAD)%1e"
--- RS starts each record so the patch git prints after a commit stays in that commit's record.
M.LINE_LOG_FORMAT = "%x1e%H%x00%P%x00%an%x00%at%x00%s%x00"
--- Fixed prefixes so user config (diff.noprefix, diff.mnemonicPrefix) cannot change paths.
local PREFIXES = { "--src-prefix=a/", "--dst-prefix=b/" }

local function inv(id, kind, args, extra)
  local t = { id = id, kind = kind, args = args }
  for k, v in pairs(extra or {}) do
    t[k] = v
  end
  return t
end

local function append(list, items)
  for _, v in ipairs(items or {}) do
    list[#list + 1] = v
  end
  return list
end

local function with_paths(args, paths)
  if paths and #paths > 0 then
    args[#args + 1] = "--"
    append(args, paths)
  end
  return args
end

--- IDs that are not git commands (file reads); listed so the sync test knows about them.
M.non_commands = { G06 = true }

-- Discovery & state -----------------------------------------------------------------------------

function M.G01()
  return inv("G01", "R", {
    "rev-parse",
    "--show-toplevel",
    "--absolute-git-dir",
    "--git-common-dir",
    "--is-shallow-repository",
    "--show-object-format",
  })
end

function M.G02()
  return inv("G02", "R", { "version" })
end

--- `-z` needs git >= 2.36; older versions use newline-separated output.
---@param nul boolean
function M.G03(nul)
  local args = { "worktree", "list", "--porcelain" }
  if nul then
    args[#args + 1] = "-z"
  end
  return inv("G03", "R", args)
end

function M.G04()
  return inv("G04", "R", { "for-each-ref", "--format=" .. M.REFS_FORMAT })
end

---@param which "symbolic"|"sha"
function M.G05(which)
  if which == "symbolic" then
    return inv("G05", "R", { "symbolic-ref", "-q", "HEAD" }, { ok_codes = { 1 } })
  end
  return inv("G05", "R", { "rev-parse", "-q", "--verify", "HEAD" }, { ok_codes = { 1 } })
end

-- Graph & search --------------------------------------------------------------------------------

--- Graph log stream.
---@param q trellis.GraphQuery
function M.G10(q)
  local args = { "log", "--no-color" }
  if q.order == "date" then
    args[#args + 1] = "--date-order"
  elseif q.order ~= "default" then
    -- "default" = plain commit-date order: streams without a full walk (research R2, spike T028)
    args[#args + 1] = "--topo-order"
  end
  args[#args + 1] = "--format=" .. M.LOG_FORMAT
  if q.author then
    args[#args + 1] = "--author=" .. q.author
  end
  if q.since then
    args[#args + 1] = "--since=" .. q.since
  end
  if q["until"] then
    args[#args + 1] = "--until=" .. q["until"]
  end
  if q.grep then
    args[#args + 1] = "--grep=" .. q.grep
  end
  if q.pickaxe then
    args[#args + 1] = "-" .. q.pickaxe.mode .. q.pickaxe.value
  end
  if q.first_parent then
    args[#args + 1] = "--first-parent"
  end
  if q.max_count then
    args[#args + 1] = "--max-count=" .. q.max_count
  end
  if q.ignore_case then
    args[#args + 1] = "--regexp-ignore-case"
  end
  if q.paths and #q.paths > 0 then
    -- Path limiting: let git rewrite %P to the nearest shown ancestors (history simplification),
    -- otherwise edges point at commits that are not in the output.
    args[#args + 1] = "--parents"
  end
  append(args, q.revs)
  return inv("G10", "R", with_paths(args, q.paths))
end

function M.G11(sha)
  return inv("G11", "R", { "show", "-s", "--date=raw", "--format=" .. M.SHOW_FORMAT, sha })
end

--- Changed files of `sha`.
--- `against` = nil: against its only parent (`--root`: root commits diff against the empty
--- tree, where `<sha>^!` would fail); a sha: two-tree diff against that parent (merges);
--- "cc": combined diff against all parents (merges; numstat is not available then).
---@param against? string
local function diff_tree(id, mode, sha, against)
  local args = { "diff-tree", "--no-commit-id", "-r", "-z", mode }
  if against == "cc" then
    append(args, { "--cc", sha })
  elseif against then
    append(args, { "--find-renames", against, sha })
  else
    append(args, { "--find-renames", "--root", sha })
  end
  return inv(id, "R", args)
end

function M.G12(sha, against)
  return diff_tree("G12", "--numstat", sha, against)
end

function M.G13(sha, against)
  return diff_tree("G13", "--name-status", sha, against)
end

--- Subjects of a few commits (parents in the commit view).
---@param shas string[]
function M.G14(shas)
  return inv("G14", "R", append({ "log", "--no-walk", "--format=%H%x00%s" }, shas))
end

--- The empty tree, for diffs of root commits.
---@param sha256? boolean
function M.empty_tree(sha256)
  return sha256 and "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321"
    or "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
end

-- Diffs & files ---------------------------------------------------------------------------------

---@param a string
---@param b? string nil = working tree
---@param path? string|string[] one path, or old and new path of a rename
function M.G20(a, b, path)
  if type(path) == "table" then
    local args =
      append({ "diff", "--patch", "--find-renames", "--no-ext-diff", "--no-color" }, PREFIXES)
    args[#args + 1] = a
    if b then
      args[#args + 1] = b
    end
    return inv("G20", "R", with_paths(args, path))
  end
  local args =
    append({ "diff", "--patch", "--find-renames", "--no-ext-diff", "--no-color" }, PREFIXES)
  args[#args + 1] = a
  if b then
    args[#args + 1] = b
  end
  return inv("G20", "R", with_paths(args, path and { path } or nil))
end

--- Object name for a file at a revision: "<sha>:<path>", or ":<n>:<path>" for index stages
--- (`rev` = ":<n>").
local function object(rev, path)
  return rev .. ":" .. path
end

function M.G21(rev, path)
  return inv("G21", "R", { "cat-file", "-s", object(rev, path) })
end

function M.G22(rev, path)
  return inv("G22", "R", { "cat-file", "--filters", object(rev, path) })
end

--- File history across renames. Each record starts with RS so the name-status lines that git
--- prints after a commit's header stay in that commit's record.
M.FILELOG_FORMAT = "%x1e%H%x00%P%x00%an%x00%at%x00%s%x00"
function M.G23(path, rev)
  local args = { "log", "--follow", "--format=" .. M.FILELOG_FORMAT, "--name-status" }
  if rev then
    args[#args + 1] = rev
  end
  append(args, { "--", path })
  return inv("G23", "R", args)
end

--- Resolve a (possibly abbreviated) revision to a full commit sha.
function M.G24(rev)
  return inv(
    "G24",
    "R",
    { "rev-parse", "--verify", "-q", rev .. "^{commit}" },
    { ok_codes = { 1 } }
  )
end

--- Newest commit at or before `rev` that changed `path` (the revision whose blob is shown).
function M.G25(rev, path)
  return inv("G25", "R", { "rev-list", "-1", rev, "--", path })
end

-- Blame & line history --------------------------------------------------------------------------

---@param o { rev?: string, path: string, ignore_whitespace?: boolean, detect_moves?: false|"file"|"copies", ignore_revs_file?: string, contents?: string }
function M.G30(o)
  local args = { "blame", "--incremental" }
  if o.ignore_whitespace then
    args[#args + 1] = "-w"
  end
  if o.detect_moves == "file" then
    args[#args + 1] = "-M"
  elseif o.detect_moves == "copies" then
    args[#args + 1] = "-C"
  end
  if o.ignore_revs_file then
    args[#args + 1] = "--ignore-revs-file=" .. o.ignore_revs_file
  end
  if o.contents then
    append(args, { "--contents", "-" })
  end
  if o.rev then
    args[#args + 1] = o.rev
  end
  append(args, { "--", o.path })
  return inv("G30", "R", args, { stdin = o.contents })
end

function M.G31(parent, commit, paths)
  local args = append({ "diff", "-U0", "--no-color", "--no-ext-diff" }, PREFIXES)
  args[#args + 1] = parent
  if commit then -- nil: against the working tree
    args[#args + 1] = commit
  end
  return inv("G31", "R", with_paths(args, paths))
end

function M.G32(s, e, path, rev)
  local args = { "log", ("-L%d,%d:%s"):format(s, e, path), "--format=" .. M.LINE_LOG_FORMAT }
  append(args, PREFIXES)
  if rev then
    args[#args + 1] = rev
  end
  return inv("G32", "R", args)
end

--- URL of a remote, for permalinks.
function M.G33(remote)
  return inv("G33", "R", { "remote", "get-url", remote })
end

-- Rebase planning & prediction ------------------------------------------------------------------

function M.G40(base, rebase_merges)
  local args = { "rev-list", "--reverse", "--topo-order" }
  if not rebase_merges then
    args[#args + 1] = "--no-merges"
  end
  args[#args + 1] = base .. "..HEAD"
  return inv("G40", "R", args)
end

function M.G41(base)
  return inv("G41", "R", { "rev-list", base .. "..HEAD", "--not", "--remotes" })
end

--- Only meaningful when onto ~= base (see contract).
function M.G42(onto, base)
  return inv("G42", "R", { "cherry", onto, "HEAD", base })
end

function M.G43(commit, tip)
  return inv("G43", "O", {
    "merge-tree",
    "--write-tree",
    "--messages",
    "--name-only",
    "-z",
    "--merge-base=" .. commit .. "^",
    tip,
    commit,
  }, { ok_codes = { 1 } })
end

function M.G44(tree, tip)
  return inv("G44", "O", { "commit-tree", tree, "-p", tip, "-m", "trellis-sim" })
end

function M.G45(sha)
  local args = append({ "diff-tree", "-p", "-U0", "--no-color", "--root" }, PREFIXES)
  args[#args + 1] = sha
  return inv("G45", "R", args)
end

-- Writes (journaled; backup first) --------------------------------------------------------------

--- `lines`: update-ref --stdin instructions, e.g. { "start", "create refs/x <sha>", "commit" }.
---@param lines string[]
function M.W01(lines)
  return inv("W01", "W", { "update-ref", "--stdin" }, { stdin = table.concat(lines, "\n") .. "\n" })
end

function M.W02()
  return inv("W02", "O", { "stash", "create" })
end

---@param base string
---@param o? { rebase_merges?: boolean, update_refs?: boolean, autostash?: boolean }
function M.W10(base, o)
  o = o or {}
  local args = { "rebase", "-i" }
  if o.rebase_merges then
    args[#args + 1] = "--rebase-merges"
  end
  if o.update_refs then
    args[#args + 1] = "--update-refs"
  end
  if o.autostash then
    args[#args + 1] = "--autostash"
  end
  args[#args + 1] = base
  return inv("W10", "W", args)
end

---@param op "continue"|"skip"|"abort"
function M.W11(op)
  return inv("W11", "W", { "rebase", "--" .. op })
end

---@param target string
---@param detach? boolean
function M.W20(target, detach)
  if detach then
    return inv("W20", "W", { "switch", "--detach", target })
  end
  return inv("W20", "W", { "switch", target })
end

---@param op "create"|"rename"|"delete"
function M.W21(op, a, b)
  if op == "create" then
    return inv("W21", "W", { "branch", a, b })
  elseif op == "rename" then
    return inv("W21", "W", { "branch", "-m", a, b })
  end
  return inv("W21", "W", { "branch", "-D", a })
end

---@param op "create"|"delete"
---@param name string
---@param sha? string
---@param message? string annotated when given
function M.W22(op, name, sha, message)
  if op == "delete" then
    return inv("W22", "W", { "tag", "-d", name })
  elseif message then
    return inv("W22", "W", { "tag", "-a", name, "-m", message, sha })
  end
  return inv("W22", "W", { "tag", name, sha })
end

---@param shas string[]|"continue"|"skip"|"abort"
---@param x? boolean
function M.W23(shas, x)
  if type(shas) == "string" then
    return inv("W23", "W", { "cherry-pick", "--" .. shas })
  end
  local args = { "cherry-pick" }
  if x then
    args[#args + 1] = "-x"
  end
  return inv("W23", "W", append(args, shas))
end

---@param sha string|"continue"|"skip"|"abort"
---@param mainline? integer
function M.W24(sha, mainline)
  if sha == "continue" or sha == "skip" or sha == "abort" then
    return inv("W24", "W", { "revert", "--" .. sha })
  end
  local args = { "revert", "--no-edit" }
  if mainline then
    append(args, { "-m", tostring(mainline) })
  end
  args[#args + 1] = sha
  return inv("W24", "W", args)
end

---@param mode "soft"|"mixed"|"hard"
function M.W25(mode, sha)
  return inv("W25", "W", { "reset", "--" .. mode, sha })
end

---@param op "add"|"ours"|"theirs"
function M.W26(op, path)
  if op == "add" then
    return inv("W26", "W", { "add", "--", path })
  end
  return inv("W26", "W", { "checkout", "--" .. op, "--", path })
end

function M.W27()
  return inv("W27", "O", { "commit-graph", "write", "--reachable" })
end

---@param index? boolean also restore the staged state (--index)
function M.W28(sha, index)
  if index then
    return inv("W28", "W", { "stash", "apply", "--index", sha })
  end
  return inv("W28", "W", { "stash", "apply", sha })
end

--- Save a working-tree file as a blob (raw bytes) before overwriting it (restore_file).
function M.W29(path)
  return inv("W29", "O", { "hash-object", "-w", "--no-filters", "--", path })
end

--- Undo/redo of the checked-out branch: `--keep` refuses to lose local changes; soft/mixed
--- reproduce the original reset's index handling.
---@param mode "keep"|"soft"|"mixed"
function M.W30(mode, sha)
  return inv("W30", "W", { "reset", "--" .. mode, sha })
end

--- Stash uncommitted changes before an undo (offered, never automatic).
function M.W31(message)
  return inv("W31", "W", { "stash", "push", "-m", message })
end

-- Reads used by the safety pipeline --------------------------------------------------------------

--- Tracked changes (untracked files are never touched by trellis operations).
function M.G07()
  return inv("G07", "R", { "status", "--porcelain=v2", "-z", "--untracked-files=no" })
end

--- Is `a` an ancestor of `b`? exit 0 yes, 1 no.
function M.G08(a, b)
  return inv("G08", "R", { "merge-base", "--is-ancestor", a, b }, { ok_codes = { 1 } })
end

--- Raw values of the given refs (annotated tags: the tag object, not the commit).
---@param refnames string[]
function M.G09(refnames)
  return inv(
    "G09",
    "R",
    append({ "for-each-ref", "--format=%(refname)%00%(objectname)" }, refnames)
  )
end

--- Refs under a prefix (backup refs of one operation, for prune).
function M.G16(prefix)
  return inv("G16", "R", { "for-each-ref", "--format=%(refname)", prefix })
end

--- Commits in `a..b` (what a reset to `a` drops from the branch).
function M.G15(a, b)
  return inv("G15", "R", { "log", "--format=%h %s", a .. ".." .. b })
end

--- Raw blob bytes (restore_file undo).
function M.G26(sha)
  return inv("G26", "R", { "cat-file", "blob", sha })
end

--- All IDs this module can build (for the contract sync test).
---@return string[]
function M.ids()
  local ids = {}
  for k in pairs(M) do
    if type(k) == "string" and k:match("^[GW]%d%d$") then
      ids[#ids + 1] = k
    end
  end
  for k in pairs(M.non_commands) do
    ids[#ids + 1] = k
  end
  table.sort(ids)
  return ids
end

return M
