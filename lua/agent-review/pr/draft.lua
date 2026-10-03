local paths = require("agent-review.pr.paths")

-- PRごとの下書き（まだGitHubに送っていないコメント・返信・解決）。送信は :AgentReviewPRSubmit でまとめて行う。
-- キャッシュと違って消えると困るので、cache とは別の場所に置く。
local M = {}

---@class AgentReviewDraftComment
---@field id string
---@field path string
---@field line integer
---@field start_line? integer
---@field side "LEFT"|"RIGHT"
---@field body string

---@class AgentReviewDraft
---@field comments AgentReviewDraftComment[]
---@field replies { thread_id: string, body: string }[]
---@field resolve table<string, boolean> スレッドID -> true（解決する）/ false（解決を取り消す）
---@field summary string レビュー本文

local function file(repo, number)
	return ("%s/drafts/%d.json"):format(paths.for_key(repo.key).repo, number)
end

---@return AgentReviewDraft
function M.load(repo, number)
	local path = file(repo, number)
	local data
	if vim.fn.filereadable(path) == 1 then
		local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
		data = ok and type(decoded) == "table" and decoded or nil
	end
	data = data or {}
	return {
		comments = data.comments or {},
		replies = data.replies or {},
		resolve = data.resolve or {},
		summary = data.summary or "",
	}
end

---@param d AgentReviewDraft
function M.save(repo, number, d)
	local path = file(repo, number)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	local tmp = ("%s.tmp.%d.%d"):format(path, vim.fn.getpid(), vim.uv.hrtime())
	vim.fn.writefile({
		vim.json.encode({
			comments = d.comments,
			replies = d.replies,
			-- 空のテーブルは配列 "[]" になるので、解決の対応表はオブジェクトとして書く。
			resolve = next(d.resolve) and d.resolve or vim.empty_dict(),
			summary = d.summary,
		}),
	}, tmp)
	vim.uv.fs_rename(tmp, path)
end

---@param d AgentReviewDraft
function M.is_empty(d)
	return #d.comments == 0 and #d.replies == 0 and next(d.resolve) == nil
end

---@param d AgentReviewDraft
function M.describe(d)
	local parts = {}
	local function add(n, word)
		if n > 0 then
			table.insert(parts, ("%d %s%s"):format(n, word, n == 1 and "" or "s"))
		end
	end
	add(#d.comments, "comment")
	add(#d.replies, "reply")
	add(vim.tbl_count(d.resolve), "resolve")
	return #parts > 0 and table.concat(parts, ", ") or "no drafts"
end

local counter = 0
function M.new_id()
	counter = counter + 1
	return ("draft-%d-%d"):format(os.time(), counter)
end

return M
