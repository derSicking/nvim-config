local M = {}

local config = require("custom.worktime.config")
local storage = require("custom.worktime.storage")
local util = require("custom.worktime.util")

-- Capture the stock statusline (nvim's default, whatever this version
-- provides) before replacing it, so an idle bar stays byte-identical to the
-- default — including the version's diagnostics/exit-code/ruler features.
local STOCK = vim.o.statusline
M.STOCK = STOCK

local function inject_segment(segment)
	local at = STOCK:find("%%=", 1, false)
	if not at then
		return segment .. STOCK
	end
	return STOCK:sub(1, at - 1) .. segment .. STOCK:sub(at)
end

-- Recording state is cached: the statusline redraws on every cursor move,
-- so it must never read the log on each call. Wall clock, not os.clock()
-- (CPU time does not advance while nvim sits idle).
local cache = { at = 0, segment = nil }
local TTL = 5000 -- ms

-- Statusline items: `%%` renders as a literal `%`, so any user-controlled
-- text (project names) must be escaped — but directives like %#Group# and
-- %* must stay literal.
local function esc(s)
	local clean = s:gsub("%%", "%%%%")
	return clean
end

local function refresh()
	cache.at = vim.loop.now()
	cache.segment = nil
	local entries = storage.read_log()
	local project = config.match_project(vim.loop.cwd())
	if storage.state(entries) == "recording" then
		local tail = entries[#entries]
		local minutes = storage.diff_min(tail.ts, storage.now_utc())
		local label = tail.ticket ~= "" and tail.ticket or "Working"
		cache.segment = " ⏱ " .. esc(label) .. " · " .. esc(tail.project) .. " · " .. util.fmt_duration(minutes)
	elseif project then
		-- Configured project open but idle: dimmed nudge, no stock text lost.
		cache.segment = "%#Comment# ◌ not recording · " .. esc(project) .. "%*"
	end
end

function M.invalidate()
	cache.at = 0
end

function M.get()
	if vim.loop.now() - cache.at > TTL then
		refresh()
	end
	if not cache.segment then
		return STOCK
	end
	return inject_segment(cache.segment)
end

_G.worktime_statusline = M.get

vim.opt.statusline = "%!v:lua.worktime_statusline()"

return M
