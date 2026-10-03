-- 設定に書いた絞り込み（{ author = "@me" } など）をGitHubの検索クエリに変換する。
-- ユーザーにGitHubの検索構文を書かせないため。
local M = {}

-- 出力の順序を固定するため、キーは配列で持つ。
local QUALIFIERS = {
	{ "author", "author" },
	{ "reviewer", "review-requested" }, -- チーム経由のレビュー依頼も含む
	{ "assignee", "assignee" },
	{ "involves", "involves" },
	{ "mentions", "mentions" },
	{ "label", "label" },
	{ "base", "base" },
	{ "head", "head" },
}

local function quote(value)
	value = tostring(value)
	if value:find('[%s"]') then
		return '"' .. value:gsub('"', '\\"') .. '"'
	end
	return value
end

---@param filter table|string 絞り込みのテーブルか、GitHubの検索クエリの文字列
---@param ctx { repo: string, state: string } repo は "owner/name"
---@return string
function M.build(filter, ctx)
	if type(filter) == "string" then
		local parts = {}
		if not filter:find("is:pr", 1, true) then
			table.insert(parts, "is:pr")
		end
		if not filter:find("repo:", 1, true) then
			table.insert(parts, "repo:" .. ctx.repo)
		end
		table.insert(parts, filter)
		return table.concat(parts, " ")
	end
	local parts = { "is:pr", "repo:" .. ctx.repo }
	local state = filter.state or ctx.state
	if state and state ~= "all" then
		table.insert(parts, "is:" .. state)
	end
	for _, q in ipairs(QUALIFIERS) do
		local value = filter[q[1]]
		if value ~= nil then
			for _, v in ipairs(type(value) == "table" and value or { value }) do
				table.insert(parts, q[2] .. ":" .. quote(v))
			end
		end
	end
	if filter.draft ~= nil then
		table.insert(parts, "draft:" .. tostring(filter.draft))
	end
	table.insert(parts, "sort:updated-desc")
	return table.concat(parts, " ")
end

return M
