-- Shared scaffolding for worktime tests (no framework, plain asserts).

local M = {}

-- Refuse to run against real data.
function M.guard_env()
	if not vim.env.WORKTIME_DATA_DIR or not vim.env.XDG_CONFIG_HOME then
		print("refusing to run without WORKTIME_DATA_DIR and XDG_CONFIG_HOME")
		os.exit(1)
	end
end

-- Returns (check, finish). check records failures; finish prints the
-- summary and exits with the appropriate code.
function M.new_check()
	local failures = 0
	local function check(cond, msg)
		if not cond then
			failures = failures + 1
			print("FAIL: " .. msg)
		end
	end
	local function finish()
		print(failures == 0 and "ALL OK" or failures .. " FAILURES")
		os.exit(failures == 0 and 0 or 1)
	end
	return check, finish
end

function M.has_ticket(entries, ticket)
	for _, e in ipairs(entries) do
		if e.ticket == ticket then
			return true
		end
	end
	return false
end

return M
