-- logarktos/commands.lua ── user commands (namespaced, with optional short aliases)
local config = require("logarktos.config")

local M = {}

local function layouts() return require("logarktos.layouts") end
local function triplicate() return require("logarktos.triplicate") end
local function bufferfiles() return require("logarktos.bufferfiles") end
local function bookmarks() return require("logarktos.bookmarks") end
local function markdown() return require("logarktos.markdown") end
local function organize() return require("logarktos.organize") end
local function tabs() return require("logarktos.tabs") end
local function cwd() return require("logarktos.cwd") end

local function recent_files_panel(dir)
	if not dir or dir == "" then
		dir = (vim.bo.filetype == "oil") and (require("logarktos.util").oil_dir(0) or vim.fn.getcwd())
			or vim.fn.getcwd()
	end
	vim.cmd("vsplit")
	require("logarktos.recentfiles").list_in_window(vim.api.nvim_get_current_win(), { dir = dir })
end

-- Each entry: { long, short, fn, opts }. `short` may be nil (no alias).
local function specs()
	return {
		-- layouts / workspaces
		{ "Triplicate", "Triplicate", function(a)
			local dir = (a.args ~= "") and vim.fn.fnamemodify(vim.fn.expand(a.args), ":p") or nil
			triplicate().open_new_tab({ dir = dir })
		end, { nargs = "?", complete = "dir", desc = "Open the Triplicate layout in a new tab" } },
		{ "TriplicateLarge", nil, function() triplicate().open_new_tab({ large = true }) end, { desc = "Triplicate (large)" } },
		{ "Large", nil, function() layouts().large_mode_tab() end, { desc = "Large layout tab" } },
		{ "NewLarge", nil, function() layouts().new_large_tab() end, { desc = "Large layout tab (3 empty)" } },
		{ "Work", nil, function() layouts().work_mode_tab() end, { desc = "Work layout (editor + 2 terminals)" } },
		{ "HereWork", nil, function() layouts().here_work_mode() end, { desc = "Work layout in the current tab" } },
		{ "Triple", nil, function() layouts().triple_mode_tab() end, { desc = "Triple synced views" } },
		{ "Dual", nil, function() layouts().dual_mode_tab() end, { desc = "Dual synced views" } },
		{ "Focus", nil, function() layouts().focus_mode_tab() end, { desc = "Focus layout (centred editor)" } },
		{ "FocusToggle", nil, function() layouts().focus_toggle() end, { desc = "Toggle inactive-window dimming" } },
		{ "FixLayout", "FixLayout", function() layouts().fix_layout() end, { desc = "Even out the current tab's columns" } },

		-- bufferfiles
		{ "BufferFiles", "BufferFiles", function() bufferfiles().open_root() end, { desc = "Open the bufferfiles root" } },
		{ "DeleteBufferfiles", "DeleteBufferfiles", function() bufferfiles().delete_all() end, { desc = "Delete temporary bufferfiles" } },

		-- bookmarks
		{ "Bookmarks", nil, function() bookmarks().bookmark_list() end, { desc = "List bookmarks" } },
		{ "BookmarkAdd", nil, function() bookmarks().bookmark_add() end, { desc = "Bookmark current/Oil file" } },
		{ "BookmarkAddDir", nil, function() bookmarks().bookmark_add_dir() end, { desc = "Bookmark current/Oil folder" } },
		{ "BookmarkDelete", nil, function() bookmarks().bookmark_del() end, { desc = "Delete a bookmark" } },

		-- markdown + organize
		{ "NewMarkdown", "NewMarkdown", function() markdown().new_markdown() end, { desc = "New timestamped Markdown note" } },
		{ "MarkdownArchive", "MarkdownArchive", function() markdown().markdown_archive() end, { desc = "Move current file to ./archive" } },
		{ "Organize", "Organize", function() organize().organize() end, { desc = "Organize directory into dated buckets" } },
		{ "OrganizeImages", "OrganizeImages", function() organize().organize_images() end, { desc = "Sort images by orientation" } },
		{ "Extract", "Extract", function() organize().extract_archives() end, { desc = "Extract archives in the Oil directory" } },
		{ "Timestamp", "Timestamp", function() organize().timestamp_folders() end, { desc = "Prefix folders with their created date" } },
		{ "SeparateDuplicates", "SeparateDuplicates", function() organize().separate_duplicates() end, { desc = "Move duplicate files to ./Duplicates" } },
		{ "Recent10", "Recent10", function(a) organize().recent10(a.args) end, { nargs = "?", complete = "dir", desc = "10 most recent files (recursive)" } },
		{ "RecentFiles", nil, function(a) recent_files_panel(a.args) end, { nargs = "?", complete = "dir", desc = "Recent files panel for a directory" } },

		-- tabs
		{ "TabRename", "TabRename", function(a)
			if a.args ~= "" then tabs().set_manual(a.args) else tabs().rename_prompt() end
		end, { nargs = "?", desc = "Rename current tab (locks the name)" } },
		{ "TabNameClear", "TabNameClear", function() tabs().clear_current() end, { desc = "Clear the current tab's name" } },
		{ "TabNameFromDir", nil, function()
			local dir = (vim.bo.filetype == "oil") and require("logarktos.util").oil_dir(0) or vim.fn.getcwd()
			tabs().auto_name(nil, { dir = dir })
		end, { desc = "Name current tab from the current directory" } },

		-- cwd mode
		{ "Local", nil, function() cwd().local_here() end, { desc = "Pin window cwd to current folder (Local)" } },
		{ "Root", nil, function() cwd().root_here() end, { desc = "Pin window cwd to project root (Root)" } },

		-- optional AI
		{ "SuggestFilename", "SuggestFilename", function() require("logarktos.ai").suggest_filename() end, { desc = "AI: suggest a filename (needs ai.enabled)" } },
	}
end

function M.setup()
	if not config.options.commands then return end
	local short = config.options.short_commands == true
	for _, s in ipairs(specs()) do
		local long, alias, fn, opts = s[1], s[2], s[3], s[4]
		vim.api.nvim_create_user_command("Logarktos" .. long, fn, opts or {})
		if short and alias then
			pcall(vim.api.nvim_create_user_command, alias, fn, opts or {})
		end
	end
end

return M
