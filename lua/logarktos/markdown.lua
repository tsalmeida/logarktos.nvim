-- logarktos/markdown.lua ── timestamped note creation + archiving
local config = require("logarktos.config")
local util = require("logarktos.util")
local uv = util.uv

local M = {}

local function is_markdown_name(name)
	return type(name) == "string" and name:lower():match("%.md$") ~= nil
end

local function oil_line_range(opts)
	opts = opts or {}
	if opts.line1 and opts.line2 then
		local line1, line2 = tonumber(opts.line1), tonumber(opts.line2)
		if line1 and line2 and line1 > 0 and line2 > 0 and line1 ~= line2 then
			if line1 > line2 then line1, line2 = line2, line1 end
			return line1, line2
		end
	end

	local mode = vim.api.nvim_get_mode().mode
	if mode == "v" or mode == "V" then
		local line1, line2 = vim.fn.line("v"), vim.fn.line(".")
		if line1 > line2 then line1, line2 = line2, line1 end
		return line1, line2
	end

	local line = vim.api.nvim_win_get_cursor(0)[1]
	return line, line
end

-- Every "file it away" command (archive/, drafts/, …) is the same operation with
-- a different destination folder and wording, so the machinery below is shared:
-- a spec is { folder, cmd, verb } and `filed_markdown` builds the pair of public
-- functions from it. Adding another destination is one more spec, not a copy.
local function move_into(path, dest_dir)
	local name = vim.fn.fnamemodify(path, ":t")
	local dest = util.unique_path(util.join(dest_dir, name))
	local ok, err = uv.fs_rename(path, dest)
	if not ok then ok, err = os.rename(path, dest) end
	return ok ~= nil and ok ~= false, dest, err
end

local function file_oil_markdown(spec, opts)
	local dir = util.oil_dir(0)
	if not dir or dir == "" then
		util.notify("Oil directory is unknown.", vim.log.levels.WARN, spec.cmd)
		return
	end

	if (util.basename(dir) or ""):lower() == spec.folder then
		util.notify(("Already in a %s/ folder."):format(spec.folder), vim.log.levels.INFO, spec.cmd)
		return
	end

	local oil = util.oil()
	if not oil or not oil.get_entry_on_line then
		util.notify("Oil entry API is unavailable.", vim.log.levels.ERROR, spec.cmd)
		return
	end

	local line1, line2 = oil_line_range(opts)
	local files, seen = {}, {}
	for lnum = line1, line2 do
		local ok_entry, entry = pcall(oil.get_entry_on_line, 0, lnum)
		if not ok_entry then entry = nil end
		if entry and entry.type == "file" and is_markdown_name(entry.name) then
			local path = util.join(dir, entry.name)
			local norm = util.normalize(path)
			if not seen[norm] and uv.fs_stat(path) then
				seen[norm] = true
				table.insert(files, path)
			end
		end
	end

	if #files == 0 then
		util.notify("No Markdown files selected in Oil.", vim.log.levels.WARN, spec.cmd)
		return
	end

	local dest_dir = util.join(dir, spec.folder)
	if not util.ensure_dir(dest_dir) then return end

	local moved, failed = {}, {}
	for _, path in ipairs(files) do
		local ok, dest, err = move_into(path, dest_dir)
		if ok then
			table.insert(moved, dest)
		else
			table.insert(failed, vim.fn.fnamemodify(path, ":t") .. ": " .. tostring(err or "unknown error"))
		end
	end

	util.refresh_oil()
	if #failed > 0 then
		util.notify(
			("%s %d Markdown file(s); %d failed:\n%s"):format(spec.verb, #moved, #failed, table.concat(failed, "\n")),
			vim.log.levels.WARN,
			spec.cmd
		)
	else
		util.notify(
			("%s %d Markdown file(s) to %s/"):format(spec.verb, #moved, spec.folder),
			vim.log.levels.INFO,
			spec.cmd
		)
	end
end

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

local function default_template_name()
	return config.options.markdown.template or "template.md"
end

--- Extra templates in `dir`: `template_read.md`, `template-talk.md`, …
--- The default `template.md` is not listed (bare Enter still selects it).
--- @return { suffix: string, name: string, key: string }[]
local function list_template_variants(dir)
	local default = default_template_name():lower()
	local found = {}
	local handle = uv.fs_scandir(dir)
	if not handle then return found end
	while true do
		local name, typ = uv.fs_scandir_next(handle)
		if not name then break end
		if typ ~= "directory" then
			local lower = name:lower()
			if lower ~= default and lower:match("%.md$") then
				-- template_read.md → "read"; template-talk.md → "talk"
				local suffix = name:match("^[Tt][Ee][Mm][Pp][Ll][Aa][Tt][Ee][_%-](.+)%.[Mm][Dd]$")
				if suffix and suffix ~= "" then
					table.insert(found, { suffix = suffix, name = name, key = suffix:lower() })
				end
			end
		end
	end
	table.sort(found, function(a, b)
		return a.key < b.key
	end)
	return found
end

--- Match user input to a variant: exact suffix, then unique prefix.
--- Accepts "read", "a", "template_read", "template_read.md".
--- @return table|nil, string|nil picked, error
local function match_template_variant(variants, input)
	local q = vim.trim(input):lower()
	q = q:gsub("%.md$", "")
	q = q:gsub("^template[_%-]", "")
	if q == "" then return nil, "empty" end

	local exact, prefixes = nil, {}
	for _, v in ipairs(variants) do
		if v.key == q then
			exact = v
		elseif v.key:sub(1, #q) == q then
			table.insert(prefixes, v)
		end
	end
	if exact then return exact end
	if #prefixes == 1 then return prefixes[1] end
	if #prefixes > 1 then
		local names = {}
		for _, v in ipairs(prefixes) do
			names[#names + 1] = v.suffix
		end
		return nil, "Ambiguous template: " .. table.concat(names, ", ")
	end
	return nil, 'No template starting with "' .. input .. '"'
end

-- ── New Markdown ─────────────────────────────────────────────────────────────
function M.new_markdown(opts)
	local dir = target_dir(opts)
	if not dir or dir == "" then return end

	local function create_note(title, template_name)
		title = vim.trim(title or "")
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

		local template_path = util.join(dir, template_name)
		local marker = config.options.markdown.focus_marker or ""
		local date_marker = config.options.markdown.date_marker or ""
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
				-- *YYYYMMDD* → today's date (e.g. 20260723). All occurrences.
				-- Run before the focus marker so a shared line keeps a correct
				-- cursor column after the shorter placeholder is expanded.
				if date_marker ~= "" then
					local today = os.date("%Y%m%d")
					for i, line in ipairs(contents) do
						if line:find(date_marker, 1, true) then
							contents[i] = line:gsub(vim.pesc(date_marker), today)
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
	end

	local function ask_title(template_name)
		vim.ui.input({ prompt = "Title (Enter to skip): " }, function(input)
			if input == nil then return end
			create_note(input, template_name)
		end)
	end

	-- Only prompt when the folder has template_<suffix>.md variants.
	-- A lone template.md keeps the old one-step title prompt.
	local variants = list_template_variants(dir)
	if #variants == 0 then
		ask_title(default_template_name())
		return
	end

	local labels = {}
	for _, v in ipairs(variants) do
		labels[#labels + 1] = v.suffix
	end
	local default = default_template_name()
	local prompt = ("Template [%s] (Enter = %s): "):format(table.concat(labels, ", "), default)

	local function ask_template()
		vim.ui.input({ prompt = prompt }, function(input)
			if input == nil then return end
			input = vim.trim(input)
			if input == "" then
				ask_title(default)
				return
			end
			local picked, err = match_template_variant(variants, input)
			if not picked then
				util.notify(err, vim.log.levels.WARN, "NewMarkdown")
				vim.schedule(ask_template)
				return
			end
			ask_title(picked.name)
		end)
	end
	ask_template()
end

-- ── Filing Markdown away (archive/, drafts/) ─────────────────────────────────
-- Move the current file unchanged into a `<folder>/` subfolder of its own dir.
local function file_markdown(spec, opts)
	opts = opts or {}
	local buf = vim.api.nvim_get_current_buf()
	if vim.bo[buf].filetype == "oil" then
		file_oil_markdown(spec, opts)
		return
	end

	local current_path = vim.api.nvim_buf_get_name(buf)
	if current_path == "" or not uv.fs_stat(current_path) then
		util.notify("Buffer has no file on disk to move.", vim.log.levels.WARN, spec.cmd)
		return
	end

	if vim.bo[buf].modifiable and vim.bo[buf].modified then
		vim.api.nvim_buf_call(buf, function() vim.cmd("silent! write") end)
	end

	local dir = vim.fn.fnamemodify(current_path, ":h")

	if vim.fs.basename(dir):lower() == spec.folder then
		util.notify(("File is already in a %s/ folder."):format(spec.folder), vim.log.levels.INFO, spec.cmd)
		return
	end

	local dest_dir = util.join(dir, spec.folder)
	if not util.ensure_dir(dest_dir) then return end

	local ok, dest, err = move_into(current_path, dest_dir)
	if not ok then
		util.notify("Could not move file: " .. tostring(err or "unknown error"), vim.log.levels.ERROR, spec.cmd)
		return
	end

	-- Land in the original folder via Oil so the moved file drops out of
	-- view, rather than following the file into the destination. Drop any cached
	-- Oil buffer for that folder first so the reopen reloads from disk: refreshing
	-- a reused hidden buffer in place races with Oil's async load and could
	-- leave the moved file visible until a manual :e!. If the buffer is still
	-- displayed (a split), we can't wipe it — fall back to an in-place refresh,
	-- which is reliable for an already-loaded, visible buffer.
	local wiped = util.wipe_oil_dir(dir)
	util.open_dir(dir)
	-- For a hidden buffer the wipe gives an instant fresh reload; for one still
	-- displayed (a split) we can't wipe, so nudge a refresh. Either way Oil's
	-- watch_for_changes is the reliable backstop -- it reloads the listing when
	-- the file moves on disk, regardless of this refresh's timing.
	if not wiped then util.refresh_oil() end
	util.notify(spec.verb .. " " .. util.relpath(dest, dir), vim.log.levels.INFO, spec.cmd)
end

local ARCHIVE = { folder = "archive", cmd = "MarkdownArchive", verb = "Archived" }
local DRAFTS = { folder = "drafts", cmd = "MarkdownDrafts", verb = "Drafted" }

--- Move the current/selected Markdown file(s) into ./archive.
function M.markdown_archive(opts)
	file_markdown(ARCHIVE, opts)
end

--- Move the current/selected Markdown file(s) into ./drafts.
function M.markdown_drafts(opts)
	file_markdown(DRAFTS, opts)
end

return M
