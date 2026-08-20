-- Pure time helpers: conversions, parsing and formatting. No I/O beyond
-- os.date/os.time, so this module is safe to use anywhere.

local M = {}

local function epoch_from_local(ts)
	local y, mo, d, h, mi, s = ts:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)$")
	if not y then
		return nil
	end
	return os.time({
		year = tonumber(y),
		month = tonumber(mo),
		day = tonumber(d),
		hour = tonumber(h),
		min = tonumber(mi),
		sec = tonumber(s),
	})
end

local function epoch_from_utc(ts)
	local y, mo, d, h, mi, s = ts:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
	if not y then
		return nil
	end
	-- os.time treats the fields as local; correct for the zone offset.
	-- isdst is deliberately NOT passed, so DST is evaluated for the date.
	local t = {
		year = tonumber(y),
		month = tonumber(mo),
		day = tonumber(d),
		hour = tonumber(h),
		min = tonumber(mi),
		sec = tonumber(s),
	}
	local as_local = os.time(t)
	local utc = os.date("!*t", as_local)
	local utc_as_local = os.time({
		year = utc.year,
		month = utc.month,
		day = utc.day,
		hour = utc.hour,
		min = utc.min,
		sec = utc.sec,
	})
	return as_local + (as_local - utc_as_local)
end

-- UTC "YYYY-MM-DDTHH:MM:SSZ" -> epoch seconds (nil when malformed)
function M.epoch(utc_ts)
	return epoch_from_utc(utc_ts)
end

function M.now_utc()
	return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- Local "YYYY-MM-DDTHH:MM:SS" -> UTC "YYYY-MM-DDTHH:MM:SSZ"
function M.to_utc(local_ts)
	local t = epoch_from_local(local_ts)
	if not t then
		return nil
	end
	return os.date("!%Y-%m-%dT%H:%M:%SZ", t)
end

-- UTC "YYYY-MM-DDTHH:MM:SSZ" -> local "YYYY-MM-DDTHH:MM:SS"
function M.to_local(utc_ts)
	local t = epoch_from_utc(utc_ts)
	if not t then
		return nil
	end
	return os.date("%Y-%m-%dT%H:%M:%S", t)
end

-- Accept "HH:MM" (today, local), "YYYY-MM-DD HH:MM", or full ISO
-- (with or without Z). Returns UTC, or nil when unparseable.
function M.parse_time_arg(arg)
	local full_utc = arg:match("^(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ)$")
	if full_utc then
		return full_utc
	end
	local full_local = arg:match("^(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d)$")
	if full_local then
		return M.to_utc(full_local)
	end
	local date, h, m = arg:match("^(%d%d%d%d%-%d%d%-%d%d) (%d%d?):(%d%d)$")
	if date then
		return M.to_utc(date .. "T" .. string.format("%02d:%s", h, m) .. ":00")
	end
	local hh, mm = arg:match("^(%d%d?):(%d%d)$")
	if hh then
		return M.to_utc(os.date("%Y-%m-%d") .. "T" .. string.format("%02d:%s", hh, mm) .. ":00")
	end
	return nil
end

-- Whole minutes between two UTC timestamps (b - a), floored.
function M.diff_min(ts_a, ts_b)
	local a, b = epoch_from_utc(ts_a), epoch_from_utc(ts_b)
	if not a or not b then
		return 0
	end
	return math.floor((b - a) / 60)
end

-- Compact local time for messages: "09:00" today, "2026-08-09 09:00" otherwise.
function M.fmt_ts(utc_ts)
	local local_ts = M.to_local(utc_ts)
	if not local_ts then
		return "?"
	end
	if local_ts:sub(1, 10) == os.date("%Y-%m-%d") then
		return local_ts:sub(12, 16)
	end
	return local_ts:gsub("T", " "):sub(1, 16)
end

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

-- Date helpers (local dates "YYYY-MM-DD", noon-based so DST never shifts
-- the day) ---------------------------------------------------------------

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function is_leap(y)
	return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

local function days_in_month(y, m)
	if m == 2 and is_leap(y) then
		return 29
	end
	return DAYS_IN_MONTH[m]
end

-- "YYYY-MM-DD" + n days (n may be negative)
function M.add_days(date, n)
	local y, m, d = date:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
	y, m, d = tonumber(y), tonumber(m), tonumber(d)
	d = d + n
	while d < 1 do
		m = m - 1
		if m < 1 then
			m = 12
			y = y - 1
		end
		d = d + days_in_month(y, m)
	end
	while d > days_in_month(y, m) do
		d = d - days_in_month(y, m)
		m = m + 1
		if m > 12 then
			m = 1
			y = y + 1
		end
	end
	return string.format("%04d-%02d-%02d", y, m, d)
end

-- Local day of week: 0 = Monday .. 6 = Sunday
function M.dow(date)
	local t = epoch_from_local(date .. "T12:00:00")
	return (os.date("*t", t).wday + 5) % 7
end

-- ISO year and week number for a local date (Thursday rule)
function M.iso_week(date)
	local thursday = M.add_days(date, 3 - M.dow(date))
	local y = tonumber(thursday:sub(1, 4))
	local yday = os.date("*t", epoch_from_local(thursday .. "T12:00:00")).yday
	return y, math.floor((yday - 1) / 7) + 1
end

-- Monday of the given ISO week ("YYYY-MM-DD")
function M.week_start_date(year, week)
	local jan1 = year .. "-01-01"
	local week1_monday = M.add_days(jan1, -M.dow(jan1))
	return M.add_days(week1_monday, (week - 1) * 7)
end

return M
