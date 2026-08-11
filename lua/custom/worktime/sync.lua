-- Git remote integration: onboarding (clone), fetch/rebase before writes,
-- commit+push after, remote state for the statusline.
--
-- Everything network-bound runs asynchronously via small shell scripts
-- (one git process per stage), so commands never block nvim. The on_exit
-- callbacks run in fast-event contexts where synchronous git (vim.wait)
-- is forbidden — the Lua side only parses script output and does file I/O.
-- The one synchronous git call (commit_local) runs only at exit, where the
-- autocmd context is normal.

local M = {}

local config = require("custom.worktime.config")
local notify = require("custom.worktime.notify").notify

-- Remote state: local | synced | push | behind | diverged | offline | new | blocked
local state = "local"

local GLYPHS = { push = " ⇡", behind = " ⇣", diverged = " ⚠", offline = " ✗", blocked = " ⚠" }
local NAMES = {
	synced = "synced",
	push = "push pending",
	behind = "remote ahead",
	diverged = "diverged",
	offline = "offline",
	new = "never synced",
	blocked = "needs attention",
}

local CONFLICT_MSG =
	"Worktime sync conflict — rebase aborted, local log kept. Resolve manually, see README."
local BLOCKED_MSG = "Worktime: log.tsv exists but no git repo — the remote is the source of truth. "
	.. "Save the local log aside, delete it, then run :WorkSync to clone."

-- Captured at module load: vim.fn calls are forbidden in fast-event
-- contexts where the async callbacks run, so nothing Vimscript may be
-- evaluated there.
local env_merged = vim.fn.environ()
env_merged.GIT_SSH_COMMAND = "ssh -o ConnectTimeout=5"
local has_git = vim.fn.executable("git") == 1

-- Scripts run with cwd = data dir. The first stdout line is a status
-- marker: READY/BLOCKED/CLONE_FAILED, OK/OFFLINE/CONFLICT, OK/FAILED.

-- Repo existence: init (local-only) or clone (remote). $WT_REMOTE comes
-- from the process environment.
local SCRIPT_REPO = [=[
[ -d .git ] && { echo READY; exit 0; }
if [ -z "$WT_REMOTE" ]; then
	git init -q 2>/dev/null
	echo READY
	exit 0
fi
[ -s log.tsv ] && { echo BLOCKED; exit 0; }
rm -f log.tsv
if git clone -q "$WT_REMOTE" . 2>/dev/null; then
	echo READY
else
	echo CLONE_FAILED
fi
]=]

-- Fetch and rebase when behind. Prints the "ahead<TAB>behind" counts,
-- then the status marker (last line).
local SCRIPT_SYNC = [=[
if ! git fetch -q origin >/dev/null 2>&1; then
	echo OFFLINE
	exit 0
fi
B=$(git symbolic-ref --short -q HEAD 2>/dev/null)
[ -z "$B" ] && B=main
N=$(git rev-list --count HEAD..origin/$B 2>/dev/null || echo 0)
if [ "$N" != "0" ]; then
	if ! git rebase -q origin/$B >/dev/null 2>&1; then
		git rebase --abort >/dev/null 2>&1
		echo CONFLICT
		exit 0
	fi
fi
C=$(git rev-list --left-right --count HEAD...origin/$B 2>/dev/null || echo "0 0")
echo "$C"
echo OK
]=]

-- Commit pending changes and push with bounded fetch/rebase retries.
-- All git chatter goes to /dev/null; the status marker is the last line.
local SCRIPT_PUSH = [=[
git add log.tsv >/dev/null 2>&1
git -c user.name=worktime -c user.email=worktime@local commit -q -m "worktime: update" >/dev/null 2>&1
B=$(git symbolic-ref --short -q HEAD 2>/dev/null)
[ -z "$B" ] && B=main
i=0
while [ $i -lt 3 ]; do
	if git push -q origin $B >/dev/null 2>&1; then
		echo OK
		exit 0
	fi
	if ! git fetch -q origin >/dev/null 2>&1; then
		echo OFFLINE
		exit 0
	fi
	if ! git rebase -q origin/$B >/dev/null 2>&1; then
		git rebase --abort >/dev/null 2>&1
		echo CONFLICT
		exit 0
	fi
	i=$((i+1))
done
echo FAILED
]=]

local function git_opts(extra_env)
	local opts = { text = true, cwd = config.data_dir, env = env_merged }
	if extra_env then
		opts.env = vim.tbl_extend("force", opts.env, extra_env)
	end
	return opts
end

-- Synchronous git call, used ONLY by commit_local at exit (autocmd context
-- is normal there, unlike vim.system on_exit callbacks).
local function git(args)
	return vim.system(
		{ "git", "-c", "user.name=worktime", "-c", "user.email=worktime@local", unpack(args) },
		git_opts()
	):wait(30000)
end

local function run_script(script, extra_env, cb)
	-- vim.system requires the cwd to exist at spawn time; the data dir may
	-- not exist yet on a fresh machine.
	config.ensure_data_dir()
	local opts = git_opts(extra_env)
	local ok_spawn, obj = pcall(vim.system, { "sh", "-c", script }, opts, function(o)
		-- In the on_exit callback the object has fields only (code, stdout,
		-- stderr) — wait() must not be called here.
		cb({ code = o.code, stdout = o.stdout, stderr = o.stderr })
	end)
	if not ok_spawn then
		-- Spawn failure (e.g. missing cwd/binary): report as offline rather
		-- than throwing into the queue worker.
		cb({ code = -1, stdout = "", stderr = tostring(obj) })
	end
end

-- Synchronous variant, legal in normal contexts only (autocmds). Used by
-- the exit-time push, where the user explicitly accepted blocking.
local function run_script_sync(script, extra_env)
	config.ensure_data_dir()
	local ok_spawn, obj = pcall(vim.system, { "sh", "-c", script }, git_opts(extra_env))
	if not ok_spawn then
		return { code = -1, stdout = "", stderr = tostring(obj) }
	end
	return obj:wait(30000)
end

-- Last non-empty line of the script output: scripts print their status
-- marker last, after any git chatter on stdout.
local function script_status(res)
	local lines = vim.split(res.stdout, "\n", { trimempty = true })
	return (lines[#lines] or ""):gsub("%s+$", "")
end

-- "ahead\tbehind" from `git rev-list --left-right --count HEAD...origin/<b>`
local function set_state_from_counts(stdout)
	local a, b = stdout:match("^(%d+)\t(%d+)$")
	a = tonumber(a) or 0
	b = tonumber(b) or 0
	if a > 0 and b > 0 then
		state = "diverged"
	elseif b > 0 then
		state = "behind"
	elseif a > 0 then
		state = "push"
	else
		state = "synced"
	end
end

function M.enabled()
	local remote = config.get().remote
	return remote ~= nil and remote ~= "" and has_git
end

function M.state()
	return state
end

function M.state_name()
	return NAMES[state] or state
end

function M.glyph()
	if not M.enabled() then
		return ""
	end
	return GLYPHS[state] or ""
end

-- Onboarding. cb(true) when the repo is ready, cb(false) when blocked.
-- The remote is the source of truth:
--   fresh machine           -> clone (instant onboarding)
--   local log without repo  -> reject: save it aside, then clone
--   clone fails             -> reject until :WorkSync succeeds
function M.repo_async(cb)
	local remote = config.get().remote or ""
	run_script(SCRIPT_REPO, { WT_REMOTE = remote }, function(res)
		local status = script_status(res)
		if status == "READY" then
			if remote == "" then
				state = "local"
			end
			return cb(true)
		end
		if status == "BLOCKED" then
			state = "blocked"
			notify(BLOCKED_MSG, vim.log.levels.WARN)
			return cb(false)
		end
		state = "offline"
		notify(
			"Worktime: clone failed — working is blocked until the remote is reachable. :WorkSync to retry.",
			vim.log.levels.WARN
		)
		cb(false)
	end)
end

-- Fetch + rebase against the remote, then update the remote state.
-- cb("ok" | "offline" | "conflict")
function M.sync_async(cb)
	if not M.enabled() then
		state = "local"
		return cb("ok")
	end
	run_script(SCRIPT_SYNC, nil, function(res)
		local lines = vim.split(res.stdout, "\n", { trimempty = true })
		local status = lines[#lines] or ""
		if status == "OFFLINE" then
			state = "offline"
			return cb("offline")
		end
		if status == "CONFLICT" then
			state = "diverged"
			notify(CONFLICT_MSG, vim.log.levels.WARN)
			return cb("conflict")
		end
		if lines[#lines - 1] then
			set_state_from_counts(lines[#lines - 1])
		end
		cb("ok")
	end)
end

-- Commit pending changes and push with bounded retries.
-- cb("ok" | "offline" | "conflict" | "failed")
function M.push_async(cb)
	if not M.enabled() then
		return cb("ok")
	end
	run_script(SCRIPT_PUSH, nil, function(res)
		local status = script_status(res)
		if status == "OK" then
			state = "synced"
			return cb("ok")
		end
		if status == "OFFLINE" then
			state = "offline"
			return cb("offline")
		end
		if status == "CONFLICT" then
			state = "diverged"
			notify(CONFLICT_MSG, vim.log.levels.WARN)
			return cb("conflict")
		end
		state = "push"
		notify("Worktime push failed after retries — :WorkPush to retry", vim.log.levels.WARN)
		cb("failed")
	end)
end

-- Commit pending changes WITHOUT fetching or pushing. Used by the exit
-- flush so queued writes are never lost; the next sync pushes them.
-- Safe to call in normal (autocmd) contexts only.
function M.commit_local()
	if not M.enabled() then
		return
	end
	git({ "add", "log.tsv" })
	git({ "commit", "-q", "-m", "worktime: update" })
end

-- Full blocking sync + push, for exit time: fetch/rebase, then commit and
-- push. Runs the push script even when the fetch failed, so pending
-- changes are at least committed (never a dirty tree). Legal only in
-- normal contexts (VimLeavePre); async paths must use queue + *_async.
function M.sync_now_blocking()
	if not M.enabled() then
		return
	end
	local r = run_script_sync(SCRIPT_SYNC, nil)
	local lines = vim.split(r.stdout, "\n", { trimempty = true })
	local status = lines[#lines] or ""
	if status == "CONFLICT" then
		state = "diverged"
		notify(CONFLICT_MSG, vim.log.levels.WARN)
		return -- local log kept; do not push over a conflict
	end
	if lines[#lines - 1] then
		set_state_from_counts(lines[#lines - 1])
	end

	local p = run_script_sync(SCRIPT_PUSH, nil)
	local pstatus = script_status(p)
	if pstatus == "OK" then
		state = "synced"
	elseif pstatus == "OFFLINE" then
		state = "offline"
		notify("Worktime: offline — recorded locally, will push next session", vim.log.levels.WARN)
	elseif pstatus == "CONFLICT" then
		state = "diverged"
		notify(CONFLICT_MSG, vim.log.levels.WARN)
	else
		state = "push"
		notify("Worktime: push failed — :WorkPush next session", vim.log.levels.WARN)
	end
end

-- Startup: ensure repo, then fetch in the background. Never blocks.
function M.warm(on_done)
	if not M.enabled() then
		state = "local"
		if on_done then
			on_done()
		end
		return
	end
	M.repo_async(function(ok)
		if ok then
			M.sync_async(function()
				if on_done then
					on_done()
				end
			end)
		elseif on_done then
			on_done()
		end
	end)
end

return M
