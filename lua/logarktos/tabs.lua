-- logarktos/tabs.lua ── tiered tab naming (auto + manual)
--
-- A tab name carries a *meaningfulness tier*. A name is only replaced by another
-- that is at least as meaningful, so the best clue wins and sticks while
-- arrangement-only labels stay disposable.
--
--   layout  — arrangement-only labels (Triplicate, Large, Triple, Dual, …).
--   note    — title typed into :NewMarkdown. Beats a layout label.
--   folder  — :HereWork folder / directory basename. Sticks.
--   heading — a Markdown file's title/H1. The strongest clue.
--   manual  — explicit :TabRename. Always wins.
--
-- Inferred names are capped (config.tabs.max_title_chars); manual names verbatim.

local config = require("logarktos.config")

local M = {}

M.PRIORITY = {
	none = 0,
	layout = 1,
	note = 2,
	folder = 3,
	heading = 4,
	manual = 5,
}
local P = M.PRIORITY

-- Names at/above this tier are "real": shown with a ● in the tabline and never
-- overwritten by mere layout labels.
local MEANINGFUL = P.note

local function max_chars()
	return (config.options.tabs and config.options.tabs.max_title_chars) or 12
end

local function get_tab(tab)
	return tab or vim.api.nvim_get_current_tabpage()
end

function M.truncate(name)
	if type(name) ~= "string" then return name end
	name = vim.trim(name)
	name = vim.fn.strcharpart(name, 0, max_chars())
	return (name:gsub("%s+$", ""))
end

function M.get(tab)
	tab = get_tab(tab)
	local ok, name = pcall(vim.api.nvim_tabpage_get_var, tab, "logarktos_name")
	if ok and type(name) == "string" and name ~= "" then return name end
	return nil
end

function M.get_priority(tab)
	tab = get_tab(tab)
	local ok, p = pcall(vim.api.nvim_tabpage_get_var, tab, "logarktos_name_priority")
	if ok and type(p) == "number" then return p end
	if M.get(tab) then return P.manual end
	return P.none
end

function M.set(tab, name, opts)
	tab = get_tab(tab)
	if not name or name == "" then return M.clear(tab) end
	opts = opts or {}
	local priority = opts.priority or ((opts.lock == false) and P.layout or P.manual)
	vim.api.nvim_tabpage_set_var(tab, "logarktos_name", name)
	vim.api.nvim_tabpage_set_var(tab, "logarktos_name_priority", priority)
	if priority >= MEANINGFUL then
		vim.api.nvim_tabpage_set_var(tab, "logarktos_name_locked", true)
	else
		pcall(vim.api.nvim_tabpage_del_var, tab, "logarktos_name_locked")
	end
end

function M.clear(tab)
	tab = get_tab(tab)
	pcall(vim.api.nvim_tabpage_del_var, tab, "logarktos_name")
	pcall(vim.api.nvim_tabpage_del_var, tab, "logarktos_name_priority")
	pcall(vim.api.nvim_tabpage_del_var, tab, "logarktos_name_locked")
end

function M.is_locked(tab)
	tab = get_tab(tab)
	local ok, locked = pcall(vim.api.nvim_tabpage_get_var, tab, "logarktos_name_locked")
	return ok and locked == true
end

local function set_if(tab, name, priority, do_truncate)
	tab = get_tab(tab)
	if do_truncate then name = M.truncate(name) end
	if not name or name == "" then return false end
	if priority < M.get_priority(tab) then return false end
	M.set(tab, name, { priority = priority })
	return true
end

function M.apply(tab, name, priority)
	return set_if(tab, name, priority, true)
end

function M.apply_note(name) return M.apply(nil, name, P.note) end
function M.apply_folder(name) return M.apply(nil, name, P.folder) end
function M.apply_heading(name) return M.apply(nil, name, P.heading) end

-- ── name generators ─────────────────────────────────────────────────────────
local function basename(dir)
	if not dir or dir == "" then return nil end
	return vim.fn.fnamemodify(dir, ":t")
end

local function project_root_name(start_path)
	local start = start_path or vim.fn.getcwd(-1, 0)
	local found = vim.fs.find({ ".git", "package.json", "artisan", "composer.json" }, {
		path = start,
		upward = true,
	})
	if #found > 0 then
		return vim.fn.fnamemodify(vim.fs.dirname(found[1]), ":t")
	end
	return nil
end

local function oil_dir_in_tab(tab)
	local util = require("logarktos.util")
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
		local buf = vim.api.nvim_win_get_buf(win)
		if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "oil" then
			local dir = util.oil_dir(buf)
			if dir and dir ~= "" then return dir end
		end
	end
	return nil
end

--- Best-effort human title for a Markdown buffer.
function M.md_title_for_buf(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(buf) then return nil end
	local fname = vim.api.nvim_buf_get_name(buf)
	local is_md = vim.bo[buf].filetype == "markdown" or fname:lower():match("%.md$") ~= nil
	if not is_md then return nil end

	local lines = vim.api.nvim_buf_get_lines(buf, 0, 200, false)
	for _, line in ipairs(lines) do
		local h1 = line:match("^#%s+(.+)$")
		if h1 then
			h1 = vim.trim(h1)
			if h1 ~= "" and h1:lower() ~= "title" then return h1 end
		end
	end

	local stem = vim.fn.fnamemodify(fname, ":t:r")
	if stem == "" then return nil end
	local title = stem:gsub("^%d%d%d%d%d%d%d%d %- %d%d%d%d%d%d%s*%-?%s*", "")
	title = vim.trim(title)
	if title ~= "" then return title end
	return nil
end

function M.name_for_layout(kind)
	local map = {
		triplicate = "Triplicate",
		work = "Work",
		focus = "Focus",
		large = "Large",
		dual = "Dual",
		triple = "Triple",
		oil = "Oil",
	}
	return map[kind] or kind
end

function M.name_from_dir(dir)
	return basename(dir)
end

function M.suggest_name(opts)
	opts = opts or {}
	if opts.layout then
		local base = M.name_for_layout(opts.layout)
		local dir = opts.dir or oil_dir_in_tab(vim.api.nvim_get_current_tabpage())
		local dname = basename(dir)
		if dname and dname ~= "" then return base .. " — " .. dname end
		return base
	end

	local dir = opts.dir
	if not dir then dir = oil_dir_in_tab(vim.api.nvim_get_current_tabpage()) end
	if dir then
		local d = basename(dir)
		if d and d ~= "" then
			local proj = project_root_name(dir)
			if proj and proj ~= d then return proj .. " — " .. d end
			return d
		end
	end

	local proj = project_root_name()
	if proj then return proj end
	return nil
end

function M.auto_name(tab, opts)
	tab = get_tab(tab)
	opts = opts or {}
	local name = M.suggest_name(opts)
	if not name or name == "" then return false end
	local priority = opts.priority or (opts.layout and P.layout or P.folder)
	return set_if(tab, name, priority, priority >= P.folder)
end

function M.set_manual(name)
	M.set(nil, name, { priority = P.manual })
end

function M.clear_current()
	M.clear(vim.api.nvim_get_current_tabpage())
end

--- Interactive rename (prompt, locks the name as manual).
function M.rename_prompt()
	local cur = M.get() or ""
	vim.ui.input({ prompt = "Tab name: ", default = cur }, function(input)
		if input == nil then return end
		if input ~= "" then M.set_manual(input) else M.clear_current() end
	end)
end

-- ── optional tabline renderer ────────────────────────────────────────────────
--- Build a tabline string showing tier-aware names with a ● for meaningful ones.
function M.tabline()
	local parts = {}
	local cur = vim.api.nvim_get_current_tabpage()
	for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
		local hl = (tab == cur) and "%#TabLineSel#" or "%#TabLine#"
		local name = M.get(tab)
		local label
		if name then
			local bullet = M.is_locked(tab) and "● " or ""
			label = bullet .. name
		else
			label = "Tab " .. i
		end
		parts[#parts + 1] = string.format("%s %%%dT %s ", hl, i, label)
	end
	parts[#parts + 1] = "%#TabLineFill#%T"
	return table.concat(parts)
end

function M.enable_tabline()
	_G.LogarktosTabline = M.tabline
	vim.o.tabline = "%!v:lua.LogarktosTabline()"
end

return M
