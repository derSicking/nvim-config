local M = {}

local config = require("custom.worktime.config")
local storage = require("custom.worktime.storage")

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO)
end

local function fmt_duration(min)
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

-- Split args into (utc_ts, rest). A first token containing ":" is parsed as
-- time; anything else is treated as ticket/message.
local function split_args(args)
	local parts = vim.split(args, "%s+", { trimempty = true })
	local first = parts[1]
	if not first or not first:match(":") then
		return storage.now_utc(), parts
	end
	local ts = storage.parse_time_arg(first)
	if not ts then
		return nil, nil, "invalid time: " .. first
	end
	return ts, vim.list_slice(parts, 2)
end

function M.workstart(opts)
	local ts, rest, err = split_args(opts.args)
	if err then
		notify(err, vim.log.levels.WARN)
		return
	end
	local ticket = rest[1] or ""
	local message = table.concat(vim.list_slice(rest, 2), " ")
	local project = config.detect_project(vim.loop.cwd())

	local res = storage.mutate_start(ts, project, ticket, message)
	if not res.ok then
		notify(res.reason, vim.log.levels.WARN)
		return
	end
	if not storage.write(res.new_lines) then
		notify("failed to write log", vim.log.levels.ERROR)
		return
	end

	local backdated = ts ~= storage.now_utc() and " (backdated " .. storage.to_local(ts) .. ")" or ""
	notify("work started · " .. project .. (ticket ~= "" and " · " .. ticket or "") .. backdated)
end

function M.workend(opts)
	local ts, rest, err = split_args(opts.args)
	if err then
		notify(err, vim.log.levels.WARN)
		return
	end
	local message = table.concat(rest, " ")

	local res = storage.mutate_end(ts, message)
	if not res.ok then
		notify(res.reason, vim.log.levels.WARN)
		return
	end
	if not storage.write(res.new_lines) then
		notify("failed to write log", vim.log.levels.ERROR)
		return
	end

	local closed = res.closed
	local proj = closed.project ~= "" and " · " .. closed.project or ""
	local tick = closed.ticket ~= "" and " · " .. closed.ticket or ""
	local backdated = ts ~= storage.now_utc() and " (backdated " .. storage.to_local(ts) .. ")" or ""
	notify("work ended after " .. fmt_duration(res.duration_min) .. proj .. tick .. backdated)
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
			if storage.to_local(open.ts):sub(1, 10) == today then
				work_min = work_min + storage.diff_min(open.ts, e.ts)
			end
			open = nil
		end
	end
	-- Open block: count from block start, or from today's midnight if it
	-- started on an earlier day.
	if open then
		local start_ts = open.ts
		if storage.to_local(open.ts):sub(1, 10) ~= today then
			start_ts = storage.to_utc(today .. "T00:00:00")
		end
		work_min = work_min + storage.diff_min(start_ts, storage.now_utc())
	end

	local detail = ("today: %s worked"):format(fmt_duration(work_min))
	if st == "recording" then
		local tick = open.ticket ~= "" and " · " .. open.ticket or ""
		notify(("recording since %s · %s%s — %s"):format(storage.to_local(open.ts), open.project, tick, detail))
	elseif st == "idle" then
		local e = entries[#entries]
		notify(("idle (last ended %s) — %s"):format(storage.to_local(e.ts), detail))
	else
		notify("no entries yet — :WorkStart to begin")
	end
end

return M
