-- logarktos/recentfiles.lua ── a panel of recently-modified files under a dir
local config = require("logarktos.config")

local M = {}
local uv = vim.uv or vim.loop

-- Walk, do not globpath("**/*"): that materializes every path under the tree
-- (including .venv / Obras/Games) before ignore_dirs can filter, and on Windows
-- it can follow directory junctions into a parent or C:\.
local HARD_SKIP = {
	[".git"] = true,
	[".svn"] = true,
	[".hg"] = true,
	["node_modules"] = true,
	[".venv"] = true,
	["venv"] = true,
	["__pycache__"] = true,
	[".cache"] = true,
}
local MAX_VISIT = 5000
local MAX_DEPTH = 12

local function ignore_dirs()
	return (config.options.recentfiles and config.options.recentfiles.ignore_dirs)
		or { ".git", "node_modules", ".venv", "venv", "__pycache__" }
end

local function skip_needles()
	local out = {}
	for _, d in ipairs(ignore_dirs()) do
		local needle = tostring(d):gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", "")
		if needle ~= "" then
			out[#out + 1] = needle
		end
	end
	return out
end

local function is_skipped(path)
	local lower = path:gsub("\\", "/"):lower()
	for _, needle in ipairs(skip_needles()) do
		local n = needle:lower()
		if lower:find("/" .. n .. "/", 1, true) or lower:match("/" .. vim.pesc(n) .. "$") then
			return true
		end
	end
	return false
end

local function dir_basename_skipped(name)
	if not name or name == "" or name == "." or name == ".." then return true end
	if HARD_SKIP[name] or HARD_SKIP[name:lower()] then return true end
	local lower = name:lower()
	for _, needle in ipairs(skip_needles()) do
		local base = needle:match("([^/]+)$") or needle
		if lower == base:lower() then return true end
	end
	return false
end

local function matches_extension(path, extensions)
	if not extensions or #extensions == 0 then return true end
	local lower_path = path:lower()
	for _, ext in ipairs(extensions) do
		local needle = ext:lower()
		if needle:sub(1, 1) ~= "." then needle = "." .. needle end
		if lower_path:sub(-#needle) == needle then return true end
	end
	return false
end

local function stat_mtime_ns(path)
	local st = uv.fs_stat(path)
	if not st or st.type ~= "file" then return nil end
	local sec = st.mtime and st.mtime.sec or 0
	local nsec = st.mtime and st.mtime.nsec or 0
	return sec * 1e9 + nsec
end

local function relative_path(path, base)
	if vim.fs and vim.fs.relpath then
		local ok, rel = pcall(vim.fs.relpath, path, base)
		if ok and rel and rel ~= "" then return rel end
	end
	local trimmed = base:gsub("[/\\]+$", "")
	if trimmed ~= "" and path:sub(1, #trimmed) == trimmed then
		return path:sub(#trimmed + 1):gsub("^[\\/]", "")
	end
	return path
end

local function gather_recent(dir, limit, opts)
	opts = opts or {}
	dir = vim.fs.normalize(dir):gsub("\\", "/")
	local ranked = {}
	local visits = 0

	local function consider_file(path)
		if not matches_extension(path, opts.extensions) then return end
		if is_skipped(path) then return end
		if opts.filter and not opts.filter(path) then return end
		local mtns = stat_mtime_ns(path)
		if mtns then ranked[#ranked + 1] = { path = path, mtns = mtns } end
	end

	local function walk(path, depth)
		if depth > MAX_DEPTH or visits >= MAX_VISIT then return end
		local fd = uv.fs_scandir(path)
		if not fd then return end
		while visits < MAX_VISIT do
			local name, typ = uv.fs_scandir_next(fd)
			if not name then break end
			visits = visits + 1
			local child = path .. "/" .. name
			-- lstat: do not follow Windows directory junctions (can loop into C:\).
			local lst = uv.fs_lstat(child)
			local kind = typ or (lst and lst.type)
			-- Skip junctions/symlinks so a link to a parent or C:\ cannot explode.
			if kind ~= "link" and not (lst and lst.type == "link") then
				if kind == "directory" then
					if not dir_basename_skipped(name) and not is_skipped(child) then
						walk(child, depth + 1)
					end
				elseif kind == "file" then
					consider_file(child)
				end
			end
		end
	end

	walk(dir, 0)
	table.sort(ranked, function(a, b) return a.mtns > b.mtns end)
	local out = {}
	for i = 1, math.min(limit, #ranked) do table.insert(out, ranked[i]) end
	return out
end

local highlight_ns = vim.api.nvim_create_namespace("logarktos_recentfiles")
local highlight_group = "LogarktosRecentFilename"

-- Tint the filename portion of each entry with the colourscheme's warning
-- background where one exists (a deliberate accent in the sepia schemes), as a
-- foreground only so the entry's background stays unassigned. When the active
-- scheme sets no such colour, leave the group empty so the name renders exactly
-- like the surrounding text — no invented off-palette green, and crucially no
-- hard-coded background painted over a transparent/textured window.
--
-- Re-derived on every render (and on ColorScheme, below) rather than latched
-- once: a value captured before the scheme finished loading, or a group wiped
-- by a later `:colorscheme` (implicit `hi clear`), would otherwise leave the
-- startup layout looking different from a hand-run :TriplicateLarge.
local function ensure_highlight()
	local attrs = {}
	local ok, warning = pcall(vim.api.nvim_get_hl, 0, { name = "WarningMsg", link = false })
	if ok and warning and warning.bg then
		local accent = warning.bg
		if type(accent) == "number" then accent = string.format("#%06x", accent) end
		if accent ~= "" then attrs = { fg = accent, bold = warning.bold or nil } end
	end
	pcall(vim.api.nvim_set_hl, 0, highlight_group, attrs)
end

-- Keep the group alive across colourscheme changes (each `:colorscheme` clears
-- all highlights). Existing extmarks reference the group by name, so simply
-- redefining it re-tints them without a re-render.
vim.api.nvim_create_autocmd("ColorScheme", {
	group = vim.api.nvim_create_augroup("LogarktosRecentHighlight", { clear = true }),
	callback = ensure_highlight,
})

local function str_take(text, count)
	if count <= 0 then return "" end
	if vim.fn and vim.fn.strcharpart then
		local chars = vim.fn.strchars(text)
		return vim.fn.strcharpart(text, 0, math.min(count, chars))
	end
	return text:sub(1, count)
end

local function format_display_entry(path, base)
	local rel = relative_path(path, base)
	local normalized = rel:gsub("\\", "/")
	local parts = {}
	for part in normalized:gmatch("[^/]+") do table.insert(parts, part) end
	if #parts == 0 then return rel, 0, #rel end
	local display_parts = {}
	for idx, part in ipairs(parts) do
		if idx == #parts then table.insert(display_parts, part)
		else table.insert(display_parts, str_take(part, 2)) end
	end

	local display = table.concat(display_parts, "/")
	local highlight_start = 0
	for i = 1, #display_parts - 1 do
		highlight_start = highlight_start + #display_parts[i] + 1
	end
	local last_part = display_parts[#display_parts]
	local highlight_end = highlight_start + #last_part
	local base_name = last_part:match("^(.*)(%.[^./]+)$")
	if base_name and base_name ~= "" then highlight_end = highlight_start + #base_name end

	return display, highlight_start, highlight_end
end

local function prepare_buffer(buf)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "logarktos_recentfiles"
	vim.bo[buf].buflisted = false
end

local function set_lines(buf, lines)
	vim.bo[buf].modifiable = true
	vim.bo[buf].readonly = false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
end

local function open_entry(buf, cmd)
	local entries = vim.b[buf].recentfiles_items or {}
	local offset = vim.b[buf].recentfiles_header_lines or 0
	local idx = vim.api.nvim_win_get_cursor(0)[1] - offset
	local entry = entries[idx]
	if not entry then return end
	local path = entry.path
	if cmd == "edit" then vim.cmd.edit(vim.fn.fnameescape(path))
	elseif cmd == "vsplit" then vim.cmd.vsplit(vim.fn.fnameescape(path))
	elseif cmd == "split" then vim.cmd.split(vim.fn.fnameescape(path)) end
end

local function configure_keymaps(buf)
	local opts = { buffer = buf, nowait = true, silent = true }
	vim.keymap.set("n", "<CR>", function() open_entry(buf, "edit") end, opts)
	vim.keymap.set("n", "<C-v>", function() open_entry(buf, "vsplit") end, opts)
	vim.keymap.set("n", "<C-x>", function() open_entry(buf, "split") end, opts)
	vim.keymap.set("n", "q", function() vim.cmd("close") end, opts)
end

function M.list_in_window(win, opts)
	opts = opts or {}
	win = win or vim.api.nvim_get_current_win()
	if not vim.api.nvim_win_is_valid(win) then return nil end

	local dir = opts.dir
	if not dir or dir == "" then return nil end
	if vim.fn.isdirectory(dir) ~= 1 then
		vim.notify("Recent files: directory not found → " .. dir, vim.log.levels.ERROR)
		return nil
	end

	local cfg = config.options.recentfiles or {}
	opts.extensions = opts.extensions or cfg.extensions
	local limit = opts.limit or cfg.limit or 20
	local entries = gather_recent(dir, limit, opts)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(win, buf)

	vim.api.nvim_set_option_value("wrap", true, { scope = "local", win = win })
	vim.api.nvim_set_option_value("linebreak", true, { scope = "local", win = win })
	vim.api.nvim_set_option_value("breakindent", true, { scope = "local", win = win })
	vim.api.nvim_set_option_value("showbreak", "↪ ", { scope = "local", win = win })

	prepare_buffer(buf)

	local lines = {}
	if #entries == 0 then
		lines = { string.format("— No recently modified files under: %s —", dir) }
		vim.b[buf].recentfiles_items = {}
		vim.b[buf].recentfiles_header_lines = 1
	else
		table.insert(lines, string.format("— %d most recently modified under: %s —", math.min(limit, #entries), dir))
		table.insert(lines, "")
		local items = {}
		for _, entry in ipairs(entries) do
			local display, hl_start, hl_end = format_display_entry(entry.path, dir)
			table.insert(lines, display)
			table.insert(items, { path = entry.path, hl_start = hl_start, hl_end = hl_end })
		end
		vim.b[buf].recentfiles_items = items
		vim.b[buf].recentfiles_header_lines = 2
	end

	set_lines(buf, lines)
	ensure_highlight()
	vim.api.nvim_buf_clear_namespace(buf, highlight_ns, 0, -1)
	local header_lines = vim.b[buf].recentfiles_header_lines or 0
	for idx, item in ipairs(vim.b[buf].recentfiles_items or {}) do
		if item.hl_start and item.hl_end and item.hl_end > item.hl_start then
			vim.api.nvim_buf_add_highlight(buf, highlight_ns, highlight_group, header_lines + idx - 1, item.hl_start, item.hl_end)
		end
	end
	configure_keymaps(buf)
	return buf
end

return M
