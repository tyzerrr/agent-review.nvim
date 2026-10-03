local paths = require("agent-review.pr.paths")

-- PRのレビューコメントを Claude Code に渡して直してもらう。
-- スレッドの内容は markdown に書き出し、コメントされたコードの行と一緒に @mention で送る。
local M = {}

local function notify(msg, level)
	vim.notify("[agent-review] " .. msg, level or vim.log.levels.INFO)
end

---ユーザーの手元でPRのブランチをcheckoutしている worktree（orca のワークスペース等）。
---Claude が直したものがそのまま本来のブランチに入るよう、あればそちらのファイルを指す。
---@return string|nil
function M.local_checkout(repo, branch)
	if not branch then
		return nil
	end
	local res = vim.system({ "git", "worktree", "list", "--porcelain" }, { cwd = repo.root, text = true }):wait()
	if res.code ~= 0 then
		return nil
	end
	local current
	for line in (res.stdout or ""):gmatch("[^\n]+") do
		local wt = line:match("^worktree (.+)$")
		if wt then
			current = wt
		elseif line == "branch refs/heads/" .. branch then
			return current
		end
	end
	return nil
end

local function ago(iso)
	return require("agent-review.pr.picker").ago(iso)
end

---@param s AgentReviewSession
---@param t AgentReviewThread
function M.send_thread(s, t)
	local ok = pcall(require, "claudecode")
	if not ok then
		return notify("claudecode.nvim is not available", vim.log.levels.WARN)
	end
	local pr, meta = s.pr, s.pr.meta
	local local_dir = M.local_checkout(pr.repo, meta.head_ref)
	local line = t.line or t.original_line
	local first = t.start_line or line
	local where = first and first ~= line and ("%s:%d-%d"):format(t.path, first, line) or ("%s:%d"):format(t.path, line or 0)

	local lines = {
		("# Review comment on PR #%d: %s"):format(meta.number, meta.title or ""),
		"",
		("- File: `%s` (%s)"):format(where, t.side == "LEFT" and "on lines the PR removed" or "on the PR's version of the file"),
	}
	if local_dir then
		table.insert(lines, ("- The PR branch `%s` is checked out at `%s`. Make the change there."):format(meta.head_ref, local_dir))
	else
		table.insert(
			lines,
			("- The PR branch `%s` is not checked out locally. `%s` is agent-review's read-only copy of the PR; check out `%s` to change it."):format(
				meta.head_ref or "?",
				s.root,
				meta.head_ref or "?"
			)
		)
	end
	if t.resolved then
		table.insert(lines, "- This thread is already resolved on GitHub.")
	end
	vim.list_extend(lines, { "", "## Thread", "" })
	for _, c in ipairs(t.comments) do
		vim.list_extend(lines, { ("**@%s** (%s):"):format(c.author, ago(c.created_at)), "" })
		vim.list_extend(lines, vim.split(c.body, "\r?\n"))
		table.insert(lines, "")
	end
	table.insert(lines, "Please address this review comment.")

	local file = ("%s/threads/pr-%d-%s.md"):format(paths.for_key(pr.repo.key).repo, meta.number, (t.id or "thread"):gsub("[^%w_-]", "_"))
	vim.fn.mkdir(vim.fs.dirname(file), "p")
	vim.fn.writefile(lines, file)

	local code = (local_dir or s.root) .. "/" .. t.path
	local mentions = { { path = file } }
	-- 削除された行への指摘は今のファイルの行番号と対応しないので、ファイルだけを渡す。
	if t.side == "LEFT" or not line then
		table.insert(mentions, { path = code })
	else
		table.insert(mentions, { path = code, l1 = first, l2 = line })
	end
	require("agent-review.claude").send_mentions(mentions)
end

return M
