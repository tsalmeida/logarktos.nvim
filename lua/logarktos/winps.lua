-- logarktos/winps.lua ── nested Windows PowerShell 5.1 from a pwsh parent
--
-- PowerShell 7 prepends its module directories to PSModulePath. It sanitizes
-- that variable only when *it* starts powershell.exe as a direct child.
-- Native tools in between (Codex, rustup, cmd, Neovim) pass the unsanitized
-- value through, and 5.1 then prefers the Core Microsoft.PowerShell.Utility
-- — so Get-FileHash / New-Guid / etc. vanish (PowerShell#18108,
-- openai/codex#34030).
--
-- Retrying the original command after that error is the wrong shape:
-- installers may have already downloaded a payload. Instead we drop
-- PSModulePath after 7 has started (inbox cmdlets stay loaded from
-- $PSHOME) so grandchild 5.1 rebuilds Desktop defaults.

local M = {}

local IS_WIN = vim.fn.has("win32") == 1
local did_setup = false

--- -Command body for an interactive pwsh/powershell that should host native
--- tools which themselves spawn Windows PowerShell 5.1.
M.NESTED_FIX_COMMAND = "Remove-Item Env:PSModulePath -ErrorAction SilentlyContinue"

--- Append `-NoExit -Command <fix>` to a Windows PowerShell argv.
--- @param argv string[]
--- @return string[]
function M.append_nested_fix(argv)
	argv[#argv + 1] = "-NoExit"
	argv[#argv + 1] = "-Command"
	argv[#argv + 1] = M.NESTED_FIX_COMMAND
	return argv
end

--- Unset PSModulePath on the Neovim process so `vim.system({ "powershell",
--- … })` / jobstart 5.1 children (Neovim is itself an intermediate process
--- when launched from pwsh) rebuild Desktop defaults.
function M.setup()
	if not IS_WIN or did_setup then return end
	did_setup = true
	vim.env.PSModulePath = nil
end

return M
