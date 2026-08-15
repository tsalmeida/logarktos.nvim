-- logarktos/bufferfiles.lua ── auto-named, autosaved scratch buffers
--
-- Write scratch notes in any empty buffer; the moment it gains text it is given
-- a name under the bufferfiles root and autosaved. You never lose a scratch note
-- and never have to decide where to put it. :w on an unnamed or nofile editor
-- buffer also saves as a bufferfile — there is no "cannot write" empty buffer.
--
-- Policy:
--   • Root holds at most `keep` most-recent files (by mtime).
--   • Older files move to ROOT/archive/  (never scanned).
--   • Files renamed away from the standard prefix are timestamped and moved to
--     ROOT/named/ (never scanned).
--   • Standard pattern (auto-created): <prefix>YYYYMMDD-HHMMSS(-N?).md

local config = require("logarktos.config")
local util = require("logarktos.util")
local uv = util.uv

local M = {}

local path_sep = package.config:sub(1, 1)

local function join(a, b)
	if a:sub(-1) == path_sep then return a .. b end
	return a .. path_sep .. b
end

local function prefix()
	return (config.options.bufferfiles and config.options.bufferfiles.prefix) or "buffer-"
end

local function keep_n()
	return (config.options.bufferfiles and config.options.bufferfiles.keep) or 20
end

-- ── dirs ─────────────────────────────────────────────────────────────────────
local function default_root()
	return vim.fs.normalize(vim.fs.joinpath(vim.fn.stdpath("state"), "logarktos", "bufferfiles"))
end

local function get_root_dir()
	-- Prefer setup / user logarktos.lua (bufferfiles.dir). $BUFFERFILES_DIR is
	-- still honoured as a last-resort override for old shells.
	local cfg = config.options.bufferfiles and config.options.bufferfiles.dir
	if cfg and cfg ~= "" then
		local p = vim.fs.normalize(cfg)
		vim.fn.mkdir(p, "p")
		return p
	end
	local env_dir = vim.env.BUFFERFILES_DIR
	if env_dir and env_dir ~= "" then
		local p = vim.fs.normalize(env_dir)
		local st = uv.fs_stat(p)
		if st and st.type == "directory" then return p end
	end
	local p = default_root()
	if uv.fs_stat(p) == nil then vim.fn.mkdir(p, "p") end
	return p
end

local function ensure_dir(p)
	if uv.fs_stat(p) == nil then vim.fn.mkdir(p, "p") end
end

local function subdirs()
	local root = get_root_dir()
	local archive = join(root, "archive")
	local named = join(root, "named")
	ensure_dir(archive)
	ensure_dir(named)
	return root, archive, named
end

-- ── filename policy ──────────────────────────────────────────────────────────
local function is_standard_filename(name)
	return vim.startswith(name, prefix())
end

local function now_ymd_hms()
	local stamp = os.date("%Y%m%d-%H%M%S")
	local ymd, hms = stamp:match("^(%d+)%-(%d+)$")
	return ymd, hms
end

local function sanitize_base(name)
	local base = name:gsub("%.%w+$", "")
	base = base:gsub("[^%w%-_ ]+", " ")
	base = vim.trim(base):gsub("%s+", "-")
	local pfx = prefix()
	if vim.startswith(base, pfx) then
		base = base:sub(#pfx + 1)
		if base == "" then base = "buffer" end
	end
	if base == "" then base = "file" end
	return base
end

local function rename_move(src, dst_dir, new_name)
	ensure_dir(dst_dir)
	local target = join(dst_dir, new_name)
	if uv.fs_stat(target) ~= nil then
		local root, ext = new_name:match("^(.*)(%.[^.]*)$")
		root, ext = root or new_name, ext or ""
		local i = 2
		while true do
			local cand_path = join(dst_dir, string.format("%s-%d%s", root, i, ext))
			if uv.fs_stat(cand_path) == nil then
				target = cand_path
				break
			end
			i = i + 1
		end
	end
	local ok, err = uv.fs_rename(src, target)
	if not ok then ok, err = os.rename(src, target) end
	return ok, err, target
end

-- ── buffer detection / naming ────────────────────────────────────────────────
local function buffer_has_text(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
	if #lines == 0 then return false end
	if #lines == 1 and lines[1] == "" then return false end
	return true
end

local confirm_state = { level = 0, prev = nil }
local function disable_confirm()
	if confirm_state.level == 0 then
		confirm_state.prev = vim.o.confirm
		vim.o.confirm = false
	end
	confirm_state.level = confirm_state.level + 1
end
local function restore_confirm()
	if confirm_state.level == 0 then return end
	confirm_state.level = confirm_state.level - 1
	if confirm_state.level == 0 and confirm_state.prev ~= nil then
		vim.o.confirm = confirm_state.prev
		confirm_state.prev = nil
	end
end
local function ensure_confirm_disabled(buf)
	if not vim.b[buf].bufferfile_confirm_active then
		disable_confirm()
		vim.b[buf].bufferfile_confirm_active = true
	end
end
local function ensure_confirm_restored(buf)
	if vim.b[buf].bufferfile_confirm_active then
		vim.b[buf].bufferfile_confirm_active = nil
		restore_confirm()
	end
end

local function is_in_root_dir(path)
	local root = vim.fs.normalize(get_root_dir()) .. "/"
	return vim.startswith(vim.fs.normalize(path), root)
end

local function is_bufferfile(buf)
	local name = vim.api.nvim_buf_get_name(buf)
	if name == "" then return false end
	return is_in_root_dir(name)
end

-- Editor buffers we are allowed to turn into bufferfiles. Skip UI panels,
-- terminals, Oil, help/qf, and anything the user cannot edit.
local function is_editor_buffer(buf)
	if not vim.api.nvim_buf_is_valid(buf) then return false end
	if not vim.api.nvim_buf_is_loaded(buf) then return false end
	if not vim.bo[buf].buflisted then return false end
	if not vim.bo[buf].modifiable then return false end
	local bt = vim.bo[buf].buftype
	if bt == "terminal" or bt == "prompt" or bt == "quickfix" or bt == "help" then
		return false
	end
	local ft = vim.bo[buf].filetype
	if ft == "oil" or util.is_list_panel(buf) then return false end
	local name = vim.api.nvim_buf_get_name(buf)
	if type(name) == "string" and name:find("://", 1, true) then return false end
	return true
end

local function unname(buf)
	pcall(vim.api.nvim_buf_call, buf, function()
		vim.cmd("silent keepalt 0file")
	end)
	vim.b[buf].bufferfile_assigned = nil
	vim.b[buf].bufferfile_path = nil
	vim.b[buf].bufferfile_reload_after_write = nil
end

-- Drop buftype=nofile / nowrite so :write is allowed. Those values are how
-- FileChangedShell (and scratch splits) mark "not a file" — and they produce
-- E382 the moment the user tries to save.
local function clear_blocking_buftype(buf)
	local bt = vim.bo[buf].buftype
	if bt == "nofile" or bt == "nowrite" then
		vim.bo[buf].buftype = ""
	end
end

local function reload_after_initial_write(buf, path)
	if vim.b[buf].bufferfile_reload_scheduled then return end
	vim.b[buf].bufferfile_reload_scheduled = true

	vim.schedule(function()
		if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then return end
		if vim.api.nvim_buf_get_name(buf) ~= path then return end
		if vim.api.nvim_buf_get_option(buf, "modified") then
			vim.b[buf].bufferfile_reload_scheduled = nil
			vim.b[buf].bufferfile_reload_after_write = path
			return
		end

		pcall(vim.api.nvim_buf_call, buf, function() vim.cmd("silent keepalt edit!") end)
	end)
end

local function autosave_bufferfile(buf)
	if not is_bufferfile(buf) then return end
	if not vim.api.nvim_buf_is_loaded(buf) then return end
	if not vim.api.nvim_buf_get_option(buf, "modifiable") then return end

	if not buffer_has_text(buf) then
		local name = vim.api.nvim_buf_get_name(buf)
		if name ~= "" and uv.fs_stat(name) then vim.fn.delete(name) end
		-- Unname immediately. Leaving the buffer pointed at a deleted file
		-- lets the config's FileChangedShell handler set buftype=nofile, after
		-- which :w is E382 and assign_name refuses to take over.
		if name ~= "" then unname(buf) end
		if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_option(buf, "modified") then
			vim.api.nvim_buf_set_option(buf, "modified", false)
		end
		return
	end

	clear_blocking_buftype(buf)
	local ok = pcall(vim.api.nvim_buf_call, buf, function() vim.cmd("silent keepalt write") end)
	if ok and vim.b[buf].bufferfile_reload_after_write then
		local path = vim.b[buf].bufferfile_reload_after_write
		vim.b[buf].bufferfile_reload_after_write = nil
		reload_after_initial_write(buf, path)
	end
end

-- Debounce autosaves. BufModifiedSet fires on every keystroke once a bufferfile
-- is named: each immediate write was a full sync disk round-trip (and then
-- BufWritePost → maintain_now). That felt like typing lag especially under
-- Neovide. Keep naming instant; only delay the write until typing pauses.
local AUTOSAVE_MS = 750
local pending_autosave = {} -- buf -> uv_timer_t

local function cancel_pending_autosave(buf)
	local t = pending_autosave[buf]
	if not t then return end
	pending_autosave[buf] = nil
	pcall(function()
		t:stop()
		t:close()
	end)
end

local function schedule_autosave(buf)
	cancel_pending_autosave(buf)
	local t = uv.new_timer()
	pending_autosave[buf] = t
	t:start(AUTOSAVE_MS, 0, vim.schedule_wrap(function()
		if pending_autosave[buf] == t then
			pending_autosave[buf] = nil
			pcall(function()
				t:stop()
				t:close()
			end)
		end
		if vim.api.nvim_buf_is_valid(buf) then
			autosave_bufferfile(buf)
		end
	end))
end

local function flush_autosave(buf)
	cancel_pending_autosave(buf)
	if vim.api.nvim_buf_is_valid(buf) then
		autosave_bufferfile(buf)
	end
end

local function next_path()
	local dir = get_root_dir()
	local timestamp = os.date("%Y%m%d-%H%M%S")
	local base = prefix() .. timestamp
	local ext = ".md"
	local path = join(dir, base .. ext)
	local suffix = 1
	while uv.fs_stat(path) do
		suffix = suffix + 1
		path = join(dir, base .. "-" .. suffix .. ext)
	end
	return path
end

local function mark_assigned(buf, path, reload)
	vim.b[buf].bufferfile_assigned = true
	vim.b[buf].bufferfile_path = path
	if reload then
		vim.b[buf].bufferfile_reload_after_write = path
	end
	ensure_confirm_disabled(buf)
end

local function assign_name(buf, opts)
	opts = opts or {}
	if vim.b[buf].bufferfile_assigned and vim.api.nvim_buf_get_name(buf) ~= "" then
		return
	end
	if vim.api.nvim_buf_get_name(buf) ~= "" then return end
	if not vim.api.nvim_buf_get_option(buf, "modifiable") then return end
	if not opts.even_empty and not buffer_has_text(buf) then return end

	local path = next_path()
	local ok = pcall(vim.api.nvim_buf_set_name, buf, path)
	if not ok then
		pcall(vim.api.nvim_buf_call, buf, function()
			vim.cmd("silent keepalt file " .. vim.fn.fnameescape(path))
		end)
	end
	if vim.api.nvim_buf_get_name(buf) == "" then return end
	mark_assigned(buf, path, true)
end

-- Make a listed editor buffer writable. Unnamed, nofile, and buffers whose
-- file has vanished on disk all become (or stay) a bufferfile so :w never
-- raises E32 / E382. UI panels, Oil, and terminals are left alone.
-- opts.even_empty: assign a path even when the buffer has no text (user :w).
function M.ensure_writable(buf, opts)
	opts = opts or {}
	buf = buf or vim.api.nvim_get_current_buf()
	if not is_editor_buffer(buf) then return false end

	clear_blocking_buftype(buf)

	local name = vim.api.nvim_buf_get_name(buf)
	if name ~= "" then
		local exists = uv.fs_stat(name) ~= nil
		if exists or is_in_root_dir(name) then
			if is_in_root_dir(name) then
				mark_assigned(buf, name, not exists)
			end
			return vim.bo[buf].buftype == ""
		end
		-- Stale path (deleted real file). Drop it and save as a bufferfile
		-- instead of recreating the vanished location.
		unname(buf)
		name = vim.api.nvim_buf_get_name(buf)
	end

	if name == "" then
		assign_name(buf, { even_empty = opts.even_empty })
	end
	return vim.api.nvim_buf_get_name(buf) ~= "" and vim.bo[buf].buftype == ""
end

local function ensure_all_writable(even_empty)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) then
			M.ensure_writable(buf, { even_empty = even_empty })
		end
	end
end

-- :w / :wq / :update (no filename) → assign a bufferfile if needed.
-- :wa → same for every loaded editor buffer.
-- :w path → only lift a blocking buftype so the chosen path can be written.
local function write_cmdline_kind(line)
	line = vim.trim(line or "")
	if line == "" then return nil end
	if line:match("^%%?%s*wa[ll]*!*%s*$")
		or line:match("^wqa[ll]*!*%s*$")
		or line:match("^xa[ll]*!*%s*$")
	then
		return "all"
	end
	if line:match("^%%?%s*w[rite]*!*%s*$")
		or line:match("^up[date]*!*%s*$")
		or line:match("^x[it]*!*%s*$")
		or line:match("^exit!*%s*$")
		or line:match("^wq!*%s*$")
	then
		return "bare"
	end
	if line:match("^%%?%s*w[rite]*!*%s+%S+") then
		return "path"
	end
	return nil
end

local function prepare_from_cmdline(line)
	local kind = write_cmdline_kind(line)
	if kind == "all" then
		ensure_all_writable(true)
	elseif kind == "bare" then
		M.ensure_writable(vim.api.nvim_get_current_buf(), { even_empty = true })
	elseif kind == "path" then
		local buf = vim.api.nvim_get_current_buf()
		if is_editor_buffer(buf) then clear_blocking_buftype(buf) end
	end
end

-- ── listing & maintenance ────────────────────────────────────────────────────
local function list_root_files()
	local root = subdirs()
	local entries = vim.fn.readdir(root, function(n)
		if n == "." or n == ".." then return false end
		if n == "archive" or n == "named" then return false end
		local st = uv.fs_stat(join(root, n))
		return st and st.type == "file"
	end)
	local files = {}
	for _, n in ipairs(entries) do files[#files + 1] = join(root, n) end
	return files
end

local function delete_empties(files)
	for _, p in ipairs(files) do
		local st = uv.fs_stat(p)
		if st and st.type == "file" and st.size == 0 then
			vim.fn.delete(p)
		end
	end
end

local function move_nonstandard(files)
	local _, _, named_dir = subdirs()
	for _, p in ipairs(files) do
		local base = vim.fs.basename(p)
		if not is_standard_filename(base) then
			local ymd, hms = now_ymd_hms()
			local plain = sanitize_base(base)
			rename_move(p, named_dir, string.format("%s-%s-%s.md", ymd, plain, hms))
		end
	end
end

local function move_older_to_archive(n)
	n = n or keep_n()
	local _, archive_dir = subdirs()
	local files = list_root_files()
	if #files <= n then return end

	local mtimes = {}
	for _, p in ipairs(files) do
		local s = uv.fs_stat(p)
		mtimes[p] = s and s.mtime and (s.mtime.sec * 1e9 + s.mtime.nsec) or 0
	end
	table.sort(files, function(a, b) return mtimes[a] > mtimes[b] end)

	for i = n + 1, #files do
		rename_move(files[i], archive_dir, vim.fs.basename(files[i]))
	end
end

local function maintain_now()
	local files = list_root_files()
	if #files == 0 then return end
	delete_empties(files)
	files = list_root_files()
	if #files == 0 then return end
	move_nonstandard(files)
	move_older_to_archive(keep_n())
end

-- ── public API ───────────────────────────────────────────────────────────────
function M.clean_empty()
	delete_empties(list_root_files())
end

function M.root_dir()
	local dir = get_root_dir()
	ensure_dir(dir)
	return dir
end

function M.open_root()
	util.open_dir(M.root_dir())
end

-- ── setup (install autocmds) ─────────────────────────────────────────────────
local did_setup = false

function M.setup()
	if did_setup then return end
	did_setup = true

	ensure_dir(get_root_dir())
	subdirs()

	local group = vim.api.nvim_create_augroup("LogarktosBufferfiles", { clear = true })

	vim.api.nvim_create_autocmd("BufModifiedSet", {
		group = group,
		callback = function(args)
			if not vim.api.nvim_buf_is_valid(args.buf) then return end
			M.ensure_writable(args.buf)
			if not vim.api.nvim_buf_is_loaded(args.buf) then return end
			if not vim.api.nvim_buf_get_option(args.buf, "modified") then return end
			-- Only schedule for real bufferfiles (named empties get a name
			-- first; next modified event will hit is_bufferfile).
			if is_bufferfile(args.buf) then
				schedule_autosave(args.buf)
			end
		end,
		desc = "Auto-assign and debounced-autosave bufferfiles when modified",
	})

	vim.api.nvim_create_autocmd("BufEnter", {
		group = group,
		callback = function(args)
			-- Recover nofile / vanished-file editor buffers even if the user
			-- has not typed since FileChangedShell detached them.
			M.ensure_writable(args.buf)
			if is_bufferfile(args.buf) then
				vim.b[args.buf].bufferfile_assigned = true
				vim.b[args.buf].bufferfile_path = vim.api.nvim_buf_get_name(args.buf)
				ensure_confirm_disabled(args.buf)
			end
		end,
		desc = "Disable confirm prompts when editing bufferfiles",
	})

	-- FileChangedShell in the user config used to set buftype=nofile on a
	-- deleted dirty file. That autocmd schedules the detach; this Post hook
	-- is queued after it (FIFO) and lifts nofile so :w is never E382.
	vim.api.nvim_create_autocmd("FileChangedShellPost", {
		group = group,
		callback = function(args)
			vim.schedule(function()
				if vim.api.nvim_buf_is_valid(args.buf) then
					M.ensure_writable(args.buf)
				end
			end)
		end,
		desc = "Recover editor buffers after a deleted-file detach",
	})

	-- :w / :wq / :update / :wa — including confirm-less empty unnamed buffers
	-- (E32) and leftover nofile buffers (E382). CmdlineLeavePre runs before
	-- the write, so the buffer already has a path and an empty buftype.
	local function on_write_cmdline()
		if vim.fn.getcmdtype() ~= ":" then return end
		if vim.v.event and vim.v.event.abort then return end
		prepare_from_cmdline(vim.fn.getcmdline())
	end
	-- CmdlineLeavePre is Neovim 0.11+; fall back to CmdlineLeave (still
	-- before the write for `:` commands on current builds).
	local write_ev = (vim.fn.exists("##CmdlineLeavePre") == 1) and "CmdlineLeavePre" or "CmdlineLeave"
	vim.api.nvim_create_autocmd(write_ev, {
		group = group,
		callback = on_write_cmdline,
		desc = "Save unnamed/nofile editor buffers as bufferfiles",
	})

	vim.api.nvim_create_autocmd({ "BufLeave", "BufUnload", "BufWipeout" }, {
		group = group,
		callback = function(args)
			-- Flush any pending debounced save before the buffer goes away.
			if is_bufferfile(args.buf) or pending_autosave[args.buf] then
				flush_autosave(args.buf)
			end
			if vim.b[args.buf].bufferfile_confirm_active then
				ensure_confirm_restored(args.buf)
			end
		end,
		desc = "Flush bufferfile autosave and restore confirm on leave",
	})

	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		callback = function(args)
			local name = vim.api.nvim_buf_get_name(args.buf)
			if name ~= "" and is_in_root_dir(name) then maintain_now() end
		end,
		desc = "Maintain bufferfiles after saving one",
	})

	vim.api.nvim_create_autocmd("VimEnter", {
		group = group,
		once = true,
		callback = function() maintain_now() end,
		desc = "Initial bufferfiles maintenance",
	})

	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			-- Flush every pending debounced save first.
			for buf in pairs(pending_autosave) do
				flush_autosave(buf)
			end
			while confirm_state.level > 0 do restore_confirm() end
			M.clean_empty()
			maintain_now()
		end,
		desc = "Prune empties & maintain on exit",
	})

	-- Write modified bufferfiles before quitting so they don't block :qall.
	vim.api.nvim_create_autocmd("QuitPre", {
		group = group,
		callback = function()
			for buf in pairs(pending_autosave) do
				flush_autosave(buf)
			end
			for _, buf in ipairs(vim.api.nvim_list_bufs()) do
				if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_option(buf, "modifiable") then
					M.ensure_writable(buf)
					local name = vim.api.nvim_buf_get_name(buf)
					if name ~= "" and is_in_root_dir(name) and vim.api.nvim_buf_get_option(buf, "modified") then
						if buffer_has_text(buf) then
							clear_blocking_buftype(buf)
							pcall(vim.api.nvim_buf_call, buf, function() vim.cmd("silent keepalt write") end)
						else
							if uv.fs_stat(name) then pcall(vim.fn.delete, name) end
							unname(buf)
							pcall(vim.api.nvim_buf_set_option, buf, "modified", false)
						end
					end
				end
			end
		end,
		desc = "Autosave modified bufferfiles so quit isn't blocked",
	})
end

return M
