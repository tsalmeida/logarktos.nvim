-- logarktos/rcfile.lua ── load / save `logarktos.lua` (user + per-folder)
--
-- Per-folder files describe layout panes (aimode / work). The special file at
-- stdpath("config")/logarktos.lua also holds user preferences (start_dir,
-- bufferfiles, ignore_dirs, bookmarks, AI model/limits, …). API keys stay in
-- the real environment / a gitignored `.env` — never in these Lua files.
--
-- Example (user / nvim config root):
--   return {
--     start_dir = "C:/Logarktos/logarktos/",
--     ignore_dirs = { ".git", "node_modules" },
--     bufferfiles = { dir = "C:/…/bufferfiles/" },
--     ai = { model = "gpt-5-mini", max_input_chars = 1000, default_instruction = "…" },
--     bookmarks = { "C:/path/to/file" },
--     aimode = { left = { cmd = "grok --yolo" }, center = { path = "documents/prompts" } },
--     work = { right = { {}, {} } },
--   }
--
-- Example (any project folder — layout only):
--   return {
--     aimode = {
--       left = { cmd = "grok --yolo" },
--       center = { path = "documents/prompts" },
--       right = { path = "frontend/sdl" },
--     },
--     work = {
--       right = { { cmd = "codex" }, { cmd = "grok --yolo" } },
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
function M.resolve_path(raw, base)
	if not raw or raw == "" or raw == "." then
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

local function serialize_value(val, indent)
	indent = indent or 0
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
				parts[#parts + 1] = serialize_value(v, 0)
			end
			return "{ " .. table.concat(parts, ", ") .. " }"
		end
		for _, v in ipairs(val) do
			parts[#parts + 1] = pad1 .. serialize_value(v, indent + 1)
		end
		return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. pad .. "}"
	end

	-- map: stable key order (known keys first, then alpha)
	local priority = {
		start_dir = 1,
		ignore_dirs = 2,
		bufferfiles = 3,
		ai = 4,
		bookmarks = 5,
		aimode = 10,
		work = 11,
		left = 20,
		center = 21,
		right = 22,
		path = 30,
		cmd = 31,
		cwd = 32,
		dir = 33,
		model = 40,
		max_input_chars = 41,
		default_instruction = 42,
		enabled = 43,
		max_name_len = 44,
		api_key_env = 45,
		keep = 50,
		prefix = 51,
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

	local parts = {}
	for _, k in ipairs(keys) do
		local key
		if type(k) == "string" and k:match("^[%a_][%w_]*$") then
			key = k
		else
			key = "[" .. serialize_value(k, 0) .. "]"
		end
		parts[#parts + 1] = pad1 .. key .. " = " .. serialize_value(val[k], indent + 1)
	end
	return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. pad .. "}"
end

function M.serialize(data)
	local body = serialize_value(data or {}, 0)
	return table.concat({
		"-- logarktos.lua — project / user settings for logarktos.nvim",
		"-- Edited by the plugin when layouts are first opened, or when bookmarks change.",
		"-- Keep secrets (API keys) out of this file; use a gitignored .env instead.",
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

function M.load_dir(dir)
	local path = M.path_in(dir)
	if not path then return nil end
	local data = M.load_file(path)
	if data then
		data._path = path
		data._dir = dir
		return data
	end
	-- Legacy logarktos.env → in-memory table (not rewritten until a section is saved).
	local legacy = util.join(dir, M.LEGACY_ENV)
	if util.exists(legacy) then
		local converted = M.parse_legacy_env(legacy, dir)
		if converted then
			converted._path = path
			converted._dir = dir
			converted._from_legacy = true
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

	local aimode = {}
	local lp = pane_from_entries(left)
	local cp = pane_from_entries(center)
	local rp = pane_from_entries(right)
	if lp then aimode.left = lp end
	if cp then aimode.center = cp end
	if rp then aimode.right = { path = rp.path } end -- right cmds belong to work

	local work = {}
	if lp and lp.path then work.left = { path = lp.path } end
	local right_list = {}
	local right_path
	for _, e in ipairs(right) do
		if e.kind == "path" and e.path and not right_path then
			right_path = M.rel_or_abs(e.path, base)
		elseif e.kind == "cmd" and e.cmd then
			right_list[#right_list + 1] = { cmd = e.cmd }
		end
	end
	if right_path then
		if #right_list == 0 then
			right_list = { { path = right_path }, { path = right_path } }
		else
			for _, item in ipairs(right_list) do
				item.path = item.path or right_path
			end
		end
	end
	if #right_list > 0 then work.right = right_list end

	local out = {}
	if next(aimode) then out.aimode = aimode end
	if next(work) then out.work = work end
	return next(out) and out or {}
end

-- ── layout section ensure (AIMode / Work) ────────────────────────────────────

local function pane_spec(pane, base)
	if type(pane) ~= "table" then
		return { cwd = base, path = nil, cmd = nil, app = nil }
	end
	local path = pane.path or pane.cwd
	local abs = path and M.resolve_path(path, base) or base
	local cmd = pane.cmd
	if type(cmd) == "string" then cmd = vim.trim(cmd) end
	if cmd == "" then cmd = nil end
	return {
		cwd = abs or base,
		path = abs,
		cmd = cmd,
		app = pane.app or M.ai_app_name(cmd),
	}
end

--- Defaults AIMode would use with no config (relative form for storage).
function M.default_aimode(base)
	base = util.normalize(base)
	local prompts = util.join(base, "documents", "prompts")
	local center = util.is_dir(prompts) and prompts or base
	local project = util.project_root(base) or base
	local sdl = util.join(project, "frontend", "sdl")
	local right = util.is_dir(sdl) and sdl or base
	return {
		left = {}, -- terminal at base, no command
		center = { path = M.rel_or_abs(center, base) or "." },
		right = { path = M.rel_or_abs(right, base) or "." },
	}
end

function M.default_work(_base)
	return {
		-- left omitted → keep current buffer
		right = {
			{}, -- top terminal, plain shell
			{}, -- bottom terminal, plain shell
		},
	}
end

--- Ensure `aimode` exists in the folder's logarktos.lua; create/update file.
--- @return table resolved { left, center, right } with absolute paths/cmds
function M.ensure_aimode(base)
	base = util.normalize(base or vim.fn.getcwd())
	local data = M.load_or_empty(base)
	local path = M.path_in(base)
	local file_missing = path and not util.exists(path)
	local section_missing = type(data.aimode) ~= "table" or not next(data.aimode)
	if section_missing then
		data.aimode = M.default_aimode(base)
	end
	if section_missing or file_missing or data._from_legacy then
		M.save_dir(base, data)
		data._from_legacy = nil
		if section_missing then
			util.notify("Wrote aimode section to " .. (path or "logarktos.lua"), vim.log.levels.INFO)
		elseif file_missing then
			util.notify("Created " .. (path or "logarktos.lua") .. " from layout settings", vim.log.levels.INFO)
		end
	end
	local am = data.aimode
	return {
		left = pane_spec(am.left, base),
		center = pane_spec(am.center, base),
		right = pane_spec(am.right, base),
		data = data,
	}
end

--- Ensure `work` exists; return resolved left + right terminal specs.
function M.ensure_work(base)
	base = util.normalize(base or vim.fn.getcwd())
	local data = M.load_or_empty(base)
	local path = M.path_in(base)
	local file_missing = path and not util.exists(path)
	local section_missing = type(data.work) ~= "table" or not next(data.work)
	if section_missing then
		data.work = M.default_work(base)
	end
	if section_missing or file_missing or data._from_legacy then
		M.save_dir(base, data)
		data._from_legacy = nil
		if section_missing then
			util.notify("Wrote work section to " .. (path or "logarktos.lua"), vim.log.levels.INFO)
		elseif file_missing then
			util.notify("Created " .. (path or "logarktos.lua") .. " from layout settings", vim.log.levels.INFO)
		end
	end
	local w = data.work
	local left = w.left and pane_spec(w.left, base) or nil
	local right_entries = w.right
	local top, bot
	if type(right_entries) == "table" and is_list(right_entries) then
		top = pane_spec(right_entries[1] or {}, base)
		bot = pane_spec(right_entries[2] or right_entries[1] or {}, base)
	elseif type(right_entries) == "table" then
		-- single pane table reused for both
		top = pane_spec(right_entries, base)
		bot = pane_spec(right_entries, base)
	else
		top = { cwd = base, cmd = nil, app = nil }
		bot = { cwd = base, cmd = nil, app = nil }
	end
	return {
		left = left,
		top = top,
		bot = bot,
		data = data,
	}
end

-- ── user config (stdpath config) ─────────────────────────────────────────────

local USER_DEFAULTS = {
	start_dir = nil,
	ignore_dirs = { ".git", "node_modules" },
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
		opts.recentfiles.ignore_dirs = user.ignore_dirs
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
