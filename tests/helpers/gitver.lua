--- The git version the tests run against, to skip cases that need a newer git.
local features = require("trellis.git.features")

local M = {}

local version
function M.version()
  if not version then
    local out = vim.system({ "git", "--version" }, { text = true }):wait().stdout or ""
    version = features.parse_version(out) or { 0, 0, 0 }
  end
  return version
end

--- Skip the current case unless git >= `req` ({2, 38}).
---@param req integer[]
---@param what string
function M.require(req, what)
  if not features.at_least(M.version(), req) then
    MiniTest.skip(
      ("%s needs git >= %s (have %s)"):format(
        what,
        features.version_string(req),
        features.version_string(M.version())
      )
    )
  end
end

return M
