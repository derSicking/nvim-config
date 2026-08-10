local M = {}

local storage = require("custom.worktime.storage")

-- "150" -> "2h 30m", "45" -> "45 min", "120" -> "2h"
function M.fmt_duration(min)
	local h = math.floor(min / 60)
	local m = min % 60
	if h == 0 then
		return string.format("%d min", m)
	end
	if m == 0 then
		return string.format("%dh", h)
	end
	return string.format("%dh %02dm", h, m)
end

-- Compact local time for notifications (lives in storage; shim here for
-- callers that already use util).
function M.fmt_ts(utc_ts)
	return storage.fmt_ts(utc_ts)
end

return M
