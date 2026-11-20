--- Default buffer-local keymaps per view and their
--- resolution against `config.keymaps`. Views register handlers by action name.
local M = {}

---@class trellis.KeymapSpec
---@field name string   action name (config key)
---@field key string    default lhs
---@field desc string
---@field mode? string|string[] default "n"

---@type table<string, trellis.KeymapSpec[]>
M.defaults = {
  common = {
    { name = "help", key = "g?", desc = "Show keymaps" },
    { name = "close", key = "q", desc = "Close view" },
    { name = "cancel", key = "<C-c>", desc = "Cancel running load" },
    { name = "refresh", key = "R", desc = "Refresh" },
  },
  graph = {
    { name = "next_commit", key = "J", desc = "Next commit row" },
    { name = "prev_commit", key = "K", desc = "Previous commit row" },
    { name = "next_ref", key = "]b", desc = "Next commit with a ref" },
    { name = "prev_ref", key = "[b", desc = "Previous commit with a ref" },
    { name = "goto_head", key = "gH", desc = "Jump to HEAD" },
    -- Same meaning as built-in G (a count still jumps to that line); loads history to the end.
    { name = "load_all_end", key = "G", desc = "Load all history and go to the end" },
    { name = "open_commit", key = "<CR>", desc = "Open commit view" },
    { name = "toggle_preview", key = "<Tab>", desc = "Toggle inline commit preview" },
    { name = "open_file", key = "o", desc = "Open a file of this commit at revision" },
    { name = "diff", key = "d", desc = "Diff commit against parent" },
    -- Not <Space>: a buffer-local <Space> would swallow <leader> where mapleader is Space.
    { name = "toggle_mark", key = "M", desc = "Mark commit for compare" },
    { name = "compare", key = "=", desc = "Diff marked commit with this one" },
    { name = "rebase", key = "gr", desc = "Rebase planner with this commit as base" },
    { name = "cherry_pick", key = "c", desc = "Cherry-pick", mode = { "n", "x" } },
    { name = "revert", key = "x", desc = "Revert" },
    { name = "checkout", key = "gco", desc = "Checkout" },
    { name = "branch_create", key = "gb", desc = "Create branch here" },
    { name = "tag_create", key = "gA", desc = "Create tag here" },
    { name = "reset", key = "gR", desc = "Reset to here" },
    { name = "yank_sha", key = "gy", desc = "Copy short sha" },
    { name = "yank_full_sha", key = "gY", desc = "Copy full sha" },
    { name = "yank_permalink", key = "gL", desc = "Copy permalink" },
    { name = "filters", key = "F", desc = "Edit filters" },
    { name = "search_all", key = "g/", desc = "Search entire history" },
    { name = "pick", key = "gp", desc = "Find a commit with your picker" },
    { name = "undo", key = "u", desc = "Undo last trellis operation" },
  },
  commit = {
    { name = "open_diff", key = "<CR>", desc = "Unified diff of file" },
    { name = "side_by_side", key = "D", desc = "Side-by-side diff of file" },
    { name = "open_file", key = "o", desc = "Open file at revision" },
    { name = "parent", key = "p", desc = "Jump to parent" },
    { name = "choose_parent", key = "P", desc = "Choose parent to diff against" },
    { name = "rebase", key = "gr", desc = "Rebase planner with this commit as base" },
  },
  filerev = {
    { name = "next_rev", key = "]r", desc = "Next revision of this file" },
    { name = "prev_rev", key = "[r", desc = "Previous revision of this file" },
    { name = "blame_line", key = "<CR>", desc = "Blame line at this revision" },
    { name = "open_worktree", key = "gW", desc = "Open working-copy file at this line" },
    -- Only on the metadata page of binary/large files (built-in `go` is meaningless there).
    { name = "open_anyway", key = "go", desc = "Open binary or large file anyway" },
  },
  diff = {
    { name = "open_file", key = "o", desc = "Open file at this line (new side)" },
  },
  search = {
    { name = "show_in_graph", key = "<CR>", desc = "Show the commit in the graph" },
    { name = "open_commit", key = "o", desc = "Open the commit view" },
  },
  ops = {
    { name = "restore", key = "r", desc = "Restore the state before this operation" },
    { name = "undo", key = "u", desc = "Undo the last operation" },
    { name = "details", key = "<Tab>", desc = "Show git commands and backup refs" },
    { name = "prune", key = "P", desc = "Prune old backups (asks first)" },
  },
  log = {},
  reflog = {
    { name = "open_commit", key = "<CR>", desc = "Open commit" },
    { name = "branch_create", key = "gb", desc = "Create a branch here (get a lost commit back)" },
    { name = "checkout", key = "gco", desc = "Checkout this commit" },
    { name = "yank_sha", key = "gy", desc = "Copy short sha" },
  },
  stash = {
    { name = "show", key = "<CR>", desc = "Show the stash's changes" },
    { name = "apply", key = "a", desc = "Apply to the worktree (undoable)" },
  },
  linehistory = {
    { name = "open_commit", key = "<CR>", desc = "Open commit" },
    { name = "open_file", key = "o", desc = "Open file at this revision and line" },
  },
  filehistory = {
    { name = "open_commit", key = "<CR>", desc = "Open commit" },
    { name = "open_file", key = "o", desc = "Open file at this revision" },
    { name = "diff", key = "d", desc = "Diff of this commit for the file" },
  },
  blame = {
    { name = "step_back", key = "[", desc = "Step back (parent of line's commit)" },
    { name = "step_forward", key = "]", desc = "Step forward" },
    { name = "open_commit", key = "<CR>", desc = "Open commit" },
    { name = "diff", key = "d", desc = "Diff of that commit for this file" },
    { name = "cycle_detail", key = "t", desc = "Cycle detail level" },
  },
  plan = {
    { name = "move_down", key = "<M-j>", desc = "Move entry down" },
    { name = "move_up", key = "<M-k>", desc = "Move entry up" },
    { name = "pick", key = "<M-p>", desc = "Action: pick" },
    { name = "reword", key = "<M-r>", desc = "Action: reword" },
    { name = "edit", key = "<M-e>", desc = "Action: edit" },
    { name = "squash", key = "<M-s>", desc = "Action: squash" },
    { name = "fixup", key = "<M-f>", desc = "Action: fixup" },
    { name = "fixup_C", key = "<M-F>", desc = "Action: fixup -C" },
    { name = "drop", key = "<M-d>", desc = "Action: drop" },
    { name = "exec", key = "<M-x>", desc = "Insert exec line below" },
    { name = "break", key = "<M-b>", desc = "Insert break line below" },
    { name = "open_commit", key = "<CR>", desc = "Open commit view for entry" },
    { name = "message", key = "<M-m>", desc = "Edit planned message" },
    { name = "fixup_into", key = "<M-t>", desc = "Fixup into target entry" },
    { name = "execute", key = "<C-CR>", desc = "Execute plan" },
    { name = "close", key = "ZQ", desc = "Close plan without executing" },
  },
  conflict = {
    { name = "open", key = "<CR>", desc = "Open file" },
    { name = "ours", key = "o", desc = "Take ours" },
    { name = "theirs", key = "t", desc = "Take theirs" },
    { name = "resolved", key = "a", desc = "Mark resolved" },
    { name = "continue", key = "C", desc = "Continue" },
    { name = "skip", key = "S", desc = "Skip" },
    { name = "abort", key = "A", desc = "Abort" },
    { name = "diff3", key = "d", desc = "3-way diff" },
  },
}

--- Views whose buffer is editable: no `common` maps that shadow editing commands.
M.editable = { plan = true }

--- Keys that keep their built-in meaning in every view (Constitution IV keymap policy).
M.protected = { "m", "'", "`", "y", "gt", "gT" }

--- Accepted exceptions in editable views: <CR> (same as `+`), ZQ (still "quit without writing"),
--- <C-CR> (no distinct built-in).
M.editable_exceptions = { ["<CR>"] = true, ["ZQ"] = true, ["<C-CR>"] = true }

--- Effective keymaps for a view: defaults (+ common for non-editable views) with user overrides.
--- `user` is `config.keymaps`: true/nil = defaults, false = none, table = per-view overrides
--- `{ graph = { cherry_pick = "C", revert = false } }`.
---@param view string
---@param user boolean|table|nil
---@return trellis.KeymapSpec[] maps, string[] problems
function M.resolve(view, user)
  local problems = {}
  if user == false then
    return {}, problems
  end
  local specs = {}
  if not M.editable[view] then
    vim.list_extend(specs, M.defaults.common)
  end
  vim.list_extend(specs, M.defaults[view] or {})
  local overrides = type(user) == "table" and user[view] or nil
  local known = {}
  for _, s in ipairs(specs) do
    known[s.name] = true
  end
  if type(overrides) == "table" then
    for name in pairs(overrides) do
      if not known[name] then
        problems[#problems + 1] = ("keymaps.%s.%s: unknown action"):format(view, name)
      end
    end
  end
  local out = {}
  for _, s in ipairs(specs) do
    local key = s.key
    if type(overrides) == "table" and overrides[s.name] ~= nil then
      key = overrides[s.name]
    end
    if key then
      out[#out + 1] = { name = s.name, key = key, desc = s.desc, mode = s.mode or "n" }
    end
  end
  return out, problems
end

return M
