-- logarktos/cwd.lua ── window-local working-directory mode (Local / Root)
--
-- Sometimes pickers, terminals and explorers should operate from the *current*
-- folder; sometimes from the *project root*. This toggles a window-local mode
-- and pins the window-local cwd accordingly. Other tools can read
-- `vim.w.pwd_mode` / `vim.t.pwd_mode` ("local" | "root") to scope themselves.
local util = require("logarktos.util")

local M = {}

local function project_root_for(path)
	path = path or vim.fn.expand("%:p")
	local start = (vim.fn.isdirectory(path) == 1) and path or vim.fn.fnamemodify(path, ":p:h")
	local found = vim.fs.find({ ".git", "package.json", "artisan", "composer.json" }, { path = start, upward = true })
	return (#found > 0) and vim.fs.dirname(found[1]) or start
end

--- Pin the window-local cwd to the current buffer's directory (Local mode).
function M.local_here()
	local path = (vim.bo.filetype == "oil") and util.oil_dir(0) or vim.fn.expand("%:p:h")
	if path and path ~= "" then
		vim.cmd("lcd " .. vim.fn.fnameescape(path))
		vim.w.pwd_mode = "local"
		util.notify("CWD ➜ " .. path, vim.log.levels.INFO, "Local")
	end
end

--- Pin the window-local cwd to the project root (Root mode).
function M.root_here()
	local root = project_root_for(vim.fn.expand("%:p"))
	vim.cmd("lcd " .. vim.fn.fnameescape(root))
	vim.w.pwd_mode = "root"
	util.notify("CWD ➜ " .. root, vim.log.levels.INFO, "Root")
end

--- The current effective mode for the active window ("local" | "root").
function M.mode()
	return vim.w.pwd_mode or vim.t.pwd_mode or "local"
end

return M
