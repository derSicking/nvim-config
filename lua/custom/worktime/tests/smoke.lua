-- Smoke tests for worktime (storage + config + command layer).
-- No framework, plain asserts. Run from the repo root, isolated from real
-- data (the test refuses to run without both env vars):
--
--   rm -rf /tmp/wt-test /tmp/wt-cfg
--   WORKTIME_DATA_DIR=/tmp/wt-test XDG_CONFIG_HOME=/tmp/wt-cfg \
--     nvim --headless -u NONE -l lua/custom/worktime/tests/smoke.lua
--
-- Exits 0 on success, 1 on failure.

-- Guard: never run against real data.
local data_dir = vim.env.WORKTIME_DATA_DIR
local cfg_home = vim.env.XDG_CONFIG_HOME
if not data_dir or not cfg_home then
	print("refusing to run without WORKTIME_DATA_DIR and XDG_CONFIG_HOME")
	os.exit(1)
end

vim.opt.rtp:append(vim.fn.getcwd())

local storage = require("custom.worktime.storage")
local config = require("custom.worktime.config")

local failures = 0
local function check(cond, msg)
	if not cond then
		failures = failures + 1
		print("FAIL: " .. msg)
	end
end

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

-- Time helpers ----------------------------------------------------------------

local ts = storage.now_utc()
check(ts:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil, "now_utc format: " .. ts)
local loc = storage.to_local(ts)
check(loc ~= nil and loc:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d$") ~= nil, "to_local format")
check(storage.to_utc(loc) == ts, "roundtrip to_utc(to_local(ts)) == ts")
check(storage.parse_time_arg("09:00") ~= nil, "HH:MM parsed")
check(storage.parse_time_arg("09:00") > storage.parse_time_arg("08:00"), "HH:MM lexicographic order")
check(storage.parse_time_arg("9:30") ~= nil, "H:MM parsed")
check(storage.parse_time_arg("2026-08-10 09:00") ~= nil, "date + HH:MM parsed")
check(storage.parse_time_arg("2026-08-10T09:00:00") ~= nil, "full local ISO parsed")
check(storage.parse_time_arg("2026-08-10T09:00:00Z") == "2026-08-10T09:00:00Z", "full UTC ISO kept as-is")
check(storage.parse_time_arg("banana") == nil, "garbage rejected")
check(storage.diff_min("2026-08-10T09:00:00Z", "2026-08-10T11:30:00Z") == 150, "diff_min works")

-- fmt_ts: compact notification timestamps
local util = require("custom.worktime.util")
local now_loc = storage.to_local(ts)
check(util.fmt_ts(ts) == now_loc:sub(12, 16), "fmt_ts: today shows HH:MM")
local old = "2020-01-01T10:00:00Z"
check(util.fmt_ts(old) == storage.to_local(old):gsub("T", " "):sub(1, 16), "fmt_ts: other day shows date + HH:MM")

-- Write rules -----------------------------------------------------------------

check(storage.state(storage.read_log()) == "empty", "empty state")

local res = storage.mutate_start(ts, "testproj", "T-1", "hello")
check(res.ok, "start ok: " .. (res.reason or ""))
check(storage.write(res.new_lines), "write ok")
check(storage.state(storage.read_log()) == "recording", "state recording")

res = storage.mutate_start(storage.now_utc(), "x", "", "")
check(not res.ok, "double start rejected: " .. (res.reason or "NO REASON"))
check(res.reason:find("since %d%d:%d%d") ~= nil, "double start shows compact time: " .. (res.reason or "?"))

res = storage.mutate_end(storage.now_utc(), "done\twith\ttabs")
check(res.ok, "end ok: " .. (res.reason or ""))
check(res.duration_min >= 0, "duration >= 0")
check(storage.write(res.new_lines), "write end")
local entries = storage.read_log()
check(storage.state(entries) == "idle", "state idle")
check(entries[#entries].message == "done with tabs", "message sanitized")

res = storage.mutate_end(storage.now_utc(), "")
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

-- Command layer ---------------------------------------------------------------

local commands = require("custom.worktime.commands")

-- Tail is an open start here; WorkStart must be rejected, no write.
local n = #storage.read_log()
commands.workstart({ args = "" })
check(#storage.read_log() == n, "WorkStart while recording does not write")

commands.workend({ args = "done for the day" })
entries = storage.read_log()
check(entries[#entries].event == "end", "command WorkEnd writes end")
check(entries[#entries].message == "done for the day", "command message passed")
commands.status() -- must not error

n = #storage.read_log()
commands.workstart({ args = "2099-01-01T00:00:00Z" })
check(#storage.read_log() == n, "future WorkStart does not write")

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
check(storage.state(storage.read_log()) == "recording", "statusline: recording state")
seg = statusline.get()
check(seg:find("⏱", 1, true) ~= nil, "statusline: segment present while recording")
check(seg:find("T-9", 1, true) ~= nil, "statusline: ticket shown")
check(seg:find("%%=", 1, false) ~= nil, "statusline: right-alignment preserved")

commands.workend({ args = "" })
vim.loop.sleep(1100) -- same-second guard before the next start
commands.workstart({ args = "" })
seg = statusline.get()
check(seg:find("Working", 1, true) ~= nil, "statusline: 'Working' when no ticket")

commands.workend({ args = "" })
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
check(storage.state(storage.read_log()) == "recording", "reminders: recording for close prompt test")
reminders.check_left_open() -- must not error
reminders.warn_open_block()
entries = storage.read_log()
check(storage.state(entries) == "idle", "reminders: close prompt Yes wrote the end")
check(entries[#entries].event == "end", "reminders: tail is end after close prompt")

print(failures == 0 and "ALL OK" or failures .. " FAILURES")
os.exit(failures == 0 and 0 or 1)
