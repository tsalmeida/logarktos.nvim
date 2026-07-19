-- logarktos/envfile.lua ── per-project logarktos.env for layout panes
--
-- Drop a `logarktos.env` in a project (or any folder you open a layout from).
-- Layout openers (AIMode, Work, Large, Triple, …) read it and redirect panes.
--
-- Format (one directive per line; blank lines and # comments ignored):
--   left:path/to/
--   center:documents/prompts/
--   right:frontend/sdl/
--   left:codex --dangerously-bypass-approvals-and-sandbox
--   right:grok --yolo
--
-- The same key may appear more than once (e.g. two `right:` lines for Work
-- mode's stacked terminals). Values that resolve to a directory (absolute, or
-- relative to the layout's base folder) are paths; everything else is a shell
-- command to launch in that pane's terminal.

local util = require("logarktos.util")

local M = {}

--- Known AI CLI app names. Used to tag tabs as `codex-<title>` etc.
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

local PANE_KEYS = { left = true, center = true, right = true }

function M.is_absolute(path)
	if not path or path == "" then return false end
	-- Windows drive or UNC; Unix root.
	if path:match("^%a:[/\\]") then return true end
	if path:match("^\\\\") or path:match("^//") then return true end
	if path:match("^/") then return true end
	return false
end

--- Extract a bare AI app id from a command string or process name, or nil.
function M.ai_app_name(text)
	if not text or text == "" then return nil end
	local token = tostring(text):match("^%s*(%S+)") or ""
	-- Strip surrounding quotes and Windows path noise.
	token = token:gsub("^[\"']", ""):gsub("[\"']$", "")
	token = token:gsub("%.exe$", ""):gsub("%.cmd$", ""):gsub("%.bat$", "")
	token = util.basename(token) or token
	token = token:lower()
	if M.AI_APPS[token] then return token end
	return nil
end

--- Classify a raw env value into a path entry and/or a command entry.
--- @param base string  layout base directory
--- @param raw string
--- @return table|nil  { kind = "path"|"cmd", path?, cmd?, app? }
function M.classify(base, raw)
	if type(raw) ~= "string" then return nil end
	raw = vim.trim(raw)
	if raw == "" then return nil end

	-- Absolute directory → path.
	if M.is_absolute(raw) then
		local abs = util.normalize(raw)
		if util.is_dir(abs) or raw:match("[/\\]$") then
			return { kind = "path", path = abs }
		end
		-- Absolute non-dir (e.g. full path to an exe) → command.
		return { kind = "cmd", cmd = raw, app = M.ai_app_name(raw) }
	end

	-- Relative path under base that exists as a directory → path.
	local joined = util.normalize(util.join(base, raw))
	if util.is_dir(joined) then
		return { kind = "path", path = joined }
	end

	-- Looks like a path (has a separator, or trailing slash, and no spaces).
	-- Keep as path even if the folder is missing so the user can create it later.
	if raw:match("[/\\]$") then
		return { kind = "path", path = joined }
	end
	if raw:match("[/\\]") and not raw:match("%s") then
		return { kind = "path", path = joined }
	end

	-- Otherwise treat as a shell command (possibly an AI CLI + flags).
	return { kind = "cmd", cmd = raw, app = M.ai_app_name(raw) }
end

--- Parse a logarktos.env file body. Returns a table with optional left/center/right
--- arrays of classified entries, plus `present = true` when the file was read.
function M.parse(text, base)
	local out = { left = {}, center = {}, right = {}, present = true }
	if type(text) ~= "string" then return out end
	base = base or vim.fn.getcwd()

	for line in (text .. "\n"):gmatch("(.-)\r?\n") do
		local trimmed = vim.trim(line)
		if trimmed ~= "" and not trimmed:match("^#") then
			local key, value = trimmed:match("^([%w_]+)%s*:%s*(.*)$")
			if key then
				key = key:lower()
				if PANE_KEYS[key] then
					local entry = M.classify(base, value)
					if entry then
						out[key][#out[key] + 1] = entry
					end
				end
			end
		end
	end
	return out
end

--- Load and parse logarktos.env from `dir` (if present). Returns nil when absent.
function M.load(dir)
	if not dir or dir == "" then return nil end
	local path = util.join(dir, "logarktos.env")
	if not util.exists(path) then return nil end
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok or type(lines) ~= "table" then return nil end
	return M.parse(table.concat(lines, "\n"), dir)
end

--- First path entry in a pane list, or nil.
function M.first_path(entries)
	if not entries then return nil end
	for _, e in ipairs(entries) do
		if e.kind == "path" and e.path then return e.path end
	end
	return nil
end

--- Command entries only (in order).
function M.commands(entries)
	local cmds = {}
	if not entries then return cmds end
	for _, e in ipairs(entries) do
		if e.kind == "cmd" and e.cmd then
			cmds[#cmds + 1] = e
		end
	end
	return cmds
end

--- Resolve cwd + optional command for a terminal pane from its env entries.
--- Path entries set the cwd; the first command entry is launched (if any).
function M.terminal_spec(entries, default_cwd)
	local cwd = default_cwd
	local cmd, app = nil, nil
	if entries then
		for _, e in ipairs(entries) do
			if e.kind == "path" and e.path then
				cwd = e.path
			elseif e.kind == "cmd" and e.cmd and not cmd then
				cmd = e.cmd
				app = e.app
			end
		end
	end
	return { cwd = cwd, cmd = cmd, app = app }
end

return M
