-- T124 / Constitution VIII: every command, option, keymap, highlight group, event and public API
-- function appears in doc/trellis.txt; the help file has valid tags.
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function doc()
  return table.concat(vim.fn.readfile(vim.fn.getcwd() .. "/doc/trellis.txt"), "\n")
end

local function missing(names, text)
  local out = {}
  for _, n in ipairs(names) do
    if not text:find(n, 1, true) then
      out[#out + 1] = n
    end
  end
  table.sort(out)
  return out
end

local function leaves(t, prefix, out)
  for k, v in pairs(t) do
    if type(v) == "table" and not vim.islist(v) and next(v) ~= nil then
      leaves(v, k, out)
    else
      out[#out + 1] = k
    end
  end
  return out
end

T["subcommands"] = function()
  eq(missing(require("trellis.commands").names(), doc()), {})
end

T["configuration options"] = function()
  eq(missing(leaves(require("trellis.config").defaults, "", {}), doc()), {})
end

T["default keys of every view"] = function()
  local text = doc()
  local keys = {}
  for view, specs in pairs(require("trellis.keymaps").defaults) do
    for _, s in ipairs(specs) do
      keys[#keys + 1] = s.key
    end
    eq({ view = view }, { view = view })
  end
  eq(missing(keys, text), {})
end

T["highlight groups and events"] = function()
  local text = doc()
  local names = vim.tbl_keys(require("trellis.highlights").links)
  -- TrellisGraph1..8 and TrellisBlameAge0..4 are documented as ranges.
  names = vim.tbl_filter(function(n)
    return not n:match("^TrellisGraph%d$") and not n:match("^TrellisBlameAge%d$")
  end, names)
  vim.list_extend(names, vim.tbl_keys(require("trellis.events").names))
  eq(missing(names, text), {})
end

T["public Lua API"] = function()
  local api = {}
  for name, fn in pairs(require("trellis")) do
    if type(fn) == "function" then
      api[#api + 1] = "trellis." .. name .. "("
    end
  end
  local text = doc():gsub('require%("trellis"%)%.', "trellis.")
  eq(missing(api, text), {})
end

T["help tags are valid"] = function()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  vim.fn.writefile(vim.fn.readfile(vim.fn.getcwd() .. "/doc/trellis.txt"), tmp .. "/trellis.txt")
  local ok, err = pcall(vim.cmd.helptags, vim.fn.fnameescape(tmp))
  eq({ ok = ok, err = (not ok) and err or nil }, { ok = true, err = nil })
  vim.fn.delete(tmp, "rf")
end

return T
