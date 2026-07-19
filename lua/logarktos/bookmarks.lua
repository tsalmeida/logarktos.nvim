-- logarktos/bookmarks.lua ── file/folder bookmarks with an Oil-like list buffer
local config = require("logarktos.config")
local util = require("logarktos.util")

local M = {}

local highlight_ns = vim.api.nvim_create_namespace("logarktos_bookmarklist")
local highlight_group = "LogarktosBookmarkFilename"

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
	group = vim.api.nvim_create_augroup("LogarktosBookmarkHighlight", { clear = true }),
	callback = ensure_highlight,
})

local function normpath(p)
	if not p or p == "" then return "" end
	p = p:gsub("\\", "/")
	if #p >= 2 then p = p:sub(1, 1):lower() .. p:sub(2) end
	if #p > 3 and p:sub(-1) == "/" then p = p:sub(1, -2) end
	return p
end

--- Bookmarks live in stdpath("config")/logarktos.lua (user file). Fall back to
--- a legacy JSON store only when the user file has no bookmarks list yet.
local function load_list()
	local rcfile = require("logarktos.rcfile")
	local from_user = rcfile.get_user_bookmarks()
	local data = from_user
	if not data then
		-- One-shot migration from the old JSON stores.
		local candidates = {
			(config.options.bookmarks and config.options.bookmarks.store) or "",
			vim.fs.joinpath(vim.fn.stdpath("data"), "bookmarks.json"),
			vim.fs.joinpath(vim.fn.stdpath("data"), "logarktos", "bookmarks.json"),
		}
		for _, path in ipairs(candidates) do
			if path ~= "" and util.exists(path) then
				local f = io.open(path, "r")
				if f then
					local ok, decoded = pcall(vim.json.decode, f:read("*a"))
					f:close()
					if ok and type(decoded) == "table" then
						data = decoded
						break
					end
				end
			end
		end
		if data then
			rcfile.set_user_bookmarks(data)
		else
			data = {}
		end
	end

	local unique, seen = {}, {}
	local is_windows = vim.fn.has("win32") == 1
	for _, p in ipairs(data) do
		if type(p) == "string" and p ~= "" then
			local n = normpath(p)
			if is_windows then n = n:lower() end
			if not seen[n] then
				seen[n] = true
				table.insert(unique, p)
			end
		end
	end
	return unique
end

local function save_list(list)
	local rcfile = require("logarktos.rcfile")
	rcfile.set_user_bookmarks(list)
end

local function exists(path)
	return vim.loop.fs_stat(path) ~= nil
end

local function prune_missing(list)
	local filtered, changed, seen = {}, false, {}
	local is_windows = vim.fn.has("win32") == 1
	for _, path in ipairs(list) do
		local n = normpath(path)
		if is_windows then n = n:lower() end
		if not seen[n] then
			if exists(path) then
				table.insert(filtered, path)
				seen[n] = true
			else
				changed = true
			end
		else
			changed = true
		end
	end
	if changed then save_list(filtered) end
	return filtered
end

local function stat(path) return vim.loop.fs_stat(path) end
local function is_dir(path)
	local st = stat(path)
	return st and st.type == "directory"
end

local function str_take(text, count)
	if count <= 0 then return "" end
	if vim.fn and vim.fn.strcharpart then
		local chars = vim.fn.strchars(text)
		return vim.fn.strcharpart(text, 0, math.min(count, chars))
	end
	return text:sub(1, count)
end

local cached_folders, cached_files = nil, nil
local render

local function format_display_entry(path, is_directory)
	local normalized = path:gsub("\\", "/")
	local parts = {}
	for part in normalized:gmatch("[^/]+") do table.insert(parts, part) end
	if #parts == 0 then return path, 0, #path end
	if is_directory == nil then is_directory = is_dir(path) end
	local display_parts = {}
	for idx, part in ipairs(parts) do
		local is_drive = idx == 1 and part:match("^[A-Za-z]:$")
		local is_last = idx == #parts
		if is_drive or is_last then
			table.insert(display_parts, part)
		else
			table.insert(display_parts, str_take(part, 2))
		end
	end

	local display = table.concat(display_parts, "/")
	local highlight_start = 0
	for i = 1, #display_parts - 1 do
		highlight_start = highlight_start + #display_parts[i] + 1
	end

	local last_part = display_parts[#display_parts]
	local highlight_end = highlight_start + #last_part
	if not is_directory then
		local base = last_part:match("^(.*)(%.[^./]+)$")
		if base and base ~= "" then highlight_end = highlight_start + #base end
	end

	return display, highlight_start, highlight_end
end

local function add(path)
	if not path or path == "" then return false, "empty path" end
	path = normpath(path)
	if not exists(path) then return false, "path not found" end
	local list = load_list()
	local is_windows = vim.fn.has("win32") == 1
	local cmp = is_windows and path:lower() or path
	for _, p in ipairs(list) do
		local np = normpath(p)
		if is_windows then np = np:lower() end
		if np == cmp then return false, "already bookmarked" end
	end
	table.insert(list, path)
	save_list(list)
	cached_folders, cached_files = nil, nil
	return true
end

local function remove(path)
	if not path or path == "" then return false, "empty path" end
	path = normpath(path)
	local list = load_list()
	local out, removed = {}, false
	local is_windows = vim.fn.has("win32") == 1
	local cmp = is_windows and path:lower() or path
	for _, p in ipairs(list) do
		local np = normpath(p)
		if is_windows then np = np:lower() end
		if np == cmp then removed = true else table.insert(out, p) end
	end
	if removed then
		save_list(out)
		cached_folders, cached_files = nil, nil
	end
	return removed
end

local function resolve_file_from_context()
	local buf = vim.api.nvim_get_current_buf()
	if vim.bo[buf].filetype == "oil" then
		local ok, oil = pcall(require, "oil")
		if not ok then return nil, "Oil not available" end
		local entry = oil.get_cursor_entry()
		if not entry or not entry.name then return nil, "Oil: no entry under cursor" end
		if entry.type ~= "file" then return nil, "Oil: cursor must be on a file" end
		local dir = oil.get_current_dir()
		if not dir or dir == "" then return nil, "Oil: unknown dir" end
		return vim.fs.normalize(vim.fs.joinpath(dir, entry.name))
	end
	local path = vim.api.nvim_buf_get_name(buf)
	if path == "" then return nil, "Current buffer has no file name" end
	return vim.fs.normalize(path)
end

local function resolve_dir_from_context()
	local buf = vim.api.nvim_get_current_buf()
	local ft = vim.bo[buf].filetype
	if ft == "oil" then
		local ok, oil = pcall(require, "oil")
		if not ok then return nil, "Oil not available" end
		local dir = oil.get_current_dir()
		if not dir or dir == "" then return nil, "Oil: unknown dir" end
		return vim.fs.normalize(dir)
	elseif ft == "netrw" then
		local dir = vim.b.netrw_curdir
		if dir and dir ~= "" then return vim.fs.normalize(dir) end
	end
	local path = vim.api.nvim_buf_get_name(buf)
	if path == "" then return nil, "Buffer has no file name" end
	return vim.fs.normalize(vim.fn.fnamemodify(path, ":p:h"))
end

-- ── public actions ───────────────────────────────────────────────────────────
function M.bookmark_add()
	local path, err = resolve_file_from_context()
	if not path then
		vim.notify("Bookmark: " .. err, vim.log.levels.WARN)
		return
	end
	local ok, why = add(path)
	if ok then
		vim.notify("Bookmarked file: " .. path, vim.log.levels.INFO, { title = "Bookmarks" })
	else
		vim.notify("Bookmark: " .. why, vim.log.levels.WARN, { title = "Bookmarks" })
	end
end

function M.bookmark_add_dir()
	local path, err = resolve_dir_from_context()
	if not path then
		vim.notify("Bookmark: " .. err, vim.log.levels.WARN)
		return
	end
	local ok, why = add(path)
	if ok then
		vim.notify("Bookmarked folder: " .. path, vim.log.levels.INFO, { title = "Bookmarks" })
	else
		vim.notify("Bookmark: " .. why, vim.log.levels.WARN, { title = "Bookmarks" })
	end
end

function M.bookmark_del()
	local buf = vim.api.nvim_get_current_buf()
	if vim.bo[buf].filetype == "logarktos_bookmarklist" then
		local row = vim.api.nvim_win_get_cursor(0)[1]
		local item = (vim.b[buf].bookmark_meta or {})[row]
		if not item or not item.path then
			vim.notify("Bookmark: no item under cursor", vim.log.levels.WARN, { title = "Bookmarks" })
			return
		end
		if remove(item.path) then
			vim.notify("Removed bookmark: " .. item.path, vim.log.levels.INFO, { title = "Bookmarks" })
			vim.bo[buf].modifiable = true
			render(buf)
		else
			vim.notify("Bookmark not found for: " .. item.path, vim.log.levels.WARN, { title = "Bookmarks" })
		end
		return
	end

	local path, err = resolve_file_from_context()
	if not path then path, err = resolve_dir_from_context() end
	if not path then
		vim.notify("Bookmark: " .. err, vim.log.levels.WARN)
		return
	end
	if remove(path) then
		vim.notify("Removed bookmark: " .. path, vim.log.levels.INFO, { title = "Bookmarks" })
	else
		vim.notify("Bookmark not found for: " .. path, vim.log.levels.WARN, { title = "Bookmarks" })
	end
end

-- ── list buffer ──────────────────────────────────────────────────────────────
function render(buf, force)
	if force or not cached_folders then
		local list = prune_missing(load_list())
		ensure_highlight()

		local entries = {}
		for _, p in ipairs(list) do
			local st = stat(p)
			if st then
				local is_directory = st.type == "directory"
				local mtime = st.mtime.sec + (st.mtime.nsec or 0) / 1e9
				local display, hl_start, hl_end = format_display_entry(p, is_directory)
				table.insert(entries, {
					path = p, is_directory = is_directory, mtime = mtime,
					display = display, hl_start = hl_start, hl_end = hl_end,
				})
			end
		end

		local folders, files = {}, {}
		for _, item in ipairs(entries) do
			if item.is_directory then table.insert(folders, item) else table.insert(files, item) end
		end
		local function sort_recent(a, b) return a.mtime > b.mtime end
		table.sort(folders, sort_recent)
		table.sort(files, sort_recent)
		cached_folders, cached_files = folders, files
	end

	local folders, files = cached_folders, cached_files
	local display_lines, meta = {}, {}

	local function get_icon(name, dir)
		local ok, mini_icons = pcall(require, "mini.icons")
		if not ok then return dir and "" or "" end
		if name == "section_folders" then return mini_icons.get("directory", "Folders")
		elseif name == "section_files" then return mini_icons.get("file", "Files")
		elseif dir then return mini_icons.get("directory", name)
		else return mini_icons.get("file", name) end
	end

	local function append_section(title_icon, title_text, items, is_folders)
		if #items == 0 then return false end
		if #display_lines > 0 then
			table.insert(display_lines, "")
			table.insert(meta, false)
		end
		table.insert(display_lines, string.format("%s  %s", title_icon, title_text))
		table.insert(meta, false)
		for _, item in ipairs(items) do
			local prefix = "  " .. get_icon(item.path, is_folders) .. " "
			table.insert(display_lines, prefix .. item.display)
			table.insert(meta, {
				path = item.path,
				hl_start = item.hl_start and (item.hl_start + #prefix) or nil,
				hl_end = item.hl_end and (item.hl_end + #prefix) or nil,
			})
		end
		return true
	end

	local has_sections = false
	has_sections = append_section(get_icon("section_folders", true), "Folders", folders, true) or has_sections
	has_sections = append_section(get_icon("section_files", false), "Files", files, false) or has_sections

	if not has_sections then
		display_lines = {
			"— No bookmarks yet —",
			"",
			"Tips:",
			"  bookmark a file   → :LogarktosBookmarkAdd",
			"  bookmark a folder → :LogarktosBookmarkAddDir",
		}
		meta = {}
	end
	vim.bo[buf].modifiable = true
	vim.bo[buf].readonly = false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)
	vim.b[buf].bookmark_meta = meta
	vim.api.nvim_buf_clear_namespace(buf, highlight_ns, 0, -1)
	for idx, item in ipairs(meta) do
		if item and item.hl_start and item.hl_end and item.hl_end > item.hl_start then
			vim.api.nvim_buf_add_highlight(buf, highlight_ns, highlight_group, idx - 1, item.hl_start, item.hl_end)
		end
	end
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
end

local function open_item_under_cursor(cmd)
	local buf = vim.api.nvim_get_current_buf()
	local row = vim.api.nvim_win_get_cursor(0)[1]
	local item = (vim.b[buf].bookmark_meta or {})[row]
	if not item or not item.path then return end
	local path = item.path
	if not exists(path) then
		vim.notify("Path not found: " .. path, vim.log.levels.WARN, { title = "Bookmarks" })
		return
	end
	if is_dir(path) then
		local ok = pcall(require, "oil")
		if cmd == "vsplit" then vim.cmd.vsplit() elseif cmd == "split" then vim.cmd.split() end
		if ok then vim.cmd("Oil " .. vim.fn.fnameescape(path)) else vim.cmd.edit(vim.fn.fnameescape(path)) end
	else
		if cmd == "edit" then vim.cmd.edit(vim.fn.fnameescape(path))
		elseif cmd == "vsplit" then vim.cmd.vsplit(vim.fn.fnameescape(path))
		elseif cmd == "split" then vim.cmd.split(vim.fn.fnameescape(path)) end
	end
end

local function open_item_external()
	local buf = vim.api.nvim_get_current_buf()
	local row = vim.api.nvim_win_get_cursor(0)[1]
	local item = (vim.b[buf].bookmark_meta or {})[row]
	if not item or not item.path then return end
	local path = item.path
	if not exists(path) then
		vim.notify("Path not found: " .. path, vim.log.levels.WARN, { title = "Bookmarks" })
		return
	end
	local ok, err = util.open_external(path)
	if not ok then
		vim.notify("Could not open: " .. tostring(err), vim.log.levels.ERROR, { title = "Bookmarks" })
	end
end

local function prepare_buffer(buf)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "logarktos_bookmarklist"
	vim.bo[buf].buflisted = false
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
end

local function configure_buffer(buf)
	prepare_buffer(buf)
	render(buf, false)

	local opts = { buffer = buf, nowait = true, silent = true }
	vim.keymap.set("n", "<CR>", function() open_item_under_cursor("edit") end, opts)
	vim.keymap.set("n", "<C-v>", function() open_item_under_cursor("vsplit") end, opts)
	vim.keymap.set("n", "<C-x>", function() open_item_under_cursor("split") end, opts)
	vim.keymap.set("n", "gx", open_item_external, opts)
	vim.keymap.set("n", "q", function() vim.cmd("close") end, opts)
	vim.keymap.set("n", "dd", function() M.bookmark_del() end, opts)

	local grp = vim.api.nvim_create_augroup("LogarktosBookmarkList@" .. buf, { clear = true })
	vim.api.nvim_create_autocmd("BufEnter", {
		buffer = buf,
		group = grp,
		callback = function() render(buf, false) end,
	})
end

local function open_in_window(win)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_set_option_value("wrap", true, { scope = "local", win = win })
	vim.api.nvim_set_option_value("linebreak", true, { scope = "local", win = win })
	vim.api.nvim_set_option_value("breakindent", true, { scope = "local", win = win })
	vim.api.nvim_set_option_value("showbreak", "↪ ", { scope = "local", win = win })
	configure_buffer(buf)
	return buf
end

function M.bookmark_list(opts)
	opts = opts or {}
	local current_buf = vim.api.nvim_get_current_buf()
	if vim.bo[current_buf].filetype == "logarktos_bookmarklist" then
		render(current_buf, true)
		return current_buf
	end
	if opts.split then
		vim.cmd("vsplit")
		return open_in_window(vim.api.nvim_get_current_win())
	end
	return open_in_window(vim.api.nvim_get_current_win())
end

function M.bookmark_list_in_window(win)
	win = win or vim.api.nvim_get_current_win()
	if not vim.api.nvim_win_is_valid(win) then return nil end
	vim.api.nvim_set_current_win(win)
	return open_in_window(win)
end

return M
