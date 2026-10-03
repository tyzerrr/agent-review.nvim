local config = require("agent-review.config")

-- PRのレビューコメントの表示。行への印と要約、スレッドの浮動窓、quickfixの項目、会話のバッファ。
local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("agent-review-comments")
M.ns = ns

local AUTHOR_COLORS = 6

---同じ人は毎回同じ色にする（誰のコメントか一目でわかるように）。
function M.author_hl(login)
	local h = 0
	for i = 1, #login do
		h = (h * 31 + login:byte(i)) % 2147483647
	end
	return "AgentReviewAuthor" .. (h % AUTHOR_COLORS + 1)
end

local function first_line(text, max)
	local line = vim.trim((text or ""):match("^[^\r\n]*") or "")
	if vim.fn.strchars(line) > max then
		line = vim.fn.strcharpart(line, 0, max - 1) .. "…"
	end
	return line
end

---@param t AgentReviewThread
function M.summary(t)
	local c = t.comments[1] or { author = "ghost", body = "" }
	local more = #t.comments > 1 and ("  (+%d)"):format(#t.comments - 1) or ""
	return c.author, first_line(c.body, 60) .. more
end

---@param threads AgentReviewThread[]
---@param side "LEFT"|"RIGHT"
---@return AgentReviewThread[]
function M.for_file(threads, rel, side)
	return vim.tbl_filter(function(t)
		return t.path == rel and t.side == side and t.line ~= nil and not t.outdated
	end, threads or {})
end

local function place(buf, threads)
	api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	local last = api.nvim_buf_line_count(buf)
	local opts = config.options.pr or {}
	for _, t in ipairs(threads) do
		local author, text = M.summary(t)
		local hl = t.resolved and "AgentReviewCommentResolved" or "AgentReviewComment"
		local chunks = { { "  " .. (t.resolved and "✓ resolved  " or "💬 "), hl }, { author, t.resolved and hl or M.author_hl(author) }, { ": " .. text, hl } }
		pcall(api.nvim_buf_set_extmark, buf, ns, math.min(t.line, last) - 1, 0, {
			sign_text = t.resolved and (opts.resolved_sign or "✓") or (opts.comment_sign or "💬"),
			sign_hl_group = hl,
			virt_text = chunks,
			virt_text_pos = "eol",
			hl_mode = "combine",
		})
	end
end

---表示中の左右のバッファに、そのファイルのスレッドを置き直す。
---@param s AgentReviewSession
function M.annotate(s)
	if not (s.pr and s.pr.threads and s:valid()) then
		return
	end
	local rel = s.current_rel
	local right = api.nvim_win_get_buf(s.right_win)
	local left = api.nvim_win_get_buf(s.left_win)
	place(right, rel and M.for_file(s.pr.threads, rel, "RIGHT") or {})
	if vim.b[left].agent_review_side == "base" then
		place(left, rel and M.for_file(s.pr.threads, rel, "LEFT") or {})
	end
end

function M.clear_all()
	for _, buf in ipairs(api.nvim_list_bufs()) do
		if api.nvim_buf_is_valid(buf) then
			api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		end
	end
end

---窓のカーソル行にかかるスレッド。
---@return AgentReviewThread[]
function M.at_cursor(s, win)
	local side = win == s.left_win and "LEFT" or "RIGHT"
	local line = api.nvim_win_get_cursor(win)[1]
	return vim.tbl_filter(function(t)
		local first = t.start_line or t.line
		return line >= first and line <= t.line
	end, M.for_file(s.pr.threads, s.current_rel, side))
end

local function ago(iso)
	return require("agent-review.pr.picker").ago(iso)
end

---スレッドを markdown にする。誰の発言かの見出し（@login）には後で色を付ける。
local function thread_lines(threads)
	local lines, authors = {}, {}
	for i, t in ipairs(threads) do
		if i > 1 then
			vim.list_extend(lines, { "", "---", "" })
		end
		table.insert(lines, ("### %s:%d%s"):format(t.path, t.line or t.original_line or 0, t.resolved and "  (resolved)" or ""))
		for _, c in ipairs(t.comments) do
			table.insert(lines, "")
			table.insert(lines, ("**@%s** · %s"):format(c.author, ago(c.created_at)))
			table.insert(authors, { #lines, c.author })
			table.insert(lines, "")
			vim.list_extend(lines, vim.split(c.body, "\r?\n"))
		end
	end
	return lines, authors
end

local function color_authors(buf, authors)
	for _, a in ipairs(authors) do
		local row = a[1] - 1
		local text = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
		local s, e = text:find("@" .. a[2], 1, true)
		if s then
			api.nvim_buf_set_extmark(buf, ns, row, s - 1, { end_col = e, hl_group = M.author_hl(a[2]) })
		end
	end
end

---@param threads AgentReviewThread[]
function M.open_float(threads)
	local lines, authors = thread_lines(threads)
	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"
	color_authors(buf, authors)
	local width = math.min(100, vim.o.columns - 6)
	local height = math.max(3, math.min(#lines, math.floor(vim.o.lines * 0.6)))
	local win = api.nvim_open_win(buf, true, {
		relative = "cursor",
		row = 1,
		col = 0,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = (" %d comment%s "):format(#threads, #threads == 1 and "" or "s"),
	})
	vim.wo[win].wrap = true
	vim.wo[win].conceallevel = 2
	for _, lhs in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", lhs, function()
			pcall(api.nvim_win_close, win, true)
		end, { buffer = buf, nowait = true })
	end
	return win
end

local function order(t)
	if t.resolved then
		return 3
	end
	return t.outdated and 2 or 1
end

---comments モードの quickfix の項目。未解決→outdated→解決済みの順。
---@param s AgentReviewSession
function M.qf_items(s)
	local threads = vim.deepcopy(s.pr.threads or {})
	table.sort(threads, function(a, b)
		if order(a) ~= order(b) then
			return order(a) < order(b)
		end
		if a.path ~= b.path then
			return a.path < b.path
		end
		return (a.line or a.original_line or 0) < (b.line or b.original_line or 0)
	end)
	local items = {}
	for _, t in ipairs(threads) do
		local author, text = M.summary(t)
		local tag = t.resolved and "[resolved] " or (t.outdated and "[outdated] " or "")
		local item = { lnum = t.line or t.original_line or 1, col = 1, text = ("%s%s: %s"):format(tag, author, text) }
		if t.side == "LEFT" then
			-- 比較元側のスレッドは base のバッファを指す。右窓に開かれたら左右を入れ替えて表示する。
			item.bufnr = s:base_buffer(t.path)
			item.module = t.path
		elseif vim.uv.fs_stat(s.root .. "/" .. t.path) then
			item.filename = s.root .. "/" .. t.path
		else
			item.bufnr = s:deleted_buffer(t.path)
			item.module = t.path
		end
		if item.bufnr or item.filename then
			table.insert(items, item)
		end
	end
	return items
end

local REVIEW_STATES = {
	APPROVED = "approved",
	CHANGES_REQUESTED = "requested changes",
	COMMENTED = "reviewed",
	DISMISSED = "dismissed a review",
	PENDING = "has a pending review",
}

---PRの説明・レビュー・コメントを時系列で並べた markdown のバッファを開く。
---@param s AgentReviewSession
function M.open_conversation(s)
	local pr, conv = s.pr, s.pr.conversation
	local lines = {
		("# %s (#%d)"):format(conv.title, pr.meta.number),
		"",
		("**@%s** opened · %s · %s ← %s"):format(conv.author, ago(conv.created_at), pr.meta.base_ref or "?", pr.meta.head_ref or "?"),
		"",
	}
	local authors = { { 3, conv.author } }
	vim.list_extend(lines, vim.split(conv.body ~= "" and conv.body or "_No description provided._", "\r?\n"))
	local open = #vim.tbl_filter(function(t)
		return not t.resolved
	end, pr.threads or {})
	vim.list_extend(lines, {
		"",
		("_%d review thread%s, %d unresolved (`:AgentReviewQuickfix comments`)_"):format(#(pr.threads or {}), #(pr.threads or {}) == 1 and "" or "s", open),
	})
	for _, item in ipairs(conv.timeline) do
		local verb = item.kind == "review" and (REVIEW_STATES[item.state] or "reviewed") or "commented"
		vim.list_extend(lines, { "", "---", "", ("**@%s** %s · %s"):format(item.author, verb, ago(item.at)) })
		table.insert(authors, { #lines, item.author })
		if item.body ~= "" then
			table.insert(lines, "")
			vim.list_extend(lines, vim.split(item.body, "\r?\n"))
		end
	end

	local name = ("agent-review://pr/%d/conversation"):format(pr.meta.number)
	local buf = vim.fn.bufnr(name)
	if buf == -1 then
		buf = api.nvim_create_buf(false, true)
		api.nvim_buf_set_name(buf, name)
	end
	vim.bo[buf].modifiable = true
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "markdown"
	api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	color_authors(buf, authors)
	local win = vim.fn.bufwinid(buf)
	if win == -1 then
		vim.cmd("botright vsplit")
		win = api.nvim_get_current_win()
		api.nvim_win_set_buf(win, buf)
		vim.wo[win].wrap = true
	end
	api.nvim_set_current_win(win)
	vim.keymap.set("n", "q", function()
		pcall(api.nvim_win_close, win, true)
	end, { buffer = buf, nowait = true })
	return buf
end

return M
