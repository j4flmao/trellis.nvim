--- Simulated history of a plan for the preview graph. Pure.
---
--- Entries are applied in order onto the base: squash/fixup fold into the previous commit,
--- drop and missing lines remove commits, reword changes the message. From the first
--- position that differs from the original history, every commit gets a new hash.
local plan_mod = require("trellis.rebase.plan")

local M = {}

---@class trellis.SimCommit
---@field id string          original sha when unchanged, else "new:<n>"
---@field from string[]      original shas folded into it
---@field subject string
---@field changed boolean
---@field parents string[]

---@param plan trellis.RebasePlanImpl
---@param entries trellis.PlanEntry[]
---@return { commits: trellis.SimCommit[], moved_refs: table<string, string>, dropped: string[], unchanged: boolean }
function M.run(plan, entries)
  local chain = {}
  local diverged = false
  local k = 0
  local moved = {}
  local kept = {}
  local function message_subject(sha, fallback)
    local m = plan.messages[sha]
    return m and (m:match("^[^\n]*") or fallback) or fallback
  end
  for _, e in ipairs(entries) do
    if plan_mod.COMMIT[e.action] then
      if e.action ~= "drop" then
        kept[e.sha] = true
      end
      k = k + 1
      local same_pos = not diverged and plan.original[k] == e.sha
      if e.action == "drop" then
        diverged = true
      elseif plan_mod.FOLD[e.action] then
        diverged = true
        local last = chain[#chain]
        if last then
          last.from[#last.from + 1] = e.sha
          last.changed = true
          last.id = "new:" .. #chain
          if e.action == "fixup_C" then
            last.subject = message_subject(last.from[1], plan.subjects[e.sha] or "")
          end
        end
      else
        -- git fast-forwards picks whose parent is unchanged (same hash); reword always makes
        -- a new commit.
        local reworded = e.action == "reword" or plan.messages[e.sha] ~= nil
        local same = same_pos and not reworded
        if not same then
          diverged = true
        end
        chain[#chain + 1] = {
          id = same and e.sha or ("new:" .. (#chain + 1)),
          from = { e.sha },
          subject = message_subject(e.sha, plan.subjects[e.sha] or e.subject or ""),
          changed = not same,
        }
      end
    elseif e.action == "update_ref" then
      moved[e.arg] = chain[#chain] and chain[#chain].id or plan.base
    end
  end
  local dropped = {}
  for _, sha in ipairs(plan.original) do
    if not kept[sha] then
      dropped[#dropped + 1] = sha
    end
  end
  if #dropped > 0 then
    diverged = true
  end
  -- Newest first with linear parents down to the base, for graph/layout.lua.
  local commits = {}
  for i = #chain, 1, -1 do
    local c = chain[i]
    c.parents = { i > 1 and chain[i - 1].id or plan.base }
    commits[#commits + 1] = c
  end
  local unchanged = not diverged and #chain == #plan.original
  for _, c in ipairs(chain) do
    if c.changed then
      unchanged = false
    end
  end
  return { commits = commits, moved_refs = moved, dropped = dropped, unchanged = unchanged }
end

return M
