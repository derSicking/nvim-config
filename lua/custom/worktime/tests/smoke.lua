-- Smoke tests for worktime (time + storage + config + statusline + commands
-- + reminders). No framework, plain asserts. Run from the repo root, isolated
-- from real data (the test refuses to run without both env vars):
--
--   rm -rf /tmp/wt-test /tmp/wt-cfg
--   WORKTIME_DATA_DIR=/tmp/wt-test XDG_CONFIG_HOME=/tmp/wt-cfg \
--     nvim --headless -u NONE -l lua/custom/worktime/tests/smoke.lua
--
-- Exits 0 on success, 1 on failure.

-- Note: rtp must be set before requiring the helpers module.
vim.opt.rtp:append(vim.fn.getcwd())
local helpers = require("custom.worktime.tests.helpers")
helpers.guard_env()

local data_dir = vim.env.WORKTIME_DATA_DIR
local cfg_home = vim.env.XDG_CONFIG_HOME

local time = require("custom.worktime.time")
local storage = require("custom.worktime.storage")
local config = require("custom.worktime.config")

local check, finish = helpers.new_check()

-- Isolation sanity (plain find: paths may contain pattern magic like "-")

check(config.log_path:find(data_dir, 1, true) ~= nil, "log path inside test data dir: " .. config.log_path)
check(config.config_path:find(cfg_home, 1, true) ~= nil, "config path inside test config home: " .. config.config_path)

-- Project detection -----------------------------------------------------------

local home = vim.fn.expand("~")
vim.fn.mkdir(cfg_home .. "/nvim-worktime", "p")
local f = io.open(cfg_home .. "/nvim-worktime/config.lua", "w")
f:write(string.format([[
return {
	projects = {
		alpha = { dirs = { "%s/Projects/alpha", "%s/Projects/alpha-extra" }, weekly_target = 10 },
		beta = { dirs = { "%s/Projects/beta" }, weekly_target = 5 },
		sandbox = { dirs = { "/tmp/wt-projects" } },
		["percent%%proj"] = { dirs = { "/tmp/wt-percent" } },
	},
}
]], home, home, home))
f:close()
config.reload()

check(config.detect_project(home .. "/Projects/alpha") == "alpha", "exact dir match")
check(config.detect_project(home .. "/Projects/alpha/src/backend") == "alpha", "nested dir match")
check(config.detect_project(home .. "/Projects/alpha-extra") == "alpha", "exact match on second dir")
check(config.detect_project(home .. "/Projects/alpha-extra/tools") == "alpha", "longest-prefix wins")
check(config.detect_project(home .. "/Projects/alphaX") == "alphaX", "no boundary match, basename fallback")
check(config.detect_project(home .. "/Projects/beta") == "beta", "second project matches")
check(config.detect_project(home .. "/Projects/unknown") == "unknown", "unknown dir, basename fallback")
check(config.weekly_target("alpha") == 10, "weekly_target read")
check(config.weekly_target("nope") == nil, "weekly_target nil for unknown")

-- match_project: configured match only, no fallback (reminder gate)
check(config.match_project(home .. "/Projects/alpha") == "alpha", "match_project exact")
check(config.match_project(home .. "/Projects/alpha-extra/tools") == "alpha", "match_project longest-prefix")
check(config.match_project(home .. "/Projects/alphaX") == nil, "match_project no boundary -> nil")
check(config.match_project(home .. "/Projects/unknown") == nil, "match_project unknown -> nil")
check(config.detect_project(home .. "/Projects/unknown") == "unknown", "detect_project fallback unchanged")
check(config.match_project("/tmp/wt-projects") == "sandbox", "match_project sandbox")

-- Malformed config entries must not crash project matching
local f_malformed = io.open(cfg_home .. "/nvim-worktime/config.lua", "w")
f_malformed:write(string.format([[
return {
	projects = {
		alpha = { dirs = { "%s/Projects/alpha", "%s/Projects/alpha-extra" }, weekly_target = 10 },
		["broken"] = { dirs = "not-a-table" },
	},
}
]], home, home))
f_malformed:close()
config.reload()
check(config.match_project(home .. "/Projects/alpha") == "alpha", "malformed project skipped, others still match")
-- restore clean config
local f_restore = io.open(cfg_home .. "/nvim-worktime/config.lua", "w")
f_restore:write(string.format([[
return {
	projects = {
		alpha = { dirs = { "%s/Projects/alpha", "%s/Projects/alpha-extra" }, weekly_target = 10 },
		beta = { dirs = { "%s/Projects/beta" }, weekly_target = 5 },
		sandbox = { dirs = { "/tmp/wt-projects" } },
		["percent%%proj"] = { dirs = { "/tmp/wt-percent" } },
	},
}
]], home, home, home))
f_restore:close()
config.reload()

-- Time helpers ----------------------------------------------------------------

local ts = time.now_utc()
check(ts:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil, "now_utc format: " .. ts)
local loc = time.to_local(ts)
check(loc ~= nil and loc:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d$") ~= nil, "to_local format")
check(time.to_utc(loc) == ts, "roundtrip to_utc(to_local(ts)) == ts")
check(time.parse_time_arg("09:00") ~= nil, "HH:MM parsed")
check(time.parse_time_arg("09:00") > time.parse_time_arg("08:00"), "HH:MM lexicographic order")
check(time.parse_time_arg("9:30") ~= nil, "H:MM parsed")
check(time.parse_time_arg("2026-08-10 09:00") ~= nil, "date + HH:MM parsed")
check(time.parse_time_arg("2026-08-10T09:00:00") ~= nil, "full local ISO parsed")
check(time.parse_time_arg("2026-08-10T09:00:00Z") == "2026-08-10T09:00:00Z", "full UTC ISO kept as-is")
check(time.parse_time_arg("banana") == nil, "garbage rejected")
check(time.diff_min("2026-08-10T09:00:00Z", "2026-08-10T11:30:00Z") == 150, "diff_min works")

-- fmt_ts: compact notification timestamps
local now_loc = time.to_local(ts)
check(time.fmt_ts(ts) == now_loc:sub(12, 16), "fmt_ts: today shows HH:MM")
local old = "2020-01-01T10:00:00Z"
check(time.fmt_ts(old) == time.to_local(old):gsub("T", " "):sub(1, 16), "fmt_ts: other day shows date + HH:MM")

-- Write rules -----------------------------------------------------------------

check(storage.state(storage.read_log()) == "empty", "empty state")

local res = storage.mutate_start(ts, "testproj", "T-1", "hello")
check(res.ok, "start ok: " .. (res.reason or ""))
check(storage.write(res.new_lines), "write ok")
check(storage.state(storage.read_log()) == "recording", "state recording")

res = storage.mutate_start(time.now_utc(), "x", "", "")
check(not res.ok, "double start rejected: " .. (res.reason or "NO REASON"))
check(res.reason:find("since %d%d:%d%d") ~= nil, "double start shows compact time: " .. (res.reason or "?"))

res = storage.mutate_end(time.now_utc(), "done\twith\ttabs")
check(res.ok, "end ok: " .. (res.reason or ""))
check(res.duration_min >= 0, "duration >= 0")
check(storage.write(res.new_lines), "write end")
local entries = storage.read_log()
check(storage.state(entries) == "idle", "state idle")
check(entries[#entries].message == "done with tabs", "message sanitized")

res = storage.mutate_end(time.now_utc(), "")
check(not res.ok, "end while idle rejected: " .. (res.reason or "NO REASON"))

-- Backdate: append an old end line directly, then start after it
local f2 = io.open(config.log_path, "a")
f2:write("2026-08-09T10:00:00Z\tend\t\t\t\n")
f2:close()
res = storage.mutate_start("2026-08-10T09:00:00Z", "p", "", "")
check(res.ok, "backdated start after old end ok: " .. (res.reason or ""))
check(storage.write(res.new_lines), "write backdated start")
res = storage.mutate_start("2026-08-09T09:00:00Z", "p", "", "")
check(not res.ok, "backdated start before tail rejected: " .. (res.reason or "NO REASON"))
res = storage.mutate_start("2099-01-01T00:00:00Z", "p", "", "")
check(not res.ok, "future start rejected: " .. (res.reason or "NO REASON"))

-- Zero-length block allowed (used by WorkChange later)
res = storage.mutate_end("2026-08-10T09:00:00Z", "")
check(res.ok and res.duration_min == 0, "zero-length end allowed: " .. (res.reason or ""))
check(storage.write(res.new_lines), "write zero-length end")
check(storage.state(storage.read_log()) == "idle", "idle after zero-length end")

-- Malformed lines are skipped, not fatal
local f3 = io.open(config.log_path, "a")
f3:write("garbage line\n")
f3:write("2026-08-10T12:00:00Z\tstart\t\t\t\n")
f3:close()
entries = storage.read_log()
check(entries[#entries].event == "start", "malformed line skipped, next parsed")

res = storage.mutate_start("2026-08-10T11:00:00Z", "p", "", "")
check(not res.ok, "backdate inside open block rejected: " .. (res.reason or "NO REASON"))

-- WorkSplit: insert a block inside a block (controlled log)
local fsplit = io.open(config.log_path, "w")
fsplit:write("2026-08-10T09:00:00Z\tstart\tmultiko\tT-1\torig message\n")
fsplit:write("2026-08-10T12:00:00Z\tend\t\t\t\n")
fsplit:close()

res = storage.mutate_split("2026-08-10T10:00:00Z", "2026-08-10T10:30:00Z", "multiko", "MTG-1", "meeting")
check(res.ok, "split ok: " .. (res.reason or ""))
check(storage.write_insert(res.insert_before, res.new_lines), "split write ok")
entries = storage.read_log()
check(#entries == 6, "split: 6 entries")
check(entries[2].event == "end" and entries[2].ts == "2026-08-10T10:00:00Z", "split: original closed at s")
check(entries[3].ticket == "MTG-1" and entries[3].message == "meeting", "split: inserted block fields")
check(entries[4].event == "end" and entries[4].ts == "2026-08-10T10:30:00Z", "split: inserted block closed at e")
check(entries[5].ticket == "T-1" and entries[5].message == "orig message" and entries[5].project == "multiko", "split: resume carries original identity")
check(entries[6].event == "end", "split: original block still ends")
local alt_ok = true
for i = 1, #entries do
	local want = (i % 2 == 1) and "start" or "end"
	if entries[i].event ~= want then
		alt_ok = false
	end
end
check(alt_ok, "split: alternation holds")

res = storage.mutate_split("2026-08-10T08:00:00Z", "2026-08-10T08:30:00Z", "p", "", "")
check(not res.ok, "split: before block start rejected")
res = storage.mutate_split("2026-08-10T11:00:00Z", "2026-08-10T13:00:00Z", "p", "", "")
check(not res.ok, "split: beyond block end rejected")
res = storage.mutate_split("2026-08-10T11:00:00Z", "2026-08-10T10:00:00Z", "p", "", "")
check(not res.ok, "split: s >= e rejected")

-- Split into an open tail block: resume becomes the new open tail
local fopen2 = io.open(config.log_path, "a")
fopen2:write("2026-08-10T14:00:00Z\tstart\tp2\tT-2\t\n")
fopen2:close()
res = storage.mutate_split("2026-08-10T14:30:00Z", "2026-08-10T15:00:00Z", "p2", "T-3", "")
check(res.ok, "split into open block ok: " .. (res.reason or ""))
check(storage.write_insert(res.insert_before, res.new_lines), "split into open block write ok")
entries = storage.read_log()
check(entries[#entries].event == "start" and entries[#entries].ticket == "T-2", "split into open block: resume is the open tail with original ticket")

-- Command layer ---------------------------------------------------------------

local commands = require("custom.worktime.commands")
local queue = require("custom.worktime.queue")

-- Commands are async: wait for the queue to drain before asserting.
local function wait_idle()
	vim.wait(10000, function()
		return queue.idle()
	end)
end

-- Tail is an open start here; WorkStart must be rejected, no write.
local n = #storage.read_log()
commands.workstart({ args = "" })
wait_idle()
check(#storage.read_log() == n, "WorkStart while recording does not write")

commands.workend({ args = "done for the day" })
wait_idle()
entries = storage.read_log()
check(entries[#entries].event == "end", "command WorkEnd writes end")
check(entries[#entries].message == "done for the day", "command message passed")
commands.status() -- must not error

n = #storage.read_log()
commands.workstart({ args = "2099-01-01T00:00:00Z" })
wait_idle()
check(#storage.read_log() == n, "future WorkStart does not write")

-- Project override: -p / --project
local cmd_cwd = vim.loop.cwd()
commands.workend({ args = "" })
wait_idle()
vim.loop.sleep(1100)
commands.workstart({ args = "-p beemo P-1 override message" })
wait_idle()
entries = storage.read_log()
check(entries[#entries].project == "beemo", "override: -p sets project")
check(entries[#entries].ticket == "P-1", "override: ticket still parsed")
check(entries[#entries].message == "override message", "override: message still parsed")
commands.workend({ args = "" })
wait_idle()
vim.loop.sleep(1100)
commands.workstart({ args = "--project=beemo2 T-2" })
wait_idle()
entries = storage.read_log()
check(entries[#entries].project == "beemo2", "override: --project= form")
commands.workend({ args = "" })
wait_idle()
n = #storage.read_log()
commands.workstart({ args = "-p" })
wait_idle()
check(#storage.read_log() == n, "override: missing name does not write")
vim.loop.sleep(1100)
-- override beats cwd detection: in the sandbox project dir with a
-- different explicit project
vim.loop.chdir("/tmp/wt-projects")
commands.workstart({ args = "-p other T-3" })
wait_idle()
entries = storage.read_log()
check(entries[#entries].project == "other", "override: beats cwd detection")
vim.loop.chdir(cmd_cwd)
commands.workend({ args = "" })
wait_idle()

-- WorkSplit through the command layer (insertion lands mid-log, at 16:00)
n = #storage.read_log()
commands.worksplit({ args = "start 2026-08-10T16:00:00Z end 2026-08-10T16:30:00Z MTG-2 split test" })
wait_idle()
check(#storage.read_log() == n + 4, "WorkSplit adds 4 entries")
entries = storage.read_log()
local found_s, found_mtg, found_resume
for _, e in ipairs(entries) do
	if e.ts == "2026-08-10T16:00:00Z" and e.event == "end" then
		found_s = true
	elseif e.ts == "2026-08-10T16:00:00Z" and e.event == "start" and e.ticket == "MTG-2" then
		found_mtg = true
	elseif e.ts == "2026-08-10T16:30:00Z" and e.event == "start" then
		found_resume = e
	end
end
check(found_s, "WorkSplit: closes original at s")
check(found_mtg, "WorkSplit: inserted block ticket")
check(found_resume ~= nil and found_resume.ticket == "T-2", "WorkSplit: resume carries original ticket")
n = #storage.read_log()
commands.worksplit({ args = "banana" })
wait_idle()
check(#storage.read_log() == n, "WorkSplit: bad args do not write")

-- Statusline ------------------------------------------------------------------

local statusline = require("custom.worktime.statusline")
check(statusline.get():find("⏱", 1, true) == nil, "statusline idle: no segment")
check(statusline.get() == statusline.STOCK, "statusline idle: byte-identical to stock")

-- Configured project open but idle: dimmed not-recording nudge
vim.fn.mkdir("/tmp/wt-projects", "p")
local orig_cwd = vim.loop.cwd()
vim.loop.chdir("/tmp/wt-projects")
statusline.invalidate()
local seg = statusline.get()
check(seg:find("not recording", 1, true) ~= nil, "statusline: not-recording nudge in configured project")
check(seg:find("%%#Comment#", 1, true) == nil, "statusline: highlight directive not double-escaped")
check(seg:find("%#Comment#", 1, true) ~= nil, "statusline: highlight directive present")

-- % in project names must be escaped for statusline rendering
vim.fn.mkdir("/tmp/wt-percent", "p")
vim.loop.chdir("/tmp/wt-percent")
statusline.invalidate()
seg = statusline.get()
check(seg:find("percent%%proj", 1, true) ~= nil, "statusline: % in project name escaped")

vim.loop.chdir(orig_cwd)
statusline.invalidate()

vim.loop.sleep(1100) -- advance now_utc() past the last end's second
commands.workstart({ args = "T-9 statusline check" })
wait_idle()
check(storage.state(storage.read_log()) == "recording", "statusline: recording state")
seg = statusline.get()
check(seg:find("⏱", 1, true) ~= nil, "statusline: segment present while recording")
check(seg:find("T-9", 1, true) ~= nil, "statusline: ticket shown")
check(seg:find("%%=", 1, false) ~= nil, "statusline: right-alignment preserved")

commands.workend({ args = "" })
wait_idle()
vim.loop.sleep(1100) -- same-second guard before the next start
commands.workstart({ args = "" })
wait_idle()
seg = statusline.get()
check(seg:find("Working", 1, true) ~= nil, "statusline: 'Working' when no ticket")

commands.workend({ args = "" })
wait_idle()
check(statusline.get():find("⏱", 1, true) == nil, "statusline: segment gone when idle")

-- Reminders -------------------------------------------------------------------

local reminders = require("custom.worktime.reminders")

-- Idle: no-ops, no crash
reminders.check_left_open()
reminders.warn_open_block()

-- Recording: check_left_open notifies; warn_open_block prompts — headless
-- confirm() returns the default (Yes), so the end gets written.
vim.loop.sleep(1100)
commands.workstart({ args = "" })
wait_idle()
check(storage.state(storage.read_log()) == "recording", "reminders: recording for close prompt test")
reminders.check_left_open() -- must not error
reminders.warn_open_block()
entries = storage.read_log()
check(storage.state(entries) == "idle", "reminders: close prompt Yes wrote the end")
check(entries[#entries].event == "end", "reminders: tail is end after close prompt")

-- Exit flush: pending queued writes are drained synchronously
vim.loop.sleep(1100)
local flush_ts = time.now_utc()
queue.push({
	kind = "write",
	mutate = function()
		return storage.mutate_start(flush_ts, "flush", "F-1", "")
	end,
	describe = function()
		return "flushed"
	end,
})
queue.flush_on_exit()
entries = storage.read_log()
check(entries[#entries].ticket == "F-1", "flush_on_exit wrote the queued entry")

finish()
