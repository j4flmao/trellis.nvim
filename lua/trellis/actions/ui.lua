--- Running actions from keys and commands: report the outcome, open the conflict panel when an
--- operation stops, remind of :Trellis undo.
local ops = require("trellis.safety.ops")

local M = {}

--- Run `fn` (returns op, err) inside async.run and report.
---@param repo trellis.Repository
---@param fn fun(): (table?, string?)
---@param after? fun(op: table?, err: string?)
function M.run(repo, fn, after)
  ops.spawn(fn, function(op, err)
    vim.schedule(function()
      if err then
        vim.notify(
          "trellis: " .. err,
          err:match("^cancelled") and vim.log.levels.INFO or vim.log.levels.ERROR
        )
      elseif op and op.status == "stopped" then
        vim.notify("trellis: " .. op.title .. " stopped on a conflict", vim.log.levels.WARN)
        require("trellis.view.conflict").open(repo)
      elseif op and op.status == "done" then
        local hint = (op.kind == "undo" and " — :Trellis redo to re-apply")
          or " — :Trellis undo reverts it"
        vim.notify("trellis: " .. op.title .. hint)
      end
      if after then
        after(op, err)
      end
    end)
  end)
end

return M
