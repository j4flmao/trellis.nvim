--- Side-by-side diff adapters (research R7, FR-023).
---
--- `views.diff.side_by_side = "auto"` picks the first available adapter: user-registered ones
--- (`require("trellis").register_diff_adapter`), then diffview.nvim, then the built-in
--- `:diffthis` between two trellis:// buffers, which always works. Neovim 0.12's `:DiffTool`
--- and codediff.nvim are not wired in yet; they can be added with register_diff_adapter.
local M = {}

---@class trellis.DiffAdapter
---@field name string
---@field available fun(): boolean
---@field open fun(repo: trellis.Repository, a: string?, b: string?, opts: trellis.DiffOpts)

---@class trellis.DiffOpts
---@field path string         path on the b side
---@field old_path? string    path on the a side (renames)
---@field added? boolean      the file does not exist on the a side
---@field deleted? boolean    the file does not exist on the b side

---@type trellis.DiffAdapter[]
M.registered = {}

local function empty_side(name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].modifiable = false
  return buf
end

--- Built-in: a new tab with the two versions side by side under :diffthis.
---@type trellis.DiffAdapter
M.builtin = {
  name = "builtin",
  available = function()
    return true
  end,
  open = function(repo, a, b, opts)
    local filerev = require("trellis.view.filerev")
    vim.cmd("tabnew")
    local left_win = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local right_win = vim.api.nvim_get_current_win()
    local pending = 2
    local function loaded()
      pending = pending - 1
      if pending > 0 then
        return
      end
      for _, w in ipairs({ left_win, right_win }) do
        if vim.api.nvim_win_is_valid(w) then
          vim.api.nvim_win_call(w, function()
            vim.cmd("diffthis")
          end)
        end
      end
    end
    local old = opts.old_path or opts.path
    if a and not opts.added then
      filerev.open(repo, a, old, { window = left_win, on_load = loaded })
    else
      vim.api.nvim_win_set_buf(left_win, empty_side("trellis://empty/" .. old))
      loaded()
    end
    if opts.deleted then
      vim.api.nvim_win_set_buf(right_win, empty_side("trellis://empty/" .. opts.path))
      loaded()
    elseif b then
      filerev.open(repo, b, opts.path, { window = right_win, on_load = loaded })
    else
      vim.api.nvim_win_call(right_win, function()
        vim.cmd.edit(vim.fn.fnameescape(repo.root .. "/" .. opts.path))
      end)
      loaded()
    end
  end,
}

---@type trellis.DiffAdapter
M.diffview = {
  name = "diffview",
  available = function()
    return vim.fn.exists(":DiffviewOpen") == 2
  end,
  open = function(_, a, b, opts)
    local range = b and (a .. ".." .. b) or a
    vim.cmd(("DiffviewOpen %s -- %s"):format(range, vim.fn.fnameescape(opts.path)))
  end,
}

--- Adapter for `views.diff.side_by_side`: "auto", "never" (nil), or an adapter name.
---@param setting string
---@return trellis.DiffAdapter?
function M.select(setting)
  if setting == "never" then
    return nil
  end
  local all = vim.list_extend(vim.list_extend({}, M.registered), { M.diffview, M.builtin })
  for _, ad in ipairs(all) do
    if (setting == "auto" or setting == ad.name) and ad.available() then
      return ad
    end
  end
  if setting ~= "auto" then
    vim.notify(
      ("trellis: diff adapter %q is not available, using builtin"):format(setting),
      vim.log.levels.WARN
    )
  end
  return M.builtin
end

---@param adapter trellis.DiffAdapter
function M.register(adapter)
  vim.validate("adapter.name", adapter.name, "string")
  vim.validate("adapter.available", adapter.available, "function")
  vim.validate("adapter.open", adapter.open, "function")
  table.insert(M.registered, adapter)
end

return M
