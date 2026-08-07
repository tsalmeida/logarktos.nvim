-- logarktos/oil_pin.lua ── keep logarktos.lua at the top of every Oil listing
--
-- Oil sorts via named columns (view_options.sort). We register a sort-only
-- column that ranks "logarktos.lua" ahead of everything else, then prepend it
-- to the active sort so it wins over mtime/name/type. `../` is rendered above
-- the sorted list by Oil itself, so the result is: .., logarktos.lua, …

local M = {}

local COLUMN = "logarktos_pin"
local PINNED = "logarktos.lua"

local did_setup = false

local function try_setup()
	if did_setup then return true end
	local ok_col, columns = pcall(require, "oil.columns")
	if not ok_col or not columns or type(columns.register) ~= "function" then
		return false
	end

	local FIELD_NAME = 2
	local ok_c, constants = pcall(require, "oil.constants")
	if ok_c and constants and constants.FIELD_NAME then
		FIELD_NAME = constants.FIELD_NAME
	end

	columns.register(COLUMN, {
		-- Sort-only: never add this name to oil's display `columns` list.
		render = function()
			error("Do not use the " .. COLUMN .. " column. It is for sorting only")
		end,
		parse = function()
			error("Do not use the " .. COLUMN .. " column. It is for sorting only")
		end,
		get_sort_value = function(entry)
			local name = entry[FIELD_NAME]
			if type(name) == "string" and name:lower() == PINNED then
				return 0
			end
			return 1
		end,
	})

	local ok_cfg, oil_config = pcall(require, "oil.config")
	if ok_cfg and oil_config and type(oil_config.view_options) == "table" then
		local sort = oil_config.view_options.sort
		if type(sort) ~= "table" then
			sort = {}
			oil_config.view_options.sort = sort
		end
		local first = sort[1]
		if not (type(first) == "table" and first[1] == COLUMN) then
			table.insert(sort, 1, { COLUMN, "asc" })
		end
	end

	did_setup = true
	return true
end

--- Register the sort column and put it first in Oil's sort (once).
--- Retries on first Oil buffer if Oil was not loadable yet at setup time.
function M.setup()
	if try_setup() then return end
	vim.api.nvim_create_autocmd("FileType", {
		pattern = "oil",
		once = true,
		group = vim.api.nvim_create_augroup("LogarktosOilPin", { clear = true }),
		callback = function()
			try_setup()
		end,
	})
end

return M
