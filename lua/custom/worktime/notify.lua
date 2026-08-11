-- vim.notify wrapper that is safe in fast-event contexts (vim.system
-- on_exit callbacks), where nvim_echo is forbidden: defer via vim.schedule.

local M = {}

function M.notify(msg, level)
	level = level or vim.log.levels.INFO
	if vim.in_fast_event() then
		vim.schedule(function()
			vim.notify(msg, level)
		end)
	else
		vim.notify(msg, level)
	end
end

return M
