-- logarktos.nvim ── a workspace plugin for task-oriented tab layouts, persistent
-- scratch buffers, timestamped notes, and chronological file organization.
--
-- Quick start (polite defaults — nothing is forced on you):
--   require("logarktos").setup()
--
-- Opt into behaviour:
--   require("logarktos").setup({
--     keymaps = true,                       -- install the default keymaps
--     startup = { layout = "triplicate" },  -- open a layout on VimEnter
--   })
local config = require("logarktos.config")

local M = {}

M.config = config

local did_setup = false

local function install_startup(startup)
	if not startup then return end
	local opts = (type(startup) == "table") and startup or {}
	local layout = opts.layout or "triplicate"
	local grp = vim.api.nvim_create_augroup("LogarktosStartup", { clear = true })
	vim.api.nvim_create_autocmd("VimEnter", {
		group = grp,
		once = true,
		callback = function()
			-- Defer so the UI and other plugins are fully ready (GUI-safe).
			vim.schedule(function()
				vim.schedule(function()
					if layout == "triplicate" then
						require("logarktos.triplicate").open({ dir = opts.dir, large = opts.large })
					else
						local L = require("logarktos.layouts")
						local fn = ({
							large = L.large_mode_tab,
							new_large = L.new_large_tab,
							focus = L.focus_mode_tab,
							work = L.work_mode_tab,
							triple = L.triple_mode_tab,
							dual = L.dual_mode_tab,
						})[layout]
						if fn then fn() end
					end
				end)
			end)
		end,
	})
end

--- Configure and activate logarktos.
--- @param opts table|nil  see logarktos.config for the full schema
function M.setup(opts)
	opts = opts or {}

	-- User file at stdpath("config")/logarktos.lua: start_dir, ignore_dirs,
	-- bufferfiles, ai prefs, bookmarks, and optional aimode/work for that folder.
	-- setup() opts win over the file so the plugin list can still force keymaps etc.
	local rcfile = require("logarktos.rcfile")
	local seed = {}
	if opts.triplicate and opts.triplicate.dir then
		seed.start_dir = opts.triplicate.dir
	end
	if opts.bufferfiles and opts.bufferfiles.dir then
		seed.bufferfiles = { dir = opts.bufferfiles.dir }
	end
	if opts.ai then
		seed.ai = vim.deepcopy(opts.ai)
	end
	local user = rcfile.ensure_user(seed)
	local from_user = rcfile.user_to_setup_opts(user)
	local merged = vim.tbl_deep_extend("force", from_user, opts)
	local cfg = config.merge(merged)

	if cfg.bufferfiles and cfg.bufferfiles.enabled then
		require("logarktos.bufferfiles").setup()
	end

	if cfg.focus then
		require("logarktos.layouts").focus_setup()
	end

	if cfg.tabs and cfg.tabs.tabline then
		require("logarktos.tabs").enable_tabline()
	end

	require("logarktos.commands").setup()
	require("logarktos.keymaps").setup()

	install_startup(cfg.startup)

	did_setup = true
	return M
end

-- Convenience re-exports so `require("logarktos").<module>` works without setup.
setmetatable(M, {
	__index = function(_, key)
		local ok, mod = pcall(require, "logarktos." .. key)
		if ok then return mod end
		return nil
	end,
})

return M
