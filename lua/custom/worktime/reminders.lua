-- Reminders: VimEnter/VimResume start suggestion, left-open catch, and the
-- blocking close prompt. Display only — all writes route through the
-- commands layer so they use the full sync pipeline.

local M = {}

local commands = require("custom.worktime.commands")
local config = require("custom.worktime.config")
local queue = require("custom.worktime.queue")
local storage = require("custom.worktime.storage")
local sync = require("custom.worktime.sync")
local time = require("custom.worktime.time")

local augroup = vim.api.nvim_create_augroup("worktime-reminders", { clear = true })

-- The open block's tail entry, or nil when not recording.
local function open_block(entries)
	if storage.state(entries) ~= "recording" then
		return nil
	end
	return entries[#entries]
end

-- "since 09:00 · project · ticket" for messages.
local function block_desc(tail)
	return ("since %s%s"):format(time.fmt_ts(tail.ts), storage.describe(tail))
end

-- Suggest :WorkStart, but only in directories belonging to a configured
-- project — random files and scratch dirs must not nag.
function M.suggest_start()
	local project = config.match_project(vim.loop.cwd())
	if not project or open_block(storage.read_log()) then
		return
	end
	-- WARN + long timeout: rendered as a floating window by snacks.notifier,
	-- prominent enough to act on.
	vim.notify(
		("Not recording · %s — :WorkStart to start"):format(project),
		vim.log.levels.WARN,
		{ timeout = 10000 }
	)
end

-- A block left open by a previous session: the reliable catch for a missed
-- close prompt (floating windows can't render during exit).
function M.check_left_open()
	local tail = open_block(storage.read_log())
	if not tail then
		return
	end
	vim.notify(
		("Work left open %s (:WorkEnd)"):format(block_desc(tail)),
		vim.log.levels.WARN,
		{ timeout = 10000 }
	)
end

-- Blocking y/n on close: vim.notify/notifier windows cannot render while
-- exiting, so prompt synchronously. The exit cannot be canceled from
-- VimLeavePre — "Yes" records the end now (the final push commits and
-- pushes it before closing), "No" leaves the block open (the next start
-- will catch it).
function M.warn_open_block()
	local tail = open_block(storage.read_log())
	if not tail then
		return
	end
	local choice = vim.fn.confirm(
		("Work open %s"):format(block_desc(tail)) .. "\nRecord end and close?",
		"&Yes\n&No",
		1,
		"WarningMsg"
	)
	if choice == 1 then
		local res = storage.mutate_end(time.now_utc(), "")
		if res.ok and storage.write(res.new_lines) then
			vim.notify("work ended after " .. time.fmt_duration(res.duration_min), vim.log.levels.INFO)
		end
	else
		vim.notify("block left open — you'll be reminded on next start", vim.log.levels.WARN)
	end
end

-- Full exit flow: drain queued writes, ask about an open block, then push
-- (blocking) so the remote is up to date before nvim closes. The push only
-- runs when a block was open (local state, no network involved in the
-- check) — plain idle exits never block on the network; their local
-- commits go out on the next session's sync.
function M.on_exit()
	queue.flush_on_exit()
	local was_recording = storage.state(storage.read_log()) == "recording"
	M.warn_open_block()
	if was_recording then
		sync.sync_now_blocking()
	end
end

vim.api.nvim_create_autocmd("VimEnter", {
	group = augroup,
	callback = function()
		vim.schedule(function()
			M.check_left_open()
			M.suggest_start()
		end)
	end,
})

vim.api.nvim_create_autocmd("VimResume", {
	group = augroup,
	callback = M.suggest_start,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
	group = augroup,
	callback = M.on_exit,
})

return M
