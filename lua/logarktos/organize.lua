-- logarktos/organize.lua ── chronological file organization helpers
local config = require("logarktos.config")
local util = require("logarktos.util")
local uv = util.uv

local M = {}

local ensure_dir = util.ensure_dir
local unique_path = util.unique_path
local relpath = util.relpath

--- The directory to operate on: Oil dir → current file's dir → cwd.
local function work_dir()
	if vim.bo.filetype == "oil" then
		local dir = util.oil_dir(0)
		if dir then return dir end
	end
	local name = vim.api.nvim_buf_get_name(0)
	if name ~= "" then return vim.fn.fnamemodify(name, ":p:h") end
	return vim.fn.getcwd()
end

-- ── archive helpers (for :Extract) ───────────────────────────────────────────
local ARCHIVE_EXTS = {
	zip = true, ["7z"] = true, rar = true, tar = true, ["tar.gz"] = true, tgz = true,
	["tar.bz2"] = true, tbz = true, tbz2 = true, ["tar.xz"] = true, txz = true,
	["tar.zst"] = true, tzst = true, gz = true, bz2 = true, xz = true,
}

local function archive_ext(name)
	local lower = name:lower()
	for _, ext in ipairs({ "tar.gz", "tar.bz2", "tar.xz", "tar.zst", "tbz2" }) do
		if lower:sub(-#ext - 1) == "." .. ext then return ext end
	end
	local ext = lower:match("%.([^.]+)$")
	return (ext and ARCHIVE_EXTS[ext]) and ext or nil
end

local function archive_tool()
	for _, exe in ipairs({ "7z", "7zz", "7za" }) do
		if vim.fn.executable(exe) == 1 then return { kind = "7z", exe = exe } end
	end
	if vim.fn.executable("tar") == 1 then return { kind = "tar", exe = "tar" } end
	return nil
end

local function system_ok(cmd)
	local result = vim.system(cmd, { text = true }):wait()
	return result.code == 0, result
end

local function list_archive(tool, path)
	local cmd = tool.kind == "7z" and { tool.exe, "l", "-slt", "--", path } or { tool.exe, "-tf", path }
	local ok, result = system_ok(cmd)
	if not ok then return nil, vim.trim(result.stderr ~= "" and result.stderr or result.stdout) end

	local entries = {}
	if tool.kind == "7z" then
		local in_entries = false
		for line in result.stdout:gmatch("[^\r\n]+") do
			if line:match("^%-%-%-%-+") then
				in_entries = true
			elseif in_entries then
				local entry = line:match("^Path = (.+)$")
				if entry and entry ~= "" then table.insert(entries, entry) end
			end
		end
	else
		for line in result.stdout:gmatch("[^\r\n]+") do
			if line ~= "" then table.insert(entries, line) end
		end
	end
	return entries, nil
end

local function extract_archive(tool, archive_path, dest)
	local cmd = tool.kind == "7z"
		and { tool.exe, "x", "-y", "-o" .. dest, "--", archive_path }
		or { tool.exe, "-xf", archive_path, "-C", dest }
	local ok, result = system_ok(cmd)
	return ok, vim.trim(result.stderr ~= "" and result.stderr or result.stdout)
end

local function normalize_archive_entry(entry)
	entry = (entry or ""):gsub("\\", "/"):gsub("^%./", ""):gsub("/+$", "")
	return entry
end

local function safe_archive_entries(entries)
	for _, raw in ipairs(entries) do
		local entry = normalize_archive_entry(raw)
		if entry ~= "" then
			if entry:match("^/") or entry:match("^%a:") then return false, raw end
			for part in entry:gmatch("[^/]+") do
				if part == ".." then return false, raw end
			end
		end
	end
	return true, nil
end

local function single_top_folder(entries)
	local nested_root, top_entries = nil, {}
	for _, raw in ipairs(entries) do
		local entry = normalize_archive_entry(raw)
		if entry ~= "" then
			local first = entry:match("^([^/]+)/(.*)$")
			if first then
				nested_root = nested_root or first
				if first ~= nested_root then return nil end
			else
				top_entries[entry] = true
			end
		end
	end
	if not nested_root then return nil end
	for entry in pairs(top_entries) do
		if entry ~= nested_root then return nil end
	end
	return nested_root
end

local function dated_folder_title(stamp, name, max_name_chars)
	if name:match("^%d%d%d%d%d%d%d%d") then return name end
	local prefix = stamp .. " - "
	local limit = max_name_chars or math.max(1, 255 - vim.fn.strchars(prefix))
	local title = vim.fn.strcharpart(name, 0, limit)
	title = title:gsub('[<>:"/\\|?*]', "_"):gsub("[%s%.]+$", "")
	return prefix .. (title ~= "" and title or "archive")
end

local function starts_with_datestamp(name)
	return name:match("^%d%d%d%d%d%d%d%d") ~= nil
end

local function stat_datestamp(stat)
	local sec = stat and stat.birthtime and stat.birthtime.sec
	if not sec or sec == 0 then sec = stat and stat.ctime and stat.ctime.sec end
	return sec and os.date("%Y%m%d", sec) or os.date("%Y%m%d")
end

local function move_archive_to_extracted(dir, archive, stamp)
	local bucket = util.join(dir, "Extracted", stamp)
	if not ensure_dir(bucket) then return false end
	local dest = unique_path(util.join(bucket, archive.name))
	return uv.fs_rename(archive.path, dest) ~= nil
end

local function move_children(source_dir, dest_dir)
	ensure_dir(dest_dir)
	local handle = uv.fs_scandir(source_dir)
	if not handle then return false end
	while true do
		local name = uv.fs_scandir_next(handle)
		if not name then break end
		local source = util.join(source_dir, name)
		local dest = unique_path(util.join(dest_dir, name))
		if not uv.fs_rename(source, dest) then return false end
	end
	return true
end

-- ── Organize ─────────────────────────────────────────────────────────────────
function M.organize()
	local dir = work_dir()
	if not dir then return end

	local org = config.options.organize
	local auto_files = util.join(dir, org.files_bucket)
	local auto_folders = util.join(dir, org.folders_bucket)
	local auto_logs = util.join(dir, org.logs_bucket)
	ensure_dir(auto_files)
	ensure_dir(auto_folders)
	ensure_dir(auto_logs)

	local ts = os.date("%Y%m%d_%H%M%S")
	local date_part = ts:sub(1, 8)
	local files_bucket = util.join(auto_files, ts)

	local ignored = {
		[org.files_bucket] = true, [org.folders_bucket] = true, [org.logs_bucket] = true,
		[".git"] = true, [".gitignore"] = true,
	}
	local handle = uv.fs_scandir(dir)
	if not handle then return end

	local moved_files, moved_dirs, total = {}, {}, 0
	while true do
		local name, t = uv.fs_scandir_next(handle)
		if not name then break end
		if not (ignored[name] or name == "." or name == "..") then
			local source = util.join(dir, name)
			if t == "directory" then
				local dest = unique_path(util.join(auto_folders, dated_folder_title(date_part, name)))
				if uv.fs_rename(source, dest) then
					total = total + 1
					table.insert(moved_dirs, "- " .. name .. " ➜ " .. relpath(dest, dir))
				end
			else
				local ext = name:match("%.([^.]+)$") or "no_extension"
				local dest_dir = util.join(files_bucket, ext:lower())
				ensure_dir(dest_dir)
				local dest = unique_path(util.join(dest_dir, name))
				if uv.fs_rename(source, dest) then
					total = total + 1
					table.insert(moved_files, "- " .. name .. " ➜ " .. relpath(dest, dir))
				end
			end
		end
	end

	if total > 0 then
		local log_path = unique_path(util.join(auto_logs, ts .. ".md"))
		local log = { "# Organize " .. ts, "", "Directory: " .. dir, "" }
		if #moved_files > 0 then
			table.insert(log, "## Files")
			vim.list_extend(log, moved_files)
			table.insert(log, "")
		end
		if #moved_dirs > 0 then
			table.insert(log, "## Folders")
			vim.list_extend(log, moved_dirs)
			table.insert(log, "")
		end
		pcall(vim.fn.writefile, log, log_path)
		util.refresh_oil()
		util.notify("Organized " .. total .. " items")
	else
		util.notify("Nothing to organize here")
	end
end

-- ── Organize Images (needs ffprobe or ImageMagick identify) ──────────────────
local IMAGE_EXTS = { jpg = true, jpeg = true, bmp = true, png = true, webm = true, webp = true }

local function get_media_dim(path)
	local function from_ffprobe()
		if vim.fn.executable("ffprobe") ~= 1 then return nil end
		local res = vim.system({ "ffprobe", "-v", "error", "-select_streams", "v:0",
			"-show_entries", "stream=width,height", "-of", "csv=p=0:s=x", path }, { text = true }):wait()
		if res.code ~= 0 then return nil end
		local w, h = res.stdout:match("^(%d+)x(%d+)$")
		return w and tonumber(w) or nil, h and tonumber(h) or nil
	end
	local function from_identify()
		if vim.fn.executable("identify") ~= 1 then return nil end
		local res = vim.system({ "identify", "-format", "%w %h", path }, { text = true }):wait()
		if res.code ~= 0 then return nil end
		local w, h = res.stdout:match("^(%d+)%s+(%d+)$")
		return w and tonumber(w) or nil, h and tonumber(h) or nil
	end
	return from_ffprobe() or from_identify()
end

function M.organize_images()
	if vim.fn.executable("ffprobe") ~= 1 and vim.fn.executable("identify") ~= 1 then
		util.notify("OrganizeImages needs `ffprobe` (FFmpeg) or `identify` (ImageMagick) on PATH.",
			vim.log.levels.ERROR)
		return
	end
	local dir = work_dir()
	local buckets = {
		square = util.join(dir, "square"),
		portrait = util.join(dir, "portrait"),
		landscape = util.join(dir, "landscape"),
	}
	for _, b in pairs(buckets) do ensure_dir(b) end

	local handle = uv.fs_scandir(dir)
	if not handle then return end
	local moved = 0
	while true do
		local name, t = uv.fs_scandir_next(handle)
		if not name then break end
		local ext = name:match("%.([^.]+)$")
		if t == "file" and ext and IMAGE_EXTS[ext:lower()] then
			local source = util.join(dir, name)
			local w, h = get_media_dim(source)
			if w and h then
				local bucket = (w == h) and buckets.square or (w > h and buckets.landscape or buckets.portrait)
				if uv.fs_rename(source, unique_path(util.join(bucket, name))) then moved = moved + 1 end
			end
		end
	end
	if moved > 0 then
		util.refresh_oil()
		util.notify("Organized " .. moved .. " images")
	else
		util.notify("No images sorted")
	end
end

-- ── Extract (Oil only) ───────────────────────────────────────────────────────
function M.extract_archives()
	if vim.bo.filetype ~= "oil" then
		util.notify(":Extract only works from an Oil buffer", vim.log.levels.WARN)
		return
	end
	local dir = util.oil_dir(0)
	if not dir or vim.fn.isdirectory(dir) ~= 1 then return end

	local tool = archive_tool()
	if not tool then
		util.notify("Install 7-Zip CLI or tar to use :Extract", vim.log.levels.ERROR)
		return
	end

	local archives = {}
	local handle = uv.fs_scandir(dir)
	if not handle then return end
	while true do
		local name, t = uv.fs_scandir_next(handle)
		if not name then break end
		if t == "file" and archive_ext(name) then
			table.insert(archives, { name = name, path = util.join(dir, name) })
		end
	end
	table.sort(archives, function(a, b) return a.name:lower() < b.name:lower() end)

	if #archives == 0 then
		util.notify("No supported archives in this Oil directory")
		return
	end

	local stamp = os.date("%Y%m%d")
	local extracted, archived, failed = 0, 0, {}

	for _, archive in ipairs(archives) do
		local entries, list_err = list_archive(tool, archive.path)
		if not entries or #entries == 0 then
			table.insert(failed, archive.name .. ": " .. ((list_err and list_err ~= "") and list_err or "could not list archive"))
		else
			local safe, unsafe_entry = safe_archive_entries(entries)
			if not safe then
				table.insert(failed, archive.name .. ": unsafe path " .. unsafe_entry)
			else
				local root = single_top_folder(entries)
				local tmp = unique_path(util.join(dir, ".extract-tmp-" .. stamp .. "-" .. archive.name))
				if not ensure_dir(tmp) then
					table.insert(failed, archive.name .. ": could not create temporary extract folder")
				else
					local ok, extract_err = extract_archive(tool, archive.path, tmp)
					if not ok then
						table.insert(failed, archive.name .. ": " .. (extract_err ~= "" and extract_err or "extract failed"))
						vim.fn.delete(tmp, "rf")
					elseif root then
						local extracted_ok = false
						local source = util.join(tmp, root)
						local dest = unique_path(util.join(dir, dated_folder_title(stamp, root)))
						if uv.fs_rename(source, dest) then
							extracted_ok = true
						elseif move_children(tmp, unique_path(util.join(dir, dated_folder_title(stamp, archive.name, 60)))) then
							extracted_ok = true
						else
							table.insert(failed, archive.name .. ": could not move extracted folder")
						end
						if extracted_ok then
							extracted = extracted + 1
							if move_archive_to_extracted(dir, archive, stamp) then
								archived = archived + 1
							else
								table.insert(failed, archive.name .. ": extracted, but could not move archive to Extracted/" .. stamp)
							end
						end
						vim.fn.delete(tmp, "rf")
					else
						local dest = unique_path(util.join(dir, dated_folder_title(stamp, archive.name, 60)))
						if move_children(tmp, dest) then
							extracted = extracted + 1
							if move_archive_to_extracted(dir, archive, stamp) then
								archived = archived + 1
							else
								table.insert(failed, archive.name .. ": extracted, but could not move archive to Extracted/" .. stamp)
							end
						else
							table.insert(failed, archive.name .. ": could not move extracted files")
						end
						vim.fn.delete(tmp, "rf")
					end
				end
			end
		end
	end

	util.refresh_oil()
	if #failed > 0 then
		util.notify(("Extracted %d archive(s), moved %d to Extracted/%s; %d issue(s):\n%s")
			:format(extracted, archived, stamp, #failed, table.concat(failed, "\n")), vim.log.levels.WARN)
	else
		util.notify(("Extracted %d archive(s); moved originals to Extracted/%s"):format(extracted, stamp))
	end
end

-- ── Timestamp folders (Oil only) ─────────────────────────────────────────────
function M.timestamp_folders()
	if vim.bo.filetype ~= "oil" then
		util.notify(":Timestamp only works from an Oil buffer", vim.log.levels.WARN)
		return
	end
	local dir = util.oil_dir(0)
	if not dir or vim.fn.isdirectory(dir) ~= 1 then return end

	local folders = {}
	local handle = uv.fs_scandir(dir)
	if not handle then return end
	while true do
		local name, t = uv.fs_scandir_next(handle)
		if not name then break end
		if t == "directory" and name ~= "Extracted" and not starts_with_datestamp(name) then
			table.insert(folders, { name = name, path = util.join(dir, name) })
		end
	end
	table.sort(folders, function(a, b) return a.name:lower() < b.name:lower() end)

	local renamed, failed = 0, {}
	for _, folder in ipairs(folders) do
		local stamp = stat_datestamp(uv.fs_stat(folder.path))
		local dest = unique_path(util.join(dir, dated_folder_title(stamp, folder.name)))
		if uv.fs_rename(folder.path, dest) then renamed = renamed + 1 else table.insert(failed, folder.name) end
	end

	util.refresh_oil()
	if #failed > 0 then
		util.notify(("Timestamped %d folder(s); %d failed: %s"):format(renamed, #failed, table.concat(failed, ", ")), vim.log.levels.WARN)
	else
		util.notify("Timestamped " .. renamed .. " folder(s)")
	end
end

-- ── Recent 10 (recursive, in a scratch split) ────────────────────────────────
function M.recent10(args)
	local base = (args and args ~= "" and args) or work_dir()
	if vim.fn.isdirectory(base) ~= 1 then return end

	local paths = vim.fn.globpath(base, "**/*", false, true)
	local ranked = {}
	for _, p in ipairs(paths) do
		if not (p:find("[/\\]%.git") or p:find("[/\\]node_modules")) then
			local st = uv.fs_stat(p)
			if st and st.type == "file" then
				table.insert(ranked, { path = p, ns = (st.mtime.sec * 1e9) + st.mtime.nsec, sec = st.mtime.sec })
			end
		end
	end
	table.sort(ranked, function(a, b) return a.ns > b.ns end)

	local top = { "— 10 most recently modified under: " .. base .. " —", "" }
	for i = 1, math.min(10, #ranked) do
		local r = ranked[i]
		table.insert(top, os.date("%Y-%m-%d %H:%M", r.sec) .. "  " .. r.path)
	end
	if #top <= 2 then
		util.notify("No files found under " .. base)
		return
	end

	vim.cmd("vsplit")
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(0, buf)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, top)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = false

	vim.keymap.set("n", "<CR>", function()
		local path = vim.api.nvim_get_current_line():match("%s+(.+)$")
		if path then vim.cmd("edit " .. vim.fn.fnameescape(path)) end
	end, { buffer = buf })
	vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf })
end

-- ── Separate Duplicates ──────────────────────────────────────────────────────
function M.separate_duplicates()
	local dir = work_dir()
	local handle = uv.fs_scandir(dir)
	if not handle then return end

	local groups = {}
	while true do
		local name, t = uv.fs_scandir_next(handle)
		if not name then break end
		if name == "Duplicates" then
			-- skip our own output folder
		elseif t == "file" then
			local full = util.join(dir, name)
			local stat = uv.fs_stat(full)
			if stat then
				local preview = ""
				local f = io.open(full, "rb")
				if f then
					preview = f:read(2048) or ""
					if stat.size > 4096 then
						f:seek("end", -2048)
						preview = preview .. (f:read(2048) or "")
					end
					f:close()
				end
				local key = (stat.size or 0) .. "|" .. vim.fn.sha256(preview)
				groups[key] = groups[key] or {}
				table.insert(groups[key], { name = name, path = full })
			end
		end
	end

	local dup_dir = util.join(dir, "Duplicates")
	local moved = 0
	for _, list in pairs(groups) do
		if #list > 1 then
			table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
			for i = 2, #list do
				ensure_dir(dup_dir)
				if uv.fs_rename(list[i].path, unique_path(util.join(dup_dir, list[i].name))) then moved = moved + 1 end
			end
		end
	end
	util.refresh_oil()
	util.notify(moved > 0 and ("Moved " .. moved .. " duplicates") or "No duplicates found")
end

return M
