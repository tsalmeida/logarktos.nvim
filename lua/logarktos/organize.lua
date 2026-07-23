-- logarktos/organize.lua ── chronological file organization helpers
local config = require("logarktos.config")
local util = require("logarktos.util")
local uv = util.uv

local M = {}

local ensure_dir = util.ensure_dir
local unique_path = util.unique_path
local relpath = util.relpath

-- ── Windows PowerShell batch helper ───────────────────────────────────────────
-- Run one PowerShell process over a whole list of paths, fed via a temp file +
-- env var so neither the command line length nor the console code page can
-- mangle paths with spaces or non-ASCII characters. `preamble` runs once before
-- the loop; `body` is the per-path PowerShell (the current path is in `$p`) and
-- must emit exactly one stdout line per result. Returns stdout on success, or
-- nil (non-Windows, or any spawn/exec failure) so callers can fall back. One
-- process for the entire batch keeps this fast even on folders of hundreds of
-- files, where a per-file PowerShell spawn would be painfully slow.
local function ps_over_paths(paths, env_name, preamble, body)
	if not util.is_windows or #paths == 0 then return nil end
	local listfile = vim.fn.tempname()
	if vim.fn.writefile(paths, listfile) ~= 0 then return nil end
	local ps = (vim.fn.executable("pwsh") == 1) and "pwsh" or "powershell"
	local script = table.concat({
		"$ErrorActionPreference='SilentlyContinue'",
		"[Console]::OutputEncoding=[System.Text.Encoding]::UTF8",
		preamble or "",
		"foreach($p in (Get-Content -LiteralPath $env:" .. env_name .. " -Encoding UTF8)){",
		"if([string]::IsNullOrWhiteSpace($p)){continue}",
		body,
		"}",
	}, "\n")
	local ok, res = pcall(function()
		return vim
			.system({ ps, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script },
				{ env = { [env_name] = listfile }, text = true })
			:wait()
	end)
	pcall(vim.fn.delete, listfile)
	if not ok or not res or res.code ~= 0 then return nil end
	return res.stdout or ""
end

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

--- Normalize a config basename: trim, drop trailing slashes.
local function organize_entry_name(s)
	if type(s) ~= "string" then return nil end
	s = vim.trim(s):gsub("[/\\]+$", "")
	if s == "" or s == "." or s == ".." then return nil end
	return s
end

--- Case-fold basenames on Windows so "Documents" matches "documents".
local function organize_name_key(name)
	if util.is_windows then return name:lower() end
	return name
end

--- Build a set from a list of basenames (config ignore / fixed).
local function name_set(list)
	local set = {}
	if type(list) ~= "table" then return set end
	for _, raw in ipairs(list) do
		local name = organize_entry_name(raw)
		if name then set[organize_name_key(name)] = name end
	end
	return set
end

--- Empty a fixed folder into folders_bucket/<name>/; leave the original empty.
local function empty_fixed_folder(source_dir, dest_root, folder_name, dir, moved_dirs)
	ensure_dir(dest_root)
	local handle = uv.fs_scandir(source_dir)
	if not handle then return 0 end
	local moved = 0
	while true do
		local child = uv.fs_scandir_next(handle)
		if not child then break end
		local from = util.join(source_dir, child)
		local to = unique_path(util.join(dest_root, child))
		if uv.fs_rename(from, to) then
			moved = moved + 1
			table.insert(moved_dirs, "- " .. folder_name .. "/" .. child
				.. " ➜ " .. relpath(to, dir) .. " (fixed)")
		end
	end
	return moved
end

function M.organize()
	local dir = work_dir()
	if not dir then return end

	-- Ensure this folder's logarktos.lua has an `organize` block (creates/fills it).
	local rcfile = require("logarktos.rcfile")
	local folder_org = rcfile.ensure_organize(dir) or rcfile.default_organize()

	local org = config.options.organize
	local auto_files = util.join(dir, org.files_bucket)
	local auto_folders = util.join(dir, org.folders_bucket)
	local auto_logs = util.join(dir, org.logs_bucket)
	ensure_dir(auto_files)
	ensure_dir(auto_folders)
	ensure_dir(auto_logs)

	local ts = os.date("%Y%m%d_%H%M%S")
	local date_part = ts:sub(1, 8)
	-- "timestamps" (default): Auto Ordered Files/<ts>/<ext>/file
	-- "extensions":           Auto Ordered Files/<ext>/file
	local files_mode = folder_org.files
	if files_mode ~= "extensions" then files_mode = "timestamps" end
	local files_root = (files_mode == "extensions") and auto_files or util.join(auto_files, ts)

	-- System buckets + VCS noise are always skipped (not configurable away).
	local ignored = name_set(folder_org.ignore)
	for _, name in ipairs({
		org.files_bucket, org.folders_bucket, org.logs_bucket,
		".git", ".gitignore",
	}) do
		ignored[organize_name_key(name)] = name
	end
	local fixed = name_set(folder_org.fixed)
	-- Fixed folders that are also ignored are fully skipped.
	for k in pairs(ignored) do fixed[k] = nil end

	local handle = uv.fs_scandir(dir)
	if not handle then return end

	local moved_files, moved_dirs, total = {}, {}, 0
	while true do
		local name, t = uv.fs_scandir_next(handle)
		if not name then break end
		if name ~= "." and name ~= ".." and not ignored[organize_name_key(name)] then
			local source = util.join(dir, name)
			local key = organize_name_key(name)
			if t == "directory" and fixed[key] then
				local dest_root = util.join(auto_folders, fixed[key] or name)
				local n = empty_fixed_folder(source, dest_root, name, dir, moved_dirs)
				total = total + n
			elseif t == "directory" then
				local dest = unique_path(util.join(auto_folders, dated_folder_title(date_part, name)))
				if uv.fs_rename(source, dest) then
					total = total + 1
					table.insert(moved_dirs, "- " .. name .. " ➜ " .. relpath(dest, dir))
				end
			else
				local ext = name:match("%.([^.]+)$") or "no_extension"
				local dest_dir = util.join(files_root, ext:lower())
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
		local log = {
			"# Organize " .. ts, "",
			"Directory: " .. dir, "",
			"files mode: " .. files_mode, "",
		}
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

-- Read image pixel dimensions for many files in a single batched .NET call —
-- no FFmpeg/ImageMagick needed for the common raster formats (jpg/png/bmp/gif/
-- tiff). Returns map[path] = { w, h }. Formats System.Drawing can't decode
-- (notably webp/webm) simply don't appear, so the caller falls back to
-- ffprobe/identify for those.
local function dims_via_dotnet(paths)
	local out = ps_over_paths(
		paths,
		"LOGK_IMGLIST",
		"Add-Type -AssemblyName System.Drawing",
		[[try{$i=[System.Drawing.Image]::FromFile($p);[Console]::Out.WriteLine(('{0} {1} {2}' -f $i.Width,$i.Height,$p));$i.Dispose()}catch{}]]
	)
	local result = {}
	if not out then return result end
	for line in out:gmatch("[^\r\n]+") do
		local w, h, p = line:match("^(%d+)%s+(%d+)%s+(.+)$")
		if w and h and p then result[p] = { tonumber(w), tonumber(h) } end
	end
	return result
end

function M.organize_images()
	local dir = work_dir()

	-- Collect candidate images first so their dimensions can be resolved in one
	-- batched pass rather than spawning a tool per file.
	local images = {}
	local handle = uv.fs_scandir(dir)
	if not handle then return end
	while true do
		local name, t = uv.fs_scandir_next(handle)
		if not name then break end
		local ext = name:match("%.([^.]+)$")
		if t == "file" and ext and IMAGE_EXTS[ext:lower()] then
			table.insert(images, { name = name, path = util.join(dir, name) })
		end
	end
	if #images == 0 then
		util.notify("No images sorted")
		return
	end

	-- Resolve dimensions: one batched System.Drawing call on Windows (zero extra
	-- dependencies for jpg/png/bmp/gif/tiff), then ffprobe/identify per file for
	-- anything it couldn't decode (e.g. webp/webm).
	local paths = {}
	for _, im in ipairs(images) do table.insert(paths, im.path) end
	local dims = dims_via_dotnet(paths)

	-- We only need an external tool when System.Drawing left some images
	-- unmeasured. Off Windows it's the only option, so the old hard requirement
	-- still applies there.
	local need_fallback = false
	for _, im in ipairs(images) do
		if not dims[im.path] then need_fallback = true break end
	end
	if need_fallback and not util.is_windows
		and vim.fn.executable("ffprobe") ~= 1 and vim.fn.executable("identify") ~= 1 then
		util.notify("OrganizeImages needs `ffprobe` (FFmpeg) or `identify` (ImageMagick) on PATH.",
			vim.log.levels.ERROR)
		return
	end

	local buckets = {
		square = util.join(dir, "square"),
		portrait = util.join(dir, "portrait"),
		landscape = util.join(dir, "landscape"),
	}

	local moved = 0
	for _, im in ipairs(images) do
		local d = dims[im.path]
		local w, h
		if d then w, h = d[1], d[2] else w, h = get_media_dim(im.path) end
		if w and h then
			local bucket = (w == h) and buckets.square or (w > h and buckets.landscape or buckets.portrait)
			ensure_dir(bucket) -- create lazily so unmatched runs don't leave empty folders
			if uv.fs_rename(im.path, unique_path(util.join(bucket, im.name))) then moved = moved + 1 end
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
-- Full-content SHA-256 for many files in a single batched Get-FileHash call.
-- Get-FileHash streams the file in .NET, so even multi-GB videos hash without
-- blowing up memory. Returns map[path] = hash (uppercase hex).
local function hashes_via_powershell(paths)
	local out = ps_over_paths(
		paths,
		"LOGK_HASHLIST",
		nil,
		[[try{$h=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash;[Console]::Out.WriteLine("$h $p")}catch{}]]
	)
	local result = {}
	if not out then return result end
	for line in out:gmatch("[^\r\n]+") do
		local h, p = line:match("^(%x+)%s+(.+)$")
		if h and p then result[p] = h end
	end
	return result
end

-- Off Windows (or if the batched PowerShell call couldn't hash a given file),
-- hash its full contents in-process as a fallback.
local function hash_file_lua(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local data = f:read("*a")
	f:close()
	return data and vim.fn.sha256(data) or nil
end

function M.separate_duplicates()
	local dir = work_dir()
	local handle = uv.fs_scandir(dir)
	if not handle then return end

	-- 1) Group by size — a cheap pre-filter. Byte-identical files must share a
	--    size, so anything alone in its size bucket can never be a duplicate and
	--    is never hashed.
	local by_size = {}
	while true do
		local name, t = uv.fs_scandir_next(handle)
		if not name then break end
		if name == "Duplicates" then
			-- skip our own output folder
		elseif t == "file" then
			local full = util.join(dir, name)
			local stat = uv.fs_stat(full)
			if stat then
				local size = stat.size or 0
				by_size[size] = by_size[size] or {}
				table.insert(by_size[size], { name = name, path = full })
			end
		end
	end

	-- 2) Only files sharing a size are duplicate candidates; full-hash just those.
	local candidates = {}
	for _, list in pairs(by_size) do
		if #list > 1 then
			for _, item in ipairs(list) do table.insert(candidates, item.path) end
		end
	end
	if #candidates == 0 then
		util.notify("No duplicates found")
		return
	end

	local hashes = hashes_via_powershell(candidates)

	-- 3) Group candidates by full-content hash. A real hash (not the old
	--    head+tail heuristic, which could wrongly flag files that merely share
	--    their first and last 2 KB) means everything grouped here is genuinely
	--    byte-for-byte identical.
	local by_hash = {}
	for _, list in pairs(by_size) do
		if #list > 1 then
			for _, item in ipairs(list) do
				local h = hashes[item.path] or hash_file_lua(item.path)
				if h then
					by_hash[h] = by_hash[h] or {}
					table.insert(by_hash[h], item)
				end
			end
		end
	end

	-- 4) Keep the first (alphabetical) of each identical set; move the rest.
	local dup_dir = util.join(dir, "Duplicates")
	local moved = 0
	for _, list in pairs(by_hash) do
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
