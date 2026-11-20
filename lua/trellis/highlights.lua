--- Highlight groups (contracts/lua-api.md → Highlight groups), all `default = true` so
--- colorschemes and users can override them. Re-applied on :colorscheme.
local M = {}

M.lane_colors = 8

M.links = {
  TrellisGraph1 = "DiagnosticInfo",
  TrellisGraph2 = "String",
  TrellisGraph3 = "Function",
  TrellisGraph4 = "Keyword",
  TrellisGraph5 = "Type",
  TrellisGraph6 = "Constant",
  TrellisGraph7 = "Special",
  TrellisGraph8 = "Identifier",
  TrellisCommitNode = "Normal",
  TrellisHead = "DiagnosticOk",
  TrellisBranchLocal = "Function",
  TrellisBranchRemote = "Comment",
  TrellisTag = "Constant",
  TrellisStash = "Special",
  TrellisWorktree = "Special",
  TrellisBackup = "Comment",
  TrellisGrafted = "WarningMsg",
  TrellisSha = "Identifier",
  TrellisAuthor = "Comment",
  TrellisDate = "Comment",
  TrellisSubject = "Normal",
  TrellisFilter = "WarningMsg",
  TrellisMarked = "Visual",
  TrellisUncommitted = "DiagnosticWarn",
  -- Blame heat, newest (0) to oldest (4).
  TrellisBlameAge0 = "Title",
  TrellisBlameAge1 = "Identifier",
  TrellisBlameAge2 = "Normal",
  TrellisBlameAge3 = "Comment",
  TrellisBlameAge4 = "NonText",
  TrellisBlameUncommitted = "DiagnosticWarn",
  TrellisPreview = "Comment",
  TrellisPlanAction = "Keyword",
  TrellisPlanDrop = "DiagnosticUnnecessary",
  TrellisPlanRisk = "DiagnosticWarn",
  TrellisPlanConflict = "DiagnosticError",
  TrellisPlanPublished = "DiagnosticHint",
  TrellisPreviewChanged = "DiffChange",
}

--- Ref kind → highlight group.
M.ref_groups = {
  head = "TrellisHead",
  ["local"] = "TrellisBranchLocal",
  remote = "TrellisBranchRemote",
  tag = "TrellisTag",
  stash = "TrellisStash",
  worktree = "TrellisWorktree",
  backup = "TrellisBackup",
}

local function apply()
  for group, link in pairs(M.links) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

local installed = false

--- Define the groups once per session and keep them across colorscheme changes.
function M.setup()
  apply()
  if installed then
    return
  end
  installed = true
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("trellis.highlights", { clear = true }),
    callback = apply,
  })
end

return M
