-- logarktos/layouts.lua ── task-oriented tab/window layouts + focus dimming
--
-- The conceptual layouts:
--   • Large / NewLarge — a wide editor flanked by narrow scratch buffers.
--   • Focus            — editor centred with empty side buffers.
--   • Work / HereWork  — editor plus two terminals.
--   • Triple / Dual    — synchronized views of the same buffer.
-- Every layout names its new tab from its *focus buffer* (see logarktos.tabs).

local config = require("logarktos.config")
local tabs = require("logarktos.tabs")
local util = require("logarktos.util")
local envfile = require("logarktos.envfile")
local rcfile = require("logarktos.rcfile")

local M = {}

--- Name a freshly-built layout tab from its focus buffer.
local function name_layout_tab(buf, layout_opts)
	if buf and vim.api.nvim_buf_is_valid(buf) then
		local md = tabs.md_title_for_buf(buf)
		if md then
			tabs.apply_heading(md)
			return
		end
		if vim.bo[buf].filetype == "oil" then
			local folder = util.project_or_dir_name(util.oil_dir(buf))
			if folder and folder ~= "" then
				tabs.apply_folder(folder)
				return
			end
		end
	end
	tabs.auto_name(nil, layout_opts)
end

--- Load optional path overrides (logarktos.lua / legacy .env) for non-AM/WM layouts.
local function load_env(base)
	if not base or base == "" then return nil end
	return envfile.load(base)
end

-- ── focus mode (inactive-window dimming) ─────────────────────────────────────
local FOCUS = { enabled = false }

local function as_hex(s)
	return (type(s) == "string" and s:match("^#%x%x%x%x%x%x$")) and s or nil
end

local function get_hl_bg(name)
	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
	if not ok or not hl or not hl.bg then return nil end
	return string.format("#%06x", hl.bg)
end

local function hex_to_rgb(hex)
	local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
	if not r then return nil end
	return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

local function rgb_to_hex(r, g, b)
	return string.format("#%02x%02x%02x",
		math.max(0, math.min(255, r)), math.max(0, math.min(255, g)), math.max(0, math.min(255, b)))
end

local function rel_luma(hex)
	local r, g, b = hex_to_rgb(hex)
	if not r then return nil end
	local function chan(u)
		u = u / 255
		return (u <= 0.03928) and (u / 12.92) or (((u + 0.055) / 1.055) ^ 2.4)
	end
	return 0.2126 * chan(r) + 0.7152 * chan(g) + 0.0722 * chan(b)
end

local function contrast_ratio(a, b)
	local la, lb = rel_luma(a), rel_luma(b)
	if not la or not lb then return 1 end
	if la < lb then la, lb = lb, la end
	return (la + 0.05) / (lb + 0.05)
end

local function gently_contrasts(sample, base)
	local cr = contrast_ratio(sample, base)
	return cr >= 1.15 and cr <= 1.8
end

local function shift_color(hex, percent)
	local r, g, b = hex_to_rgb(hex)
	if not r then return hex end
	local delta = function(c) return math.floor(c + (percent / 100) * (percent > 0 and (255 - c) or c)) end
	return rgb_to_hex(delta(r), delta(g), delta(b))
end

local function derive_from(base)
	local l = rel_luma(base) or 0.5
	return (l < 0.5) and shift_color(base, 8) or shift_color(base, -8)
end

-- Colourscheme hint contract: a scheme may publish its preferred inactive-window
-- tint (e.g. chromaki's per-flavour green/blue/red) via vim.g.inactive_win_bg_hint,
-- with vim.g.inactive_win_bg_override / _force as hard overrides. Honouring these
-- keeps the tint scheme-driven rather than auto-derived from Normal/CursorLine.
local HINT_KEY = "inactive_win_bg_hint"
local OVERRIDE_KEYS = { "inactive_win_bg_override", "inactive_win_bg_force" }

local function pick_inactive_bg()
	local forced = as_hex(config.options.focus and config.options.focus.inactive_bg)
	for _, key in ipairs(OVERRIDE_KEYS) do
		forced = forced or as_hex(vim.g[key])
	end
	if forced then return forced end

	local normal_bg = get_hl_bg("Normal")

	-- Scheme-published hint wins, as long as it isn't washed out against Normal.
	-- "Washed out" means TOO LITTLE contrast (an invisible tint) -- so only a
	-- lower bound applies here. The 1.8 upper bound in gently_contrasts is for
	-- the auto-DERIVED dim below (which must stay subtle); an explicit scheme
	-- hint may legitimately be a strong tint (e.g. chromaki's "shaded blue"
	-- inactive, which is deliberately high-contrast against a light page). Using
	-- the full gently_contrasts range here wrongly rejected such hints and fell
	-- through to a derived near-Normal tint -- so shaded blue rendered as white.
	local hint = as_hex(vim.g[HINT_KEY])
	if hint and (not normal_bg or contrast_ratio(hint, normal_bg) >= 1.15) then
		return hint
	end

	if not normal_bg then return nil end
	for _, grp in ipairs({ "CursorLine", "StatusLine", "StatusLineNC", "Visual" }) do
		local bg = get_hl_bg(grp)
		if bg and gently_contrasts(bg, normal_bg) then return bg end
	end
	return derive_from(normal_bg)
end

function M.focus_refresh()
	if FOCUS.enabled then
		local tint = pick_inactive_bg()
		if tint then
			vim.api.nvim_set_hl(0, "NormalNC", { bg = tint, fg = "NONE" })
		else
			pcall(vim.api.nvim_set_hl, 0, "NormalNC", { link = "Normal" })
		end
	else
		pcall(vim.api.nvim_set_hl, 0, "NormalNC", { link = "Normal" })
	end
end

function M.focus_toggle()
	FOCUS.enabled = not FOCUS.enabled
	M.focus_refresh()
	vim.notify("Focus dimming: " .. (FOCUS.enabled and "ON" or "OFF"))
end

function M.focus_setup()
	FOCUS.enabled = (config.options.focus and config.options.focus.enabled) == true
	local grp = vim.api.nvim_create_augroup("LogarktosFocus", { clear = true })
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = grp,
		callback = function() vim.schedule(M.focus_refresh) end,
	})
	M.focus_refresh()
end

-- ── layout builders ──────────────────────────────────────────────────────────
function M.focus_mode_tab()
	local source_buf = vim.api.nvim_get_current_buf()
	local cwd = util.resolve_cwd(source_buf)
	local base = cwd or vim.fn.getcwd()
	local env = load_env(base)
	local left_dir = env and envfile.first_path(env.left) or nil
	local center_dir = env and envfile.first_path(env.center) or nil
	local right_dir = env and envfile.first_path(env.right) or nil
	local view = vim.fn.winsaveview()
	vim.cmd("tabnew")
	local middle_win = vim.api.nvim_get_current_win()
	if center_dir then
		util.open_dir(center_dir)
	else
		-- List panels (bookmarks) → open selected path, not the list buffer itself.
		util.open_focus_or_buf(source_buf, view)
	end
	vim.cmd("leftabove vnew")
	if left_dir then
		util.open_dir(left_dir)
	else
		local l_buf = vim.api.nvim_get_current_buf()
		vim.bo[l_buf].bufhidden = "wipe"
		vim.bo[l_buf].swapfile = false
	end
	vim.api.nvim_set_current_win(middle_win)
	vim.cmd("rightbelow vnew")
	if right_dir then
		util.open_dir(right_dir)
	else
		local r_buf = vim.api.nvim_get_current_buf()
		vim.bo[r_buf].bufhidden = "wipe"
		vim.bo[r_buf].swapfile = false
	end
	vim.api.nvim_set_current_win(middle_win)
	if not center_dir and not util.is_list_panel(source_buf) then
		vim.fn.winrestview(view)
	end
	vim.cmd("wincmd =")

	name_layout_tab(vim.api.nvim_win_get_buf(middle_win), { layout = "focus" })
end

--- Open a terminal in `win`. When `cmd` is set, run that shell command (AI CLI
--- etc.); otherwise open a plain interactive shell. Marks the buffer so AI-app
--- tab renaming can watch it when `watch_ai` is true.
---
--- When `cmd` is set, `b:logarktos_term_cmd` is written *before* termopen so
--- config-side TermOpen hooks (e.g. feeding Set-ExecutionPolicy into interactive
--- PowerShell) can skip this buffer — chansend would otherwise land in the AI
--- CLI's stdin and garble the TUI.
--- @return integer terminal buffer
local function open_term(win, cwd, cmd, opts)
	opts = opts or {}
	vim.api.nvim_set_current_win(win)
	local t_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[t_buf].bufhidden = "wipe"
	vim.api.nvim_win_set_buf(win, t_buf)
	local term_opts = { cwd = cwd }
	if cmd and cmd ~= "" then
		-- Mark before termopen so TermOpen autocmds see it (they fire mid-call).
		vim.b[t_buf].logarktos_term_cmd = cmd
		local app = opts.app or envfile.ai_app_name(cmd)
		if app then
			vim.b[t_buf].logarktos_ai_app = app
		end
		-- String form goes through 'shell'/'shellcmdflag' so PATH and flags work
		-- the same as typing the command by hand. shellcmdflag already carries
		-- -ExecutionPolicy on Windows; do not also feed policy text via chansend.
		vim.fn.termopen(cmd, term_opts)
	else
		vim.fn.termopen(vim.o.shell, term_opts)
	end
	if opts.watch_ai then
		vim.b[t_buf].logarktos_watch_ai = true
	end
	return t_buf
end

--- Best-effort: detect a running AI CLI child of a terminal job (or the job
--- itself when the terminal was opened with the AI command directly).
local function detect_ai_app_for_buf(buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then return nil end
	if vim.bo[buf].buftype ~= "terminal" then return nil end

	-- Direct launch stores the app on the buffer.
	local tagged = vim.b[buf].logarktos_ai_app
	if type(tagged) == "string" and tagged ~= "" then return tagged end

	-- Terminal title often carries the running program name.
	local title = vim.b[buf].term_title
	if type(title) == "string" and title ~= "" then
		local from_title = envfile.ai_app_name(title)
		if from_title then return from_title end
		-- Titles like "codex — project" or "Administrator: codex".
		for app in pairs(envfile.AI_APPS) do
			if title:lower():find(app, 1, true) then return app end
		end
	end

	-- Check the terminal job process itself (direct `termopen("codex …")`) and
	-- its children (AI CLI launched from an interactive shell).
	local ok_job, job_id = pcall(function() return vim.b[buf].terminal_job_id end)
	if not ok_job or not job_id then return nil end
	local ok_pid, pid = pcall(vim.fn.jobpid, job_id)
	if not ok_pid or not pid or pid <= 0 then return nil end

	local names = {}
	if util.is_windows then
		local ps = table.concat({
			("$p = Get-CimInstance Win32_Process -Filter \"ProcessId=%d\";"):format(pid),
			"if ($p) { $p.Name }",
			("Get-CimInstance Win32_Process -Filter \"ParentProcessId=%d\" | Select-Object -ExpandProperty Name"):format(pid),
		}, "; ")
		local res = vim.system({ "powershell", "-NoProfile", "-Command", ps }, { text = true }):wait()
		if res and res.code == 0 and res.stdout then
			for name in res.stdout:gmatch("[^\r\n]+") do
				names[#names + 1] = name
			end
		end
	else
		local res = vim.system({
			"sh", "-c",
			("ps -o comm= -p %d; ps -o comm= --ppid %d"):format(pid, pid),
		}, { text = true }):wait()
		if res and res.code == 0 and res.stdout then
			for name in res.stdout:gmatch("[^\r\n]+") do
				names[#names + 1] = name
			end
		end
	end
	for _, name in ipairs(names) do
		local app = envfile.ai_app_name(name)
		if app then return app end
	end
	return nil
end

local function apply_ai_app_from_buf(buf, tab)
	local app = detect_ai_app_for_buf(buf)
	if app then tabs.apply_ai_app(app, tab) end
end

--- Watch AI-mode (and Work-mode) terminals so typing `codex` / `grok` etc.
--- updates the tab title to `codex-<base>`.
local AI_WATCH_GROUP = nil
local function ensure_ai_watch()
	if AI_WATCH_GROUP then return end
	AI_WATCH_GROUP = vim.api.nvim_create_augroup("LogarktosAIWatch", { clear = true })
	vim.api.nvim_create_autocmd({ "TermLeave", "TermEnter", "BufEnter", "FocusGained" }, {
		group = AI_WATCH_GROUP,
		callback = function(args)
			local buf = args.buf
			if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
			if not vim.b[buf].logarktos_watch_ai and not vim.b[buf].logarktos_ai_app then
				return
			end
			local tab = vim.api.nvim_get_current_tabpage()
			-- Defer so the child process has a moment to appear after Enter.
			vim.defer_fn(function()
				apply_ai_app_from_buf(buf, tab)
			end, 200)
		end,
	})
	-- Lightweight poll while any watched terminal is still open.
	vim.api.nvim_create_autocmd("TermOpen", {
		group = AI_WATCH_GROUP,
		callback = function(args)
			local buf = args.buf
			vim.defer_fn(function()
				if vim.api.nvim_buf_is_valid(buf)
					and (vim.b[buf].logarktos_watch_ai or vim.b[buf].logarktos_ai_app)
				then
					local tab = nil
					for _, t in ipairs(vim.api.nvim_list_tabpages()) do
						for _, win in ipairs(vim.api.nvim_tabpage_list_wins(t)) do
							if vim.api.nvim_win_get_buf(win) == buf then
								tab = t
								break
							end
						end
						if tab then break end
					end
					if tab then apply_ai_app_from_buf(buf, tab) end
				end
			end, 400)
		end,
	})
end

--- Shared Work layout: editor on the left, two terminals stacked on the right.
--- Uses / seeds the folder's logarktos.lua `work` section (create on first run).
local function build_work_layout(opts)
	opts = opts or {}
	local buf = vim.api.nvim_get_current_buf()
	local cwd = util.resolve_cwd(buf)
	local base = cwd or vim.fn.getcwd()
	local work = rcfile.ensure_work(base)
	local view = vim.fn.winsaveview()

	if opts.new_tab then
		vim.cmd("tabnew")
	else
		vim.cmd("only")
	end

	local left_win = vim.api.nvim_get_current_win()
	if opts.new_tab then
		-- Default: keep the source buffer. From a bookmark/recent list, open the
		-- selected path (Oil for folders, :edit for files) instead of cloning the list.
		util.open_focus_or_buf(buf, view)
	elseif util.is_list_panel(buf) then
		-- HereWork: still replace a list panel with the selection in-place.
		util.open_focus_or_buf(buf, view)
	end
	if cwd then pcall(vim.cmd, "lcd " .. vim.fn.fnameescape(cwd)) end

	-- Optional left path: open Oil there instead of the source buffer.
	if work.left and work.left.path then
		vim.api.nvim_set_current_win(left_win)
		util.open_dir(work.left.path)
	end

	vim.cmd("rightbelow vsplit")
	vim.cmd("rightbelow vsplit")
	local rt = vim.api.nvim_get_current_win()
	vim.cmd("belowright split")
	local rb = vim.api.nvim_get_current_win()

	local top_spec = work.top or { cwd = base, cmd = nil, app = nil }
	local bot_spec = work.bot or { cwd = base, cmd = nil, app = nil }

	ensure_ai_watch()
	open_term(rt, top_spec.cwd, top_spec.cmd, { app = top_spec.app, watch_ai = true })
	open_term(rb, bot_spec.cwd, bot_spec.cmd, { app = bot_spec.app, watch_ai = true })
	vim.api.nvim_set_current_win(left_win)
	vim.cmd("wincmd =")

	return {
		buf = buf,
		cwd = cwd,
		base = base,
		top_app = top_spec.app,
		bot_app = bot_spec.app,
	}
end

function M.work_mode_tab()
	local info = build_work_layout({ new_tab = true })
	-- Name from the left pane after open (bookmark list → Oil/file, not the list).
	local left_buf = vim.api.nvim_get_current_buf()
	name_layout_tab(left_buf, { layout = "work", dir = info.cwd })
	-- Prefer the top terminal's AI app for the tab label when auto-started.
	local app = info.top_app or info.bot_app
	if app then tabs.apply_ai_app(app) end
end

function M.here_work_mode()
	local info = build_work_layout({ new_tab = false })
	-- HereWork transforms the current tab in place, so it must (re)name it from
	-- the buffer we started on. Prefer the git-aware project-root name (so a deep
	-- file or an Oil listing inside RunningWild/ names the tab "RunningWild"),
	-- falling back to the plain folder name when we're not inside a project.
	local folder = util.project_or_dir_name(info.cwd or vim.fn.getcwd())
	if folder and folder ~= "" then tabs.apply_folder(folder) end
	local app = info.top_app or info.bot_app
	if app then tabs.apply_ai_app(app) end
end

--- Open `dir` in Oil in the current window; else the focus path of `buf`
--- (bookmark/recent selection), or keep `buf` when it is real content.
local function open_pane_dir_or_buf(dir, buf, view)
	if dir then
		util.open_dir(dir)
		return
	end
	util.open_focus_or_buf(buf, view)
end

function M.triple_mode_tab()
	local buf = vim.api.nvim_get_current_buf()
	local cwd = util.resolve_cwd(buf)
	local base = cwd or vim.fn.getcwd()
	local env = load_env(base)
	local left_dir = env and envfile.first_path(env.left) or nil
	local center_dir = env and envfile.first_path(env.center) or nil
	local right_dir = env and envfile.first_path(env.right) or nil
	local view = vim.fn.winsaveview()
	vim.cmd("tabnew")
	local mid = vim.api.nvim_get_current_win()
	open_pane_dir_or_buf(center_dir, buf, view)
	if cwd then
		pcall(vim.cmd, "lcd " .. vim.fn.fnameescape(cwd))
		vim.t.pwd_mode = "local"
	end
	vim.cmd("leftabove vsplit")
	open_pane_dir_or_buf(left_dir, buf, view)
	vim.api.nvim_set_current_win(mid)
	vim.cmd("rightbelow vsplit")
	open_pane_dir_or_buf(right_dir, buf, view)
	vim.api.nvim_set_current_win(mid)
	vim.cmd("wincmd =")

	name_layout_tab(vim.api.nvim_win_get_buf(mid), { layout = "triple", dir = cwd })
end

function M.dual_mode_tab()
	local buf = vim.api.nvim_get_current_buf()
	local cwd = util.resolve_cwd(buf)
	local base = cwd or vim.fn.getcwd()
	local env = load_env(base)
	local left_dir = env and envfile.first_path(env.left) or nil
	local right_dir = env and envfile.first_path(env.right) or nil
	local view = vim.fn.winsaveview()
	vim.cmd("tabnew")
	local left = vim.api.nvim_get_current_win()
	open_pane_dir_or_buf(left_dir, buf, view)
	if cwd then
		pcall(vim.cmd, "lcd " .. vim.fn.fnameescape(cwd))
		vim.t.pwd_mode = "local"
	end
	vim.cmd("rightbelow vsplit")
	open_pane_dir_or_buf(right_dir, buf, view)
	vim.api.nvim_set_current_win(left)
	vim.cmd("wincmd =")

	name_layout_tab(vim.api.nvim_win_get_buf(left), { layout = "dual", dir = cwd })
end

function M.large_mode_tab()
	local buf = vim.api.nvim_get_current_buf()
	local cwd = util.resolve_cwd(buf)
	local base = cwd or vim.fn.getcwd()
	local env = load_env(base)
	local left_dir = env and envfile.first_path(env.left) or nil
	local center_dir = env and envfile.first_path(env.center) or nil
	local right_dir = env and envfile.first_path(env.right) or nil
	local view = vim.fn.winsaveview()
	vim.cmd("tabnew")
	local mid = vim.api.nvim_get_current_win()
	if center_dir then
		util.open_dir(center_dir)
	else
		util.open_focus_or_buf(buf, view)
	end
	vim.cmd("leftabove vnew")
	local left = vim.api.nvim_get_current_win()
	if left_dir then
		util.open_dir(left_dir)
	else
		vim.bo.bufhidden = "wipe"
		vim.bo.swapfile = false
	end
	vim.api.nvim_set_current_win(mid)
	vim.cmd("rightbelow vnew")
	local right = vim.api.nvim_get_current_win()
	if right_dir then
		util.open_dir(right_dir)
	else
		vim.bo.bufhidden = "wipe"
		vim.bo.swapfile = false
	end
	local q = math.floor(vim.o.columns * 0.25)
	vim.api.nvim_win_set_width(left, q)
	vim.api.nvim_win_set_width(right, q)
	vim.api.nvim_set_current_win(mid)

	name_layout_tab(vim.api.nvim_win_get_buf(mid), { layout = "large" })
end

function M.new_large_tab()
	local base = vim.fn.getcwd()
	local env = load_env(base)
	local left_dir = env and envfile.first_path(env.left) or nil
	local center_dir = env and envfile.first_path(env.center) or nil
	local right_dir = env and envfile.first_path(env.right) or nil

	vim.cmd("tabnew")
	local mid = vim.api.nvim_get_current_win()
	if center_dir then util.open_dir(center_dir) end
	vim.cmd("leftabove vnew")
	local left = vim.api.nvim_get_current_win()
	if left_dir then util.open_dir(left_dir) end
	vim.api.nvim_set_current_win(mid)
	vim.cmd("rightbelow vnew")
	local right = vim.api.nvim_get_current_win()
	if right_dir then util.open_dir(right_dir) end
	local q = math.floor(vim.o.columns * 0.25)
	vim.api.nvim_win_set_width(left, q)
	vim.api.nvim_win_set_width(right, q)
	vim.api.nvim_set_current_win(mid)

	name_layout_tab(vim.api.nvim_win_get_buf(mid), { layout = "large" })
end

--- AI mode: three columns. Left = terminal (optional command), centre / right =
--- Oil. Pane targets come from the folder's logarktos.lua `aimode` section;
--- when that section is missing it is created as plain defaults (interactive
--- terminal + Oil on the layout folder for both columns — no path heuristics).
function M.ai_mode_tab()
	local cwd = util.resolve_cwd(vim.api.nvim_get_current_buf())
	local base = cwd or vim.fn.getcwd()
	local am = rcfile.ensure_aimode(base)

	local left_spec = am.left or { cwd = base, cmd = nil, app = nil }
	local center_dir = (am.center and am.center.path) or base
	local right_dir = (am.right and am.right.path) or base

	vim.cmd("tabnew")
	local mid = vim.api.nvim_get_current_win()
	vim.cmd("leftabove vnew")
	local left = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_win(mid)
	vim.cmd("rightbelow vnew") -- the third (right) column
	local right = vim.api.nvim_get_current_win()

	vim.api.nvim_set_current_win(mid)
	util.open_dir(center_dir)
	vim.api.nvim_set_current_win(right)
	util.open_dir(right_dir)

	ensure_ai_watch()
	open_term(left, left_spec.cwd or base, left_spec.cmd, {
		app = left_spec.app,
		watch_ai = true,
	})

	-- The terminal and centre columns share the same width (an even third plus
	-- one right-arrow width-step, "+10"); the right Oil column takes whatever is
	-- left, so it ends up the narrowest of the three.
	local wide = math.floor(vim.o.columns / 3) + 10
	vim.api.nvim_win_set_width(left, wide)
	vim.api.nvim_win_set_width(mid, wide)

	-- Name the tab the same git-aware way HereWork does: the project-root folder
	-- name when the PWD is inside a project, else the plain folder name.
	local folder = util.project_or_dir_name(base)
	if folder and folder ~= "" then tabs.apply_folder(folder) end
	-- If logarktos.lua auto-started an AI CLI, prefix immediately: codex-Title.
	if left_spec.app then tabs.apply_ai_app(left_spec.app) end

	-- Land in the terminal, ready to type. Deferred so the layout has settled
	-- before we enter Terminal-Job (insert) mode.
	vim.schedule(function()
		if vim.api.nvim_win_is_valid(left) then
			vim.api.nvim_set_current_win(left)
			vim.cmd("startinsert")
		end
	end)
end

function M.large_triplicate_tab()
	require("logarktos.triplicate").open_new_tab({ large = true })
end

-- Re-even the current tab's columns after they've drifted out of shape.
--   • two columns      → equal halves
--   • three columns    → equal thirds (Triple/Triplicate proportions)
--   • a column Work mode split in two → its stacked halves balanced too
-- :wincmd = equalises every window regardless of 'equalalways', so it restores
-- even columns and rebalances any vertical split without flattening it.
function M.fix_layout()
	local tab = vim.api.nvim_get_current_tabpage()
	local layout = vim.fn.winlayout(tab)
	local cols = (layout[1] == "row") and #layout[2] or 1

	vim.cmd("wincmd =")

	util.notify(("Layout evened (%d column%s)"):format(cols, cols == 1 and "" or "s"),
		vim.log.levels.INFO, "FixLayout")
end

return M
