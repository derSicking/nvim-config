-- Worktime: record work blocks with project/ticket, export hours. See
-- README.md in this directory for the full design.

local config = require("custom.worktime.config")
local commands = require("custom.worktime.commands")
local statusline = require("custom.worktime.statusline")
local sync = require("custom.worktime.sync")

config.reload()

require("custom.worktime.reminders")

vim.api.nvim_create_user_command("WorkStart", commands.workstart, {
	nargs = "*",
	desc = "Start a work block: WorkStart [time] [ticket] [message...]",
})
vim.api.nvim_create_user_command("WorkEnd", commands.workend, {
	nargs = "*",
	desc = "End the current block: WorkEnd [time] [message...]",
})
vim.api.nvim_create_user_command("WorkSplit", commands.worksplit, {
	nargs = "*",
	desc = "Insert a block inside another block: WorkSplit start <s> end <e> [ticket] [message...]",
})
vim.api.nvim_create_user_command("WorkAdd", commands.workadd, {
	nargs = "*",
	desc = "Backfill: WorkAdd start <s> end <e> [ticket] [message...] | WorkAdd end <e> start <s> [message...]",
})
vim.api.nvim_create_user_command("WorkStatus", commands.status, {
	nargs = 0,
	desc = "Show recording state and today's totals",
})
vim.api.nvim_create_user_command("WorkSync", commands.sync_now, {
	nargs = 0,
	desc = "Fetch, rebase and push with the remote",
})
vim.api.nvim_create_user_command("WorkPush", commands.push_now, {
	nargs = 0,
	desc = "Push local commits now",
})

-- Warm the remote state in the background; never blocks startup.
sync.warm(function()
	statusline.invalidate()
end)
