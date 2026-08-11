-- User command handlers. Commands return immediately: the actual write,
-- commit and push run in the background through the queue, and the
-- notification arrives when the pipeline has completed.

local M = {}

local config = require("custom.worktime.config")
local notify = require("custom.worktime.notify").notify
local queue = require("custom.worktime.queue")
local storage = require("custom.worktime.storage")
local statusline = require("custom.worktime.statusline")
local sync = require("custom.worktime.sync")
local time = require("custom.worktime.time")

-- Split args into (utc_ts, rest, err, explicit). A first token containing
-- ":" is parsed as time; anything else is treated as ticket/message.
-- `explicit` tells whether the user supplied the time (vs. defaulting to
-- now) — the only reliable "backdated" signal: comparing ts against a
-- re-read now_utc() would false-positive whenever a second boundary or the
-- sync round-trip falls between the two calls.
local function split_args(args)
	local parts = vim.split(args, "%s+", { trimempty = true })
	local first = parts[1]
	if not first or not first:match(":") then
		return time.now_utc(), parts, nil, false
	end
	local ts = time.parse_time_arg(first)
	if not ts then
		return nil, nil, "invalid time: " .. first, true
	end
	return ts, vim.list_slice(parts, 2), nil, true
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
	local ts, rest, err, explicit = split_args(opts.args)
	if err then
		notify(err, vim.log.levels.WARN)
		return
	end
	local ticket, message = take_ticket(rest)
	local project = config.detect_project(vim.loop.cwd())

	queue.push({
		kind = "write",
		mutate = function()
			return storage.mutate_start(ts, project, ticket, message)
		end,
		describe = function()
			return "work started · " .. project .. (ticket ~= "" and " · " .. ticket or "") .. backdated_note(ts, explicit)
		end,
	})
end

function M.workend(opts)
	local ts, rest, err, explicit = split_args(opts.args)
	if err then
		notify(err, vim.log.levels.WARN)
		return
	end
	local message = table.concat(rest, " ")

	queue.push({
		kind = "write",
		mutate = function()
			return storage.mutate_end(ts, message)
		end,
		describe = function(res)
			return "work ended after " .. time.fmt_duration(res.duration_min) .. storage.describe(res.closed)
				.. backdated_note(ts, explicit)
		end,
	})
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
