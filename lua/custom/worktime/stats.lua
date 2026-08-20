-- Pure weekly aggregation. Given all log entries, an ISO week and the
-- configured weekly targets, produce the report data structure consumed by
-- the renderers (markdown now, CSV later). No I/O, no nvim calls.

local M = {}

local time = require("custom.worktime.time")

-- report = {
--   year, week, week_start, week_end,      -- local dates "YYYY-MM-DD"
--   total_minutes,                         -- open blocks excluded (silently)
--   total_target_minutes, total_delta_minutes,
--   projects = { [name] = {
--     minutes, target_minutes?, delta_minutes?,
--     blocks = { { day, ticket, message, minutes } },
--   } },
--   days = { [date] = minutes },
--   matrix = { [date] = { [project] = minutes } },
--   open_blocks = { entry, ... },          -- informational only
-- }
function M.compute_week(entries, year, week, targets)
	local week_start = time.week_start_date(year, week)
	local week_end = time.add_days(week_start, 6)

	local report = {
		year = year,
		week = week,
		week_start = week_start,
		week_end = week_end,
		total_minutes = 0,
		projects = {},
		days = {},
		matrix = {},
		open_blocks = {},
	}

	-- Every configured project is part of the report, even with 0 hours:
	-- its target and delta must show regardless of whether work happened.
	for name, target_hours in pairs(targets or {}) do
		report.projects[name] = {
			minutes = 0,
			blocks = {},
			target_minutes = math.floor(target_hours * 60),
		}
	end

	local block_start
	local function close_block(block, end_ts)
		if block then
			local minutes = time.diff_min(block.ts, end_ts)
			if minutes > 0 then
				local day = time.to_local(block.ts):sub(1, 10)
				if day >= week_start and day <= week_end then
					local project = block.project == "" and "(kein Projekt)" or block.project
					local p = report.projects[project]
					if not p then
						p = { minutes = 0, blocks = {} }
						report.projects[project] = p
					end
					p.minutes = p.minutes + minutes
					p.blocks[#p.blocks + 1] = {
						day = day,
						ticket = block.ticket,
						message = block.message,
						minutes = minutes,
					}
					report.total_minutes = report.total_minutes + minutes
					report.days[day] = (report.days[day] or 0) + minutes
					report.matrix[day] = report.matrix[day] or {}
					report.matrix[day][project] = (report.matrix[day][project] or 0) + minutes
				end
			end
			block = nil
		end
		return block
	end

	for _, e in ipairs(entries) do
		if e.event == "start" then
			block_start = e
		elseif e.event == "end" then
			block_start = close_block(block_start, e.ts)
		end
	end
	-- Still-open blocks have no end: excluded from the totals silently.
	if block_start then
		report.open_blocks[#report.open_blocks + 1] = block_start
	end

	-- Targets and deltas: every configured project counts toward the
	-- totals, whether or not it has hours this week.
	local total_target = 0
	for name, p in pairs(report.projects) do
		if p.target_minutes then
			p.delta_minutes = p.minutes - p.target_minutes
			total_target = total_target + p.target_minutes
		end
	end
	report.total_target_minutes = total_target
	report.total_delta_minutes = report.total_minutes - total_target

	return report
end

return M
