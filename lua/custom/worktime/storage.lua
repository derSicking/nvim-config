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

-- WorkSplit: insert a work block inside an existing block, splitting it.
-- The original block ends at ts_s, the new block runs ts_s–ts_e, and a
-- `start` at ts_e resumes the original block carrying its recorded
-- project/ticket/message. The 4 lines preserve strict alternation.
-- Returns { ok, new_lines, insert_before = ts_s, closed } or fail.
function M.mutate_split(ts_s, ts_e, project, ticket, message)
	local err = check_ts(ts_s, "split start")
	if err then
		return fail(err)
	end
	err = check_ts(ts_e, "split end")
	if err then
		return fail(err)
	end
	if ts_s >= ts_e then
		return fail("split end must be after split start")
	end

	local entries = M.read_log()
	local block_start
	for _, e in ipairs(entries) do
		if e.event == "start" then
			block_start = e
		elseif e.event == "end" and block_start then
			if block_start.ts < ts_s and ts_e < e.ts then
				return {
					ok = true,
					new_lines = {
						entry_line(ts_s, "end", "", "", ""),
						entry_line(ts_s, "start", project, ticket, message),
						entry_line(ts_e, "end", "", "", ""),
						entry_line(ts_e, "start", block_start.project, block_start.ticket, block_start.message),
					},
					insert_before = ts_s,
					closed = block_start,
				}
			end
			block_start = nil
		end
	end
	-- Open tail block (no end yet): the window just needs e <= now.
	if block_start and block_start.ts < ts_s then
		return {
			ok = true,
			new_lines = {
				entry_line(ts_s, "end", "", "", ""),
				entry_line(ts_s, "start", project, ticket, message),
				entry_line(ts_e, "end", "", "", ""),
				entry_line(ts_e, "start", block_start.project, block_start.ticket, block_start.message),
			},
			insert_before = ts_s,
			closed = block_start,
		}
	end
	return fail("no work block contains " .. time.fmt_ts(ts_s) .. "–" .. time.fmt_ts(ts_e))
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

-- Atomically insert lines before the first existing line with timestamp
-- greater than before_ts (append when none exists). Temp file + rename,
-- so a crash mid-write leaves the old log intact.
function M.write_insert(before_ts, new_lines)
	config.ensure_data_dir()
	local raw = {}
	local f = io.open(config.log_path, "rb")
	if f then
		for line in f:lines() do
			raw[#raw + 1] = line
		end
		f:close()
	end
	local idx = #raw + 1
	for i, line in ipairs(raw) do
		if line:sub(1, 19) > before_ts then
			idx = i
			break
		end
	end
	local tmp = config.log_path .. ".tmp"
	local out = io.open(tmp, "w")
	if not out then
		return false
	end
	for i = 1, idx - 1 do
		out:write(raw[i], "\n")
	end
	for _, line in ipairs(new_lines) do
		out:write(line, "\n")
	end
	for i = idx, #raw do
		out:write(raw[i], "\n")
	end
	out:close()
	os.rename(tmp, config.log_path)
	return true
end

return M
