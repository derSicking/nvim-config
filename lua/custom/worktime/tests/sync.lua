-- Sync tests for worktime. Uses a local bare repo as the remote
-- (file:///tmp/wt-sync-remote.git), so no network is involved.
--
-- Run from the repo root, isolated from real data:
--
--   rm -rf /tmp/wt-sync /tmp/wt-sync-cfg
--   WORKTIME_DATA_DIR=/tmp/wt-sync XDG_CONFIG_HOME=/tmp/wt-sync-cfg \
--     nvim --headless -u NONE -l lua/custom/worktime/tests/sync.lua
--
-- Exits 0 on success, 1 on failure.

-- Note: rtp must be set before requiring the helpers module.
vim.opt.rtp:append(vim.fn.getcwd())
local helpers = require("custom.worktime.tests.helpers")
helpers.guard_env()

if vim.fn.executable("git") == 0 then
	print("git is required")
	os.exit(1)
end

local check, finish = helpers.new_check()
local has_ticket = helpers.has_ticket

local data_dir = vim.env.WORKTIME_DATA_DIR
local cfg_home = vim.env.XDG_CONFIG_HOME

local REMOTE = "/tmp/wt-sync-remote.git"
local OTHER = "/tmp/wt-other"

-- Clean slate
os.execute("rm -rf '" .. data_dir .. "' '" .. REMOTE .. "' '" .. OTHER .. "' /tmp/wt-sync-saved.log")

-- The "server": an empty repo with an initial log committed by another machine.
vim.fn.system("git init --bare -q " .. REMOTE)
vim.fn.system("git clone -q " .. REMOTE .. " " .. OTHER)
local f = io.open(OTHER .. "/log.tsv", "w")
f:write("2026-08-09T09:00:00Z\tstart\tserverproj\tS-1\tfrom server\n")
f:write("2026-08-09T10:00:00Z\tend\t\t\t\n")
f:close()
vim.fn.system("git -C " .. OTHER .. " add log.tsv")
vim.fn.system("git -C " .. OTHER .. " -c user.name=t -c user.email=t@x commit -q -m initial")
vim.fn.system("git -C " .. OTHER .. " push -q origin HEAD")

-- Config with the remote
vim.fn.mkdir(cfg_home .. "/nvim-worktime", "p")
local function write_config(remote)
	local f = io.open(cfg_home .. "/nvim-worktime/config.lua", "w")
	f:write("return {\n\tremote = " .. string.format("%q", remote) .. ",\n\tprojects = {},\n}\n")
	f:close()
end
write_config("file://" .. REMOTE)

local config = require("custom.worktime.config")
local storage = require("custom.worktime.storage")
local sync = require("custom.worktime.sync")
local commands = require("custom.worktime.commands")
local statusline = require("custom.worktime.statusline")
local queue = require("custom.worktime.queue")
config.reload()

-- Commands are async: wait for the queue to drain before asserting.
local function wait_idle()
	vim.wait(10000, function()
		return queue.idle()
	end)
end

-- 1. Clone onboarding: fresh machine pulls the server state instantly
check(sync.enabled(), "sync enabled with remote")
commands.workstart({ args = "N-1 first on new machine" })
wait_idle()
local entries = storage.read_log()
check(has_ticket(entries, "S-1"), "clone brought server entries")
check(entries[#entries].ticket == "N-1", "new start written after clone")
check(sync.state() == "synced", "state synced after clone+push: " .. sync.state())

-- Push reached the remote: re-clone elsewhere and verify
os.execute("rm -rf " .. OTHER)
vim.fn.system("git clone -q " .. REMOTE .. " " .. OTHER)
local f2 = io.open(OTHER .. "/log.tsv")
local content = f2:read("*a")
f2:close()
check(content:find("N%-1") ~= nil, "push reached the remote")

-- Async warm: background fetch must run its callback without error
-- (regression: obj:wait() inside the on_exit callback used to throw).
local warmed = false
sync.warm(function()
	warmed = true
end)
vim.wait(5000, function()
	return warmed
end)
check(warmed, "warm callback ran")
check(sync.state() == "synced", "warm refreshed state: " .. sync.state())

-- 2. Blocked: local log but no repo — write must be rejected
os.execute("rm -rf " .. data_dir)
vim.fn.mkdir(data_dir, "p")
local f3 = io.open(data_dir .. "/log.tsv", "w")
f3:write("2026-08-09T09:00:00Z\tstart\told\tO-1\tlocal only\n")
f3:close()
commands.workstart({ args = "X-1 should not land" })
wait_idle()
check(#storage.read_log() == 1, "blocked: write rejected")
check(sync.state() == "blocked", "state blocked: " .. sync.state())
check(vim.fn.isdirectory(data_dir .. "/.git") == 0, "blocked: no repo created")

-- 3. Resolve: save the log aside (OUTSIDE the data dir, so the clone target
-- is empty), then WorkSync clones
os.rename(data_dir .. "/log.tsv", "/tmp/wt-sync-saved.log")
commands.sync_now()
wait_idle()
check(sync.state() == "synced", "WorkSync cloned after resolve: " .. sync.state())
entries = storage.read_log()
check(has_ticket(entries, "S-1"), "cloned server entries after resolve")

-- 4. Remote ahead: another machine pushes, our write must merge it
os.execute("rm -rf " .. OTHER)
vim.fn.system("git clone -q " .. REMOTE .. " " .. OTHER)
local f4 = io.open(OTHER .. "/log.tsv", "a")
f4:write("2026-08-09T11:00:00Z\tstart\tother\tO-2\tother machine\n")
f4:write("2026-08-09T11:30:00Z\tend\t\t\t\n")
f4:close()
vim.fn.system("git -C " .. OTHER .. " add log.tsv")
vim.fn.system("git -C " .. OTHER .. " -c user.name=t -c user.email=t@x commit -q -m other")
vim.fn.system("git -C " .. OTHER .. " push -q origin HEAD")
commands.workstart({ args = "N-2 after remote ahead" })
wait_idle()
entries = storage.read_log()
check(has_ticket(entries, "O-2"), "remote-ahead entry merged in")
check(entries[#entries] and entries[#entries].ticket == "N-2", "our write landed after merge")
check(sync.state() == "synced", "synced after merge: " .. sync.state())

-- 4b. The exit flow writes, commits AND pushes the end before closing
-- (regression: it used to leave the repo dirty or defer the push).
local reminders = require("custom.worktime.reminders")
reminders.on_exit() -- headless confirm -> Yes -> end + blocking push
check(storage.state(storage.read_log()) == "idle", "close prompt closed the block")
os.execute("rm -rf " .. OTHER)
vim.fn.system("git clone -q " .. REMOTE .. " " .. OTHER)
local f5 = io.open(OTHER .. "/log.tsv")
local c5 = f5:read("*a")
f5:close()
check(c5:find("\tend\t\t\t\n", 1, true) ~= nil, "close prompt end reached the remote immediately")

-- 4c. Idle exit must not block on network: no fetch/push when the log tail
-- is an end (regression: on_exit used to sync unconditionally).
write_config("ssh://git@127.0.0.1:1/nope.git")
config.reload()
vim.fn.system("git -C " .. data_dir .. " remote set-url origin ssh://git@127.0.0.1:1/nope.git")
local commits_before = tonumber((vim.fn.system("git -C " .. data_dir .. " rev-list --count HEAD"):gsub("%s+$", "")))
local state_before = sync.state()
reminders.on_exit() -- idle -> no prompt, no push attempt
check(sync.state() == state_before, "idle exit: no sync attempt, state unchanged")
local commits_after = tonumber((vim.fn.system("git -C " .. data_dir .. " rev-list --count HEAD"):gsub("%s+$", "")))
check(commits_after == commits_before, "idle exit: no new commits")

-- 5. Offline with an existing repo: writes proceed, state offline
write_config("ssh://git@127.0.0.1:1/nope.git")
config.reload()
vim.fn.system("git -C " .. data_dir .. " remote set-url origin ssh://git@127.0.0.1:1/nope.git")
vim.loop.sleep(1100) -- same-second guard before the next start
commands.workstart({ args = "N-3 offline" })
wait_idle()
entries = storage.read_log()
check(entries[#entries].ticket == "N-3", "offline write still lands")
check(sync.state() == "offline", "state offline: " .. sync.state())
check(statusline.get():find("✗", 1, true) ~= nil, "statusline shows offline glyph")

-- 6. Fresh machine offline: clone fails -> write blocked, no local repo
os.execute("rm -rf " .. data_dir)
commands.workstart({ args = "N-4 should not land" })
wait_idle()
check(#storage.read_log() == 0, "fresh offline: write rejected")
check(sync.state() == "offline", "fresh offline state: " .. sync.state())
check(vim.fn.isdirectory(data_dir .. "/.git") == 0, "fresh offline: no local repo created")

finish()
