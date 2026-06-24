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

--- Open `dir` in Oil when available, otherwise :edit it.
function M.open_dir(dir)
	if M.has_oil() then
		local ok = pcall(vim.cmd, "Oil " .. vim.fn.fnameescape(dir))
		if ok then return end
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
			return (pcall(vim.api.nvim_buf_delete, buf, { force = false }))
		end
	end
	return false
end

--- Resolve a working directory from a buffer: Oil dir → file's dir → cwd.
function M.resolve_cwd(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	if vim.bo[buf].filetype == "oil" then
		local dir = M.oil_dir(buf)
		if dir then return dir end
	end
	local path = vim.api.nvim_buf_get_name(buf)
	if path ~= "" then return vim.fn.fnamemodify(path, ":p:h") end
	return vim.fn.getcwd()
end

return M
