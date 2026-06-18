-- logarktos/keymaps.lua ── optional default keymaps (opt-in via setup)
local config = require("logarktos.config")

local M = {}

local function L() return require("logarktos.layouts") end
local function T() return require("logarktos.tabs") end
local function B() return require("logarktos.bufferfiles") end
local function BM() return require("logarktos.bookmarks") end
local function MD() return require("logarktos.markdown") end
local function ORG() return require("logarktos.organize") end
local function CWD() return require("logarktos.cwd") end
local function TRI() return require("logarktos.triplicate") end

local function open_oil_here()
	if vim.fn.exists(":Oil") == 2 then vim.cmd("Oil") else vim.cmd("edit .") end
end

-- action key → { mode, rhs, desc }. rhs is a function or a string.
local function actions()
	return {
		-- layouts
		triplicate          = { "n", function() TRI().open_new_tab() end, "Triplicate (new tab)" },
		triplicate_new      = { "n", function() TRI().open_new_tab() end, "Triplicate (new tab)" },
		triplicate_large    = { "n", function() TRI().open_new_tab({ large = true }) end, "Triplicate (large)" },
		large               = { "n", function() L().large_mode_tab() end, "Large layout" },
		new_large           = { "n", function() L().new_large_tab() end, "Large layout (3 empty)" },
		ai_mode             = { "n", function() L().ai_mode_tab() end, "AI layout (terminal + 2 scratch)" },
		work                = { "n", function() L().work_mode_tab() end, "Work layout" },
		here_work           = { "n", function() L().here_work_mode() end, "Here Work layout" },
		triple              = { "n", function() L().triple_mode_tab() end, "Triple synced views" },
		dual                = { "n", function() L().dual_mode_tab() end, "Dual synced views" },
		focus               = { "n", function() L().focus_mode_tab() end, "Focus layout" },
		focus_toggle        = { "n", function() L().focus_toggle() end, "Toggle inactive dimming" },
		fix_layout          = { "n", function() L().fix_layout() end, "Fix layout (even columns)" },

		-- tabs
		tab_rename          = { "n", function() T().rename_prompt() end, "Rename tab" },
		tab_name_from_dir   = { "n", function()
			local dir = (vim.bo.filetype == "oil") and require("logarktos.util").oil_dir(0) or vim.fn.getcwd()
			T().auto_name(nil, { dir = dir })
		end, "Name tab from current dir" },
		tab_new             = { "n", "<cmd>tabnew<CR>", "New tab" },
		oil_tab             = { "n", function()
			vim.cmd("tabnew")
			open_oil_here()
			T().auto_name(nil, { layout = "oil" })
		end, "New tab (Oil)" },
		tab_close           = { "n", function()
			if #vim.api.nvim_list_tabpages() > 1 then vim.cmd("tabclose") else vim.cmd("confirm qall") end
		end, "Close tab (quit if last)" },

		-- windows
		here_empty          = { "n", "<cmd>enew<CR>", "Empty buffer here" },
		here_oil            = { "n", open_oil_here, "Oil here" },
		here_terminal       = { "n", "<cmd>terminal<CR>", "Terminal here" },
		split_empty         = { "n", "<cmd>vnew<CR>", "Split (empty)" },
		split_oil           = { "n", function() vim.cmd("vsplit"); open_oil_here() end, "Split (Oil)" },
		split_terminal      = { "n", "<cmd>vsplit | terminal<CR>", "Split (terminal)" },
		split_close         = { "n", "<cmd>close<CR>", "Close window" },

		-- bufferfiles
		bufferfiles_open    = { "n", function() B().open_root() end, "Open bufferfiles" },
		bufferfiles_delete  = { "n", function() B().delete_all() end, "Delete bufferfiles" },

		-- bookmarks
		bookmark_add_file   = { { "n", "v" }, function() BM().bookmark_add() end, "Bookmark file" },
		bookmark_add_dir    = { { "n", "v" }, function() BM().bookmark_add_dir() end, "Bookmark folder" },
		bookmark_delete     = { { "n", "v" }, function() BM().bookmark_del() end, "Delete bookmark" },
		bookmark_list       = { "n", function() BM().bookmark_list() end, "List bookmarks" },

		-- markdown + organize
		new_markdown        = { "n", function() MD().new_markdown() end, "New Markdown note" },
		markdown_archive    = { "n", function() MD().markdown_archive() end, "Archive current file" },
		organize            = { "n", function() ORG().organize() end, "Organize directory" },
		organize_images     = { "n", function() ORG().organize_images() end, "Sort images" },
		separate_duplicates = { "n", function() ORG().separate_duplicates() end, "Separate duplicates" },

		-- cwd mode
		cwd_local           = { "n", function() CWD().local_here() end, "CWD: Local" },
		cwd_root            = { "n", function() CWD().root_here() end, "CWD: Root" },
		cwd_local_and_oil   = { "n", function() CWD().local_here(); open_oil_here() end, "CWD: Local + Oil" },

		-- window resize with arrows
		resize_left         = { "n", "<cmd>vertical resize -10<CR>", "Resize narrower" },
		resize_right        = { "n", "<cmd>vertical resize +10<CR>", "Resize wider" },
		resize_up           = { "n", "<cmd>resize +10<CR>", "Resize taller" },
		resize_down         = { "n", "<cmd>resize -10<CR>", "Resize shorter" },

		-- optional AI
		suggest_filename    = { "n", function() require("logarktos.ai").suggest_filename() end, "AI: suggest filename" },
	}
end

function M.setup()
	local keys = config.resolve_keymaps()
	if not keys then return end
	local acts = actions()
	for action_key, lhs in pairs(keys) do
		local spec = acts[action_key]
		if lhs and lhs ~= false and lhs ~= "" and spec then
			local mode, rhs, desc = spec[1], spec[2], spec[3]
			vim.keymap.set(mode, lhs, rhs, { silent = true, desc = "Logarktos: " .. desc })
		end
	end
end

return M
