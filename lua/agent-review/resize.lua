local api = vim.api

local M = {}

---左右のdiff窓に、2つ合わせた幅を均等に配分する。Claudeのターミナルなど他の窓の幅には触れない。
---@param s AgentReviewSession
function M.equalize(s)
	if not s:valid() or api.nvim_get_current_tabpage() ~= s.tab then
		return
	end
	local lw = api.nvim_win_get_width(s.left_win)
	local rw = api.nvim_win_get_width(s.right_win)
	local target = math.floor((lw + rw) / 2)
	if lw ~= target then
		-- 左窓を広げると直後の兄弟（右窓）から幅を取るため、他の窓は変わらない。
		pcall(api.nvim_win_set_width, s.left_win, target)
	end
end

---@param s AgentReviewSession
function M.attach(s)
	local function schedule()
		vim.schedule(function()
			M.equalize(s)
		end)
	end
	api.nvim_create_autocmd({ "WinNew", "WinClosed", "VimResized" }, {
		group = s.augroup,
		callback = schedule,
	})
	api.nvim_create_autocmd("TabEnter", {
		group = s.augroup,
		callback = function()
			if api.nvim_get_current_tabpage() == s.tab then
				require("agent-review.claude").bring_terminal(s)
			end
			schedule()
		end,
	})
	api.nvim_create_autocmd("WinResized", {
		group = s.augroup,
		callback = function()
			-- 左右の窓だけが変わった場合はユーザーの手動リサイズなので尊重する。
			for _, win in ipairs(vim.v.event.windows or {}) do
				if win ~= s.left_win and win ~= s.right_win then
					schedule()
					return
				end
			end
		end,
	})
end

return M
