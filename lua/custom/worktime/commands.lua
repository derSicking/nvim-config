-- User command handlers. Commands return immediately: the actual write,
-- commit and push run in the background through the queue, and the
-- notification arrives when the pipeline has completed.

local M = {}

local config = require("custom.worktime.config")
local export = require("custom.worktime.export")
local notify = require("custom.worktime.notify").notify
local queue = require("custom.worktime.queue")
local storage = require("custom.worktime.storage")
local statusline = require("custom.worktime.statusline")
local sync = require("custom.worktime.sync")
local time = require("custom.worktime.time")

-- Parse command args: optional -p/--project override, optional time,
-- ticket and message. Returns
--   { ts = utc, rest = {...}, project = name|nil, explicit = bool }
-- or { err = "..." }.
-- `explicit` tells whether the user supplied the time (vs. defaulting to
-- now) — the only reliable "backdated" signal: comparing ts against a
-- re-read now_utc() would false-positive whenever a second boundary or the
-- sync round-trip falls between the two calls.
local function parse_args(args)
	local parts = vim.split(args, "%s+", { trimempty = true })

	local project
	local kept = {}
	local i = 1
	while i <= #parts do
		local p = parts[i]
		if p == "-p" or p == "--project" then
			local name = parts[i + 1]
			if not name then
				return { err = "missing project name after " .. p }
			end
			project = name
			i = i + 2
		elseif p:match("^%-%-project=") then
			project = p:sub(11)
			i = i + 1
		else
			kept[#kept + 1] = p
			i = i + 1
		end
	end

	-- A first kept token containing ":" is parsed as time; anything else is
	-- treated as ticket/message.
	local first = kept[1]
	if not first or not first:match(":") then
		return { ts = time.now_utc(), rest = kept, project = project, explicit = false }
	end
	local ts = time.parse_time_arg(first)
	if not ts then
		return { err = "invalid time: " .. first }
	end
	return { ts = ts, rest = vim.list_slice(kept, 2), project = project, explicit = true }
end

-- "ticket" + "message" from the remaining args.
local function take_ticket(rest)
	local ticket = rest[1] or ""
	local message = table.concat(vim.list_slice(rest, 2), " ")
	return ticket, message
end

local function backdated_note(ts, explicit)
	if not explicit then
		return ""
	end
	return " (backdated " .. time.fmt_ts(ts) .. ")"
end

function M.workstart(opts)
	local a = parse_args(opts.args)
	if a.err then
		notify(a.err, vim.log.levels.WARN)
		return
	end
	local ticket, message = take_ticket(a.rest)
	local project = a.project or config.detect_project(vim.loop.cwd())

	queue.push({
		kind = "write",
		mutate = function()
			return storage.mutate_start(a.ts, project, ticket, message)
		end,
		describe = function()
			return "work started · " .. project .. (ticket ~= "" and " · " .. ticket or "") .. backdated_note(a.ts, a.explicit)
		end,
	})
end

function M.workend(opts)
	local a = parse_args(opts.args)
	if a.err then
		notify(a.err, vim.log.levels.WARN)
		return
	end
	local message = table.concat(a.rest, " ")

	queue.push({
		kind = "write",
		mutate = function()
			return storage.mutate_end(a.ts, message)
		end,
		describe = function(res)
			return "work ended after " .. time.fmt_duration(res.duration_min) .. storage.describe(res.closed)
				.. backdated_note(a.ts, a.explicit)
		end,
	})
end

function M.workadd(opts)
	local a = parse_args(opts.args)
	if a.err then
		notify(a.err, vim.log.levels.WARN)
		return
	end
	local rest = a.rest

	-- Work pair into a gap
	if rest[1] == "start" and rest[3] == "end" then
		local ts_s = time.parse_time_arg(rest[2])
		local ts_e = time.parse_time_arg(rest[4])
		if not ts_s or not ts_e then
			notify("invalid time in WorkAdd (HH:MM or full ISO)", vim.log.levels.WARN)
			return
		end
		local ticket, message = take_ticket(vim.list_slice(rest, 5))
		local project = a.project or config.detect_project(vim.loop.cwd())
		queue.push({
			kind = "write",
			mutate = function()
				return storage.mutate_add_work(ts_s, ts_e, project, ticket, message)
			end,
			describe = function()
				return ("added work %s–%s · %s%s"):format(
					time.fmt_ts(ts_s),
					time.fmt_ts(ts_e),
					project,
					ticket ~= "" and " · " .. ticket or ""
				)
			end,
		})
		return
	end

	-- Break pair into a block
	if rest[1] == "end" and rest[3] == "start" then
		local ts_e = time.parse_time_arg(rest[2])
		local ts_s = time.parse_time_arg(rest[4])
		if not ts_s or not ts_e then
			notify("invalid time in WorkAdd (HH:MM or full ISO)", vim.log.levels.WARN)
			return
		end
		local message = table.concat(vim.list_slice(rest, 5), " ")
		queue.push({
			kind = "write",
			mutate = function()
				return storage.mutate_add_break(ts_e, ts_s, message)
			end,
			describe = function(res)
				local label = res.closed.ticket ~= "" and res.closed.ticket or res.closed.project
				return ("added break %s–%s · %s"):format(time.fmt_ts(ts_e), time.fmt_ts(ts_s), label)
			end,
		})
		return
	end

	notify(
		"usage: WorkAdd start <s> end <e> [ticket] [message...] | WorkAdd end <e> start <s> [message...]",
		vim.log.levels.WARN
	)
end

function M.worksplit(opts)
	local a = parse_args(opts.args)
	if a.err then
		notify(a.err, vim.log.levels.WARN)
		return
	end
	-- Expect: start <s> end <e> [ticket] [message...]
	local rest = a.rest
	if rest[1] ~= "start" or rest[3] ~= "end" then
		notify("usage: WorkSplit start <time> end <time> [ticket] [message...]", vim.log.levels.WARN)
		return
	end
	local ts_s = time.parse_time_arg(rest[2])
	local ts_e = time.parse_time_arg(rest[4])
	if not ts_s or not ts_e then
		notify("invalid time in WorkSplit (HH:MM or full ISO)", vim.log.levels.WARN)
		return
	end
	local ticket, message = take_ticket(vim.list_slice(rest, 5))
	local project = a.project or config.detect_project(vim.loop.cwd())

	queue.push({
		kind = "write",
		mutate = function()
			return storage.mutate_split(ts_s, ts_e, project, ticket, message)
		end,
		describe = function(res)
			local orig = res.closed
			local orig_label = orig.ticket ~= "" and orig.ticket or orig.message
			return ("split %s at %s · inserted %s%s (%s–%s)"):format(
				orig_label,
				time.fmt_ts(ts_s),
				ticket ~= "" and ticket or "block",
				project ~= "" and " · " .. project or "",
				time.fmt_ts(ts_s),
				time.fmt_ts(ts_e)
			)
		end,
	})
end

-- "" -> current week; "33" -> week 33 of this year; "2026-W33" explicit.
local function parse_week_arg(arg)
	if arg == "" then
		return time.iso_week(os.date("%Y-%m-%d"))
	end
	local y, w = arg:match("^(%d%d%d%d)%-W(%d%d?)$")
	if y then
		return tonumber(y), tonumber(w)
	end
	local w2 = arg:match("^(%d%d?)$")
	if w2 then
		return tonumber(os.date("%Y")), tonumber(w2)
	end
	return nil
end

function M.workexport(opts)
	local year, week = parse_week_arg(opts.args)
	if not year or week < 1 or week > 53 then
		notify("usage: WorkExport [week] | WorkExport YYYY-Www", vim.log.levels.WARN)
		return
	end
	export.run(year, week)
end

function M.status()
	local entries = storage.read_log()
	local st = storage.state(entries)
	local today = os.date("%Y-%m-%d")

	local work_min = 0
	local open
	for _, e in ipairs(entries) do
		if e.event == "start" then
			open = e
		elseif e.event == "end" and open then
			-- Closed blocks are attributed to the day of their start.
			if time.to_local(open.ts):sub(1, 10) == today then
				work_min = work_min + time.diff_min(open.ts, e.ts)
			end
			open = nil
		end
	end
	-- Open block: count from block start, or from today's midnight if it
	-- started on an earlier day.
	if open then
		local start_ts = open.ts
		if time.to_local(open.ts):sub(1, 10) ~= today then
			start_ts = time.to_utc(today .. "T00:00:00")
		end
		work_min = work_min + time.diff_min(start_ts, time.now_utc())
	end

	local detail = ("today: %s worked"):format(time.fmt_duration(work_min))
	if sync.enabled() then
		detail = detail .. " · sync: " .. sync.state_name()
	end
	if st == "recording" then
		notify(("recording since %s%s — %s"):format(time.fmt_ts(open.ts), storage.describe(open), detail))
	elseif st == "idle" then
		local e = entries[#entries]
		notify(("idle (last ended %s) — %s"):format(time.fmt_ts(e.ts), detail))
	else
		notify("no entries yet — :WorkStart to begin")
	end
end

local function require_remote()
	if sync.enabled() then
		return true
	end
	notify("no remote configured (config.lua: remote)", vim.log.levels.INFO)
	return false
end

function M.sync_now()
	if not require_remote() then
		return
	end
	queue.push({ kind = "sync" })
end

function M.push_now()
	if not require_remote() then
		return
	end
	queue.push({ kind = "push" })
end

return M
