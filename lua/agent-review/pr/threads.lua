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

local pad_ns = api.nvim_create_namespace("agent-review-comment-pad")

---diffのhunkを使って、片側の行が反対側のどの行に並ぶかを返す（0 は先頭より前）。
---@param from "RIGHT"|"LEFT"
local function aligned_line(hunks, line, from)
	local offset = 0
	for _, h in ipairs(hunks) do
		local fs, fc = h.work_start, h.work_count
		local ts, tc = h.base_start, h.base_count
		if from == "LEFT" then
			fs, fc, ts, tc = ts, tc, fs, fc
		end
		if fc > 0 and line >= fs and line <= fs + fc - 1 then
			local k = line - fs
			if k < tc then
				return ts + k
			end
			return tc > 0 and (ts + tc - 1) or ts
		end
		if (fc > 0 and line < fs) or (fc == 0 and line <= fs) then
			return line + offset
		end
		offset = offset + (tc - fc)
	end
	return line + offset
end

---コメントの行を足した分だけ、反対側の窓にも空行を足して左右の並びを保つ。
---Neovimのdiffは virt_lines を位置合わせに数えないため。
local function pad(buf, line, count)
	if count <= 0 or not api.nvim_buf_is_valid(buf) then
		return
	end
	local blank = {}
	for i = 1, count do
		blank[i] = { { "", "" } }
	end
	local last = api.nvim_buf_line_count(buf)
	if line <= 0 then
		pcall(api.nvim_buf_set_extmark, buf, pad_ns, 0, 0, { virt_lines = blank, virt_lines_above = true })
	else
		pcall(api.nvim_buf_set_extmark, buf, pad_ns, math.min(line, last) - 1, 0, { virt_lines = blank })
	end
end

local function draft_of(s)
	return require("agent-review.pr.draft").load(s.pr.repo, s.pr.meta.number)
end

---@param d AgentReviewDraft
---@return table<integer, integer> 行 -> そこに足したコメントの行数
local function place(buf, threads, drafts, d)
	api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	local added = {}
	local last = api.nvim_buf_line_count(buf)
	local opts = config.options.pr or {}
	local replied = {}
	for _, r in ipairs(d.replies) do
		replied[r.thread_id] = true
	end
	for _, t in ipairs(threads) do
		local author, text = M.summary(t)
		local hl = t.resolved and "AgentReviewCommentResolved" or "AgentReviewComment"
		local pending = ""
		if replied[t.id] then
			pending = pending .. "  📝 draft reply"
		end
		if d.resolve[t.id] == true then
			pending = pending .. "  (will resolve)"
		elseif d.resolve[t.id] == false then
			pending = pending .. "  (will unresolve)"
		end
		local chunks = { { "  " .. (t.resolved and "✓ resolved  " or "💬 "), hl }, { author, t.resolved and hl or M.author_hl(author) }, { ": " .. text, hl } }
		if pending ~= "" then
			table.insert(chunks, { pending, "AgentReviewDraft" })
		end
		-- 行末だと長い行で画面の外に出てしまうので、GitHubと同じくコメントは行の下に出す。
		local line = math.min(t.line, last)
		pcall(api.nvim_buf_set_extmark, buf, ns, line - 1, 0, {
			sign_text = t.resolved and (opts.resolved_sign or "✓") or (opts.comment_sign or "💬"),
			sign_hl_group = hl,
			virt_lines = { chunks },
		})
		added[line] = (added[line] or 0) + 1
	end
	for _, c in ipairs(drafts) do
		local line = math.min(c.line, last)
		pcall(api.nvim_buf_set_extmark, buf, ns, line - 1, 0, {
			sign_text = opts.draft_sign or "📝",
			sign_hl_group = "AgentReviewDraft",
			virt_lines = { { { "  📝 draft: " .. first_line(c.body, 60), "AgentReviewDraft" } } },
		})
		added[line] = (added[line] or 0) + 1
	end
	return added
end

local function drafts_for(d, rel, side)
	return vim.tbl_filter(function(c)
		return c.path == rel and c.side == side
	end, d.comments)
end

---表示中の左右のバッファに、そのファイルのスレッドを置き直す。
---@param s AgentReviewSession
function M.annotate(s)
	if not (s.pr and s.pr.threads and s:valid()) then
		return
	end
	local rel = s.current_rel
	local d = draft_of(s)
	local right = api.nvim_win_get_buf(s.right_win)
	local left = api.nvim_win_get_buf(s.left_win)
	api.nvim_buf_clear_namespace(right, pad_ns, 0, -1)
	api.nvim_buf_clear_namespace(left, pad_ns, 0, -1)
	local right_added = place(right, rel and M.for_file(s.pr.threads, rel, "RIGHT") or {}, rel and drafts_for(d, rel, "RIGHT") or {}, d)
	if vim.b[left].agent_review_side ~= "base" then
		return
	end
	local left_added = place(left, rel and M.for_file(s.pr.threads, rel, "LEFT") or {}, rel and drafts_for(d, rel, "LEFT") or {}, d)
	local f = rel and s:file(rel)
	local hunks = f and require("agent-review.changes").compute(s.root, s.base_sha, f).hunks or {}
	for line, count in pairs(right_added) do
		pad(left, aligned_line(hunks, line, "RIGHT"), count)
	end
	for line, count in pairs(left_added) do
		pad(right, aligned_line(hunks, line, "LEFT"), count)
	end
end

function M.clear_all()
	for _, buf in ipairs(api.nvim_list_bufs()) do
		if api.nvim_buf_is_valid(buf) then
			api.nvim_buf_clear_namespace(buf, ns, 0, -1)
			api.nvim_buf_clear_namespace(buf, pad_ns, 0, -1)
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
---@param d? AgentReviewDraft 下書きの返信・解決も並べて見せる
---@return string[] lines, table authors, { first: integer, thread: AgentReviewThread }[] ranges
local function thread_lines(threads, d)
	local lines, authors, ranges = {}, {}, {}
	for i, t in ipairs(threads) do
		if i > 1 then
			vim.list_extend(lines, { "", "---", "" })
		end
		local state = t.resolved and "  (resolved)" or ""
		if d and d.resolve[t.id] ~= nil then
			state = state .. (d.resolve[t.id] and "  (will resolve)" or "  (will unresolve)")
		end
		table.insert(lines, ("### %s:%d%s"):format(t.path, t.line or t.original_line or 0, state))
		table.insert(ranges, { first = #lines, thread = t })
		for _, c in ipairs(t.comments) do
			table.insert(lines, "")
			table.insert(lines, ("**@%s** · %s"):format(c.author, ago(c.created_at)))
			table.insert(authors, { #lines, c.author })
			table.insert(lines, "")
			vim.list_extend(lines, vim.split(c.body, "\r?\n"))
		end
		for _, r in ipairs(d and d.replies or {}) do
			if r.thread_id == t.id then
				vim.list_extend(lines, { "", "**📝 draft reply**", "" })
				vim.list_extend(lines, vim.split(r.body, "\r?\n"))
			end
		end
	end
	return lines, authors, ranges
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
---@param s? AgentReviewSession 渡すと r（返信）/ R（解決の切り替え）が使える
function M.open_float(threads, s)
	local d = s and draft_of(s) or nil
	local lines, authors, ranges = thread_lines(threads, d)
	local buf = api.nvim_create_buf(false, true)
	local function render()
		lines, authors, ranges = thread_lines(threads, s and draft_of(s) or nil)
		vim.bo[buf].modifiable = true
		api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false
		api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		color_authors(buf, authors)
	end
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].bufhidden = "wipe"
	render()
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
		footer = s and " r reply · R resolve · c Claude · q close " or " q close ",
		footer_pos = "right",
	})
	vim.wo[win].wrap = true
	vim.wo[win].conceallevel = 2
	for _, lhs in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", lhs, function()
			pcall(api.nvim_win_close, win, true)
		end, { buffer = buf, nowait = true })
	end
	if s then
		-- カーソルが乗っているスレッド（見出しより下で最も近いもの）を対象にする。
		local function current()
			local row = api.nvim_win_get_cursor(win)[1]
			local found = ranges[1] and ranges[1].thread
			for _, r in ipairs(ranges) do
				if r.first <= row then
					found = r.thread
				end
			end
			return found
		end
		vim.keymap.set("n", "r", function()
			local t = current()
			pcall(api.nvim_win_close, win, true)
			require("agent-review.pr.review").reply(s, t)
		end, { buffer = buf, nowait = true, desc = "Reply (draft)" })
		vim.keymap.set("n", "c", function()
			local t = current()
			pcall(api.nvim_win_close, win, true)
			require("agent-review.pr.handoff").send_thread(s, t)
		end, { buffer = buf, nowait = true, desc = "Send to Claude Code" })
		vim.keymap.set("n", "R", function()
			require("agent-review.pr.review").toggle_resolve(s, current())
			render()
		end, { buffer = buf, nowait = true, desc = "Toggle resolve (draft)" })
	end
	return win
end

local function order(t)
	if t.resolved then
		return 3
	end
	return t.outdated and 2 or 1
end

local function locate(s, item, path, side)
	if side == "LEFT" then
		-- 比較元側のスレッドは base のバッファを指す。右窓に開かれたら左右を入れ替えて表示する。
		item.bufnr = s:base_buffer(path)
		item.module = path
	elseif vim.uv.fs_stat(s.root .. "/" .. path) then
		item.filename = s.root .. "/" .. path
		item.module = path
	else
		item.bufnr = s:deleted_buffer(path)
		item.module = path
	end
	return item.bufnr or item.filename
end

---comments モードの quickfix の項目。下書き→未解決→outdated→解決済みの順。
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
	local d = draft_of(s)
	for _, c in ipairs(d.comments) do
		local item = { lnum = c.line, col = 1, text = "[draft] you: " .. first_line(c.body, 60) }
		if locate(s, item, c.path, c.side) then
			table.insert(items, item)
		end
	end
	for _, t in ipairs(threads) do
		local author, text = M.summary(t)
		local tag = t.resolved and "[resolved] " or (t.outdated and "[outdated] " or "")
		local item = { lnum = t.line or t.original_line or 1, col = 1, text = ("%s%s: %s"):format(tag, author, text) }
		if locate(s, item, t.path, t.side) then
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
	local checks = pr.checks
	if checks and #checks.items > 0 then
		vim.list_extend(lines, { "", "## Checks", "" })
		for _, c in ipairs(checks.items) do
			local mark = (c.state == "SUCCESS" or c.state == "NEUTRAL" or c.state == "SKIPPED") and "✓"
				or ((c.state == "FAILURE" or c.state == "ERROR" or c.state == "TIMED_OUT" or c.state == "CANCELLED" or c.state == "ACTION_REQUIRED") and "✗" or "…")
			table.insert(lines, ("- %s %s%s"):format(mark, c.name, c.url and ("  <%s>"):format(c.url) or ""))
		end
	end
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
		if s:valid() then
			api.nvim_set_current_win(s.right_win)
		end
	end, { buffer = buf, nowait = true })
	return buf
end

return M
