-- logarktos/template.lua ── reading a :NewMarkdown template, includes expanded
--
-- A template line that holds only the include marker and a path, such as
--
--   *include_attachment* "L:/Vault/Documents/Others/Logarktos-briefing.md"
--
-- is replaced by that file's lines when a note is seeded from the template, so
-- text that many templates share lives in one file instead of a copy in each.
-- The path may be absolute, relative to the file that holds the line, or use
-- %VAR%, $VAR or ~. An included file may include others. A line whose file
-- cannot be read is left exactly as written, so a broken include shows up in
-- the note instead of silently vanishing.
local config = require("logarktos.config")
local util = require("logarktos.util")
local uv = util.uv

local M = {}

local MAX_DEPTH = 8

--- The path an include line names, or nil when `line` is not an include line.
local function include_target(line, marker)
	local s, e = line:find(marker, 1, true)
	if not s or vim.trim(line:sub(1, s - 1)) ~= "" then return nil end
	local rest = vim.trim(line:sub(e + 1))
	local target = vim.trim(rest:match('^"(.*)"$') or rest:match("^'(.*)'$") or rest)
	return target ~= "" and target or nil
end

local function resolve(target, base_dir)
	local path = target:gsub("%%([%w_]+)%%", function(name) return uv.os_getenv(name) end)
	path = path:gsub("%$([%a_][%w_]*)", function(name) return uv.os_getenv(name) end)
	if path:sub(1, 1) == "~" then path = (uv.os_homedir() or "~") .. path:sub(2) end
	if not (path:match("^%a:[/\\]") or path:match("^[/\\]")) then path = util.join(base_dir, path) end
	return path
end

--- Read a template with its include lines expanded.
--- @return string[]|nil lines nil when `path` itself cannot be read
--- @return string[] problems includes that could not be expanded, and why
function M.read(path)
	local marker = (config.options.markdown and config.options.markdown.include_marker) or ""
	local problems = {}

	local function read(file, depth, open)
		local ok, lines = pcall(vim.fn.readfile, file)
		if not ok then return nil end
		local out = {}
		local dir = vim.fn.fnamemodify(file, ":h")
		for i, line in ipairs(lines) do
			-- A CRLF file or a byte-order mark would otherwise leak into the note.
			line = line:gsub("\r$", "")
			if i == 1 then line = line:gsub("^\239\187\191", "") end
			local target = marker ~= "" and include_target(line, marker) or nil
			if not target then
				out[#out + 1] = line
			else
				local included
				local resolved = resolve(target, dir)
				local key = util.normalize(resolved):lower()
				if open[key] then
					problems[#problems + 1] = resolved .. " includes itself"
				elseif depth >= MAX_DEPTH then
					problems[#problems + 1] = resolved .. " is nested more than " .. MAX_DEPTH .. " deep"
				elseif not uv.fs_stat(resolved) then
					problems[#problems + 1] = "cannot find " .. resolved
				else
					open[key] = true
					included = read(resolved, depth + 1, open)
					open[key] = nil
					if not included then problems[#problems + 1] = "cannot read " .. resolved end
				end
				if included then
					vim.list_extend(out, included)
				else
					out[#out + 1] = line
				end
			end
		end
		return out
	end

	return read(path, 0, { [util.normalize(path):lower()] = true }), problems
end

return M
