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
	local view = vim.fn.winsaveview()
	vim.cmd("tabnew")
	local middle_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(middle_win, source_buf)
	vim.fn.winrestview(view)
	vim.cmd("leftabove vnew")
	local l_buf = vim.api.nvim_get_current_buf()
	vim.bo[l_buf].bufhidden = "wipe"
	vim.bo[l_buf].swapfile = false
	vim.api.nvim_set_current_win(middle_win)
	vim.cmd("rightbelow vnew")
	local r_buf = vim.api.nvim_get_current_buf()
	vim.bo[r_buf].bufhidden = "wipe"
	vim.bo[r_buf].swapfile = false
	vim.api.nvim_set_current_win(middle_win)
	vim.fn.winrestview(view)
	vim.cmd("wincmd =")

	name_layout_tab(source_buf, { layout = "focus" })
end

local function open_term(win, cwd)
	vim.api.nvim_set_current_win(win)
	local t_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[t_buf].bufhidden = "wipe"
	vim.api.nvim_win_set_buf(win, t_buf)
	vim.fn.termopen(vim.o.shell, { cwd = cwd })
end

function M.work_mode_tab()
	local buf = vim.api.nvim_get_current_buf()
	local cwd = util.resolve_cwd(buf)
	local view = vim.fn.winsaveview()
	vim.cmd("tabnew")
	local left_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(left_win, buf)
	vim.fn.winrestview(view)
	if cwd then pcall(vim.cmd, "lcd " .. vim.fn.fnameescape(cwd)) end
	vim.cmd("rightbelow vsplit")
	vim.cmd("rightbelow vsplit")
	local rt = vim.api.nvim_get_current_win()
	vim.cmd("belowright split")
	local rb = vim.api.nvim_get_current_win()
	open_term(rt, cwd)
	open_term(rb, cwd)
	vim.api.nvim_set_current_win(left_win)
	vim.cmd("wincmd =")

	name_layout_tab(buf, { layout = "work", dir = cwd })
end

function M.here_work_mode()
	local buf = vim.api.nvim_get_current_buf()
	local cwd = util.resolve_cwd(buf)

	vim.cmd("only")
	local left_win = vim.api.nvim_get_current_win()
	if cwd then pcall(vim.cmd, "lcd " .. vim.fn.fnameescape(cwd)) end
	vim.cmd("rightbelow vsplit")
	vim.cmd("rightbelow vsplit")
	local rt = vim.api.nvim_get_current_win()
	vim.cmd("belowright split")
	local rb = vim.api.nvim_get_current_win()
	open_term(rt, cwd)
	open_term(rb, cwd)
	vim.api.nvim_set_current_win(left_win)
	vim.cmd("wincmd =")

	-- HereWork transforms the current tab in place, so it must (re)name it from
	-- the buffer we started on. Prefer the git-aware project-root name (so a deep
	-- file or an Oil listing inside RunningWild/ names the tab "RunningWild"),
	-- falling back to the plain folder name when we're not inside a project.
	local folder = util.project_or_dir_name(cwd or vim.fn.getcwd())
	if folder and folder ~= "" then tabs.apply_folder(folder) end
end

function M.triple_mode_tab()
	local buf = vim.api.nvim_get_current_buf()
	local cwd = util.resolve_cwd(buf)
	local view = vim.fn.winsaveview()
	vim.cmd("tabnew")
	local mid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(mid, buf)
	vim.fn.winrestview(view)
	if cwd then
		pcall(vim.cmd, "lcd " .. vim.fn.fnameescape(cwd))
		vim.t.pwd_mode = "local"
	end
	vim.cmd("leftabove vsplit")
	vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
	vim.fn.winrestview(view)
	vim.api.nvim_set_current_win(mid)
	vim.cmd("rightbelow vsplit")
	vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
	vim.fn.winrestview(view)
	vim.api.nvim_set_current_win(mid)
	vim.cmd("wincmd =")

	name_layout_tab(buf, { layout = "triple", dir = cwd })
end

function M.dual_mode_tab()
	local buf = vim.api.nvim_get_current_buf()
	local cwd = util.resolve_cwd(buf)
	local view = vim.fn.winsaveview()
	vim.cmd("tabnew")
	local left = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(left, buf)
	vim.fn.winrestview(view)
	if cwd then
		pcall(vim.cmd, "lcd " .. vim.fn.fnameescape(cwd))
		vim.t.pwd_mode = "local"
	end
	vim.cmd("rightbelow vsplit")
	vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
	vim.fn.winrestview(view)
	vim.api.nvim_set_current_win(left)
	vim.cmd("wincmd =")

	name_layout_tab(buf, { layout = "dual", dir = cwd })
end

function M.large_mode_tab()
	local buf = vim.api.nvim_get_current_buf()
	local view = vim.fn.winsaveview()
	vim.cmd("tabnew")
	local mid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(mid, buf)
	vim.fn.winrestview(view)
	vim.cmd("leftabove vnew")
	local left = vim.api.nvim_get_current_win()
	vim.bo.bufhidden = "wipe"
	vim.bo.swapfile = false
	vim.api.nvim_set_current_win(mid)
	vim.cmd("rightbelow vnew")
	local right = vim.api.nvim_get_current_win()
	vim.bo.bufhidden = "wipe"
	vim.bo.swapfile = false
	local q = math.floor(vim.o.columns * 0.25)
	vim.api.nvim_win_set_width(left, q)
	vim.api.nvim_win_set_width(right, q)
	vim.api.nvim_set_current_win(mid)

	name_layout_tab(buf, { layout = "large" })
end

function M.new_large_tab()
	vim.cmd("tabnew")
	local mid = vim.api.nvim_get_current_win()
	vim.cmd("leftabove vnew")
	local left = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_win(mid)
	vim.cmd("rightbelow vnew")
	local right = vim.api.nvim_get_current_win()
	local q = math.floor(vim.o.columns * 0.25)
	vim.api.nvim_win_set_width(left, q)
	vim.api.nvim_win_set_width(right, q)
	vim.api.nvim_set_current_win(mid)

	name_layout_tab(vim.api.nvim_win_get_buf(mid), { layout = "large" })
end

--- AI mode: three columns. The left one is a terminal for your AI CLI, one
--- width-step wider than an even third, and the cursor lands there in insert
--- mode so you can type straight away. The centre shows the PWD's
--- documents/prompts/ folder in Oil when it exists (else the PWD itself), and
--- the right shows frontend/sdl/ when the project has that folder, otherwise
--- the PWD in Oil.
function M.ai_mode_tab()
	local cwd = util.resolve_cwd(vim.api.nvim_get_current_buf())
	local base = cwd or vim.fn.getcwd()
	local prompts = util.join(base, "documents", "prompts")
	local center_dir = util.is_dir(prompts) and prompts or base
	local project = util.project_root(base) or base
	local sdl = util.join(project, "frontend", "sdl")
	local right_dir = util.is_dir(sdl) and sdl or base

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

	open_term(left, cwd)

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
