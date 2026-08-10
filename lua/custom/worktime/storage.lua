local M = {}

local config = require("custom.worktime.config")

-- Time helpers ----------------------------------------------------------------

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

-- Accept "HH:MM[:SS]" (today, local), "YYYY-MM-DD HH:MM[:SS]", or full ISO.
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

-- Parsing ----------------------------------------------------------------------

local function sanitize(s)
	local clean = (s or ""):gsub("[\t\n\r]", " ")
	return clean -- gsub returns (string, count); return only the string
end

local function parse_line(line)
	local ts, event, project, ticket, message = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
	if not ts then
		return nil
	end
	if not ts:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") then
		return nil
	end
	if event ~= "start" and event ~= "end" then
		return nil
	end
	return { ts = ts, event = event, project = project, ticket = ticket, message = message }
end

function M.read_log()
	local entries = {}
	local f = io.open(config.log_path, "rb")
	if not f then
		return entries
	end
	for line in f:lines() do
		local e = parse_line(line:gsub("\r$", ""))
		if e then
			entries[#entries + 1] = e
		end
	end
	f:close()
	return entries
end

function M.state(entries)
	local e = entries[#entries]
	if not e then
		return "empty"
	end
	if e.event == "start" then
		return "recording"
	end
	return "idle"
end

-- Mutations (validated against the current log) -------------------------------

local function entry_line(ts, event, project, ticket, message)
	return table.concat({ ts, event, sanitize(project), sanitize(ticket), sanitize(message) }, "\t")
end

local function fail(reason)
	return { ok = false, reason = reason }
end

-- Returns { ok = true, new_lines = {...} } or { ok = false, reason = ... }
function M.mutate_start(ts, project, ticket, message)
	local entries = M.read_log()
	local tail = entries[#entries]
	if tail and tail.event == "start" then
		local extra = tail.project ~= "" and " · " .. tail.project or ""
		local tick = tail.ticket ~= "" and " · " .. tail.ticket or ""
		return fail("already recording since " .. M.fmt_ts(tail.ts) .. extra .. tick .. "; :WorkEnd first")
	end
	if tail and ts <= tail.ts then
		return fail("start must be after the last entry (" .. M.fmt_ts(tail.ts) .. ")")
	end
	if ts > M.now_utc() then
		return fail("start cannot be in the future")
	end
	return { ok = true, new_lines = { entry_line(ts, "start", project, ticket, message) } }
end

function M.mutate_end(ts, message)
	local entries = M.read_log()
	local tail = entries[#entries]
	if not tail then
		return fail("no open block; :WorkStart first")
	end
	if tail.event == "end" then
		return fail("not recording; :WorkStart first")
	end
	if ts < tail.ts then
		return fail("end must be after the block start (" .. M.fmt_ts(tail.ts) .. ")")
	end
	if ts > M.now_utc() then
		return fail("end cannot be in the future")
	end
	return {
		ok = true,
		new_lines = { entry_line(ts, "end", "", "", message) },
		closed = tail,
		duration_min = M.diff_min(tail.ts, ts),
	}
end

-- Write ------------------------------------------------------------------------

function M.write(new_lines)
	vim.fn.mkdir(vim.fn.fnamemodify(config.log_path, ":h"), "p")
	local f = io.open(config.log_path, "a")
	if not f then
		return false
	end
	for _, line in ipairs(new_lines) do
		f:write(line, "\n")
	end
	f:close()
	return true
end

return M
