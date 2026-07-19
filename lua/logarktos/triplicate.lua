-- logarktos/triplicate.lua ── the signature opening workspace
--   left:   Oil directory listing
--   middle: bookmarks panel
--   right:  recent files under the directory
local config = require("logarktos.config")
local tabs = require("logarktos.tabs")
local util = require("logarktos.util")

local M = {}

local function determine_start_dir()
	-- Prefer setup / user logarktos.lua (start_dir → triplicate.dir).
	local cfg = config.options.triplicate and config.options.triplicate.dir
	if cfg and cfg ~= "" then return cfg end
	-- Legacy env fallback for shells that still export it.
	if vim.env.NVIM_START_DIR and vim.env.NVIM_START_DIR ~= "" then
		return vim.env.NVIM_START_DIR
	end
	return vim.fn.getcwd()
end

local function create_vertical_triplet()
	vim.cmd("silent! only")
	vim.cmd("vsplit")
	local right_win = vim.api.nvim_get_current_win()
	vim.cmd("wincmd h")
	vim.cmd("vsplit")
	local middle_win = vim.api.nvim_get_current_win()
	vim.cmd("wincmd h")
	local left_win = vim.api.nvim_get_current_win()
	return left_win, middle_win, right_win
end

function M.open(opts)
	opts = opts or {}
	local dir = opts.dir or determine_start_dir()
	if vim.fn.isdirectory(dir) ~= 1 then
		util.notify("Directory does not exist → " .. dir, vim.log.levels.ERROR, "Triplicate")
		return false
	end

	local left_win, middle_win, right_win = create_vertical_triplet()
	vim.w[left_win].triplicate_role = "left"
	vim.w[middle_win].triplicate_role = "middle"
	vim.w[right_win].triplicate_role = "right"

	local escaped = vim.fn.fnameescape(dir)
	vim.api.nvim_set_current_win(left_win)
	util.open_dir(dir)
	pcall(vim.cmd, "lcd " .. escaped)

	local cfg = config.options.triplicate or {}
	vim.api.nvim_set_current_win(middle_win)
	require("logarktos.bookmarks").bookmark_list_in_window(middle_win)

	vim.api.nvim_set_current_win(right_win)
	require("logarktos.recentfiles").list_in_window(right_win, {
		dir = dir,
		limit = cfg.recent_limit or 20,
		extensions = cfg.recent_extensions or { ".md" },
	})

	if opts.large then
		local quarter = math.floor(vim.o.columns * 0.25)
		vim.api.nvim_win_set_width(left_win, quarter)
		vim.api.nvim_win_set_width(right_win, quarter)
		vim.api.nvim_set_current_win(middle_win)
	else
		vim.api.nvim_set_current_win(left_win)
	end

	tabs.auto_name(nil, { layout = "triplicate", dir = dir })
	-- Let a per-window colorscheme (chromaki's spotlight) re-resolve the inactive
	-- panes once they're all built; mirrors layouts.lua's announce_layout_built().
	vim.schedule(function()
		pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "LogarktosLayoutBuilt", modeline = false })
	end)
	return true
end

function M.open_new_tab(opts)
	opts = opts or {}
	local previous_tab = vim.api.nvim_get_current_tabpage()
	vim.cmd("tabnew")
	local new_tab = vim.api.nvim_get_current_tabpage()

	if M.open(opts) then
		tabs.auto_name(new_tab, { layout = "triplicate", dir = opts.dir or determine_start_dir() })
		return true
	end

	if vim.api.nvim_tabpage_is_valid(new_tab) then pcall(vim.cmd, "tabclose") end
	if vim.api.nvim_tabpage_is_valid(previous_tab) then
		pcall(vim.api.nvim_set_current_tabpage, previous_tab)
	end
	return false
end

function M.start_dir()
	return determine_start_dir()
end

return M
