--- Date formatting for graph rows and views.
local M = {}

local MINUTE, HOUR, DAY = 60, 3600, 86400
local WEEK, MONTH, YEAR = 7 * DAY, 30 * DAY, 365 * DAY

local function plural(n, unit)
  return ("%d %s%s ago"):format(n, unit, n == 1 and "" or "s")
end

--- Human relative age, e.g. "5 minutes ago". Future timestamps (clock skew) read "in the future".
---@param ts integer unix time
---@param now? integer defaults to os.time()
---@return string
function M.relative(ts, now)
  local d = (now or os.time()) - ts
  if d < 0 then
    return "in the future"
  elseif d < 45 then
    return "just now"
  elseif d < HOUR then
    return plural(math.max(1, math.floor(d / MINUTE + 0.5)), "minute")
  elseif d < DAY then
    return plural(math.floor(d / HOUR), "hour")
  elseif d < WEEK then
    return plural(math.floor(d / DAY), "day")
  elseif d < MONTH then
    return plural(math.floor(d / WEEK), "week")
  elseif d < YEAR then
    return plural(math.floor(d / MONTH), "month")
  end
  return plural(math.floor(d / YEAR), "year")
end

--- Format per `graph.date_format`: "relative" | "iso" | strftime pattern.
---@param ts integer
---@param fmt string
---@param now? integer
---@return string
function M.format(ts, fmt, now)
  if fmt == "relative" then
    return M.relative(ts, now)
  elseif fmt == "iso" then
    return os.date("%Y-%m-%d %H:%M", ts) --[[@as string]]
  end
  return os.date(fmt, ts) --[[@as string]]
end

return M
