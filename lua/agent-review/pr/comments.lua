local gh = require("agent-review.pr.gh")
local store = require("agent-review.pr.store")

-- PRのレビューコメント（スレッド）と会話（説明・レビュー・コメント）の取得。
-- 読むのに必要なものを1つのGraphQLで取り、スレッドが100件を超える時だけページを送る。
local M = {}

local QUERY = [[
query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      title body createdAt updatedAt
      author { login }
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id path line startLine originalLine diffSide startDiffSide
          isResolved isOutdated subjectType
          comments(first: 100) {
            nodes { id databaseId body createdAt url author { login avatarUrl } replyTo { id } }
          }
        }
      }
      reviews(first: 100) { nodes { state body submittedAt author { login } } }
      comments(first: 100) { nodes { body createdAt author { login } } }
    }
  }
}
]]

---@class AgentReviewComment
---@field id string
---@field db_id integer
---@field author string
---@field avatar string|nil
---@field body string
---@field created_at string
---@field url string
---@field reply_to string|nil

---@class AgentReviewThread
---@field id string
---@field path string
---@field line integer|nil 今のPRの先頭での行。outdated なら nil
---@field start_line integer|nil 複数行のスレッドの先頭
---@field original_line integer|nil
---@field side "LEFT"|"RIGHT" LEFT は比較元（削除された行）側
---@field resolved boolean
---@field outdated boolean
---@field subject string LINE|FILE
---@field comments AgentReviewComment[]

---@class AgentReviewConversation
---@field title string
---@field body string
---@field author string
---@field created_at string
---@field timeline { kind: "review"|"comment", author: string, state?: string, body: string, at: string }[]

local function login(node)
	return (node and node.author or {}).login or "ghost"
end

---@return AgentReviewThread
local function normalize_thread(node)
	return {
		id = node.id,
		path = node.path,
		line = node.line,
		start_line = node.startLine,
		original_line = node.originalLine,
		side = node.diffSide or "RIGHT",
		resolved = node.isResolved == true,
		outdated = node.isOutdated == true,
		subject = node.subjectType or "LINE",
		comments = vim.tbl_map(function(c)
			return {
				id = c.id,
				db_id = c.databaseId,
				author = login(c),
				avatar = (c.author or {}).avatarUrl,
				body = c.body or "",
				created_at = c.createdAt or "",
				url = c.url,
				reply_to = (c.replyTo or {}).id,
			}
		end, ((node.comments or {}).nodes or {})),
	}
end

---@return AgentReviewConversation
local function normalize_conversation(pr)
	local timeline = {}
	for _, r in ipairs((pr.reviews or {}).nodes or {}) do
		table.insert(timeline, { kind = "review", author = login(r), state = r.state, body = r.body or "", at = r.submittedAt or "" })
	end
	for _, c in ipairs((pr.comments or {}).nodes or {}) do
		table.insert(timeline, { kind = "comment", author = login(c), body = c.body or "", at = c.createdAt or "" })
	end
	table.sort(timeline, function(a, b)
		return a.at < b.at
	end)
	return {
		title = pr.title or "",
		body = pr.body or "",
		author = login(pr),
		created_at = pr.createdAt or "",
		timeline = timeline,
	}
end

local function cache_key(repo, number)
	return ("%s/pulls/%d/comments"):format(repo.key, number)
end

---前回取得したコメント（無ければ nil）。
---@return { threads: AgentReviewThread[], conversation: AgentReviewConversation }|nil
function M.cached(repo, number)
	local entry = store.get(cache_key(repo, number))
	return entry and entry.value or nil
end

---@param repo AgentReviewRepo
---@param cb fun(err: AgentReviewGhError|nil, data: { threads: AgentReviewThread[], conversation: AgentReviewConversation }|nil)
function M.fetch(repo, number, cb)
	local threads, conversation = {}, nil
	local function page(cursor)
		local vars = { owner = repo.owner, name = repo.name, number = number, cursor = cursor }
		gh.graphql(QUERY, vars, function(err, data)
			if err then
				return cb(err)
			end
			local pr = ((data or {}).repository or {}).pullRequest
			if not pr then
				return cb({ kind = "api", message = ("PR #%d not found"):format(number) })
			end
			conversation = conversation or normalize_conversation(pr)
			local rt = pr.reviewThreads or {}
			for _, node in ipairs(rt.nodes or {}) do
				table.insert(threads, normalize_thread(node))
			end
			local info = rt.pageInfo or {}
			if info.hasNextPage and info.endCursor then
				return page(info.endCursor)
			end
			local result = { threads = threads, conversation = conversation }
			store.put(cache_key(repo, number), result)
			cb(nil, result)
		end, { hostname = repo.host })
	end
	page(nil)
end

return M
