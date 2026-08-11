-- Serialized async write pipeline. Every mutation (and WorkSync/WorkPush)
-- goes through here: items are processed one at a time, so the log never
-- sees interleaved writes and the git tree stays clean between commits.
--
-- The worker runs entirely on async git callbacks (fast-event contexts),
-- so it must never call synchronous git — only storage I/O, state reads
-- and notifications. At exit, flush_on_exit() drains pending writes
-- synchronously, because async work cannot complete once nvim is closing.

local M = {}

local notify = require("custom.worktime.notify").notify
local storage = require("custom.worktime.storage")
local statusline = require("custom.worktime.statusline")
local sync = require("custom.worktime.sync")

local items = {}
local running = false

local function process_next()
	local item = items[1]
	if not item then
		running = false
		return
	end
	table.remove(items, 1)

	local function done()
		process_next()
	end

	-- Every item needs the repo (clone on first use, reject when blocked).
	sync.repo_async(function(ok)
		if not ok then
			return done() -- blocked, message already shown
		end

		if item.kind == "sync" then
			sync.sync_async(function()
				sync.push_async(function()
					statusline.invalidate()
					notify("sync: " .. sync.state_name())
					done()
				end)
			end)
			return
		end

		if item.kind == "push" then
			sync.push_async(function()
				statusline.invalidate()
				notify("sync: " .. sync.state_name())
				done()
			end)
			return
		end

		-- kind == "write": sync -> validate against the fresh log -> write
		-- -> push. Failures (rejection, offline, conflict) notify but never
		-- block the next item.
		sync.sync_async(function()
			local ok_call, res = pcall(item.mutate)
			if not ok_call or not res.ok then
				if ok_call then
					notify(res.reason, vim.log.levels.WARN)
				end
				return done()
			end
			if not storage.write(res.new_lines) then
				notify("failed to write log", vim.log.levels.ERROR)
				return done()
			end
			statusline.invalidate()
			sync.push_async(function()
				statusline.invalidate()
				notify(item.describe(res))
				done()
			end)
		end)
	end)
end

-- Enqueue an item: { kind = "write", mutate, describe } | { kind = "sync" }
-- | { kind = "push" }
function M.push(item)
	items[#items + 1] = item
	if not running then
		running = true
		vim.schedule(function()
			local ok_call, err = pcall(process_next)
			if not ok_call then
				-- A worker error must never wedge the queue: drop pending
				-- items and report.
				vim.notify("worktime pipeline error: " .. tostring(err), vim.log.levels.ERROR)
				items = {}
				running = false
			end
		end)
	end
end

-- True when the queue is drained (used by tests and the exit flush).
function M.idle()
	return not running and #items == 0
end

-- VimLeavePre: pending async work cannot complete while nvim is closing,
-- so drain queued writes synchronously (no network) and commit whatever
-- the worker may have written but not yet committed.
function M.flush_on_exit()
	for _, item in ipairs(items) do
		if item.kind == "write" then
			local ok_call, res = pcall(item.mutate)
			if ok_call and res.ok then
				storage.write(res.new_lines)
				notify(item.describe(res))
			elseif ok_call then
				notify(res.reason, vim.log.levels.WARN)
			end
		end
	end
	items = {}
	running = false
	sync.commit_local()
end

return M
