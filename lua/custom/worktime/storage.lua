-- Log file: format, parsing, validated mutations, writing.
-- Owns the entry model; time math lives in `time`, paths in `config`.

local M = {}

local config = require("custom.worktime.config")
local time = require("custom.worktime.time")

-- Parsing ---------------------------------------------------------------------

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

-- All entries, chronologically. Malformed lines are skipped, never fatal.
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

-- "empty" | "recording" (tail is start) | "idle" (tail is end)
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

-- " · project · ticket" (parts omitted when empty), for messages.
function M.describe(entry)
	local proj = entry.project ~= "" and " · " .. entry.project or ""
	local tick = entry.ticket ~= "" and " · " .. entry.ticket or ""
	return proj .. tick
end

-- Mutations (validated against the current log) -------------------------------

local function entry_line(ts, event, project, ticket, message)
	return table.concat({ ts, event, sanitize(project), sanitize(ticket), sanitize(message) }, "\t")
end

local function fail(reason)
	return { ok = false, reason = reason }
end

-- Returns nil or an error string; `what` names the event for messages.
local function check_ts(ts, what)
	if not ts or not ts:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") then
		return "invalid " .. what .. " time"
	end
	if ts > time.now_utc() then
		return what .. " cannot be in the future"
	end
	return nil
end

-- Returns { ok = true, new_lines = {...}, ... } or { ok = false, reason = ... }
function M.mutate_start(ts, project, ticket, message)
	local err = check_ts(ts, "start")
	if err then
		return fail(err)
	end
	local entries = M.read_log()
	local tail = entries[#entries]
	if tail and tail.event == "start" then
		return fail("already recording since " .. time.fmt_ts(tail.ts) .. M.describe(tail) .. "; :WorkEnd first")
	end
	if tail and ts <= tail.ts then
		return fail("start must be after the last entry (" .. time.fmt_ts(tail.ts) .. ")")
	end
	return { ok = true, new_lines = { entry_line(ts, "start", project, ticket, message) } }
end

function M.mutate_end(ts, message)
	local err = check_ts(ts, "end")
	if err then
		return fail(err)
	end
	local entries = M.read_log()
	local tail = entries[#entries]
	if not tail then
		return fail("no open block; :WorkStart first")
	end
	if tail.event == "end" then
		return fail("not recording; :WorkStart first")
	end
	if ts < tail.ts then
		return fail("end must be after the block start (" .. time.fmt_ts(tail.ts) .. ")")
	end
	return {
		ok = true,
		new_lines = { entry_line(ts, "end", "", "", message) },
		closed = tail,
		duration_min = time.diff_min(tail.ts, ts),
	}
end

-- Write ------------------------------------------------------------------------

-- Append the mutation's lines to the log. Returns true on success.
function M.write(new_lines)
	config.ensure_data_dir()
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
