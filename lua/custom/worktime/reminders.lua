local M = {}

local config = require("custom.worktime.config")
local storage = require("custom.worktime.storage")
local util = require("custom.worktime.util")

local augroup = vim.api.nvim_create_augroup("worktime-reminders", { clear = true })

-- Suggest :WorkStart, but only in directories belonging to a configured
-- project — random files and scratch dirs must not nag.
function M.suggest_start()
	local project = config.match_project(vim.loop.cwd())
	if not project then
		return
	end
	local entries = storage.read_log()
	if storage.state(entries) == "recording" then
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
	local entries = storage.read_log()
	if storage.state(entries) ~= "recording" then
		return
	end
	local tail = entries[#entries]
	local tick = tail.ticket ~= "" and " · " .. tail.ticket or ""
	vim.notify(
		("Work left open since %s · %s%s (:WorkEnd)"):format(util.fmt_ts(tail.ts), tail.project, tick),
		vim.log.levels.WARN,
		{ timeout = 10000 }
	)
end

-- Blocking y/n on close: vim.notify/notifier windows cannot render while
-- exiting, so prompt synchronously. The exit cannot be canceled from
-- VimLeavePre — "Yes" records the end now, "No" leaves the block open (the
-- next start will catch it).
function M.warn_open_block()
	local entries = storage.read_log()
	if storage.state(entries) ~= "recording" then
		return
	end
	local tail = entries[#entries]
	local tick = tail.ticket ~= "" and " · " .. tail.ticket or ""
	local msg = ("Work open since %s · %s%s"):format(util.fmt_ts(tail.ts), tail.project, tick)
	local choice = vim.fn.confirm(msg .. "\nRecord end and close?", "&Yes\n&No", 1, "WarningMsg")
	if choice == 1 then
		local res = storage.mutate_end(storage.now_utc(), "")
		if res.ok and storage.write(res.new_lines) then
			vim.notify("work ended after " .. util.fmt_duration(res.duration_min), vim.log.levels.INFO)
		end
	else
		vim.notify("block left open — you'll be reminded on next start", vim.log.levels.WARN)
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
	callback = M.warn_open_block,
})

return M
