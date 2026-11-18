-- trellis.nvim entry point. Startup budget < 1 ms (Constitution III): define the command and
-- autocmds only; every module is required lazily on first use.
if vim.g.loaded_trellis then
  return
end
vim.g.loaded_trellis = true

vim.api.nvim_create_user_command("Trellis", function(cmd)
  require("trellis.commands").run(cmd)
end, {
  nargs = "*",
  range = true,
  bang = true,
  desc = "trellis.nvim: git history explorer",
  complete = function(arglead, line)
    return require("trellis.commands").complete(arglead, line)
  end,
})

local group = vim.api.nvim_create_augroup("trellis", { clear = true })
vim.api.nvim_create_autocmd("BufReadCmd", {
  group = group,
  pattern = "trellis://*",
  nested = true,
  callback = function(ev)
    require("trellis.commands").read_uri(ev)
  end,
})
vim.api.nvim_create_autocmd("BufWriteCmd", {
  group = group,
  pattern = "trellis://*",
  callback = function(ev)
    require("trellis.commands").write_uri(ev)
  end,
})
