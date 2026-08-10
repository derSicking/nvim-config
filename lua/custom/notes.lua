local M = {}

local NOTES_DIR = vim.fn.expand("~/Notes")
local OVERRIDES_FILE = NOTES_DIR .. "/overrides.json"

local function ensure_notes_dir()
	vim.fn.mkdir(NOTES_DIR, "p")
end

local function read_overrides()
	local f = io.open(OVERRIDES_FILE, "rb")
	if not f then
		return {}
	end
	local content = f:read("*a")
	f:close()
	local ok, data = pcall(vim.json.decode, content)
	if not ok or type(data) ~= "table" then
		return {}
	end
	return data
end

local function write_overrides(overrides)
	ensure_notes_dir()
	local f = io.open(OVERRIDES_FILE, "w+")
	if not f then
		return
	end
	f:write(vim.json.encode(overrides))
	f:close()
end

local function normalize(dir)
	return vim.fn.fnamemodify(dir, ":p"):gsub("/+$", "")
end

local function slugify(dir)
	local base = vim.fn.fnamemodify(dir, ":t")
	return base:gsub("[^%w_-]", "-")
end

local function find_override(cwd)
	local overrides = read_overrides()
	if overrides[cwd] then
		return overrides[cwd]
	end
	local best, best_len
	for dir, name in pairs(overrides) do
		local nd = normalize(dir)
		if cwd:sub(1, #nd) == nd and cwd:sub(#nd + 1, #nd + 1) == "/" then
			if not best_len or #nd > best_len then
				best, best_len = name, #nd
			end
		end
	end
	return best
end

local function open_note(name)
	ensure_notes_dir()
	local file = NOTES_DIR .. "/" .. name
	vim.cmd("edit " .. vim.fn.fnameescape(file))
end

M.project_note = function()
	local cwd = normalize(vim.loop.cwd())
	local name = find_override(cwd) or slugify(cwd) .. ".md"
	open_note(name)
end

M.general_note = function()
	open_note("general.md")
end

M.add_override = function(name)
	if not name or name == "" then
		vim.notify("NoteOverride: missing note file name", vim.log.levels.WARN)
		return
	end
	local overrides = read_overrides()
	overrides[normalize(vim.loop.cwd())] = name:gsub("%.md$", "") .. ".md"
	write_overrides(overrides)
	vim.notify("Note override set for " .. vim.loop.cwd())
end

M.remove_override = function()
	local overrides = read_overrides()
	local cwd = normalize(vim.loop.cwd())
	if overrides[cwd] then
		overrides[cwd] = nil
		write_overrides(overrides)
		vim.notify("Note override removed for " .. vim.loop.cwd())
	else
		vim.notify("No note override for " .. vim.loop.cwd(), vim.log.levels.WARN)
	end
end

vim.keymap.set("n", "<leader>t", M.project_note, { desc = "Open project note" })
vim.keymap.set("n", "<leader>T", M.general_note, { desc = "Open general note" })

vim.api.nvim_create_user_command("NoteOverride", function(opts)
	M.add_override(opts.args)
end, { nargs = "?" })

vim.api.nvim_create_user_command("NoteOverrideRemove", M.remove_override, {})

return M
