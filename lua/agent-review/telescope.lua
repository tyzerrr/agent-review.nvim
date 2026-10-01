local changes = require("agent-review.changes")
local picker = require("agent-review.picker")

local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local conf = require("telescope.config").values
local finders = require("telescope.finders")
local pickers = require("telescope.pickers")
local previewers = require("telescope.previewers")

local M = {}

local diff_previewer = previewers.new_buffer_previewer({
	title = "Diff",
	define_preview = function(self, entry)
		local item = entry.value
		local lines = changes.unified(item.root, item.base_sha, item.change.file)
		vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
		require("telescope.previewers.utils").highlighter(self.state.bufnr, "diff")
		if item.hunk_index then
			local seen = 0
			for i, l in ipairs(lines) do
				if l:sub(1, 2) == "@@" then
					seen = seen + 1
					if seen == item.hunk_index then
						pcall(vim.api.nvim_win_set_cursor, self.state.winid, { i, 0 })
						vim.api.nvim_win_call(self.state.winid, function()
							vim.cmd("normal! zt")
						end)
						break
					end
				end
			end
		end
	end,
})

local function open(title, items, opts)
	opts = opts or {}
	if #items == 0 then
		return vim.notify("[agent-review] no changes", vim.log.levels.INFO)
	end
	pickers
		.new(opts, {
			prompt_title = title,
			finder = finders.new_table({
				results = items,
				entry_maker = function(item)
					-- filename/lnumを持たせるとtelescope標準の<C-q>（quickfixへ送る）等もそのまま使える。
					return {
						value = item,
						display = item.display,
						ordinal = item.display,
						filename = item.abs,
						lnum = item.lnum,
					}
				end,
			}),
			sorter = conf.generic_sorter(opts),
			previewer = diff_previewer,
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry then
						picker.select(entry.value)
					end
				end)
				return true
			end,
		})
		:find()
end

function M.files(opts)
	open("Agent Review: changed files", picker.items(), opts)
end

function M.hunks(opts)
	open("Agent Review: changed hunks", picker.hunk_items(), opts)
end

return M
