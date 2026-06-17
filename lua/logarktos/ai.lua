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

local function slice_buffer(buf, limit)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
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

local function call_openai(messages)
	local cfg = ai_cfg()
	local api_key = util.getenv_trim(cfg.api_key_env or "OPENAI_API_KEY")
	if not api_key then
		util.notify(("%s is not set."):format(cfg.api_key_env or "OPENAI_API_KEY"),
			vim.log.levels.ERROR, "SuggestFilename")
		return nil, nil
	end
	local model = util.getenv_trim(cfg.model_env or "OPENAI_MODEL") or cfg.model or "gpt-4o-mini"
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
	local preview, truncated = slice_buffer(buf, max_chars)
	if preview == "" then
		util.notify("Buffer is empty — nothing to analyze.", vim.log.levels.WARN, "SuggestFilename")
		return
	end

	local current_path = vim.api.nvim_buf_get_name(buf)
	local system_prompt = table.concat({
		"You suggest concise CamelCase file names.",
		"Respond with a single ASCII alphanumeric token.",
		"Do not include file extensions or additional commentary.",
		"Keep the name readable, descriptive, and at most 60 characters.",
	}, " ")
	local qualifier = truncated and " (truncated)" or ""
	local escaped_preview = preview:gsub("%%", "%%%%")
	local user_prompt = string.format(
		"The following text is the beginning of a file%s (first %d characters):\n\n%s\n\nProvide a CamelCase filename (no extension). Reply with only the proposed name.",
		qualifier, max_chars, escaped_preview)

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

return M
