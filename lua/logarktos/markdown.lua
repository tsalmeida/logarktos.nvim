-- logarktos/markdown.lua ── timestamped note creation + archiving
local config = require("logarktos.config")
local util = require("logarktos.util")
local uv = util.uv

local M = {}

--- Resolve the directory a new note should be created in.
local function target_dir(opts)
	opts = opts or {}
	if opts.dir and opts.dir ~= "" then return opts.dir end
	if vim.bo.filetype == "oil" then
		local dir = util.oil_dir(0)
		if dir then return dir end
	end
	local name = vim.api.nvim_buf_get_name(0)
	if name ~= "" then return vim.fn.fnamemodify(name, ":p:h") end
	return vim.fn.getcwd()
end

-- ── New Markdown ─────────────────────────────────────────────────────────────
function M.new_markdown(opts)
	local dir = target_dir(opts)
	if not dir or dir == "" then return end

	vim.ui.input({ prompt = "Title (Enter to skip): " }, function(input)
		if input == nil then return end

		local title = vim.trim(input)
		local stamp = os.date(config.options.markdown.timestamp or "%Y%m%d - %H%M%S")
		local filename
		if title ~= "" then
			local safe_title = title:gsub('[<>:"/\\|?*]', ""):gsub("[%s%.]+$", ""):gsub("^%s+", "")
			filename = (safe_title ~= "") and (stamp .. " - " .. safe_title .. ".md") or (stamp .. ".md")
		else
			filename = stamp .. ".md"
		end

		local path = util.join(dir, filename)
		if uv.fs_stat(path) then return end

		local template_name = config.options.markdown.template or "template.md"
		local template_path = util.join(dir, template_name)
		local marker = config.options.markdown.focus_marker or ""
		local contents, used_template = {}, false
		local focus -- { row = <1-based line>, col = <0-based byte col> } once found
		if template_name ~= "" and uv.fs_stat(template_path) then
			local ok_read, lines = pcall(vim.fn.readfile, template_path)
			if ok_read then
				contents, used_template = lines, true
				if title ~= "" then
					for i, line in ipairs(contents) do
						if line == "# Title" then
							contents[i] = "# " .. title
							break
						end
					end
				end
				-- Locate the writing-focus marker, strip it from the line, and
				-- remember where it sat so we can land the cursor there.
				if marker ~= "" then
					for i, line in ipairs(contents) do
						local s = line:find(marker, 1, true)
						if s then
							contents[i] = line:sub(1, s - 1) .. line:sub(s + #marker)
							focus = { row = i, col = s - 1 }
							break
						end
					end
				end
			end
		end

		if pcall(vim.fn.writefile, contents, path) then
			-- Surface the title as a soft "note" tab name when one was given.
			if title ~= "" then
				require("logarktos.tabs").apply_note(title)
			end

			if used_template then
				-- A template was applied: open the note straight away rather
				-- than just landing on it in the Oil listing. NB: we do NOT
				-- refresh Oil in place here — its async reload would land on
				-- this new window afterwards and clobber the file's filetype
				-- and window options (wrap, conceal, syntax). Instead we wipe
				-- the Oil buffer we're leaving (see below) so a later return to
				-- Oil reloads the directory fresh and shows the new file.
				local came_from_oil = vim.bo.filetype == "oil"

				vim.cmd.edit(vim.fn.fnameescape(path))
				if focus then
					-- Drop the cursor where the marker sat, centre the line
					-- (zz), and start typing there.
					local win = vim.api.nvim_get_current_win()
					local buf = vim.api.nvim_win_get_buf(win)
					local row = math.min(focus.row, vim.api.nvim_buf_line_count(buf))
					local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
					if focus.col >= #line then
						-- Marker sat at the end of its line: append there.
						vim.api.nvim_win_set_cursor(win, { row, math.max(#line - 1, 0) })
						vim.cmd("normal! zz")
						vim.cmd("startinsert!")
					else
						vim.api.nvim_win_set_cursor(win, { row, focus.col })
						vim.cmd("normal! zz")
						vim.cmd("startinsert")
					end
				end

				-- Drop the stale Oil buffer now that we've left it, so the next
				-- visit reloads the directory and shows the new file.
				if came_from_oil then util.wipe_oil_dir(dir) end
			elseif vim.bo.filetype == "oil" then
				-- No template: stay in Oil, refresh the listing, and place the
				-- cursor on the new file's name stem.
				util.refresh_oil()
				vim.schedule(function()
					local pos = vim.fn.searchpos("\\V" .. filename, "Wn")
					if pos[1] ~= 0 then
						local line = vim.api.nvim_buf_get_lines(0, pos[1] - 1, pos[1], false)[1]
						local dot = line:find("%.[^%.]*$")
						if dot then vim.api.nvim_win_set_cursor(0, { pos[1], dot - 1 }) end
					end
				end)
			else
				-- No template, outside Oil: just open the note.
				vim.cmd.edit(vim.fn.fnameescape(path))
			end
			util.notify("Created " .. filename .. (used_template and (" (from " .. template_name .. ")") or ""))
		end
	end)
end

-- ── Markdown Archive ─────────────────────────────────────────────────────────
-- Move the current file unchanged into an `archive/` subfolder of its own dir.
function M.markdown_archive()
	local buf = vim.api.nvim_get_current_buf()
	if vim.bo[buf].filetype == "oil" then
		util.notify("Open the file first, then archive it.", vim.log.levels.WARN, "MarkdownArchive")
		return
	end

	local current_path = vim.api.nvim_buf_get_name(buf)
	if current_path == "" or not uv.fs_stat(current_path) then
		util.notify("Buffer has no file on disk to archive.", vim.log.levels.WARN, "MarkdownArchive")
		return
	end

	if vim.bo[buf].modifiable and vim.bo[buf].modified then
		vim.api.nvim_buf_call(buf, function() vim.cmd("silent! write") end)
	end

	local dir = vim.fn.fnamemodify(current_path, ":h")
	local name = vim.fn.fnamemodify(current_path, ":t")

	if vim.fs.basename(dir):lower() == "archive" then
		util.notify("File is already in an archive/ folder.", vim.log.levels.INFO, "MarkdownArchive")
		return
	end

	local archive_dir = util.join(dir, "archive")
	if not util.ensure_dir(archive_dir) then return end

	local dest = util.unique_path(util.join(archive_dir, name))
	local ok, err = uv.fs_rename(current_path, dest)
	if not ok then ok, err = os.rename(current_path, dest) end
	if not ok then
		util.notify("Could not archive file: " .. tostring(err or "unknown error"), vim.log.levels.ERROR, "MarkdownArchive")
		return
	end

	-- Land in the original folder via Oil so the archived file drops out of
	-- view, rather than following the file into archive/. Drop any cached Oil
	-- buffer for that folder first so the reopen reloads from disk: refreshing
	-- a reused hidden buffer in place races with Oil's async load and could
	-- leave the moved file visible until a manual :e!. If the buffer is still
	-- displayed (a split), we can't wipe it — fall back to an in-place refresh,
	-- which is reliable for an already-loaded, visible buffer.
	local wiped = util.wipe_oil_dir(dir)
	util.open_dir(dir)
	if not wiped then util.refresh_oil() end
	util.notify("Archived " .. util.relpath(dest, dir), vim.log.levels.INFO, "MarkdownArchive")
end

return M
