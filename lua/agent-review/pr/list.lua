local config = require("agent-review.config")
local gh = require("agent-review.pr.gh")
local query = require("agent-review.pr.query")
local store = require("agent-review.pr.store")

-- PR一覧の取得。設定の各リストをGraphQLの1リクエストにまとめて検索し、
-- キャッシュがあればまず返してから取り直す（stale-while-revalidate）。
local M = {}

local FIELDS = [[
number title url isDraft state createdAt updatedAt
additions deletions changedFiles headRefName baseRefName body reviewDecision
author { login }
commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
]]

---@class AgentReviewPrItem
---@field number integer
---@field title string
---@field url string
---@field author string
---@field draft boolean
---@field state string OPEN|CLOSED|MERGED
---@field review string|nil APPROVED|CHANGES_REQUESTED|REVIEW_REQUIRED
---@field checks string|nil SUCCESS|FAILURE|ERROR|PENDING|EXPECTED
---@field additions integer
---@field deletions integer
---@field changed_files integer
---@field head string
---@field base string
---@field body string
---@field updated_at string ISO 8601

---@return AgentReviewPrItem
local function normalize(node)
	local commit = (((node.commits or {}).nodes or {})[1] or {}).commit or {}
	return {
		number = node.number,
		title = node.title or "",
		url = node.url,
		author = (node.author or {}).login or "ghost",
		draft = node.isDraft == true,
		state = node.state,
		review = node.reviewDecision,
		checks = (commit.statusCheckRollup or {}).state,
		additions = node.additions or 0,
		deletions = node.deletions or 0,
		changed_files = node.changedFiles or 0,
		head = node.headRefName,
		base = node.baseRefName,
		body = node.body or "",
		updated_at = node.updatedAt or "",
	}
end

---@return string[]|nil queries, string|nil err
local function queries_for(repo, name)
	local opts = config.options.pr
	local filters = opts.lists
	if name then
		filters = (opts.presets or {})[name]
		if filters == nil then
			return nil, ("unknown preset '%s'"):format(name)
		end
	end
	if type(filters) == "string" or (type(filters) == "table" and not vim.islist(filters)) then
		filters = { filters }
	end
	return vim.tbl_map(function(f)
		return query.build(f, { repo = repo.nwo, state = opts.state })
	end, filters)
end

local function request(queries)
	local decls, fields, vars = {}, {}, {}
	for i, q in ipairs(queries) do
		local v = "q" .. i
		vars[v] = q
		table.insert(decls, ("$%s: String!"):format(v))
		table.insert(
			fields,
			("%s: search(query: $%s, type: ISSUE, first: %d) { nodes { ... on PullRequest { %s } } }"):format(
				v,
				v,
				config.options.pr.limit or 50,
				FIELDS
			)
		)
	end
	return ("query(%s) { %s }"):format(table.concat(decls, ", "), table.concat(fields, " ")), vars
end

local function merge(data, n)
	local seen, items = {}, {}
	for i = 1, n do
		for _, node in ipairs(((data or {})["q" .. i] or {}).nodes or {}) do
			if node.number and not seen[node.number] then
				seen[node.number] = true
				table.insert(items, normalize(node))
			end
		end
	end
	table.sort(items, function(a, b)
		return a.updated_at > b.updated_at
	end)
	return items
end

---@class AgentReviewPrFetchInfo
---@field from_cache boolean
---@field final boolean これ以上コールバックが呼ばれない

---PR一覧を取得する。古いキャッシュがある時は、キャッシュと取り直した結果の2回コールバックを呼ぶ。
---@param repo AgentReviewRepo
---@param name? string presetの名前。nil なら pr.lists
---@param opts { force?: boolean }
---@param cb fun(err: AgentReviewGhError|{message: string}|nil, items: AgentReviewPrItem[]|nil, info: AgentReviewPrFetchInfo|nil)
function M.fetch(repo, name, opts, cb)
	local queries, err = queries_for(repo, name)
	if not queries then
		return cb({ kind = "config", message = err })
	end
	-- 設定を変えた時に古い結果を使わないよう、クエリ自体をキーに含める。
	local key = ("%s/pr-lists/%s"):format(repo.key, vim.fn.sha256(table.concat(queries, "\n")):sub(1, 16))
	local cached = store.get(key)
	if cached and not opts.force then
		local fresh = os.time() - cached.fetched_at < (config.options.pr.list_ttl or 0)
		cb(nil, cached.value, { from_cache = true, final = fresh })
		if fresh then
			return
		end
	end
	local q, vars = request(queries)
	gh.graphql(q, vars, function(gerr, data)
		if gerr then
			return cb(gerr, nil, { from_cache = false, final = true })
		end
		local items = merge(data, #queries)
		store.put(key, items)
		cb(nil, items, { from_cache = false, final = true })
	end, { hostname = repo.host })
end

---@return string[]
function M.preset_names()
	local names = vim.tbl_keys(config.options.pr.presets or {})
	table.sort(names)
	return names
end

return M
