-- logarktos/envfile.lua ── compatibility shim
--
-- Layout / project config now lives in logarktos.lua (see logarktos.rcfile).
-- This module re-exports AI app helpers and a thin legacy loader used by
-- layouts that still honour optional left/center/right path overrides.

local rcfile = require("logarktos.rcfile")
local util = require("logarktos.util")

local M = {}

M.AI_APPS = rcfile.AI_APPS
M.ai_app_name = rcfile.ai_app_name
M.is_absolute = rcfile.is_absolute

--- Classify a raw string as path or command (legacy helpers).
function M.classify(base, raw)
	if type(raw) ~= "string" then return nil end
	raw = vim.trim(raw)
	if raw == "" then return nil end
	if rcfile.is_absolute(raw) then
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
	if raw:match("[/\\]$") then
		return { kind = "path", path = joined }
	end
	if raw:match("[/\\]") and not raw:match("%s") then
		return { kind = "path", path = joined }
	end
	return { kind = "cmd", cmd = raw, app = M.ai_app_name(raw) }
end

local function entries_from_pane(pane, base)
	local out = {}
	if type(pane) ~= "table" then return out end
	if pane.path or pane.cwd then
		local abs = rcfile.resolve_path(pane.path or pane.cwd, base)
		if abs then out[#out + 1] = { kind = "path", path = abs } end
	end
	if pane.cmd and pane.cmd ~= "" then
		out[#out + 1] = { kind = "cmd", cmd = pane.cmd, app = M.ai_app_name(pane.cmd) }
	end
	return out
end

--- Load optional path overrides for non-AIMode/Work layouts.
--- Prefers logarktos.lua `paths` / flat left-center-right / aimode panes;
--- falls back to legacy logarktos.env.
function M.load(dir)
	if not dir or dir == "" then return nil end
	local data = rcfile.load_dir(dir)
	if not data then return nil end

	local left, center, right = {}, {}, {}
	local paths = data.paths
	if type(paths) == "table" then
		left = entries_from_pane(paths.left or paths[1], dir)
		center = entries_from_pane(paths.center or paths[2], dir)
		right = entries_from_pane(paths.right or paths[3], dir)
	elseif data.left or data.center or data.right then
		left = entries_from_pane(data.left, dir)
		center = entries_from_pane(data.center, dir)
		right = entries_from_pane(data.right, dir)
	elseif type(data.aimode) == "table" then
		left = entries_from_pane(data.aimode.left, dir)
		center = entries_from_pane(data.aimode.center, dir)
		right = entries_from_pane(data.aimode.right, dir)
	else
		return nil
	end

	return {
		present = true,
		left = left,
		center = center,
		right = right,
	}
end

function M.first_path(entries)
	if not entries then return nil end
	for _, e in ipairs(entries) do
		if e.kind == "path" and e.path then return e.path end
	end
	return nil
end

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
