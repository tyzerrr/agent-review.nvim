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
		require("agent-review.highlight").setup()
		local bufnr = self.state.bufnr
		local lnum = require("agent-review.preview").render(bufnr, entry.value)
		local winid = self.state.winid
		-- telescopeはdefine_previewの後のtickでバッファを窓に載せるので、それを待ってから位置を合わせる。
		vim.schedule(function()
			if winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
				pcall(vim.api.nvim_win_set_cursor, winid, { lnum, 0 })
				vim.api.nvim_win_call(winid, function()
					vim.cmd("normal! zz")
				end)
			end
		end)
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
