local config = require("agent-review.config")
local git = require("agent-review.git")

local api = vim.api

local M = {}

---base側のバッファ内容をClaudeが読めるファイルとして書き出す。
---.git配下に置くことで作業ツリーを汚さず、gitの追跡対象にもならない。
---@return string|nil path
function M.materialize(session, buf)
	local base_rel = vim.b[buf].agent_review_base_path
	if not base_rel then
		return nil
	end
	local git_dir = git.git_dir(session.root)
	if not git_dir then
		return nil
	end
	local path = ("%s/agent-review/base-%s/%s"):format(git_dir, session.short_sha, base_rel)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	vim.fn.writefile(api.nvim_buf_get_lines(buf, 0, -1, false), path)
	return path
end

local function find_terminal_win()
	local pattern = config.options.claude.terminal_pattern
	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		local buf = api.nvim_win_get_buf(win)
		if vim.bo[buf].buftype == "terminal" and api.nvim_buf_get_name(buf):match(pattern) then
			return win
		end
	end
end

---@param line1 integer 1-indexed
---@param line2 integer 1-indexed
function M.send(session, buf, line1, line2)
	local ok, claudecode = pcall(require, "claudecode")
	if not ok then
		vim.notify("[agent-review] claudecode.nvim is not available", vim.log.levels.WARN)
		return false
	end
	local path = M.materialize(session, buf)
	if not path then
		vim.notify("[agent-review] nothing to send from this buffer", vim.log.levels.WARN)
		return false
	end
	-- claudecode.nvimの行番号は0-indexed。
	local sent, err = claudecode.send_at_mention(path, line1 - 1, line2 - 1, "agent-review")
	if not sent then
		vim.notify("[agent-review] " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	if config.options.claude.focus_after_send then
		-- send_at_mentionがターミナルを非同期に開く場合があるため次のtickでフォーカスする。
		vim.schedule(function()
			local win = find_terminal_win()
			if win then
				api.nvim_set_current_win(win)
				vim.cmd("startinsert")
			end
		end)
	end
	return true
end

function M.send_visual(session)
	local l1, l2 = vim.fn.line("v"), vim.fn.line(".")
	if l1 > l2 then
		l1, l2 = l2, l1
	end
	api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
	return M.send(session, api.nvim_get_current_buf(), l1, l2)
end

local function terminal_api()
	local ok, terminal = pcall(require, "claudecode.terminal")
	if ok and terminal.get_active_terminal_bufnr then
		return terminal
	end
end

local function windows_in_tab(buf, tab)
	return vim.tbl_filter(function(w)
		return api.nvim_win_get_tabpage(w) == tab
	end, vim.fn.win_findbuf(buf))
end

---claudecode.nvimは別タブに表示中のターミナルも「表示中」とみなすため、
---レビュータブでトグルすると元のタブ側で閉じてしまう。表示中なら自分のタブへ移す。
---@param session AgentReviewSession
function M.bring_terminal(session)
	if not config.options.claude.follow_terminal then
		return
	end
	local terminal = terminal_api()
	local buf = terminal and terminal.get_active_terminal_bufnr()
	if not buf or #vim.fn.win_findbuf(buf) == 0 or #windows_in_tab(buf, session.tab) > 0 then
		return
	end
	session.claude_origin_tab = api.nvim_win_get_tabpage(vim.fn.win_findbuf(buf)[1])
	local cur = api.nvim_get_current_win()
	-- providerの内部状態（term.win）を壊さないよう、移動はclaudecode自身のAPIで行う。
	pcall(terminal.simple_toggle)
	pcall(terminal.ensure_visible)
	if api.nvim_win_is_valid(cur) then
		api.nvim_set_current_win(cur)
	end
end

---レビュー終了時、レビュータブで表示されていたターミナルを再表示する。
---別タブから持ってきた場合はそのタブへ、レビュータブで開いた場合は今のタブへ戻す。
function M.restore_terminal(session, was_visible)
	local terminal = terminal_api()
	if not (was_visible and terminal) then
		return
	end
	local origin = session.claude_origin_tab
	if origin and api.nvim_tabpage_is_valid(origin) then
		api.nvim_set_current_tabpage(origin)
	end
	local cur = api.nvim_get_current_win()
	pcall(terminal.ensure_visible)
	if api.nvim_win_is_valid(cur) then
		api.nvim_set_current_win(cur)
	end
end

---@return integer|nil
function M.terminal_buf()
	local terminal = terminal_api()
	return terminal and terminal.get_active_terminal_bufnr()
end

---@return boolean
function M.terminal_visible_in(tab)
	local buf = M.terminal_buf()
	return buf ~= nil and tab ~= nil and api.nvim_tabpage_is_valid(tab) and #windows_in_tab(buf, tab) > 0
end

return M
