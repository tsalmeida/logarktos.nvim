-- logarktos/rcfile.lua ── load / save `logarktos.lua` (user + per-folder)
--
-- Per-folder files describe layout panes (work / textwork). The special
-- file at stdpath("config")/logarktos.lua also holds user preferences (start_dir,
-- bufferfiles, ignore_dirs, bookmarks, AI model/limits, …). API keys stay in
-- the real environment / a gitignored `.env` — never in these Lua files.
--
-- Example (user / nvim config root):
--   return {
--     tabname = "",  -- e.g. "NVIM-Config" to name tabs opened on this folder
--     start_dir = "L:/Vault/",
--     ignore_dirs = { ".git", "node_modules" },
--     bufferfiles = { dir = "C:/…/bufferfiles/" },
--     ai = { model = "gpt-5-mini", max_input_chars = 1000, default_instruction = "…" },
--     bookmarks = { "C:/path/to/file" },
--     work = {
--       left   = { mode = "terminal", path = ".", command = "" },
--       center = { mode = "oil",      path = ".", command = "", focus = "" },
--       right  = { mode = "oil",      path = ".", command = "", focus = "" },
--     },
--     textwork = {
--       right = { focus = "" },
--     },
--   }

local util = require("logarktos.util")

local M = {}

M.FILENAME = "logarktos.lua"
M.LEGACY_ENV = "logarktos.env"

--- Known AI CLI app names (tab prefix + command detection).
M.AI_APPS = {
	codex = true,
	grok = true,
	claude = true,
	agy = true,
	gemini = true,
	aider = true,
	opencode = true,
	cursor = true,
}

-- ── path helpers ─────────────────────────────────────────────────────────────

function M.user_path()
	return util.join(vim.fn.stdpath("config"), M.FILENAME)
end

function M.path_in(dir)
	if not dir or dir == "" then return nil end
	return util.join(dir, M.FILENAME)
end

function M.is_absolute(path)
	if not path or path == "" then return false end
	if path:match("^%a:[/\\]") then return true end
	if path:match("^\\\\") or path:match("^//") then return true end
	if path:match("^/") then return true end
	return false
end

--- Prefer a path relative to `base` when the absolute path lives under it.
function M.rel_or_abs(abs, base)
	if not abs or abs == "" then return nil end
	abs = util.normalize(abs):gsub("\\", "/")
	base = base and util.normalize(base):gsub("\\", "/") or nil
	if base and base ~= "" then
		local a = abs:gsub("/+$", "")
		local b = base:gsub("/+$", "")
		local a_cmp, b_cmp = a, b
		if vim.fn.has("win32") == 1 then
			a_cmp, b_cmp = a:lower(), b:lower()
		end
		if a_cmp == b_cmp then return "." end
		local prefix = b_cmp .. "/"
		if a_cmp:sub(1, #prefix) == prefix then
			return a:sub(#b + 2)
		end
	end
	return abs
end

--- Resolve a stored path (relative or absolute) against `base`.
--- `""`, `"."`, and `"root"` all mean the layout folder.
function M.resolve_path(raw, base)
	if type(raw) == "string" then raw = vim.trim(raw) end
	if not raw or raw == "" or raw == "." or (type(raw) == "string" and raw:lower() == "root") then
		return base and util.normalize(base) or nil
	end
	if M.is_absolute(raw) then
		return util.normalize(raw)
	end
	if not base or base == "" then
		return util.normalize(raw)
	end
	return util.normalize(util.join(base, raw))
end

function M.ai_app_name(text)
	if not text or text == "" then return nil end
	local token = tostring(text):match("^%s*(%S+)") or ""
	token = token:gsub("^[\"']", ""):gsub("[\"']$", "")
	token = token:gsub("%.exe$", ""):gsub("%.cmd$", ""):gsub("%.bat$", "")
	token = util.basename(token) or token
	token = token:lower()
	if M.AI_APPS[token] then return token end
	return nil
end

-- ── serialize ────────────────────────────────────────────────────────────────

local function is_list(t)
	if type(t) ~= "table" then return false end
	local count = 0
	for k in pairs(t) do
		if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
		count = count + 1
	end
	if count == 0 then return false end
	for i = 1, count do
		if t[i] == nil then return false end
	end
	return true
end

local function quote_str(s)
	return string.format("%q", s)
end

-- One short sentence per known key, emitted above that field when writing.
-- Keys are dotted paths from the root table (e.g. "organize.files").
local KEY_COMMENTS = {
	-- Folder identity — the tab title for layouts opened on this folder.
	tabname = 'Name for tabs opened on this folder (e.g. "NVIM-Config"). Empty = automatic.',
	-- User-file prefs
	start_dir = "Default folder for Triplicate (space+tr).",
	ignore_dirs = "Folder basenames skipped by the recent-files panel.",
	bufferfiles = "Autosaved scratch buffers (space+bu).",
	["bufferfiles.dir"] = "Folder that stores bufferfiles.",
	["bufferfiles.keep"] = "How many recent bufferfiles to keep.",
	["bufferfiles.prefix"] = "Filename prefix for new bufferfiles.",
	ai = "OpenAI helpers (space+ai / space+sf).",
	["ai.enabled"] = "Master switch for AI commands.",
	["ai.model"] = "OpenAI model name.",
	["ai.max_input_chars"] = "Max characters sent to the model.",
	["ai.default_instruction"] = "Default prompt prefix for space+ai.",
	["ai.max_name_len"] = "Max length of AI-suggested filenames.",
	["ai.api_key_env"] = "Env var name that holds the API key (never the key itself).",
	bookmarks = "Paths shown in the bookmark list (space+bl).",
	-- Organize
	organize = "Settings for :Organize (space+or).",
	["organize.ignore"] = "Basenames never moved by :Organize.",
	["organize.fixed"] = "Folder names emptied into the folders bucket without a date prefix.",
	["organize.files"] = '"timestamps" or "extensions" — how files are bucketed.',
	-- Layouts
	work = "WorkMode (space+wm): three panes. Each has mode / path / command.",
	textwork = "TextWork (space+tw): same file left+center, Oil right.",
	["textwork.right.focus"] = "Oil entry to land on; empty = the dual-pane file.",
	-- Pane fields (nested under work / textwork)
	mode = '"terminal", "oil", or "empty".',
	path = 'Folder for this pane (relative, absolute, or "root" / "." for the layout folder).',
	command = "Command typed into the terminal; empty = plain shell. Ignored unless mode is terminal.",
	cmd = "Command typed into the terminal; empty = plain shell.",
	focus = "Oil entry basename to land on; empty = Oil default.",
}

local function serialize_value(val, indent, path)
	indent = indent or 0
	path = path or ""
	local pad = string.rep("  ", indent)
	local pad1 = string.rep("  ", indent + 1)
	local t = type(val)
	if val == nil then
		return "nil"
	elseif t == "boolean" then
		return val and "true" or "false"
	elseif t == "number" then
		return tostring(val)
	elseif t == "string" then
		return quote_str(val)
	elseif t ~= "table" then
		return quote_str(tostring(val))
	end

	if is_list(val) then
		local parts = {}
		local simple = true
		for _, v in ipairs(val) do
			if type(v) == "table" then simple = false end
		end
		if simple and #val <= 6 then
			for _, v in ipairs(val) do
				parts[#parts + 1] = serialize_value(v, 0, path)
			end
			return "{ " .. table.concat(parts, ", ") .. " }"
		end
		for _, v in ipairs(val) do
			parts[#parts + 1] = pad1 .. serialize_value(v, indent + 1, path)
		end
		return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. pad .. "}"
	end

	-- map: stable key order (known keys first, then alpha)
	local priority = {
		tabname = 0,
		start_dir = 1,
		ignore_dirs = 2,
		bufferfiles = 3,
		ai = 4,
		bookmarks = 5,
		organize = 6,
		work = 10,
		textwork = 12,
		left = 20,
		center = 21,
		right = 22,
		mode = 29,
		path = 30,
		focus = 31,
		command = 32,
		cmd = 33,
		cwd = 34,
		dir = 34,
		model = 40,
		max_input_chars = 41,
		default_instruction = 42,
		enabled = 43,
		max_name_len = 44,
		api_key_env = 45,
		keep = 50,
		prefix = 51,
		ignore = 60,
		fixed = 61,
		files = 62,
	}
	local keys = {}
	for k in pairs(val) do
		if type(k) == "string" or type(k) == "number" then
			keys[#keys + 1] = k
		end
	end
	table.sort(keys, function(a, b)
		local pa = priority[a] or 100
		local pb = priority[b] or 100
		if pa ~= pb then return pa < pb end
		return tostring(a) < tostring(b)
	end)

	if #keys == 0 then return "{}" end

	-- Emit comments without trailing commas (join commas only after real fields).
	local lines = {}
	for _, k in ipairs(keys) do
		local child_path = path == "" and tostring(k) or (path .. "." .. tostring(k))
		-- Prefer dotted paths (e.g. "organize.files"); fall back to bare key
		-- names for shared pane fields (path / cmd / focus under any layout).
		local comment = KEY_COMMENTS[child_path]
			or (type(k) == "string" and KEY_COMMENTS[k])
			or nil
		if comment then
			lines[#lines + 1] = { kind = "comment", text = pad1 .. "-- " .. comment }
		end
		local key
		if type(k) == "string" and k:match("^[%a_][%w_]*$") then
			key = k
		else
			key = "[" .. serialize_value(k, 0) .. "]"
		end
		lines[#lines + 1] = {
			kind = "field",
			text = pad1 .. key .. " = " .. serialize_value(val[k], indent + 1, child_path),
		}
	end
	local parts = {}
	for _, line in ipairs(lines) do
		if line.kind == "comment" then
			parts[#parts + 1] = line.text
		else
			parts[#parts + 1] = line.text .. ","
		end
	end
	return "{\n" .. table.concat(parts, "\n") .. "\n" .. pad .. "}"
end

function M.serialize(data)
	local body = serialize_value(data or {}, 0, "")
	return table.concat({
		"-- logarktos.lua — project / user settings for logarktos.nvim",
		"",
		"return " .. body,
		"",
	}, "\n")
end

-- ── load / save ──────────────────────────────────────────────────────────────

function M.load_file(path)
	if not path or path == "" or not util.exists(path) then return nil end
	local chunk, err = loadfile(path)
	if not chunk then
		util.notify("Could not load " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
		return nil
	end
	local ok, data = pcall(chunk)
	if not ok then
		util.notify("Error running " .. path .. ": " .. tostring(data), vim.log.levels.ERROR)
		return nil
	end
	if type(data) ~= "table" then return {} end
	return data
end

function M.save_file(path, data)
	if not path or path == "" then return false end
	local dir = vim.fn.fnamemodify(path, ":h")
	if dir and dir ~= "" then util.ensure_dir(dir) end
	local text = M.serialize(data)
	local ok, write_err = pcall(vim.fn.writefile, vim.split(text, "\n", { plain = true }), path)
	if not ok then
		util.notify("Could not write " .. path .. ": " .. tostring(write_err), vim.log.levels.ERROR)
		return false
	end
	return true
end

--- After loading an on-disk folder config, add any standard keys that were
--- introduced after that file was written (e.g. `tabname`). Writes the file
--- when something was missing. Implemented below `deep_fill_missing` / folder
--- template; called via `M.apply_folder_defaults` at runtime.
function M.load_dir(dir)
	local path = M.path_in(dir)
	if not path then return nil end
	local data = M.load_file(path)
	if data then
		data._path = path
		data._dir = dir
		-- Older project files often predate keys like tabname — backfill on read
		-- so space+am / space+wm / tab naming always see a complete shape.
		M.persist_folder_defaults(data, dir)
		return data
	end
	-- Legacy logarktos.env → convert, fill standard keys, and write logarktos.lua.
	local legacy = util.join(dir, M.LEGACY_ENV)
	if util.exists(legacy) then
		local converted = M.parse_legacy_env(legacy, dir)
		if converted then
			converted._path = path
			converted._dir = dir
			converted._from_legacy = true
			M.persist_folder_defaults(converted, dir)
			return converted
		end
	end
	return nil
end

--- Load or create an empty table for `dir` (does not write yet).
function M.load_or_empty(dir)
	return M.load_dir(dir) or { _path = M.path_in(dir), _dir = dir }
end

function M.save_dir(dir, data)
	local path = M.path_in(dir)
	if not path then return false end
	local clean = vim.deepcopy(data)
	clean._path, clean._dir, clean._from_legacy = nil, nil, nil
	return M.save_file(path, clean)
end

-- ── legacy logarktos.env ─────────────────────────────────────────────────────

local function classify_legacy(base, raw)
	if type(raw) ~= "string" then return nil end
	raw = vim.trim(raw)
	if raw == "" then return nil end
	if M.is_absolute(raw) then
		local abs = util.normalize(raw)
		if util.is_dir(abs) or raw:match("[/\\]$") then
			return { kind = "path", path = abs }
		end
		return { kind = "cmd", cmd = raw, app = M.ai_app_name(raw) }
	end
	local joined = util.normalize(util.join(base, raw))
	if util.is_dir(joined) then
		return { kind = "path", path = joined }
	end
	if raw:match("[/\\]$") or (raw:match("[/\\]") and not raw:match("%s")) then
		return { kind = "path", path = joined }
	end
	return { kind = "cmd", cmd = raw, app = M.ai_app_name(raw) }
end

function M.parse_legacy_env(path, base)
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok or type(lines) ~= "table" then return nil end
	local left, center, right = {}, {}, {}
	for _, line in ipairs(lines) do
		local trimmed = vim.trim(line)
		if trimmed ~= "" and not trimmed:match("^#") then
			local key, value = trimmed:match("^([%w_]+)%s*:%s*(.*)$")
			if key then
				key = key:lower()
				local entry = classify_legacy(base, value)
				if entry then
					if key == "left" then left[#left + 1] = entry
					elseif key == "center" then center[#center + 1] = entry
					elseif key == "right" then right[#right + 1] = entry
					end
				end
			end
		end
	end

	local function pane_from_entries(entries)
		local pane = {}
		for _, e in ipairs(entries) do
			if e.kind == "path" and e.path and not pane.path then
				pane.path = M.rel_or_abs(e.path, base)
			elseif e.kind == "cmd" and e.cmd and not pane.cmd then
				pane.cmd = e.cmd
			end
		end
		if next(pane) then return pane end
		return nil
	end

	local function work_pane_from_entries(entries, default_mode)
		local pane = {
			mode = default_mode,
			path = ".",
			command = "",
			focus = "",
		}
		for _, e in ipairs(entries) do
			if e.kind == "path" and e.path and (not pane.path or pane.path == ".") then
				pane.path = M.rel_or_abs(e.path, base) or "."
			elseif e.kind == "cmd" and e.cmd and pane.command == "" then
				pane.command = e.cmd
				pane.mode = "terminal"
			end
		end
		return pane
	end

	return {
		work = {
			left = work_pane_from_entries(left, "terminal"),
			center = work_pane_from_entries(center, "oil"),
			right = work_pane_from_entries(right, "oil"),
		},
	}
end

-- ── organize section (per-folder :Organize) ──────────────────────────────────

--- Defaults written into every new/ensured `organize` block.
function M.default_organize()
	return {
		ignore = { "documents", "logarktos.lua" },
		fixed = {},
		files = "timestamps", -- or "extensions"
	}
end

--- Ensure `organize` exists in the folder's logarktos.lua; fill missing keys.
--- Creates the file when missing. Called by :Organize and when brand-new
--- logarktos.lua files are written.
--- @return table organize settings (ignore / fixed / files)
function M.ensure_organize(base)
	base = util.normalize(base or vim.fn.getcwd())
	local data = M.load_or_empty(base)
	local path = M.path_in(base)
	local file_missing = path and not util.exists(path)
	local defaults = M.default_organize()
	local changed = false

	if type(data.organize) ~= "table" then
		data.organize = vim.deepcopy(defaults)
		changed = true
	else
		local org = data.organize
		if type(org.ignore) ~= "table" then
			org.ignore = vim.deepcopy(defaults.ignore)
			changed = true
		end
		if type(org.fixed) ~= "table" then
			org.fixed = vim.deepcopy(defaults.fixed)
			changed = true
		end
		if type(org.files) ~= "string" or org.files == "" then
			org.files = defaults.files
			changed = true
		end
	end
	-- New files (and any still-missing top-level keys) get the full standard shape.
	if #M.apply_folder_defaults(data, base) > 0 then
		changed = true
	end

	if changed or file_missing or data._from_legacy then
		M.save_dir(base, data)
		data._from_legacy = nil
		if changed and not file_missing then
			util.notify("Wrote organize section to " .. (path or "logarktos.lua"), vim.log.levels.INFO)
		elseif file_missing then
			util.notify("Created " .. (path or "logarktos.lua") .. " with organize settings", vim.log.levels.INFO)
		end
	end
	return data.organize, data
end

--- Inject default organize into an in-memory table when the on-disk file is new.
local function seed_organize_if_new_file(data, file_missing)
	if file_missing and type(data.organize) ~= "table" then
		data.organize = M.default_organize()
		return true
	end
	return false
end

-- ── :Logarktos — refresh missing standard sections ───────────────────────────

--- Non-empty `tabname` from a folder's logarktos.lua, or nil when unset/empty.
--- @param dir string|nil
--- @return string|nil
function M.get_tabname(dir)
	if not dir or dir == "" then return nil end
	local data = M.load_dir(dir)
	if not data then return nil end
	local name = data.tabname
	if type(name) ~= "string" then return nil end
	name = vim.trim(name)
	if name == "" then return nil end
	return name
end

--- The standard per-folder logarktos.lua shape (all known top-level categories
--- and their nested keys). Used by :Logarktos to fill gaps without overwriting.
function M.folder_template(base)
	return {
		-- tabname: set this to pin layout tab titles for this folder.
		tabname = "",
		organize = M.default_organize(),
		work = M.default_work(base),
		textwork = M.default_textwork(base),
	}
end

--- Deep-fill `target` from `template`: only add keys that are absent.
--- Existing values (including empty tables/lists) are never replaced.
--- Recurses into map-shaped tables; list tables are treated as atomic values.
--- @return string[] dotted paths that were added
local function deep_fill_missing(target, template, prefix)
	prefix = prefix or ""
	local added = {}
	if type(target) ~= "table" or type(template) ~= "table" then
		return added
	end
	for k, v in pairs(template) do
		if type(k) == "string" or type(k) == "number" then
			local path = prefix == "" and tostring(k) or (prefix .. "." .. tostring(k))
			if target[k] == nil then
				target[k] = vim.deepcopy(v)
				added[#added + 1] = path
			elseif type(target[k]) == "table" and type(v) == "table"
				and not is_list(target[k]) and not is_list(v) then
				vim.list_extend(added, deep_fill_missing(target[k], v, path))
			end
		end
	end
	return added
end

--- Fill missing standard folder keys into an in-memory table (no write).
--- @return string[] dotted paths that were added
function M.apply_folder_defaults(data, dir)
	if type(data) ~= "table" then return {} end
	return deep_fill_missing(data, M.folder_template(dir))
end

--- Apply folder defaults and write the file when anything was missing (or the
--- table came from a legacy logarktos.env). Used by load_dir so every read of
--- an existing project file grows to the current standard shape.
--- @return string[] paths that were added (empty if already complete / no write)
function M.persist_folder_defaults(data, dir)
	if type(data) ~= "table" or not dir or dir == "" then return {} end
	local path = data._path or M.path_in(dir)
	local migrated = M.migrate_work_section(data, dir)
	local added = M.apply_folder_defaults(data, dir)
	local from_legacy = data._from_legacy
	if #added == 0 and #migrated == 0 and not from_legacy then
		return {}
	end
	if not M.save_dir(dir, data) then
		return {}
	end
	data._from_legacy = nil
	table.sort(added)
	if #migrated > 0 then
		local extra = #added > 0 and (" — also added: " .. table.concat(added, ", ")) or ""
		util.notify(
			"Updated " .. (path or "logarktos.lua") .. " — " .. table.concat(migrated, "; ") .. extra,
			vim.log.levels.INFO
		)
	elseif #added > 0 then
		util.notify(
			"Updated " .. (path or "logarktos.lua") .. " — added missing defaults: "
				.. table.concat(added, ", "),
			vim.log.levels.INFO
		)
	elseif from_legacy then
		util.notify(
			"Migrated logarktos.env → " .. (path or "logarktos.lua"),
			vim.log.levels.INFO
		)
	end
	return added
end

--- Directory for :Logarktos: Oil dir → current file's dir → cwd.
local function refresh_work_dir()
	if vim.bo.filetype == "oil" then
		local dir = util.oil_dir(0)
		if dir then return dir end
	end
	local name = vim.api.nvim_buf_get_name(0)
	if name ~= "" then return vim.fn.fnamemodify(name, ":p:h") end
	return vim.fn.getcwd()
end

--- Refresh this folder's logarktos.lua: keep every existing key, add any
--- standard category/key that is still missing. Creates the file when absent.
--- (Existing files are also auto-backfilled whenever they are loaded.)
--- @param dir string|nil  folder to refresh (default: Oil / buffer / cwd)
--- @return boolean ok, string[]|nil added_paths
function M.refresh(dir)
	dir = util.normalize(dir or refresh_work_dir())
	if not dir or dir == "" then
		util.notify("No directory to refresh", vim.log.levels.WARN)
		return false, nil
	end
	if vim.fn.isdirectory(dir) ~= 1 then
		util.notify("Not a directory: " .. dir, vim.log.levels.WARN)
		return false, nil
	end

	local path = M.path_in(dir)
	local file_missing = path and not util.exists(path)
	-- Load raw (not via load_dir) so this command owns notify / write once.
	-- Auto-backfill on other reads still goes through load_dir → persist_folder_defaults.
	local data
	if not file_missing then
		data = M.load_file(path) or {}
		data._path = path
		data._dir = dir
	else
		local legacy = util.join(dir, M.LEGACY_ENV)
		if util.exists(legacy) then
			data = M.parse_legacy_env(legacy, dir) or {}
			data._path = path
			data._dir = dir
			data._from_legacy = true
		else
			data = { _path = path, _dir = dir }
		end
	end
	local migrated = M.migrate_work_section(data, dir)
	local added = M.apply_folder_defaults(data, dir)

	if not (file_missing or #added > 0 or #migrated > 0 or data._from_legacy) then
		util.notify((path or "logarktos.lua") .. " is already up to date", vim.log.levels.INFO)
		return true, {}
	end

	if not M.save_dir(dir, data) then
		return false, nil
	end
	data._from_legacy = nil
	table.sort(added)

	if file_missing then
		util.notify(
			"Created " .. (path or "logarktos.lua")
				.. (#added > 0 and (" with " .. table.concat(added, ", ")) or ""),
			vim.log.levels.INFO
		)
	elseif #added > 0 then
		util.notify(
			"Updated " .. (path or "logarktos.lua") .. " — added: " .. table.concat(added, ", "),
			vim.log.levels.INFO
		)
	else
		util.notify("Rewrote " .. (path or "logarktos.lua") .. " from legacy format", vim.log.levels.INFO)
	end
	util.refresh_oil()
	return true, added
end

-- ── layout section ensure (WorkMode) ─────────────────────────────────────────

local VALID_MODES = { terminal = true, oil = true, empty = true }

--- Normalize a pane mode string. Accepts a few aliases; unknown → nil.
function M.normalize_mode(mode)
	if type(mode) ~= "string" then return nil end
	mode = vim.trim(mode):lower()
	if mode == "term" or mode == "shell" then mode = "terminal" end
	if mode == "scratch" or mode == "none" then mode = "empty" end
	if VALID_MODES[mode] then return mode end
	return nil
end

--- Stored path field: "" / "." / "root" all serialize as ".".
function M.normalize_path_field(raw)
	if type(raw) ~= "string" then return "." end
	raw = vim.trim(raw)
	if raw == "" or raw == "." or raw:lower() == "root" then return "." end
	return raw
end

--- Optional Oil-entry focus string from a pane table (empty/absent → nil).
local function pane_focus(pane)
	if type(pane) ~= "table" then return nil end
	local focus = pane.focus
	if type(focus) ~= "string" then return nil end
	focus = vim.trim(focus)
	if focus == "" then return nil end
	return focus
end

--- Resolve a stored pane into absolute paths / command / mode for layouts.
--- @param fallback_mode string|nil used when `pane.mode` is missing
local function pane_spec(pane, base, fallback_mode)
	if type(pane) ~= "table" then
		local mode = fallback_mode or "oil"
		return {
			mode = mode,
			cwd = base,
			path = base,
			command = nil,
			cmd = nil,
			app = nil,
			focus = nil,
		}
	end
	local mode = M.normalize_mode(pane.mode) or fallback_mode or "oil"
	local path = pane.path or pane.cwd
	local abs = path and M.resolve_path(path, base) or base
	local command = pane.command or pane.cmd
	if type(command) == "string" then command = vim.trim(command) end
	if command == "" then command = nil end
	if mode ~= "terminal" then command = nil end
	return {
		mode = mode,
		cwd = abs or base,
		path = abs,
		command = command,
		cmd = command,
		app = pane.app or M.ai_app_name(command),
		focus = pane_focus(pane),
	}
end

local function stored_work_pane(pane, fallback_mode)
	pane = type(pane) == "table" and pane or {}
	local command = pane.command or pane.cmd
	if type(command) ~= "string" then command = "" else command = vim.trim(command) end
	local focus = pane.focus
	if type(focus) ~= "string" then focus = "" end
	local mode = M.normalize_mode(pane.mode)
	if not mode then
		mode = fallback_mode or ((command ~= "") and "terminal" or "oil")
	end
	return {
		mode = mode,
		path = M.normalize_path_field(pane.path or pane.cwd),
		command = command,
		focus = focus,
	}
end

--- New WorkMode shape: named left/center/right pane tables (not a list of terminals).
local function is_new_work(w)
	if type(w) ~= "table" then return false end
	if type(w.center) == "table" and not is_list(w.center) then return true end
	if type(w.right) == "table" and is_list(w.right) then return false end
	if type(w.left) == "table" and not is_list(w.left) then return true end
	if type(w.right) == "table" and not is_list(w.right) then return true end
	return false
end

--- Rewrite leftover `aimode` / stacked-terminal `work` into the three-pane shape.
--- Existing new-shape values are kept; `aimode` is dropped once `work` owns the panes.
--- @return string[] notes describing what changed (empty if already current)
function M.migrate_work_section(data, _dir)
	if type(data) ~= "table" then return {} end
	local notes = {}
	local am = data.aimode
	local w = data.work

	if is_new_work(w) then
		for _, slot in ipairs({ "left", "center", "right" }) do
			local p = w[slot]
			if type(p) == "table" then
				if (p.command == nil or p.command == "")
					and type(p.cmd) == "string" and vim.trim(p.cmd) ~= ""
				then
					p.command = vim.trim(p.cmd)
					notes[#notes + 1] = slot .. ".cmd → command"
				end
				p.cmd = nil
				if p.mode == nil then
					local fallback = (slot == "left") and "terminal" or "oil"
					if type(p.command) == "string" and p.command ~= "" then
						fallback = "terminal"
					end
					p.mode = fallback
					notes[#notes + 1] = slot .. ".mode"
				end
				if p.path == nil and p.cwd ~= nil then
					p.path = p.cwd
					notes[#notes + 1] = slot .. ".cwd → path"
				end
			end
		end
		if am ~= nil then
			data.aimode = nil
			notes[#notes + 1] = "removed leftover aimode (WorkMode now owns the three panes)"
		end
		return notes
	end

	if type(am) == "table" and next(am) then
		data.work = {
			left = stored_work_pane(am.left, "terminal"),
			center = stored_work_pane(am.center, "oil"),
			right = stored_work_pane(am.right, "oil"),
		}
		data.aimode = nil
		notes[#notes + 1] = "migrated aimode → work"
		return notes
	end

	if type(w) == "table" and next(w) then
		data.work = M.default_work()
		notes[#notes + 1] = "replaced stacked-terminal work with three-pane WorkMode"
		return notes
	end

	return notes
end

--- Defaults WorkMode uses with no config (relative form for storage).
--- Plain only: terminal left (empty command) + Oil on the layout folder for
--- centre and right. No frontend/sdl or prompts heuristics — set mode / path /
--- command / focus by hand when you want them.
--- `path = "."` (or `"root"`) is the layout folder. `command` only fires when
--- `mode` is `"terminal"`. `focus` is the Oil-entry basename to land on.
function M.default_work_pane(mode)
	return {
		mode = mode or "oil",
		path = ".",
		command = "",
		focus = "",
	}
end

function M.default_work(_base)
	return {
		left = M.default_work_pane("terminal"),
		center = M.default_work_pane("oil"),
		right = M.default_work_pane("oil"),
	}
end

--- @deprecated WorkMode absorbed AIMode; kept so older callers still load.
function M.default_aimode(base)
	return M.default_work(base)
end

--- Defaults for TextWork (space+tw): dual views of one file + Oil of its folder.
--- `right.focus` empty → land Oil on the dual-pane file's basename.
function M.default_textwork(_base)
	return {
		right = {
			focus = "",
		},
	}
end

--- Ensure `work` exists in the folder's logarktos.lua; create/update file.
--- Migrates leftover `aimode` / stacked-terminal `work` into the three-pane
--- shape, then fills any missing nested keys without overwriting values.
--- @return table resolved { left, center, right } with mode / absolute paths / command
function M.ensure_work(base)
	base = util.normalize(base or vim.fn.getcwd())
	local data = M.load_or_empty(base)
	local path = M.path_in(base)
	local file_missing = path and not util.exists(path)
	local migrated = M.migrate_work_section(data, base)
	local section_missing = type(data.work) ~= "table" or not next(data.work) or not is_new_work(data.work)
	local filled = #migrated > 0
	if section_missing then
		data.work = M.default_work(base)
	else
		local added = deep_fill_missing(data.work, M.default_work(base))
		filled = filled or #added > 0
	end
	seed_organize_if_new_file(data, file_missing)
	if #M.apply_folder_defaults(data, base) > 0 then
		filled = true
	end
	if section_missing or file_missing or data._from_legacy or filled then
		M.save_dir(base, data)
		data._from_legacy = nil
		if #migrated > 0 then
			util.notify(
				"Updated " .. (path or "logarktos.lua") .. " — " .. table.concat(migrated, "; "),
				vim.log.levels.INFO
			)
		elseif section_missing then
			util.notify("Wrote work section to " .. (path or "logarktos.lua"), vim.log.levels.INFO)
		elseif filled then
			util.notify("Updated work section in " .. (path or "logarktos.lua"), vim.log.levels.INFO)
		elseif file_missing then
			util.notify("Created " .. (path or "logarktos.lua") .. " from layout settings", vim.log.levels.INFO)
		end
	end
	local w = data.work
	return {
		left = pane_spec(w.left, base, "terminal"),
		center = pane_spec(w.center, base, "oil"),
		right = pane_spec(w.right, base, "oil"),
		data = data,
	}
end

--- @deprecated WorkMode absorbed AIMode. Returns the same table as ensure_work.
function M.ensure_aimode(base)
	return M.ensure_work(base)
end

--- Ensure `textwork` exists; return resolved right-pane Oil focus.
--- Empty / absent `right.focus` means "use the dual-pane file's basename".
--- @return table { right_focus: string|nil, data: table }
function M.ensure_textwork(base)
	base = util.normalize(base or vim.fn.getcwd())
	local data = M.load_or_empty(base)
	local path = M.path_in(base)
	local file_missing = path and not util.exists(path)
	local section_missing = type(data.textwork) ~= "table" or not next(data.textwork)
	local filled = false
	if section_missing then
		data.textwork = M.default_textwork(base)
	else
		local added = deep_fill_missing(data.textwork, M.default_textwork(base))
		filled = #added > 0
	end
	seed_organize_if_new_file(data, file_missing)
	if #M.apply_folder_defaults(data, base) > 0 then
		filled = true
	end
	if section_missing or file_missing or data._from_legacy or filled then
		M.save_dir(base, data)
		data._from_legacy = nil
		if section_missing then
			util.notify("Wrote textwork section to " .. (path or "logarktos.lua"), vim.log.levels.INFO)
		elseif filled then
			util.notify("Updated textwork section in " .. (path or "logarktos.lua"), vim.log.levels.INFO)
		elseif file_missing then
			util.notify("Created " .. (path or "logarktos.lua") .. " from layout settings", vim.log.levels.INFO)
		end
	end
	local tw = data.textwork
	local right = type(tw.right) == "table" and tw.right or {}
	return {
		right_focus = pane_focus(right),
		data = data,
	}
end

-- ── user config (stdpath config) ─────────────────────────────────────────────

local USER_DEFAULTS = {
	start_dir = nil,
	ignore_dirs = { ".git", "node_modules", ".venv", "venv" },
	bufferfiles = {
		dir = nil, -- nil → plugin default under stdpath("state")
		keep = 20,
		prefix = "buffer-",
	},
	ai = {
		enabled = true,
		model = "gpt-4o-mini",
		max_input_chars = 1000,
		max_name_len = 60,
		default_instruction = "Please comment on the following content:",
		api_key_env = "OPENAI_API_KEY",
	},
	bookmarks = {},
	-- Per-folder organize defaults also seed the user config template.
	organize = M.default_organize(),
}

local function migrate_bookmarks_json()
	local candidates = {
		util.join(vim.fn.stdpath("data"), "bookmarks.json"),
		util.join(vim.fn.stdpath("data"), "logarktos", "bookmarks.json"),
	}
	for _, p in ipairs(candidates) do
		if util.exists(p) then
			local f = io.open(p, "r")
			if f then
				local ok, data = pcall(vim.json.decode, f:read("*a"))
				f:close()
				if ok and type(data) == "table" then
					local list = {}
					for _, item in ipairs(data) do
						if type(item) == "string" and item ~= "" then
							list[#list + 1] = item
						end
					end
					if #list > 0 then return list end
				end
			end
		end
	end
	return nil
end

--- Build the initial user file contents from defaults + optional seed table.
function M.user_template(seed)
	seed = seed or {}
	local data = vim.tbl_deep_extend("force", vim.deepcopy(USER_DEFAULTS), seed)
	if not data.bookmarks or #data.bookmarks == 0 then
		local migrated = migrate_bookmarks_json()
		if migrated then data.bookmarks = migrated end
	end
	return data
end

function M.load_user()
	local path = M.user_path()
	local data = M.load_file(path)
	if data then
		data._path = path
		return data
	end
	return nil
end

function M.save_user(data)
	local path = M.user_path()
	local clean = vim.deepcopy(data)
	clean._path, clean._dir, clean._from_legacy = nil, nil, nil
	return M.save_file(path, clean)
end

--- Load user file, creating it with defaults when missing.
--- @param seed table|nil  values to bake into a newly created file
function M.ensure_user(seed)
	local path = M.user_path()
	local data = M.load_file(path)
	if data then
		data._path = path
		return data, false
	end
	data = M.user_template(seed)
	M.save_file(path, data)
	data._path = path
	util.notify(
		"Created " .. path .. " with logarktos defaults.\n"
			.. "Put your OpenAI API key in a gitignored .env as OPENAI_API_KEY "
			.. "(or set that environment variable).",
		vim.log.levels.INFO
	)
	return data, true
end

--- Map user-file keys onto the plugin setup() option tree.
function M.user_to_setup_opts(user)
	if type(user) ~= "table" then return {} end
	local opts = {}
	if user.start_dir and user.start_dir ~= "" then
		opts.triplicate = opts.triplicate or {}
		opts.triplicate.dir = user.start_dir
	end
	if type(user.ignore_dirs) == "table" then
		opts.recentfiles = opts.recentfiles or {}
		-- Union with plugin defaults so a custom list cannot drop .git / .venv.
		local seen, merged = {}, {}
		local function add(list)
			for _, d in ipairs(list or {}) do
				if type(d) == "string" and d ~= "" and not seen[d] then
					seen[d] = true
					merged[#merged + 1] = d
				end
			end
		end
		add(require("logarktos.config").defaults.recentfiles.ignore_dirs)
		add(user.ignore_dirs)
		opts.recentfiles.ignore_dirs = merged
	end
	if type(user.bufferfiles) == "table" then
		opts.bufferfiles = vim.tbl_deep_extend("force", {}, user.bufferfiles)
	end
	if type(user.ai) == "table" then
		opts.ai = vim.tbl_deep_extend("force", {}, user.ai)
	end
	-- bookmarks list is consumed by bookmarks.lua, not setup merge
	return opts
end

--- Update bookmarks array in the user file (creates file if needed).
function M.set_user_bookmarks(list)
	local data = M.load_user() or M.user_template()
	data.bookmarks = list or {}
	M.save_user(data)
	return data
end

function M.get_user_bookmarks()
	local data = M.load_user()
	if data and type(data.bookmarks) == "table" then
		local out = {}
		for _, p in ipairs(data.bookmarks) do
			if type(p) == "string" and p ~= "" then out[#out + 1] = p end
		end
		return out
	end
	return nil
end

return M
