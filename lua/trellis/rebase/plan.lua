--- RebasePlan model (data-model.md → RebasePlan): build from a range, buffer lines ↔ entries,
--- validation, git todo serialization, autosquash.
---
--- The plan buffer is the source of truth while editing: `parse_lines` turns its text into
--- entries plus diagnostics. Only `from_range` and `is_stale` talk to git.
local argv = require("trellis.git.argv")
local todo = require("trellis.git.parse.todo")

local M = {}

M.COMMIT = todo.commit_actions -- pick reword edit squash fixup fixup_C fixup_c drop
M.FOLD = { squash = true, fixup = true, fixup_C = true, fixup_c = true }
M.ACTION_WORD = {
  pick = "pick",
  reword = "reword",
  edit = "edit",
  squash = "squash",
  fixup = "fixup",
  fixup_C = "fixup -C",
  fixup_c = "fixup -c",
  drop = "drop",
}

---@class trellis.PlanEntry
---@field action string
---@field sha? string
---@field subject? string
---@field arg? string
---@field lnum? integer

---@class trellis.RebasePlanImpl
---@field id string
---@field base string
---@field onto string
---@field head_ref string?
---@field head_sha string
---@field original string[]            commits of base..HEAD, oldest first
---@field subjects table<string, string>
---@field published table<string, boolean>
---@field messages table<string, string> planned full messages by sha (reword / chain head)
---@field entries trellis.PlanEntry[]   initial entries (the buffer may change them)
---@field opts table
---@field created_at integer

-- Autosquash ------------------------------------------------------------------------------------

local MARKERS = { { "fixup! ", "fixup" }, { "squash! ", "squash" }, { "amend! ", "fixup_C" } }

local function strip_markers(subject)
  local action
  local changed = true
  while changed do
    changed = false
    for _, m in ipairs(MARKERS) do
      if subject:sub(1, #m[1]) == m[1] then
        subject = subject:sub(#m[1] + 1)
        action = action or m[2]
        changed = true
      end
    end
  end
  return action, subject
end

--- Reorder "fixup! / squash! / amend!" commits after their target, like git's --autosquash.
---@param entries trellis.PlanEntry[]
---@return trellis.PlanEntry[]
function M.autosquash(entries)
  local out, placed = {}, {}
  local target_of = {}
  for i, e in ipairs(entries) do
    local action, rest = strip_markers(e.subject or "")
    if action and e.sha then
      -- Target: an earlier commit whose subject equals `rest`, else starts with it, else whose
      -- sha starts with it.
      local t
      for j = 1, i - 1 do
        local s = entries[j].subject or ""
        if not strip_markers(s) and s == rest then
          t = j
          break
        end
      end
      if not t then
        for j = 1, i - 1 do
          local s, sha = entries[j].subject or "", entries[j].sha or ""
          if
            not strip_markers(s)
            and (vim.startswith(s, rest) or (#rest >= 4 and vim.startswith(sha, rest)))
          then
            t = j
            break
          end
        end
      end
      if t then
        target_of[i] = { t = t, action = action }
      end
    end
  end
  local followers = {}
  for i, info in pairs(target_of) do
    followers[info.t] = followers[info.t] or {}
    table.insert(followers[info.t], i)
  end
  for _, list in pairs(followers) do
    table.sort(list)
  end
  local function emit(i)
    if placed[i] then
      return
    end
    placed[i] = true
    local e = vim.deepcopy(entries[i])
    if target_of[i] then
      e.action = target_of[i].action
    end
    out[#out + 1] = e
    for _, f in ipairs(followers[i] or {}) do
      emit(f)
    end
  end
  for i = 1, #entries do
    if not target_of[i] then
      emit(i)
    end
  end
  for i = 1, #entries do
    emit(i) -- targets that were not found earlier (should not happen) keep their place
  end
  return out
end

-- Building ----------------------------------------------------------------------------------

local function git(repo, inv)
  return require("trellis.safety.backup").git(repo, inv)
end

--- Plan for rebasing HEAD onto `base` (exclusive). Inside async.run.
---@param repo trellis.Repository
---@param base_rev string
---@param opts? { rebase_merges?: boolean, update_refs?: boolean, autosquash?: boolean, order?: string }
---@return trellis.RebasePlanImpl? plan, string? err
function M.from_range(repo, base_rev, opts)
  opts = opts or {}
  if opts.rebase_merges then
    return nil,
      "--rebase-merges plans are not supported yet (planned after 0.5); merges are linearized by a plain rebase -i"
  end
  local backup = require("trellis.safety.backup")
  local preflight = require("trellis.safety.preflight")
  local err, res = git(repo, argv.G24(base_rev))
  local base = res and res.code == 0 and vim.trim(res.stdout) or nil
  if err or not base or base == "" then
    return nil, ("unknown revision %q"):format(base_rev)
  end
  local _, head = backup.read_refs(repo, {})
  if not head.sha then
    return nil, "HEAD has no commits"
  end
  if base == head.sha then
    return nil, "nothing to rebase: the base is HEAD"
  end
  if not preflight.is_ancestor(repo, base, head.sha) then
    return nil, ("%s is not an ancestor of HEAD"):format(base_rev)
  end
  local lerr, list = git(repo, argv.G40(base, false))
  if lerr then
    return nil, lerr
  end
  local original = vim.split(vim.trim(list.stdout), "\n", { trimempty = true })
  if #original == 0 then
    return nil, "no commits to rebase between " .. base_rev .. " and HEAD (merges only?)"
  end
  local subjects = {}
  for i = 1, #original, 400 do
    local _, sres = git(repo, argv.G14({ unpack(original, i, math.min(#original, i + 399)) }))
    for line in ((sres and sres.stdout) or ""):gmatch("[^\n]+") do
      local sha, s = line:match("^(%x+)%z(.*)$")
      if sha then
        subjects[sha] = s
      end
    end
  end
  local _, unpub = git(repo, argv.G41(base))
  local unpublished = {}
  for sha in ((unpub and unpub.stdout) or ""):gmatch("%x+") do
    unpublished[sha] = true
  end
  local published = {}
  local entries = {}
  for _, sha in ipairs(original) do
    published[sha] = not unpublished[sha]
    entries[#entries + 1] = { action = "pick", sha = sha, subject = subjects[sha] or "" }
  end
  if opts.autosquash then
    entries = M.autosquash(entries)
  end
  if opts.update_refs and repo.refs then
    local with_refs = {}
    for _, e in ipairs(entries) do
      with_refs[#with_refs + 1] = e
      for _, r in ipairs(repo.refs.by_sha[e.sha] or {}) do
        if
          r.kind == "local"
          and r.name ~= head.symbolic
          and not preflight.checked_out_elsewhere(repo, r.name)
        then
          with_refs[#with_refs + 1] = { action = "update_ref", arg = r.name }
        end
      end
    end
    entries = with_refs
  end
  return {
    id = require("trellis.safety.journal").new_id(),
    base = base,
    onto = base,
    head_ref = head.symbolic,
    head_sha = head.sha,
    original = original,
    subjects = subjects,
    published = published,
    messages = {},
    entries = entries,
    opts = opts,
    created_at = os.time(),
  }
end

--- Is the plan out of date (HEAD moved, branch switched, base no longer an ancestor)? Async.
---@return string? reason
function M.stale_reason(repo, plan)
  local _, head = require("trellis.safety.backup").read_refs(repo, {})
  if head.sha ~= plan.head_sha or head.symbolic ~= plan.head_ref then
    return "plan is stale — HEAD moved since the plan was created; reopen it with :Trellis rebase "
      .. plan.base:sub(1, 7)
  end
end

-- Buffer lines ------------------------------------------------------------------------------

--- Shortest abbreviation (≥ 7) that is unique among the plan's commits.
function M.abbrev(plan)
  if plan.abbrev_len then
    return plan.abbrev_len
  end
  local len = 7
  while len < 64 do
    local seen, clash = {}, false
    for _, sha in ipairs(plan.original) do
      local p = sha:sub(1, len)
      if seen[p] then
        clash = true
        break
      end
      seen[p] = true
    end
    if not clash then
      break
    end
    len = len + 1
  end
  plan.abbrev_len = len
  return len
end

local function entry_line(plan, e)
  if M.COMMIT[e.action] then
    local subject = (plan.subjects[e.sha] or e.subject or ""):gsub("%c", "?")
    return ("%s %s %s"):format(M.ACTION_WORD[e.action], e.sha:sub(1, M.abbrev(plan)), subject)
  elseif e.action == "exec" then
    return "exec " .. e.arg
  elseif e.action == "break" then
    return "break"
  elseif e.action == "update_ref" then
    return "update-ref " .. e.arg
  end
  return e.action .. " " .. (e.arg or "")
end

---@param plan trellis.RebasePlanImpl
---@param entries? trellis.PlanEntry[]
---@return string[]
function M.to_lines(plan, entries)
  local lines = {}
  local list = entries or plan.entries
  if plan.opts.order == "newest_first" then
    for i = #list, 1, -1 do
      lines[#lines + 1] = entry_line(plan, list[i])
    end
  else
    for _, e in ipairs(list) do
      lines[#lines + 1] = entry_line(plan, e)
    end
  end
  return lines
end

---@class trellis.PlanDiagnostic
---@field lnum integer 1-based
---@field severity "error"|"warn"|"info"
---@field message string

--- Parse plan buffer lines into entries (oldest first) and diagnostics.
---@param plan trellis.RebasePlanImpl
---@param lines string[]
---@return trellis.PlanEntry[] entries, trellis.PlanDiagnostic[] diagnostics
function M.parse_lines(plan, lines)
  local entries, diags = {}, {}
  local seen = {}
  local order = {}
  if plan.opts.order == "newest_first" then
    for i = #lines, 1, -1 do
      order[#order + 1] = i
    end
  else
    for i = 1, #lines do
      order[#order + 1] = i
    end
  end
  local function diag(lnum, severity, message)
    diags[#diags + 1] = { lnum = lnum, severity = severity, message = message }
  end
  local have_commit = false
  for _, lnum in ipairs(order) do
    local t = todo.parse_line(lines[lnum], { trellis_aliases = true })
    if t.kind == "error" then
      diag(lnum, "error", t.message)
    elseif t.kind == "entry" then
      if t.action == "label" or t.action == "reset" or t.action == "merge" then
        diag(lnum, "error", t.action .. ": --rebase-merges plans are not supported yet")
      elseif M.COMMIT[t.action] then
        local full, ambiguous
        for _, sha in ipairs(plan.original) do
          if vim.startswith(sha, t.sha) then
            if full then
              full, ambiguous = nil, true
              diag(lnum, "error", "ambiguous commit " .. t.sha)
              break
            end
            full = sha
          end
        end
        if ambiguous then
          -- reported above
        elseif not full then
          diag(lnum, "error", ("%s is not one of the commits being rebased"):format(t.sha))
        elseif seen[full] then
          diag(lnum, "error", ("%s appears twice (first on line %d)"):format(t.sha, seen[full]))
        else
          seen[full] = lnum
          if M.FOLD[t.action] and not have_commit then
            diag(lnum, "error", t.action:gsub("_.*", "") .. " needs an earlier commit to fold into")
          end
          if t.action ~= "drop" then
            have_commit = true
          end
          entries[#entries + 1] =
            { action = t.action, sha = full, subject = plan.subjects[full], lnum = lnum }
        end
      else
        entries[#entries + 1] = { action = t.action, arg = t.arg, lnum = lnum }
      end
    end
  end
  for _, sha in ipairs(plan.original) do
    if not seen[sha] then
      -- A deleted line drops the commit (git semantics); say so, gently.
      diags[#diags + 1] = {
        lnum = 0,
        severity = "info",
        message = sha:sub(1, 7) .. " is not in the plan: it will be dropped",
      }
    end
  end
  return entries, diags
end

--- Git todo text (full shas) for entries.
---@param entries trellis.PlanEntry[]
---@return string
function M.to_todo(plan, entries)
  local out = {}
  for _, e in ipairs(entries) do
    if M.COMMIT[e.action] then
      out[#out + 1] = {
        action = e.action,
        sha = e.sha,
        subject = (plan.subjects[e.sha] or ""):gsub("[\r\n]", " "),
      }
    else
      out[#out + 1] = { action = e.action, arg = e.arg }
    end
  end
  return todo.serialize(out)
end

--- Head of the commit chain an entry belongs to (for planned messages of squash chains).
---@return string? sha
function M.chain_head(entries, index)
  for i = index, 1, -1 do
    local e = entries[i]
    if e.sha and not M.FOLD[e.action] and e.action ~= "drop" then
      return e.sha
    elseif not e.sha then
      return nil
    end
  end
end

--- Counts for the summary line.
function M.summary(plan, entries)
  local counts = { commits = 0, squash = 0, drop = 0, reword = 0, edit = 0, exec = 0 }
  local kept = {}
  for _, e in ipairs(entries) do
    if M.COMMIT[e.action] then
      kept[e.sha] = true
      if e.action == "drop" then
        counts.drop = counts.drop + 1
      elseif M.FOLD[e.action] then
        counts.squash = counts.squash + 1
      else
        counts.commits = counts.commits + 1
        if e.action == "reword" or plan.messages[e.sha] then
          counts.reword = counts.reword + 1
        elseif e.action == "edit" then
          counts.edit = counts.edit + 1
        end
      end
    elseif e.action == "exec" then
      counts.exec = counts.exec + 1
    end
  end
  for _, sha in ipairs(plan.original) do
    if not kept[sha] then
      counts.drop = counts.drop + 1
    end
  end
  return counts
end

return M
