local changes = require("agent-review.changes")
local compose = require("agent-review.pr.compose")
local draft = require("agent-review.pr.draft")
local gh = require("agent-review.pr.gh")

-- レビューを書く操作。コメント・返信・解決はすべて下書きに溜め、submit でまとめて1回のGraphQLで送る。
local M = {}

local api = vim.api

local function notify(msg, level)
	vim.notify("[agent-review] " .. msg, level or vim.log.levels.INFO)
end

-- GitHubは変更行の前後この行数までをdiffとして表示し、そこにしかコメントを付けられない。
local CONTEXT = 3

---GitHubのdiffに表示される（＝コメントできる）行か。
local function commentable(s, rel, side, line)
	local f = s:file(rel)
	if not f then
		return false
	end
	local c = changes.compute(s.root, s.base_sha, f)
	for _, h in ipairs(c.hunks) do
		local start = side == "LEFT" and h.base_start or h.work_start
		local count = side == "LEFT" and h.base_count or h.work_count
		if line >= start - CONTEXT + (count == 0 and 1 or 0) and line <= start + math.max(count, 1) - 1 + CONTEXT then
			return true
		end
	end
	return false
end

local function refresh_view(s)
	require("agent-review.pr.threads").annotate(s)
	if s.qf_mode == "comments" and s.qf_id then
		s:update_quickfix()
	end
end

local function split(body)
	return body ~= "" and vim.split(body, "\n", { plain = true }) or {}
end

---カーソル行（またはl1〜l2）にコメントを書く。同じ場所の下書きがあればそれを編集する。
---@param s AgentReviewSession
function M.comment(s, win, l1, l2)
	local side = win == s.left_win and "LEFT" or "RIGHT"
	local rel = s.current_rel
	if not (rel and s:file(rel)) then
		return notify("comments can only be added to files changed in the PR", vim.log.levels.WARN)
	end
	if side == "LEFT" and vim.b[api.nvim_win_get_buf(win)].agent_review_side ~= "base" then
		return notify("this file has no base side to comment on", vim.log.levels.WARN)
	end
	if l1 > l2 then
		l1, l2 = l2, l1
	end
	for _, line in ipairs(l1 == l2 and { l1 } or { l1, l2 }) do
		if not commentable(s, rel, side, line) then
			return notify(
				("GitHub only accepts comments on lines shown in the diff (changes and %d lines around them)"):format(CONTEXT),
				vim.log.levels.WARN
			)
		end
	end
	local repo, n = s.pr.repo, s.pr.meta.number
	local start_line = l1 < l2 and l1 or nil
	local function same(c)
		return c.path == rel and c.side == side and c.line == l2 and c.start_line == start_line
	end
	local existing
	for _, c in ipairs(draft.load(repo, n).comments) do
		if same(c) then
			existing = c
		end
	end
	local where = start_line and ("%s:%d-%d"):format(rel, l1, l2) or ("%s:%d"):format(rel, l2)
	compose.open({
		title = (" Comment on %s%s "):format(where, side == "LEFT" and " (base)" or ""),
		lines = existing and split(existing.body) or {},
		on_save = function(body)
			local d = draft.load(repo, n)
			d.comments = vim.tbl_filter(function(c)
				return not same(c)
			end, d.comments)
			if body ~= "" then
				table.insert(d.comments, { id = draft.new_id(), path = rel, line = l2, start_line = start_line, side = side, body = body })
			end
			draft.save(repo, n, d)
			refresh_view(s)
		end,
	})
end

---@param t AgentReviewThread
function M.reply(s, t)
	local repo, n = s.pr.repo, s.pr.meta.number
	local existing
	for _, r in ipairs(draft.load(repo, n).replies) do
		if r.thread_id == t.id then
			existing = r
		end
	end
	compose.open({
		title = (" Reply to %s on %s:%d "):format((t.comments[1] or {}).author or "thread", t.path, t.line or t.original_line or 0),
		lines = existing and split(existing.body) or {},
		on_save = function(body)
			local d = draft.load(repo, n)
			d.replies = vim.tbl_filter(function(r)
				return r.thread_id ~= t.id
			end, d.replies)
			if body ~= "" then
				table.insert(d.replies, { thread_id = t.id, body = body })
			end
			draft.save(repo, n, d)
			refresh_view(s)
		end,
	})
end

---スレッドの解決／解決の取り消しを下書きに入れる（もう一度押すと取り消す）。
---@param t AgentReviewThread
function M.toggle_resolve(s, t)
	local repo, n = s.pr.repo, s.pr.meta.number
	local d = draft.load(repo, n)
	if d.resolve[t.id] ~= nil then
		d.resolve[t.id] = nil
	else
		d.resolve[t.id] = not t.resolved
	end
	draft.save(repo, n, d)
	refresh_view(s)
	return d.resolve[t.id]
end

local EVENTS = { approve = "APPROVE", request_changes = "REQUEST_CHANGES", comment = "COMMENT" }

---下書きを1回のGraphQLにまとめる。返り値の parts は alias と下書きの対応。
---@param d AgentReviewDraft
local function build(s, d, event, body)
	local decls, fields, vars, parts = {}, {}, {}, {}
	if event then
		vim.list_extend(decls, {
			"$prId: ID!",
			"$commit: GitObjectID!",
			"$event: PullRequestReviewEvent!",
			"$body: String",
			"$threads: [DraftPullRequestReviewThread]",
		})
		table.insert(
			fields,
			"review: addPullRequestReview(input: {pullRequestId: $prId, commitOID: $commit, event: $event, body: $body, threads: $threads}) { pullRequestReview { id url } }"
		)
		vars.prId = s.pr.pr_id
		vars.commit = s.pr.head
		vars.event = event
		vars.body = body
		vars.threads = vim.tbl_map(function(c)
			local t = { path = c.path, line = c.line, side = c.side, body = c.body }
			if c.start_line then
				t.startLine = c.start_line
				t.startSide = c.side
			end
			return t
		end, d.comments)
		parts.review = { kind = "review" }
	end
	for i, r in ipairs(d.replies) do
		local alias = "reply" .. i
		table.insert(decls, ("$%s: AddPullRequestReviewThreadReplyInput!"):format(alias))
		table.insert(fields, ("%s: addPullRequestReviewThreadReply(input: $%s) { comment { id } }"):format(alias, alias))
		vars[alias] = { pullRequestReviewThreadId = r.thread_id, body = r.body }
		parts[alias] = { kind = "reply", thread_id = r.thread_id }
	end
	local i = 0
	for thread_id, resolve in pairs(d.resolve) do
		i = i + 1
		local alias = (resolve and "resolve" or "unresolve") .. i
		table.insert(decls, ("$%s: ID!"):format(alias))
		table.insert(
			fields,
			("%s: %s(input: {threadId: $%s}) { thread { id isResolved } }"):format(alias, resolve and "resolveReviewThread" or "unresolveReviewThread", alias)
		)
		vars[alias] = thread_id
		parts[alias] = { kind = "resolve", thread_id = thread_id }
	end
	return ("mutation(%s) { %s }"):format(table.concat(decls, ", "), table.concat(fields, " ")), vars, parts
end

local function send(s, event, body)
	local repo, n = s.pr.repo, s.pr.meta.number
	local d = draft.load(repo, n)
	if event and not s.pr.pr_id then
		return notify("PR details are still loading; try again in a moment", vim.log.levels.WARN)
	end
	local query, vars, parts = build(s, d, event, body)
	notify(("submitting %s…"):format(draft.describe(d)))
	gh.graphql_raw(query, vars, function(err, data, errors)
		if err then
			return notify("submit failed: " .. err.message, vim.log.levels.ERROR)
		end
		data = data or {}
		-- 成功したものだけを下書きから外す。失敗したものは残して送り直せるようにする。
		local current = draft.load(repo, n)
		local sent = 0
		for alias, part in pairs(parts) do
			if data[alias] ~= nil then
				sent = sent + 1
				if part.kind == "review" then
					current.comments = {}
					current.summary = ""
				elseif part.kind == "reply" then
					current.replies = vim.tbl_filter(function(r)
						return r.thread_id ~= part.thread_id
					end, current.replies)
				else
					current.resolve[part.thread_id] = nil
				end
			end
		end
		if sent < vim.tbl_count(parts) and event and data.review == nil then
			current.summary = body
		end
		draft.save(repo, n, current)
		if sent > 0 then
			require("agent-review.pr.open").load_comments(s)
		end
		if errors and errors[1] then
			local messages = vim.tbl_map(function(e)
				return e.message
			end, errors)
			return notify("submit failed: " .. table.concat(messages, "; "), vim.log.levels.ERROR)
		end
		local review = data.review and data.review.pullRequestReview
		if review then
			notify(("review submitted%s"):format(review.url and (": " .. review.url) or ""))
		else
			notify(("submitted %s"):format(draft.describe(d)))
		end
	end, { hostname = repo.host })
end

---下書きをまとめてGitHubへ送る。event を付けるとレビュー（Approve等）として送り、本文を書く窓を開く。
---@param s AgentReviewSession
---@param name? "approve"|"request_changes"|"comment"
function M.submit(s, name)
	local event = name and EVENTS[name]
	if name and not event then
		return notify(("unknown review type '%s' (approve, request_changes, comment)"):format(name), vim.log.levels.ERROR)
	end
	local repo, n = s.pr.repo, s.pr.meta.number
	local d = draft.load(repo, n)
	-- 行へのコメントはレビューの一部としてしか送れないので、種類の指定が無ければ Comment として送る。
	if not event and #d.comments > 0 then
		event = "COMMENT"
	end
	if not event then
		if draft.is_empty(d) then
			return notify("nothing to submit")
		end
		return send(s, nil, nil)
	end
	compose.open({
		title = (" Submit review: %s · %s "):format(event, draft.describe(d)),
		lines = d.summary ~= "" and vim.split(d.summary, "\n", { plain = true }) or {},
		on_save = function(body)
			send(s, event, body)
		end,
	})
end

M.EVENT_NAMES = { "approve", "request_changes", "comment" }

return M
