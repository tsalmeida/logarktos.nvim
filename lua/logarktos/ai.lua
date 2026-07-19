-- logarktos/ai.lua ── OPTIONAL AI filename suggester (:LogarktosSuggestFilename)
--
-- Disabled by default. Enable with:
--   require("logarktos").setup({ ai = { enabled = true } })
-- and provide an API key via the env var named by `ai.api_key_env`
-- (default OPENAI_API_KEY). This is the only module that talks to the network.
local config = require("logarktos.config")
local util = require("logarktos.util")
local uv = util.uv

local M = {}

local function ai_cfg()
	return config.options.ai or {}
end

function M.enabled()
	return ai_cfg().enabled == true
end

local function slice_lines(lines, limit)
	if #lines == 0 then return "", false end
	local parts, count, truncated = {}, 0, false
	for i, line in ipairs(lines) do
		local remain = limit - count
		if remain <= 0 then truncated = true break end
		if #line > remain then
			table.insert(parts, line:sub(1, remain))
			truncated = true
			break
		else
			table.insert(parts, line)
			count = count + #line
		end
		if i < #lines then
			if count < limit then
				table.insert(parts, "\n")
				count = count + 1
			else
				truncated = true
				break
			end
		end
	end
	return table.concat(parts), truncated
end

-- ── template-aware trimming ──────────────────────────────────────────────────
-- :NewMarkdown can seed a note from a `template.md`. When naming such a note we
-- strip the shared template lines first, so the model judges the file by what
-- the *user* wrote on top of the boilerplate — otherwise every note made from
-- the same template tends to get the same template-flavoured name.

--- Locate the template that seeded `current_path`, if any. Looks in the file's
--- own folder, and — for archived notes — in the parent of an `archive/` folder.
local function template_for(current_path)
	if not current_path or current_path == "" then return nil end
	local template_name = (config.options.markdown and config.options.markdown.template) or "template.md"
	if template_name == "" then return nil end
	local dir = vim.fn.fnamemodify(current_path, ":h")
	local cand = util.join(dir, template_name)
	if util.exists(cand) then return cand end
	if (util.basename(dir) or ""):lower() == "archive" then
		cand = util.join(vim.fn.fnamemodify(dir, ":h"), template_name)
		if util.exists(cand) then return cand end
	end
	return nil
end

--- Drop every buffer line that exactly matches a (non-blank) template line.
--- Returns the kept lines and how many were removed.
local function strip_template(lines, template_path)
	local ok, tmpl = pcall(vim.fn.readfile, template_path)
	if not ok or #tmpl == 0 then return lines, 0 end
	local tmpl_set = {}
	for _, l in ipairs(tmpl) do
		local key = vim.trim(l)
		if key ~= "" then tmpl_set[key] = true end
	end
	local kept, removed = {}, 0
	for _, l in ipairs(lines) do
		local key = vim.trim(l)
		if key ~= "" and tmpl_set[key] then
			removed = removed + 1
		else
			kept[#kept + 1] = l
		end
	end
	return kept, removed
end

local function api_key_missing_msg(env_name)
	local path = require("logarktos.rcfile").user_path()
	return table.concat({
		(env_name or "OPENAI_API_KEY") .. " is not set.",
		"Put your OpenAI API key in a gitignored .env next to your Neovim config:",
		"  OPENAI_API_KEY=sk-…",
		"or export that variable in your shell.",
		"Model / limits / default instruction live in:",
		"  " .. path,
	}, "\n")
end

local function resolve_model(cfg)
	return util.getenv_trim(cfg.model_env or "OPENAI_MODEL") or cfg.model or "gpt-4o-mini"
end

local function call_openai(messages)
	local cfg = ai_cfg()
	local api_key = util.getenv_trim(cfg.api_key_env or "OPENAI_API_KEY")
	if not api_key then
		util.notify(api_key_missing_msg(cfg.api_key_env), vim.log.levels.ERROR, "SuggestFilename")
		return nil, nil
	end
	local model = resolve_model(cfg)
	local json = vim.json.encode({ model = model, messages = messages })

	local res = vim.system({
		"curl", "-sS", "-H", "Authorization: Bearer " .. api_key,
		"-H", "Content-Type: application/json", "-d", "@-",
		"https://api.openai.com/v1/chat/completions",
	}, { stdin = json, text = true }):wait()

	if res.code ~= 0 then
		util.notify("Request failed: curl exit " .. tostring(res.code) .. "\n" .. (res.stderr or ""),
			vim.log.levels.ERROR, "SuggestFilename")
		return nil, nil
	end
	local ok, data = pcall(vim.json.decode, res.stdout)
	if not ok then
		util.notify("Could not parse OpenAI response JSON.", vim.log.levels.ERROR, "SuggestFilename")
		return nil, nil
	end
	local reply = data and data.choices and data.choices[1] and data.choices[1].message
		and data.choices[1].message.content or nil
	if not reply or reply == "" then
		util.notify("OpenAI returned no content.", vim.log.levels.WARN, "SuggestFilename")
		return nil, nil
	end
	return reply, model
end

local function sanitize_filename(raw, max_len)
	local candidate = raw:match("([A-Za-z0-9]+)") or raw
	local cleaned = candidate:gsub("[^A-Za-z0-9]", "")
	if cleaned == "" then return nil end
	cleaned = cleaned:gsub("^(%l)", string.upper)
	if cleaned:match("^%d") then cleaned = "F" .. cleaned end
	if #cleaned > max_len then cleaned = cleaned:sub(1, max_len) end
	return cleaned
end

local function unique_filename(base, ext, dir, current_path, max_len)
	local normalized_current = current_path and current_path ~= "" and util.normalize(current_path) or nil
	local function build(suffix)
		local suffix_str = suffix and tostring(suffix) or ""
		local allowed = math.max(1, max_len - #suffix_str)
		return base:sub(1, allowed) .. suffix_str .. ext
	end
	local name = build(nil)
	local target = util.join(dir, name)
	if normalized_current and util.normalize(target) == normalized_current then return target, name end
	if util.exists(target) then
		local suffix = 2
		while true do
			name = build(suffix)
			target = util.join(dir, name)
			if normalized_current and util.normalize(target) == normalized_current then break end
			if not util.exists(target) then break end
			suffix = suffix + 1
		end
	end
	return target, name
end

function M.suggest_filename()
	if not M.enabled() then
		util.notify("The AI module is disabled. Enable it with setup({ ai = { enabled = true } }).",
			vim.log.levels.WARN, "SuggestFilename")
		return
	end

	local buf = vim.api.nvim_get_current_buf()
	local cfg = ai_cfg()
	local max_chars = cfg.max_input_chars or 1000
	local current_path = vim.api.nvim_buf_get_name(buf)

	-- Start from the whole buffer, then drop shared template boilerplate so the
	-- model only weighs what the user added on top of a :NewMarkdown template.
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
	local from_template = false
	local tpath = template_for(current_path)
	if tpath then
		local kept, removed = strip_template(lines, tpath)
		if removed > 0 then
			local has_content = false
			for _, l in ipairs(kept) do
				if vim.trim(l) ~= "" then has_content = true break end
			end
			-- Only adopt the trimmed text when something the user wrote remains;
			-- otherwise fall back to the full buffer rather than send nothing.
			if has_content then lines, from_template = kept, true end
		end
	end

	local preview, truncated = slice_lines(lines, max_chars)
	if preview == "" then
		util.notify("Buffer is empty — nothing to analyze.", vim.log.levels.WARN, "SuggestFilename")
		return
	end

	local system_prompt = table.concat({
		"You suggest concise CamelCase file names.",
		"Respond with a single ASCII alphanumeric token.",
		"Do not include file extensions or additional commentary.",
		"Keep the name readable, descriptive, and at most 60 characters.",
	}, " ")
	local origin = from_template
		and "the user-written portion of a note (shared template boilerplate removed)"
		or "the beginning of a file"
	local qualifier = truncated and " (truncated)" or ""
	local escaped_preview = preview:gsub("%%", "%%%%")
	local user_prompt = string.format(
		"The following text is %s%s (up to %d characters):\n\n%s\n\nProvide a CamelCase filename (no extension). Reply with only the proposed name.",
		origin, qualifier, max_chars, escaped_preview)

	local reply, model = call_openai({
		{ role = "system", content = system_prompt },
		{ role = "user", content = user_prompt },
	})

	if not reply then
		local default_name = "SuggestedFile"
		if current_path ~= "" then
			local inferred = vim.fn.fnamemodify(current_path, ":t:r")
			if inferred ~= "" then default_name = inferred end
		end
		local input = vim.trim(vim.fn.input("Rename to (CamelCase, no extension): ", default_name))
		if input == "" then
			util.notify("Rename cancelled.", vim.log.levels.INFO, "SuggestFilename")
			return
		end
		reply, model = input, "manual"
	end

	local sanitized = sanitize_filename(reply, cfg.max_name_len or 60) or "SuggestedFile"
	sanitized = sanitized:gsub("^(%l)", string.upper)

	-- Preserve a :NewMarkdown "YYYYMMDD - HHMMSS" prefix when present.
	local current_stem = (current_path ~= "") and vim.fn.fnamemodify(current_path, ":t:r") or ""
	local nm_prefix = current_stem:match("^(%d%d%d%d%d%d%d%d %- %d%d%d%d%d%d)")
	local base = nm_prefix and (nm_prefix .. " - " .. sanitized)
		or (os.date("%Y%m%d - %H%M%S") .. " - " .. sanitized)

	local dir = (current_path ~= "") and vim.fn.fnamemodify(current_path, ":h") or vim.fn.getcwd()
	local ext = ""
	if current_path ~= "" then
		local current_ext = vim.fn.fnamemodify(current_path, ":e")
		if current_ext ~= "" then ext = "." .. current_ext end
	end
	if ext == "" then
		local ft = vim.bo[buf].filetype
		if ft == "markdown" then ext = ".md" elseif ft == "text" then ext = ".txt" end
	end

	local target_path, final_name = unique_filename(base, ext, dir, current_path, 200)
	local normalized_current = current_path ~= "" and util.normalize(current_path) or nil
	if normalized_current and normalized_current == util.normalize(target_path) then
		util.notify("Filename already matches the suggested name.", vim.log.levels.INFO, "SuggestFilename")
		return
	end

	local renamed = false
	if current_path ~= "" and normalized_current then
		local ok, err = uv.fs_rename(current_path, target_path)
		if not ok then ok, err = os.rename(current_path, target_path) end
		if not ok then
			util.notify("Could not rename file: " .. tostring(err or "unknown error"), vim.log.levels.ERROR, "SuggestFilename")
			return
		end
		renamed = true
	end

	vim.api.nvim_buf_set_name(buf, target_path)
	if vim.b[buf].bufferfile_assigned then vim.b[buf].bufferfile_path = target_path end

	if renamed then
		util.notify(string.format("Renamed to %s (model: %s)", final_name, model), vim.log.levels.INFO, "SuggestFilename")
	else
		util.notify(string.format("Suggested buffer name: %s (model: %s)", final_name, model), vim.log.levels.INFO, "SuggestFilename")
	end
end

-- ── send selection / buffer to AI (space+ai) ─────────────────────────────────

local function get_text_from_context()
	local mode = vim.fn.mode()
	local has_visual = mode:find("[vV\022]") ~= nil
	if has_visual then
		local _, ls, cs = unpack(vim.fn.getpos("'<"))
		local _, le, ce = unpack(vim.fn.getpos("'>"))
		if ls > le or (ls == le and cs > ce) then ls, le, cs, ce = le, ls, ce, cs end
		local lines = vim.api.nvim_buf_get_lines(0, ls - 1, le, true)
		if #lines == 0 then return "", true end
		lines[1] = string.sub(lines[1], cs > 0 and cs or 1)
		lines[#lines] = string.sub(lines[#lines], 1, ce > 0 and ce or #lines[#lines])
		return table.concat(lines, "\n"), true
	end
	return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, true), "\n"), false
end

local function new_right_split_with(lines)
	vim.cmd("vnew")
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].buftype = ""
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "markdown"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modified = true
	pcall(vim.cmd, "doautocmd <nomodeline> BufModifiedSet")
end

local function extract_text_from_chat(data)
	local c = data and data.choices and data.choices[1]
	local msg = c and c.message
	if msg and type(msg.content) == "string" and msg.content ~= "" then
		return msg.content
	end
	if msg and type(msg.content) == "table" then
		local parts = {}
		for _, seg in ipairs(msg.content) do
			if type(seg) == "table" and type(seg.text) == "string" then
				parts[#parts + 1] = seg.text
			end
		end
		if #parts > 0 then return table.concat(parts, "\n") end
	end
	return nil
end

--- Send the visual selection (or whole buffer) to OpenAI and show the reply
--- in a right-hand split. Model / max chars / default instruction come from
--- the user logarktos.lua (and setup); the API key from $OPENAI_API_KEY.
function M.send_to_ai()
	if not M.enabled() then
		util.notify(
			"AI is disabled. Enable it in your logarktos.lua (`ai = { enabled = true }`) "
				.. "or setup({ ai = { enabled = true } }).",
			vim.log.levels.WARN,
			"AI"
		)
		return
	end

	local cfg = ai_cfg()
	local env_name = cfg.api_key_env or "OPENAI_API_KEY"
	local api_key = util.getenv_trim(env_name)
	if not api_key then
		util.notify(api_key_missing_msg(env_name), vim.log.levels.ERROR, "AI")
		return
	end

	local model = resolve_model(cfg)
	local max_chars = tonumber(cfg.max_input_chars) or 1000
	local instruction = cfg.default_instruction
		or "Please analyze or improve the following content."

	local text, had_visual = get_text_from_context()
	if text == "" then
		util.notify("Nothing to send (empty selection/buffer).", vim.log.levels.WARN, "AI")
		return
	end

	local truncated = false
	if #text > max_chars then
		text = text:sub(1, max_chars)
		truncated = true
	end

	local payload = {
		model = model,
		messages = {
			{ role = "system", content = instruction },
			{ role = "user", content = text },
		},
	}
	local json = vim.json.encode(payload)

	local res = vim.system({
		"curl", "-sS",
		"-H", "Authorization: Bearer " .. api_key,
		"-H", "Content-Type: application/json",
		"-d", "@-",
		"-w", "\n__CURL_STATUS:%{http_code}",
		"https://api.openai.com/v1/chat/completions",
	}, { stdin = json, text = true }):wait()

	if res.code ~= 0 then
		util.notify(
			"Request failed (curl exit " .. tostring(res.code) .. ").\n" .. (res.stderr or ""),
			vim.log.levels.ERROR,
			"AI"
		)
		return
	end

	local stdout = res.stdout or ""
	local marker = "__CURL_STATUS:"
	local http_status
	local body = stdout
	local code_pos = stdout:match("()\n" .. marker .. "%d%d%d$")
	local code_str = stdout:match("\n" .. marker .. "(%d%d%d)$")
	if code_pos and code_str then
		http_status = tonumber(code_str)
		body = stdout:sub(1, code_pos - 1)
	end
	body = body:gsub("%s+$", "")

	if http_status and (http_status < 200 or http_status >= 300) then
		local msg
		local okj, data = pcall(vim.json.decode, body)
		if okj and data and data.error then
			msg = type(data.error) == "table" and (data.error.message or data.error.type) or tostring(data.error)
		end
		util.notify(
			string.format("HTTP %s from AI provider.", tostring(http_status))
				.. (msg and ("\n" .. msg) or (body ~= "" and ("\n" .. body) or "")),
			vim.log.levels.ERROR,
			"AI"
		)
		return
	end

	local ok, data = pcall(vim.json.decode, body)
	if not ok then
		util.notify("Could not parse OpenAI response JSON.", vim.log.levels.ERROR, "AI")
		return
	end
	if data.error then
		local em = type(data.error) == "table" and (data.error.message or data.error.type) or tostring(data.error)
		util.notify("OpenAI error: " .. em, vim.log.levels.ERROR, "AI")
		return
	end

	local reply = extract_text_from_chat(data)
	if not reply or reply == "" then
		util.notify("OpenAI returned no textual content.", vim.log.levels.WARN, "AI")
		return
	end

	local stamp = os.date("%Y-%m-%d %H:%M:%S")
	local header = {
		("# AI response — %s"):format(stamp),
		("**Model:** %s"):format(model),
		("**Source:** %s"):format(had_visual and "selection" or "buffer"),
	}
	if truncated then
		header[#header + 1] = ("**Note:** input truncated to %d chars"):format(max_chars)
	end
	header[#header + 1] = ""

	local out_lines = {}
	vim.list_extend(out_lines, header)
	vim.list_extend(out_lines, vim.split(vim.trim(reply), "\n", { plain = true }))
	new_right_split_with(out_lines)
end

return M
