-- logarktos/util.lua ── shared helpers (paths, Oil integration, notifications)
local M = {}

M.uv = vim.uv or vim.loop

local TITLE = "Logarktos"

function M.notify(msg, level, title)
	vim.notify(msg, level or vim.log.levels.INFO, { title = title or TITLE })
end

-- ── paths ────────────────────────────────────────────────────────────────
M.sep = package.config:sub(1, 1)
M.is_windows = M.sep == "\\"

--- Argv for an interactive user shell (list form for `termopen`).
--- On Windows always starts pwsh/powershell with ExecutionPolicy Bypass on the
--- argv — independent of Neovim's global `'shell'` (which stays cmd.exe so
--- `:!` / plugins keep simple, fast quoting). No need to chansend Set-ExecutionPolicy.
--- @return string[]
function M.interactive_shell_argv()
	if M.is_windows then
		local ps = (vim.fn.executable("pwsh") == 1) and "pwsh" or "powershell"
		return { ps, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass" }
	end
	local sh = vim.env.SHELL
	if type(sh) == "string" and sh ~= "" then
		return { sh }
	end
	return { vim.o.shell }
end

--- Working directory a terminal buffer was started in (or last pinned to).
--- Prefers `b:logarktos_term_cwd`, then the `{cwd}` in `term://{cwd}//{pid}:{cmd}`.
--- Does not use `:p:h` of the buffer name — that turns `term://C:\proj//1:pwsh`
--- into a nonsense parent path.
--- @param buf? integer
--- @return string|nil
function M.terminal_cwd(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	if not buf or not vim.api.nvim_buf_is_valid(buf) then return nil end
	local tagged = vim.b[buf].logarktos_term_cwd
	if type(tagged) == "string" and tagged ~= "" and M.is_dir(tagged) then
		return M.normalize(tagged)
	end
	local name = vim.api.nvim_buf_get_name(buf)
	if type(name) ~= "string" or name == "" then return nil end
	-- Neovim: term://{cwd}//{pid}:{cmd}. `{cwd}` may contain drive-letter colons.
	local cwd = name:match("^term://(.*)//%d+:")
	if not cwd or cwd == "" then return nil end
	if not M.is_dir(cwd) then
		local abs = vim.fn.fnamemodify(cwd, ":p")
		if M.is_dir(abs) then cwd = abs end
	end
	if M.is_dir(cwd) then return M.normalize(cwd) end
	return nil
end

--- Directory a "here" terminal (space+ht / space+wt) should start in.
--- Window/tab `lcd`/`tcd` first (so a split of an AIMode pane keeps that
--- pane's folder), then the current terminal's own cwd, then Oil listing /
--- file parent. Capture this *before* replacing the buffer — a fresh empty
--- buffer has no path of its own.
--- @param win? integer
--- @param buf? integer
--- @return string
function M.here_terminal_cwd(win, buf)
	win = win or vim.api.nvim_get_current_win()
	buf = buf or vim.api.nvim_win_get_buf(win)
	-- 1 = window lcd, 2 = tab tcd. Either is the pane's "active directory".
	if vim.fn.haslocaldir(win) ~= 0 then
		local local_dir = vim.fn.getcwd(win)
		if type(local_dir) == "string" and local_dir ~= "" then
			return M.normalize(local_dir)
		end
	end
	if vim.bo[buf].buftype == "terminal" then
		local tdir = M.terminal_cwd(buf)
		if tdir then return tdir end
	end
	if vim.bo[buf].filetype == "oil" then
		local dir = M.oil_dir(buf)
		if dir then return dir end
	end
	local path = vim.api.nvim_buf_get_name(buf)
	if path ~= "" and vim.bo[buf].buftype ~= "terminal" then
		return vim.fn.fnamemodify(path, ":p:h")
	end
	return vim.fn.getcwd(win)
end

--- Open an interactive shell in the current window (or after a split).
--- Always installs a fresh buffer first: `termopen` requires an unmodified
--- buffer, and a split of an existing terminal reuses that (always-modified)
--- buffer — so space+ht on top of a terminal would fail with E5108 otherwise.
--- The old buffer stays open in any other window still showing it.
---
--- When `opts.cwd` is omitted, the new shell starts in the invoking window's
--- active directory (AIMode/Work `lcd`/`tcd`, the terminal being replaced, Oil
--- listing, or the file's parent) — never Neovim's launch cwd by accident.
--- @param opts? { vsplit?: boolean, split?: boolean, cwd?: string, startinsert?: boolean }
function M.open_interactive_terminal(opts)
	opts = opts or {}
	-- Capture before split / buffer replace: those steal the context the new
	-- shell must inherit (standing BUFFER / WINDOW IDENTITY rule).
	local src_win = vim.api.nvim_get_current_win()
	local src_buf = vim.api.nvim_win_get_buf(src_win)
	local cwd = opts.cwd
	if type(cwd) ~= "string" or cwd == "" then
		cwd = M.here_terminal_cwd(src_win, src_buf)
	end
	if opts.vsplit then
		vim.cmd("vsplit")
	elseif opts.split then
		vim.cmd("split")
	end
	-- Same pattern as layouts.open_term: never call termopen on the current
	-- buffer (terminal / named / modified all fail or hijack a file buffer).
	local win = vim.api.nvim_get_current_win()
	local fresh = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_win_set_buf(win, fresh)
	-- Must be a Vim dictionary. A bare Lua `{}` becomes an empty *list* over
	-- the API bridge, and termopen then fails with E475 "expected dictionary".
	local term_opts = vim.empty_dict()
	if cwd and cwd ~= "" then
		term_opts.cwd = cwd
		vim.b[fresh].logarktos_term_cwd = cwd
	end
	vim.fn.termopen(M.interactive_shell_argv(), term_opts)
	-- Pin the window so a later Ctrl-W s / space+ht inherits this folder,
	-- even when the tab has no tcd (and so termopen-cwd lived only in the name).
	if cwd and cwd ~= "" then
		pcall(vim.cmd, "lcd " .. vim.fn.fnameescape(cwd))
	end
	if opts.startinsert ~= false then
		vim.cmd("startinsert")
	end
end

function M.join(...)
	return vim.fs.joinpath(...)
end

function M.normalize(path)
	if not path or path == "" then return path end
	if vim.fs and vim.fs.normalize then return vim.fs.normalize(path) end
	return vim.fn.fnamemodify(path, ":p")
end

function M.exists(path)
	return path and path ~= "" and M.uv.fs_stat(path) ~= nil
end

--- Open a path or URL with the operating system's default handler.
function M.open_external(target)
	if not target or target == "" then return false, "empty target" end

	if vim.ui and vim.ui.open then
		local ok, job, err = pcall(vim.ui.open, target)
		if ok and job then return true end
		if ok and not err then err = "no system opener found" end
		if not ok then err = job end
		return false, tostring(err)
	end

	if M.is_windows and vim.system then
		local ok = pcall(vim.system, { "cmd.exe", "/c", "start", "", target }, { detach = true, text = true })
		if ok then return true end
	end

	return false, "no system opener found"
end

function M.is_dir(path)
	local st = path and M.uv.fs_stat(path)
	return st ~= nil and st.type == "directory"
end

function M.ensure_dir(path)
	if not path or path == "" then return false end
	if M.is_dir(path) then return true end
	local ok, err = pcall(vim.fn.mkdir, path, "p")
	if not ok then
		M.notify("Could not create folder: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	return true
end

--- Return a non-clashing path by appending " (2)", " (3)", … before the ext.
function M.unique_path(path)
	if not M.exists(path) then return path end
	local dir = vim.fs.dirname(path)
	local base = vim.fs.basename(path)
	local stem, ext = base:match("^(.*)(%.[^.]*)$")
	if not stem then stem, ext = base, "" end
	local i = 2
	while true do
		local cand = M.join(dir, string.format("%s (%d)%s", stem, i, ext))
		if not M.exists(cand) then return cand end
		i = i + 1
	end
end

--- Rename src → dir/name, uniquifying the name if needed. Returns ok, target.
function M.move(src, dir, name)
	M.ensure_dir(dir)
	local target = M.unique_path(M.join(dir, name))
	local ok = M.uv.fs_rename(src, target)
	if not ok then ok = os.rename(src, target) end
	return ok ~= nil and ok ~= false, target
end

function M.relpath(target, base)
	if vim.fs and vim.fs.relpath then
		local ok, rel = pcall(vim.fs.relpath, target, base)
		if ok and rel and rel ~= "" then return rel end
	end
	return target
end

function M.basename(path)
	if not path or path == "" then return nil end
	-- Oil (and some callers) hand us directories with a trailing slash, on which
	-- fnamemodify(..., ":t") returns "" — strip them so we get the real tail.
	path = path:gsub("[\\/]+$", "")
	if path == "" then return nil end
	return vim.fn.fnamemodify(path, ":t")
end

-- ── project / git awareness ──────────────────────────────────────────────────
-- Files/dirs that mark the root of a project. `.git` (and the other VCS dirs)
-- come first so version-controlled projects win; the rest catch common
-- non-git layouts. `.root` is an explicit escape hatch users can drop anywhere.
M.root_markers = {
	".git", ".hg", ".svn",
	"package.json", "pyproject.toml", "Cargo.toml", "go.mod",
	"composer.json", "artisan", ".root",
}

--- The project root directory containing `path`, or nil when none is found.
--- `path` may be a file or a directory; the search walks upward from it.
function M.project_root(path)
	path = path or vim.fn.expand("%:p")
	if not path or path == "" then return nil end
	local start = M.is_dir(path) and path or vim.fn.fnamemodify(path, ":p:h")
	local found = vim.fs.find(M.root_markers, { path = start, upward = true })
	if #found > 0 then return vim.fs.dirname(found[1]) end
	return nil
end

--- The git-aware basename for `path`: the project root's folder name when
--- `path` lives inside a project, else the folder's own basename.
function M.project_or_dir_name(path)
	if not path or path == "" then return nil end
	local root = M.project_root(path)
	if root then return M.basename(root) end
	local dir = M.is_dir(path) and path or vim.fn.fnamemodify(path, ":p:h")
	return M.basename(dir)
end

-- ── environment ────────────────────────────────────────────────────────────
function M.getenv_trim(name)
	local v = vim.env[name]
	if not v then return nil end
	local t = vim.trim(tostring(v))
	return (t ~= "") and t or nil
end

-- ── Oil integration (all optional / guarded) ────────────────────────────────
function M.oil()
	local ok, oil = pcall(require, "oil")
	if ok then return oil end
	return nil
end

function M.has_oil()
	return vim.fn.exists(":Oil") == 2 or M.oil() ~= nil
end

--- The directory shown in the given Oil buffer (or current), or nil.
function M.oil_dir(buf)
	local oil = M.oil()
	if not oil or not oil.get_current_dir then return nil end
	local ok, dir
	if buf then
		ok, dir = pcall(vim.api.nvim_buf_call, buf, function() return oil.get_current_dir() end)
	else
		ok, dir = pcall(oil.get_current_dir)
	end
	if ok and dir and dir ~= "" then return dir end
	return nil
end

--- The Oil entry under the cursor, or nil.
function M.oil_cursor_entry()
	local oil = M.oil()
	if not oil or not oil.get_cursor_entry then return nil end
	local ok, entry = pcall(oil.get_cursor_entry)
	if ok then return entry end
	return nil
end

--- Place the Oil cursor on the entry named `name` in `win` (current win if nil).
--- Matches files and folders in the open listing; on Windows the match is
--- case-insensitive. Returns true when the cursor moved.
--- @param name string basename (or trailing-slash folder name) in the listing
--- @param win? integer
--- @return boolean
function M.oil_focus_entry(name, win)
	if not name or name == "" then return false end
	-- Listing entries are basenames; strip a trailing slash and any path prefix
	-- so `focus = "BuildAndRun.bat"` and `focus = "subdir/"` both work.
	name = tostring(name):gsub("[\\/]+$", "")
	if name == "" then return false end
	if name:find("[\\/]") then
		name = vim.fs.basename(name) or name
	end
	if name == "" then return false end

	win = win or vim.api.nvim_get_current_win()
	if not vim.api.nvim_win_is_valid(win) then return false end
	local buf = vim.api.nvim_win_get_buf(win)
	if not vim.api.nvim_buf_is_valid(buf) then return false end
	if vim.bo[buf].filetype ~= "oil" then return false end

	local oil = M.oil()
	if not oil or not oil.get_entry_on_line then return false end

	local want = name
	local want_cmp = M.is_windows and want:lower() or want
	local n = vim.api.nvim_buf_line_count(buf)
	for lnum = 1, n do
		local ok, entry = pcall(oil.get_entry_on_line, buf, lnum)
		if ok and entry and type(entry.name) == "string" and entry.name ~= "" then
			local ename = entry.name:gsub("[\\/]+$", "")
			local ename_cmp = M.is_windows and ename:lower() or ename
			if ename_cmp == want_cmp then
				local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
				-- Prefer the column of the entry name (after icons / id columns).
				local col = line:find(entry.name, 1, true)
					or line:find(ename, 1, true)
					or 1
				pcall(vim.api.nvim_win_set_cursor, win, { lnum, math.max(col - 1, 0) })
				return true
			end
		end
	end
	return false
end

--- Open `dir` in Oil when available, otherwise :edit it.
--- Optional second arg: a focus name (string) or `{ focus = "file-or-folder" }`.
--- When `focus` is set, the Oil listing lands the cursor on that entry after
--- the directory finishes loading (see logarktos.lua pane `focus`).
--- @param dir string
--- @param opts? string|{ focus?: string }
function M.open_dir(dir, opts)
	local focus
	if type(opts) == "string" then
		focus = opts
	elseif type(opts) == "table" then
		focus = opts.focus
	end
	if type(focus) == "string" then
		focus = vim.trim(focus)
		if focus == "" then focus = nil end
	else
		focus = nil
	end

	-- Capture the window *before* Oil steals focus or another pane opens.
	local win = vim.api.nvim_get_current_win()

	local function apply_focus()
		if not focus then return end
		if not vim.api.nvim_win_is_valid(win) then return end
		-- Retry a few times: Oil's listing is async and can repaint after the
		-- first "ready" callback, which would otherwise leave the cursor on ../.
		local attempts = 0
		local function try()
			attempts = attempts + 1
			if not vim.api.nvim_win_is_valid(win) then return end
			if M.oil_focus_entry(focus, win) then return end
			if attempts < 6 then
				vim.defer_fn(try, 40 * attempts)
			end
		end
		try()
	end

	local oil = M.oil()
	if oil and type(oil.open) == "function" then
		-- Prefer the API so we get a true "buffer ready" callback.
		local ok = pcall(oil.open, dir, nil, apply_focus)
		if ok then
			-- Oil can short-circuit (same buffer already open) without calling cb;
			-- a scheduled pass still lands focus when the listing is already ready.
			if focus then vim.schedule(apply_focus) end
			return
		end
	end
	if M.has_oil() then
		local ok = pcall(vim.cmd, "Oil " .. vim.fn.fnameescape(dir))
		if ok then
			local ok_u, oil_util = pcall(require, "oil.util")
			if ok_u and oil_util.run_after_load then
				pcall(oil_util.run_after_load, 0, apply_focus)
			else
				vim.schedule(apply_focus)
			end
			return
		end
	end
	vim.cmd({ cmd = "edit", args = { dir } })
end

--- Refresh the current Oil listing (no-op when Oil isn't loaded).
function M.refresh_oil()
	local ok, actions = pcall(require, "oil.actions")
	if ok and actions.refresh and actions.refresh.callback then
		pcall(actions.refresh.callback)
	end
end

--- Drop a cached (hidden) Oil buffer for `dir` so the next visit reloads the
--- directory from disk. Oil keeps buffers with bufhidden=hide, so a buffer that
--- was listed before a filesystem change keeps showing the stale listing on
--- return; refreshing such a reused buffer in place races with Oil's async
--- load and can be swallowed. Wiping it is the reliable cure. Safe no-op when
--- Oil isn't loaded, no such buffer exists, it has unsaved Oil edits, or it is
--- still displayed in a window (where wiping would be disruptive).
--- Returns true when a buffer was actually wiped.
function M.wipe_oil_dir(dir)
	if not dir or dir == "" then return false end
	local oil = M.oil()
	if not oil or not oil.get_url_for_path then return false end
	local ok, url = pcall(oil.get_url_for_path, dir, false)
	if not ok or not url or url == "" then return false end
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf)
			and vim.api.nvim_buf_get_name(buf) == url
			and not vim.bo[buf].modified
			and #vim.fn.win_findbuf(buf) == 0
		then
			-- Must be a full :bwipeout, not nvim_buf_delete (which is :bdelete and
			-- leaves the buffer *valid* but unloaded). Oil reuses that husk by name
			-- on the next `:Oil <dir>` and its load path short-circuits on the
			-- leftover buffer-local filetype marker, so view.initialize() never runs
			-- again -- and that is the only thing that repopulates the buffer's
			-- render session. The next render then indexes a nil session and crashes
			-- (oil/view.lua render_buffer). Wiping forces Oil to build a fresh buffer
			-- (and session) from scratch.
			return (pcall(vim.cmd, "silent! bwipeout " .. buf))
		end
	end
	return false
end

--- Cursor row for `buf` when it is shown in a window (else nil).
local function cursor_row_for_buf(buf)
	local wins = vim.fn.win_findbuf(buf)
	if #wins > 0 then
		return vim.api.nvim_win_get_cursor(wins[1])[1]
	end
	if vim.api.nvim_get_current_buf() == buf then
		return vim.api.nvim_win_get_cursor(0)[1]
	end
	return nil
end

--- True for list panels that are not themselves editable content (bookmark /
--- recent-file lists). Layouts must open the *selected* path instead of
--- cloning these buffers into Triple/Dual/Work/etc.
function M.is_list_panel(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
	local ft = vim.bo[buf].filetype
	return ft == "logarktos_bookmarklist" or ft == "logarktos_recentfiles"
end

--- Exact path under the cursor / focus of `buf`, or nil.
--- Bookmark list → selected entry; recent-files → selected entry;
--- Oil → directory entry under the cursor, else the Oil listing dir;
--- normal file buffer → its path. List headers / empty rows return nil.
function M.resolve_focus_path(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	if not buf or not vim.api.nvim_buf_is_valid(buf) then return nil end
	local ft = vim.bo[buf].filetype

	if ft == "logarktos_bookmarklist" then
		local row = cursor_row_for_buf(buf)
		if not row then return nil end
		local item = (vim.b[buf].bookmark_meta or {})[row]
		if type(item) == "table" and item.path and item.path ~= "" then
			return M.normalize(item.path)
		end
		return nil
	end

	if ft == "logarktos_recentfiles" then
		local row = cursor_row_for_buf(buf)
		if not row then return nil end
		local offset = vim.b[buf].recentfiles_header_lines or 0
		local entry = (vim.b[buf].recentfiles_items or {})[row - offset]
		if type(entry) == "table" and entry.path and entry.path ~= "" then
			return M.normalize(entry.path)
		end
		return nil
	end

	if ft == "oil" then
		return M.oil_selected_dir(buf) or M.oil_dir(buf)
	end

	local path = vim.api.nvim_buf_get_name(buf)
	if path ~= "" and (vim.bo[buf].buftype == "" or vim.bo[buf].buftype == "acwrite") then
		return path
	end
	return nil
end

--- Open a filesystem path: directories in Oil (or :edit), files with :edit.
function M.open_path(path)
	if not path or path == "" then return false end
	if M.is_dir(path) then
		M.open_dir(path)
		return true
	end
	if M.exists(path) then
		vim.cmd.edit(vim.fn.fnameescape(path))
		return true
	end
	return false
end

--- When Oil's cursor is on a real directory entry (not `..`), return that
--- folder's absolute path. Parent line, files, links-to-files, and empty
--- cursor all return nil so callers can fall back to the listing directory.
--- Mirrors bookmark-list selection: pick a folder to open layouts there;
--- put the cursor on `../` to keep the folder Oil is already showing.
--- @param buf? integer
--- @return string|nil
function M.oil_selected_dir(buf)
	local dir = M.oil_dir(buf)
	if not dir or dir == "" then return nil end

	-- get_cursor_entry reads the *current window* cursor. Layout keymaps run
	-- while the Oil window is still current; if `buf` is another Oil buffer,
	-- only trust the cursor when that buffer is displayed in the current win.
	local cur = vim.api.nvim_get_current_buf()
	if buf and buf ~= cur then return nil end

	local entry = M.oil_cursor_entry()
	if not entry or type(entry.name) ~= "string" or entry.name == "" then return nil end
	-- Oil marks the parent row as type "parent" (often named "..").
	if entry.type == "parent" then return nil end

	local selected = M.normalize(M.join(dir, entry.name))
	if selected and selected ~= "" and M.is_dir(selected) then
		return selected
	end
	return nil
end

--- Resolve a working directory from a buffer:
--- Oil selected folder (or Oil dir) → focus path (bookmark/recent/file) as dir → cwd.
--- Layouts use this for terminals, lcd, and logarktos.lua base folder.
--- Terminal buffers are *not* treated as files: `:p:h` of `term://…` is garbage.
function M.resolve_cwd(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	if vim.bo[buf].buftype == "terminal" then
		local tdir = M.terminal_cwd(buf)
		if tdir then return tdir end
		return vim.fn.getcwd()
	end
	local ft = vim.bo[buf].filetype
	if ft == "oil" then
		-- Folder under the cursor wins (same idea as space+bl bookmarks).
		-- `../` or a file → the Oil listing directory itself.
		local selected = M.oil_selected_dir(buf)
		if selected then return selected end
		local dir = M.oil_dir(buf)
		if dir then return dir end
	end
	local focus = M.resolve_focus_path(buf)
	if focus then
		if M.is_dir(focus) then return focus end
		return vim.fn.fnamemodify(focus, ":p:h")
	end
	local path = vim.api.nvim_buf_get_name(buf)
	if path ~= "" then return vim.fn.fnamemodify(path, ":p:h") end
	return vim.fn.getcwd()
end

--- Open the layout "content" for `buf`: list panels → selected path; else keep buf.
--- Returns true when something was opened into the current window.
function M.open_focus_or_buf(buf, view)
	if buf and vim.api.nvim_buf_is_valid(buf) and M.is_list_panel(buf) then
		local path = M.resolve_focus_path(buf)
		if path and M.open_path(path) then return true end
		return false
	end
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_win_set_buf(0, buf)
		if view then vim.fn.winrestview(view) end
		return true
	end
	return false
end

return M
