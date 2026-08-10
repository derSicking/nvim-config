local M = {}

-- Data dir: XDG data home via nvim stdpath, overridable for tests.
local data_dir = vim.env.WORKTIME_DATA_DIR or vim.fn.stdpath("data") .. "/worktime"

-- Config dir: $XDG_CONFIG_HOME, falling back to ~/.config (no stdpath).
local function config_dir()
	local xdg = vim.env.XDG_CONFIG_HOME
	if xdg and xdg ~= "" then
		return xdg .. "/nvim-worktime"
	end
	return vim.fn.expand("~/.config/nvim-worktime")
end

M.data_dir = data_dir
M.log_path = data_dir .. "/log.tsv"
M.config_path = config_dir() .. "/config.lua"

local cached

local EXAMPLE_CONFIG = [==[
-- Worktime configuration
-- Project dirs are machine-specific; keep this file out of version control.
-- remote = "git@github.com:you/worktime.git" -- optional; omit for local-only
return {
	projects = {
		-- ["client-a"] = {
		-- 	dirs = { "~/code/client-a" },
		-- 	weekly_target = 20, -- hours
		-- },
	},
}
]==]

local function ensure_config()
	vim.fn.mkdir(config_dir(), "p")
	if vim.fn.filereadable(M.config_path) == 0 then
		local f = io.open(M.config_path, "w")
		if f then
			f:write(EXAMPLE_CONFIG)
			f:close()
			vim.notify("Worktime: created config at " .. M.config_path, vim.log.levels.INFO)
		end
	end
end

local function load_config()
	ensure_config()
	local ok, cfg = pcall(dofile, M.config_path)
	if not ok then
		vim.notify("Worktime: config error, using defaults: " .. tostring(cfg), vim.log.levels.WARN)
		return {}
	end
	if type(cfg) ~= "table" then
		vim.notify("Worktime: config must return a table, using defaults", vim.log.levels.WARN)
		return {}
	end
	return cfg
end

function M.get()
	if cached == nil then
		cached = load_config()
	end
	return cached
end

-- Re-read the config file (also ensures the example file exists on first run).
function M.reload()
	cached = load_config()
end

local function normalize(dir)
	return vim.fn.fnamemodify(vim.fn.expand(dir), ":p"):gsub("/+$", "")
end

-- Longest-prefix match over configured project dirs; fallback: cwd basename.
function M.detect_project(cwd)
	local cfg = M.get()
	local best, best_len
	for name, proj in pairs(cfg.projects or {}) do
		for _, dir in ipairs(proj.dirs or {}) do
			local nd = normalize(dir)
			if nd ~= "" and cwd:sub(1, #nd) == nd and cwd:sub(#nd + 1, #nd + 1) == "/" then
				if not best_len or #nd > best_len then
					best, best_len = name, #nd
				end
			end
		end
	end
	if best then
		return best
	end
	return vim.fn.fnamemodify(cwd, ":t")
end

function M.weekly_target(project)
	local cfg = M.get()
	local proj = cfg.projects and cfg.projects[project]
	return proj and proj.weekly_target or nil
end

return M
