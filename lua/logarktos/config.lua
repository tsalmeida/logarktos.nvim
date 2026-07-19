-- logarktos/config.lua ── default options + user merge
local M = {}

--- The default keymaps. Only applied when `keymaps = true` (use all defaults) or
--- when `keymaps` is a table (merged over these). Set any value to `false` to
--- disable that single mapping.
M.default_keymaps = {
	-- layouts / workspaces
	triplicate          = "<leader>tt",
	triplicate_new      = "<leader>tr",
	triplicate_large    = "<leader>lt",
	large               = "<leader>lm",
	new_large           = "<leader>nl",
	ai_mode             = "<leader>am",
	work                = "<leader>wm",
	here_work           = "<leader>hw",
	triple              = "<leader>tm",
	dual                = "<leader>dm",
	focus               = "<leader>fm",
	focus_toggle        = "<leader>fo",
	fix_layout          = "<leader>fl",
	-- tabs
	tab_rename          = "<leader>tn",
	tab_name_from_dir   = "<leader>tN",
	tab_new             = "<leader>te",
	oil_tab             = "<leader>to",
	tab_close           = "<leader>tq",
	-- windows ("here" = current window, "split" = right split)
	here_empty          = "<leader>he",
	here_oil            = "<leader>ho",
	here_terminal       = "<leader>ht",
	split_empty         = "<leader>we",
	split_oil           = "<leader>wo",
	split_terminal      = "<leader>wt",
	split_close         = "<leader>wq",
	-- bufferfiles
	bufferfiles_open    = "<leader>bu",
	-- bookmarks
	bookmark_add_file   = "<leader>bf",
	bookmark_add_dir    = "<leader>bF",
	bookmark_delete     = "<leader>bd",
	bookmark_list       = "<leader>bl",
	-- markdown + organize
	new_markdown        = "<leader>nm",
	markdown_archive    = "<leader>ma",
	organize            = "<leader>or",
	organize_images     = "<leader>ri",
	separate_duplicates = "<leader>sd",
	-- cwd / location mode
	cwd_local           = "<leader>ul",
	cwd_root            = "<leader>ur",
	cwd_local_and_oil   = "<leader>uo",
	-- window resize with the arrow keys
	resize_left         = "<left>",
	resize_right        = "<right>",
	resize_up           = "<up>",
	resize_down         = "<down>",
	-- optional AI
	suggest_filename    = false,
	send_to_ai          = false,
}

M.defaults = {
	-- Master switches ---------------------------------------------------------
	-- false (none) | true (all defaults) | table (override individual mappings)
	keymaps = false,
	-- Register the namespaced :Logarktos* user commands.
	commands = true,
	-- Also register short, unprefixed command aliases (:Triplicate, :Organize…).
	-- Off by default to avoid clashing with other plugins.
	short_commands = false,
	-- Open a layout on startup. false | { layout = "triplicate", dir = …, large = true }
	startup = false,

	bufferfiles = {
		enabled = true,
		-- Root folder for scratch bufferfiles. Defaults to a private state dir.
		-- Prefer setting this in stdpath("config")/logarktos.lua; $BUFFERFILES_DIR
		-- is still accepted as a legacy fallback when dir is nil.
		dir = nil,
		-- Keep at most this many files in the root; older ones move to archive/.
		keep = 20,
		-- Filename prefix the module auto-creates: <prefix>YYYYMMDD-HHMMSS.md
		prefix = "buffer-",
	},

	triplicate = {
		-- Starting directory for :Triplicate. Defaults to $NVIM_START_DIR or cwd.
		dir = nil,
		-- Right pane shows the most recent files under `dir` of these extensions.
		recent_extensions = { ".md" },
		recent_limit = 20,
	},

	recentfiles = {
		extensions = nil, -- nil = every file type
		ignore_dirs = { ".git", "node_modules" },
		limit = 20,
	},

	bookmarks = {
		enabled = true,
		-- JSON store path. Defaults to stdpath('data')/logarktos/bookmarks.json
		store = nil,
	},

	focus = {
		-- Inactive-window dimming. Colourscheme-sensitive, so off by default.
		enabled = false,
		-- Optional explicit inactive background (e.g. "#1c1c1c"). When nil, the
		-- tint is taken from the colourscheme's vim.g.inactive_win_bg_hint (with
		-- vim.g.inactive_win_bg_override / _force as hard overrides) if set, and
		-- otherwise auto-derived from Normal/CursorLine/StatusLine/Visual.
		inactive_bg = nil,
	},

	tabs = {
		-- Inferred (folder/heading/note) names are capped to this many chars.
		max_title_chars = 12,
		-- Install the bundled tabline renderer (shows names + ● markers).
		-- Off by default so it never fights an existing tabline plugin.
		tabline = false,
	},

	markdown = {
		-- Template file looked up in the target directory for :NewMarkdown.
		template = "template.md",
		-- os.date() format for the timestamp prefix of new notes.
		timestamp = "%Y%m%d - %H%M%S",
		-- Marker in template.md that pins where typing should start: it is
		-- stripped on creation and the cursor drops there in insert mode.
		focus_marker = "*template_focus*",
	},

	organize = {
		files_bucket = "Auto Ordered Files",
		folders_bucket = "Auto Ordered Folders",
		logs_bucket = "Auto Ordered Logs",
	},

	-- Optional AI helpers (filename suggester + space+ai send). Disabled by
	-- default in the plugin; the user's logarktos.lua usually enables them.
	-- The API key is never stored in logarktos.lua — only the env var *name*.
	ai = {
		enabled = false,
		api_key_env = "OPENAI_API_KEY",
		-- Optional override from the environment (e.g. OPENAI_MODEL); when
		-- unset, `model` below is used.
		model_env = "OPENAI_MODEL",
		model = "gpt-4o-mini",
		max_input_chars = 1000,
		max_name_len = 60,
		default_instruction = "Please comment on the following content:",
	},
}

-- The live, merged configuration (populated by setup()).
M.options = vim.deepcopy(M.defaults)

--- Merge user opts over the defaults and return the resolved config.
function M.merge(opts)
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
	return M.options
end

--- Resolve the effective keymap table given the `keymaps` option.
function M.resolve_keymaps()
	local k = M.options.keymaps
	if k == false or k == nil then
		return nil
	end
	if k == true then
		return vim.deepcopy(M.default_keymaps)
	end
	if type(k) == "table" then
		return vim.tbl_extend("force", vim.deepcopy(M.default_keymaps), k)
	end
	return nil
end

return M
