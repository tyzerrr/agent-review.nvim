local gh = require("agent-review.pr.gh")
local mirror = require("agent-review.pr.mirror")
local repo_mod = require("agent-review.pr.repo")

-- PRをレビュー画面で開く。PRの情報（headのSHA等）だけをGitHubに問い合わせ、
-- diff自体はPRのコミットを取ってきてローカルで計算する（APIを使わない）。
local M = {}

local function notify(msg, level)
	vim.notify("[agent-review] " .. msg, level or vim.log.levels.INFO)
end

---@class AgentReviewPr
---@field number integer
---@field title string
---@field url string
---@field author string
---@field head_ref string
---@field head_sha string
---@field base_ref string
---@field base_sha string
---@field state string OPEN|CLOSED|MERGED

---REST /pulls/<n> の応答を必要な形にする。
---@return AgentReviewPr
function M.meta(pull)
	local merged = pull.merged_at ~= nil and pull.merged_at ~= vim.NIL
	return {
		number = pull.number,
		title = pull.title or "",
		url = pull.html_url,
		author = (pull.user or {}).login or "ghost",
		head_ref = (pull.head or {}).ref,
		head_sha = (pull.head or {}).sha,
		base_ref = (pull.base or {}).ref,
		base_sha = (pull.base or {}).sha,
		state = merged and "MERGED" or (pull.state or "open"):upper(),
	}
end

---PRの情報を取る。ETagで問い合わせるので、変わっていなければレート制限を使わない。
---@param cb fun(err: string|nil, meta: AgentReviewPr|nil, info: { from_cache: boolean }|nil)
local function fetch_meta(repo, number, cb)
	gh.rest_cached(("%s/pulls/%d"):format(repo.key, number), ("repos/%s/pulls/%d"):format(repo.nwo, number), function(err, pull, info)
		if err then
			return cb(("PR #%d: %s"):format(number, err.message))
		end
		cb(nil, M.meta(pull), info)
	end, { hostname = repo.host })
end

---レビューコメントを取得して表示する。
---@param s AgentReviewSession
function M.load_comments(s)
	local pr = s.pr
	require("agent-review.pr.comments").fetch(pr.repo, pr.meta.number, function(err, data)
		if err then
			return notify(("PR #%d comments: %s"):format(pr.meta.number, err.message), vim.log.levels.WARN)
		end
		if s.closed then
			return
		end
		pr.threads, pr.conversation = data.threads, data.conversation
		require("agent-review.pr.threads").annotate(s)
		if s.qf_mode == "comments" and s.qf_id then
			s:update_quickfix()
		end
	end)
end

---@param number integer
function M.open(number)
	local repo, err = repo_mod.detect()
	if not repo then
		return notify(err, vim.log.levels.ERROR)
	end
	notify(("opening PR #%d…"):format(number))
	fetch_meta(repo, number, function(merr, meta)
		if merr then
			return notify(merr, vim.log.levels.ERROR)
		end
		mirror.prepare(repo, meta, function(perr, checkout)
			if perr then
				return notify(perr, vim.log.levels.ERROR)
			end
			require("agent-review").open_pr_session(repo, meta, checkout)
		end)
	end)
end

---開いているPRに新しいpushがあれば取り込む。
---@param s AgentReviewSession
---@param cb fun(changed: boolean)
function M.update(s, cb)
	local pr = s.pr
	fetch_meta(pr.repo, pr.meta.number, function(err, meta, info)
		if err then
			notify(err, vim.log.levels.WARN)
			return cb(false)
		end
		-- コメントが付くとPRの更新日時が変わりETagも変わる。304（変化なし）ならコメントも取り直さない。
		if not info.from_cache then
			M.load_comments(s)
		end
		if meta.head_sha == pr.head then
			return cb(false)
		end
		mirror.prepare(pr.repo, meta, function(perr, checkout)
			if perr then
				notify(perr, vim.log.levels.WARN)
				return cb(false)
			end
			if s.closed then
				return cb(false)
			end
			pr.meta = meta
			pr.head = checkout.head
			s:set_base(checkout.base)
			notify(("PR #%d updated to %s"):format(meta.number, checkout.head:sub(1, 8)))
			cb(true)
		end)
	end)
end

---開いていないPRの取ってきたコードを消す。
function M.clean()
	local repo, err = repo_mod.detect()
	if not repo then
		return notify(err, vim.log.levels.ERROR)
	end
	local s = require("agent-review")._session
	local keep = s and s.pr and s.pr.repo.key == repo.key and s.pr.meta.number or nil
	local targets = vim.tbl_filter(function(n)
		return n ~= keep
	end, mirror.checkouts(repo))
	if #targets == 0 then
		return notify("no PR checkouts to remove")
	end
	local left = #targets
	for _, n in ipairs(targets) do
		mirror.remove(repo, n, function()
			left = left - 1
			if left == 0 then
				notify(("removed %d PR checkout%s"):format(#targets, #targets == 1 and "" or "s"))
			end
		end)
	end
end

return M
