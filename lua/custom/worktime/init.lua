-- Worktime: record work blocks with project/ticket, export hours. See
-- README.md in this directory for the full design.

local config = require("custom.worktime.config")
local commands = require("custom.worktime.commands")

config.reload()

vim.api.nvim_create_user_command("WorkStart", commands.workstart, {
	nargs = "*",
	desc = "Start a work block: WorkStart [time] [ticket] [message...]",
})
vim.api.nvim_create_user_command("WorkEnd", commands.workend, {
	nargs = "*",
	desc = "End the current block: WorkEnd [time] [message...]",
})
vim.api.nvim_create_user_command("WorkStatus", commands.status, {
	nargs = 0,
	desc = "Show recording state and today's totals",
})
