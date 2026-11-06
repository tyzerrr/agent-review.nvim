-- レビュータブの左端に出す変更ファイルのツリーの窓。描画内容は tree.lua が作る。
local changes = require("agent-review.changes")
local config = require("agent-review.config")
local tree = require("agent-review.tree")

local api = vim.api

local M = {}

local NAME = "agent-review://tree"
local ns = api.nvim_create_namespace("agent-review-tree")
local ns_current = api.nvim_create_namespace("agent-review-tree-current")

local function icon_provider()
	if not config.options.tree.icons then
		return nil
	end
	local ok_mini, mini = pcall(require, "mini.icons")
	if ok_mini and _G.MiniIcons then
		return function(name)
			local icon, hl = mini.get("file", name)
			return icon, hl
		end
	end
	local ok_dev, devicons = pcall(require, "nvim-web-devicons")
	if ok_dev then
		return function(name)
			return devicons.get_icon(name, nil, { default = true })
		end
	end
end

---@param s AgentReviewSession
function M.is_open(s)
	return s.tree_win ~= nil and api.nvim_win_is_valid(s.tree_win) and api.nvim_win_get_buf(s.tree_win) == s.tree_buf
end

local function buffer(s)
	if s.tree_buf and api.nvim_buf_is_valid(s.tree_buf) then
		return s.tree_buf
	end
	local existing = vim.fn.bufnr(NAME)
	if existing ~= -1 then
		pcall(api.nvim_buf_delete, existing, { force = true })
	end
	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_name(buf, NAME)
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "agent-review-tree"
	s.tree_buf = buf
	s:map_tree_buffer(buf)
	api.nvim_create_autocmd("CursorMoved", {
		group = s.augroup,
		buffer = buf,
		callback = function()
			M.on_cursor_moved(s)
		end,
	})
	return buf
end

---ツリーの窓をタブの左端に開く。フォーカスは動かさない。
---@param s AgentReviewSession
function M.open(s)
	if M.is_open(s) then
		return
	end
	local buf = buffer(s)
	local win = api.nvim_open_win(buf, false, {
		split = "left",
		win = -1,
		width = config.options.tree.width,
	})
	s.tree_win = win
	local wo = vim.wo[win]
	wo.winfixwidth = true
	wo.number = false
	wo.relativenumber = false
	wo.signcolumn = "no"
	wo.foldcolumn = "0"
	wo.spell = false
	wo.list = false
	wo.wrap = false
	wo.cursorline = true
	api.nvim_create_autocmd("WinClosed", {
		group = s.augroup,
		pattern = tostring(win),
		callback = function()
			if s.tree_win == win then
				s.tree_win = nil
			end
		end,
	})
	M.render(s)
end

---@param s AgentReviewSession
function M.close(s)
	if s.tree_win and api.nvim_win_is_valid(s.tree_win) then
		pcall(api.nvim_win_close, s.tree_win, true)
	end
	s.tree_win = nil
end

local function esc(text)
	return (text:gsub("%%", "%%%%"))
end

---@return string label, integer width 見出しのモード名（winbarの書式）と表示幅
local function mode_label(s)
	local text, hl, extra
	if s.mode == "working" then
		text, hl = " Uncommitted ", "AgentReviewTreeMode"
	elseif s.mode == "branch" then
		text, hl, extra = " Branch ", "AgentReviewTreeModeBranch", "⑂ " .. s.base
	else
		text, hl = " " .. s.label .. " ", "AgentReviewTreeModeBranch"
	end
	local label = ("%%#%s#%s%%*"):format(hl, esc(text))
	local width = vim.fn.strdisplaywidth(text)
	if extra then
		label = label .. " " .. esc(extra)
		width = width + 1 + vim.fn.strdisplaywidth(extra)
	end
	return label, width
end

---狭い窓でwinbarの頭（モード名）が切れないよう、入る分だけ要約を付ける。
local function winbar(s, list, viewed)
	local label, width = mode_label(s)
	local parts = tree.summary_parts(list, viewed)
	if s.hidden_tests > 0 then
		table.insert(parts, ("%d test%s hidden"):format(s.hidden_tests, s.hidden_tests == 1 and "" or "s"))
	end
	local room = api.nvim_win_get_width(s.tree_win) - width
	local out = label
	for _, part in ipairs(parts) do
		local w = vim.fn.strdisplaywidth(part) + 2
		if w > room then
			break
		end
		out = out .. "  " .. esc(part)
		room = room - w
	end
	return out
end

---@param s AgentReviewSession
function M.render(s)
	if not M.is_open(s) then
		return
	end
	local list = changes.collect(s.root, s.base_sha, s.review_files, s.base_cache)
	local function viewed(path)
		return s:is_viewed(path)
	end
	local r = tree.build(list, { collapsed = s.tree_collapsed, viewed = viewed, icon = icon_provider() })
	s.tree_render = r
	local buf = s.tree_buf
	vim.bo[buf].modifiable = true
	api.nvim_buf_set_lines(buf, 0, -1, false, r.lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
	api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for _, h in ipairs(r.highlights) do
		api.nvim_buf_set_extmark(buf, ns, h.line, h.col, { end_col = h.end_col, hl_group = h.group })
	end
	for lnum, virt in pairs(r.virt) do
		api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, { virt_text = virt, virt_text_pos = "eol" })
	end
	vim.wo[s.tree_win].winbar = winbar(s, list, viewed)
	M.mark_current(s)
end

---@return AgentReviewTreeNode|nil
function M.node_at_cursor(s)
	if not (M.is_open(s) and s.tree_render) then
		return nil
	end
	return s.tree_render.nodes[api.nvim_win_get_cursor(s.tree_win)[1]]
end

---右に出しているファイルの行に印を付け、ツリーのカーソルもそこへ移す。
---ツリーで操作中にフォルダの行を見ている時は、カーソルを奪わない。
---@param s AgentReviewSession
function M.mark_current(s)
	if not (M.is_open(s) and s.tree_render) then
		return
	end
	local buf = s.tree_buf
	api.nvim_buf_clear_namespace(buf, ns_current, 0, -1)
	local lnum = s.current_rel and s.tree_render.file_line[s.current_rel]
	if not lnum then
		return
	end
	api.nvim_buf_set_extmark(buf, ns_current, lnum - 1, 0, { line_hl_group = "AgentReviewTreeCurrent" })
	local node = M.node_at_cursor(s)
	local in_tree = api.nvim_get_current_win() == s.tree_win
	if node and node.path == s.current_rel then
		return
	end
	if in_tree and node and node.kind == "dir" then
		return
	end
	s.tree_moving = true
	pcall(api.nvim_win_set_cursor, s.tree_win, { lnum, 0 })
	s.tree_moving = false
end

---ツリーで選んだファイルを右に出し、最初の変更箇所へカーソルを置く。
local function show_node(s, node)
	if node.path ~= s.current_rel then
		s:show(node.path)
		local lnum = node.change and node.change.lnum or 1
		local last = api.nvim_buf_line_count(api.nvim_win_get_buf(s.right_win))
		pcall(api.nvim_win_set_cursor, s.right_win, { math.min(math.max(lnum, 1), last), 0 })
		api.nvim_win_call(s.right_win, function()
			vim.cmd("normal! zz")
		end)
	end
end

function M.on_cursor_moved(s)
	if s.tree_moving or not config.options.tree.follow_cursor or not s:valid() then
		return
	end
	if api.nvim_get_current_win() ~= s.tree_win then
		return
	end
	local node = M.node_at_cursor(s)
	if node and node.kind == "file" then
		show_node(s, node)
	end
end

---カーソル行がファイルなら右のdiffへ移り、フォルダなら畳む／開く。
function M.activate(s)
	local node = M.node_at_cursor(s)
	if not node then
		return
	end
	if node.kind == "dir" then
		s.tree_collapsed[node.path] = node.open or nil
		M.render(s)
		local lnum
		for l, n in pairs(s.tree_render.nodes) do
			if n.kind == "dir" and n.path == node.path then
				lnum = l
			end
		end
		if lnum then
			s.tree_moving = true
			api.nvim_win_set_cursor(s.tree_win, { lnum, 0 })
			s.tree_moving = false
		end
		return
	end
	show_node(s, node)
	api.nvim_set_current_win(s.right_win)
end

---カーソル行のファイル（フォルダなら中の全ファイル）。
---@return string[]
function M.paths_at_cursor(s)
	local node = M.node_at_cursor(s)
	if not node then
		return {}
	end
	if node.kind == "file" then
		return { node.path }
	end
	local prefix = node.path .. "/"
	local out = {}
	for _, f in ipairs(s.review_files) do
		if f.path:sub(1, #prefix) == prefix then
			table.insert(out, f.path)
		end
	end
	return out
end

return M
