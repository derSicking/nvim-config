-- Markdown weekly report rendering + export command logic. Rendering is
-- pure (given a stats report); run() adds the file writing and buffer open.

local M = {}

local config = require("custom.worktime.config")
local stats = require("custom.worktime.stats")
local storage = require("custom.worktime.storage")
local time = require("custom.worktime.time")

local DAY_NAMES = { "Mo", "Di", "Mi", "Do", "Fr", "Sa", "So" }

local function fmt_date(date)
	return DAY_NAMES[time.dow(date) + 1] .. " " .. date:sub(9, 10) .. "." .. date:sub(6, 7) .. "."
end

-- "150" -> "2.5h"
local function hours(min)
	return string.format("%.1fh", min / 60)
end

local function delta(min)
	if min == 0 then
		return "0.0h"
	end
	return string.format("%+.1fh", min / 60)
end

-- Pipes in user text must not break the tables.
local function esc(s)
	return (s or ""):gsub("%|", "\\|")
end

-- Projects ordered by minutes desc, then name.
local function project_order(report)
	local order = {}
	for name in pairs(report.projects) do
		order[#order + 1] = name
	end
	table.sort(order, function(a, b)
		local pa, pb = report.projects[a], report.projects[b]
		if pa.minutes ~= pb.minutes then
			return pa.minutes > pb.minutes
		end
		return a < b
	end)
	return order
end

function M.render(report)
	local lines = {}
	local function add(s)
		lines[#lines + 1] = s
	end

	add("# Arbeitszeiten KW " .. report.week .. " (" .. fmt_date(report.week_start) .. " – " .. fmt_date(report.week_end) .. ")")
	add("")

	local order = project_order(report)

	add("## Zusammenfassung")
	add("")
	add("| Projekt | Stunden | Ziel | Delta |")
	add("| --- | --- | --- | --- |")
	for _, name in ipairs(order) do
		local p = report.projects[name]
		local target = p.target_minutes and hours(p.target_minutes) or "–"
		local d = p.delta_minutes and delta(p.delta_minutes) or "–"
		add("| " .. esc(name) .. " | " .. hours(p.minutes) .. " | " .. target .. " | " .. d .. " |")
	end
	local total_target = report.total_target_minutes and hours(report.total_target_minutes) or "–"
	local total_delta = report.total_delta_minutes and delta(report.total_delta_minutes) or "–"
	add("| **Gesamt** | **" .. hours(report.total_minutes) .. "** | " .. total_target .. " | " .. total_delta .. " |")
	add("")

	add("## Pro Tag")
	add("")
	local header = { "Tag" }
	for _, name in ipairs(order) do
		header[#header + 1] = esc(name)
	end
	header[#header + 1] = "**Gesamt**"
	add("| " .. table.concat(header, " | ") .. " |")
	local sep = {}
	for _ = 1, #header do
		sep[#sep + 1] = "---"
	end
	add("| " .. table.concat(sep, " | ") .. " |")
	local days = {}
	for date in pairs(report.matrix) do
		days[#days + 1] = date
	end
	table.sort(days)
	for _, date in ipairs(days) do
		local row = { fmt_date(date) }
		local day_total = 0
		for _, name in ipairs(order) do
			local m = report.matrix[date][name]
			row[#row + 1] = m and hours(m) or "–"
			day_total = day_total + (m or 0)
		end
		row[#row + 1] = "**" .. hours(day_total) .. "**"
		add("| " .. table.concat(row, " | ") .. " |")
	end
	add("")

	for _, name in ipairs(order) do
		local p = report.projects[name]
		add("## " .. esc(name))
		add("")
		add("| Tag | Ticket | Stunden | Beschreibung |")
		add("| --- | --- | --- | --- |")
		for _, b in ipairs(p.blocks) do
			local ticket = b.ticket ~= "" and b.ticket or "–"
			local message = b.message ~= "" and b.message or "–"
			add("| " .. fmt_date(b.day) .. " | " .. esc(ticket) .. " | " .. hours(b.minutes) .. " | " .. esc(message) .. " |")
		end
		local subtotal = "**Zwischensumme: " .. hours(p.minutes) .. "**"
		if p.target_minutes then
			subtotal = subtotal .. " (Ziel " .. hours(p.target_minutes) .. ", Delta " .. delta(p.delta_minutes) .. ")"
		end
		add(subtotal)
		add("")
	end

	return table.concat(lines, "\n") .. "\n"
end

-- Render, write to exports/YYYY-Www.md and open it in a buffer.
function M.run(year, week)
	local entries = storage.read_log()
	local targets = {}
	for name, proj in pairs(config.get().projects or {}) do
		if type(proj) == "table" and proj.weekly_target then
			targets[name] = proj.weekly_target
		end
	end
	local report = stats.compute_week(entries, year, week, targets)
	local md = M.render(report)

	config.ensure_data_dir()
	local dir = config.data_dir .. "/exports"
	vim.fn.mkdir(dir, "p")
	local path = dir .. "/" .. year .. "-W" .. string.format("%02d", week) .. ".md"
	local f = io.open(path, "w")
	if not f then
		vim.notify("Worktime: cannot write " .. path, vim.log.levels.ERROR)
		return
	end
	f:write(md)
	f:close()
	vim.cmd("edit " .. vim.fn.fnameescape(path))
	vim.notify("Worktime: exported " .. path, vim.log.levels.INFO)
end

return M
