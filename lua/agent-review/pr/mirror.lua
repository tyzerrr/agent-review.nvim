local paths = require("agent-review.pr.paths")

-- PRのコードを置く場所の管理。リポジトリごとに専用の複製（bare）を state ディレクトリに作り、
-- PRごとにそこから worktree を出す。ユーザーのリポジトリ（.git・worktree一覧・ref）には何も書かない。
local M = {}

local function git(args, cwd, cb)
	vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, text = true }, function(res)
		vim.schedule(function()
			cb(res.code == 0, vim.trim(res.stdout or ""), vim.trim(res.stderr or ""))
		end)
	end)
end

---コルーチンの中で git を順に呼ぶための小さな仕組み。コールバックの入れ子を避ける。
local function run(body, cb)
	local co
	local function await_git(args, cwd)
		git(args, cwd, function(...)
			local ok, err = coroutine.resume(co, ...)
			if not ok then
				cb(tostring(err))
			end
		end)
		return coroutine.yield()
	end
	co = coroutine.create(function()
		local err, value = body(await_git)
		cb(err, value)
	end)
	local ok, err = coroutine.resume(co)
	if not ok then
		cb(tostring(err))
	end
end

---@class AgentReviewPrMeta
---@field number integer
---@field base_ref string マージ先のブランチ名
---@field base_sha? string GitHubが記録しているマージ先のコミット（マージ済み・クローズ済みのPRで使う）
---@field state string OPEN|CLOSED|MERGED

---@class AgentReviewPrCheckout
---@field root string worktreeのディレクトリ
---@field head string PRの先頭のコミット
---@field base string 比較元（GitHubの "Files changed" と同じ merge-base）

---PRを取ってきて worktree をその先頭に合わせる。2回目以降は同じディレクトリを使い回す。
---@param repo AgentReviewRepo
---@param meta AgentReviewPrMeta
---@param cb fun(err: string|nil, checkout: AgentReviewPrCheckout|nil)
function M.prepare(repo, meta, cb)
	local dirs = paths.for_key(repo.key)
	local n = meta.number
	run(function(await)
		if vim.fn.isdirectory(dirs.mirror) == 0 then
			vim.fn.mkdir(dirs.repo, "p")
			-- 手元のリポジトリからのcloneはネットワークを使わず、オブジェクトはハードリンクになる。
			-- ハードリンクは独立した参照なので、元のリポジトリのgcで消えることもない。
			local ok, _, e = await({ "clone", "--bare", "--quiet", repo.root, dirs.mirror }, dirs.repo)
			if not ok then
				vim.fn.delete(dirs.mirror, "rf")
				return "could not create the mirror: " .. e
			end
			await({ "remote", "set-url", "origin", repo.url }, dirs.mirror)
		end

		local pr_ref = ("refs/agent-review/pr/%d"):format(n)
		local base_ref = ("refs/agent-review/base/%d"):format(n)
		-- PRの先頭が前回取ってきたものと同じなら、通信（fetch）を省く。開き直しが速くなる。
		local have_ok, have = await({ "rev-parse", "--verify", "--quiet", pr_ref }, dirs.mirror)
		local ok, e
		if not (meta.head_sha and have_ok and have == meta.head_sha) then
			ok, _, e = await({
				"fetch",
				"--quiet",
				"--no-tags",
				"origin",
				("+refs/pull/%d/head:%s"):format(n, pr_ref),
				("+refs/heads/%s:%s"):format(meta.base_ref, base_ref),
			}, dirs.mirror)
			if not ok then
				return ("could not fetch PR #%d: %s"):format(n, e)
			end
		end
		local _, head = await({ "rev-parse", pr_ref }, dirs.mirror)

		-- マージ済みのPRはマージ先がPRを含むので、今のマージ先とのmerge-baseでは差分が消える。
		-- GitHubが記録しているその時のマージ先のコミットを使う。
		local target = base_ref
		if meta.state ~= "OPEN" and meta.base_sha then
			local has = await({ "cat-file", "-e", meta.base_sha .. "^{commit}" }, dirs.mirror)
			if has then
				target = meta.base_sha
			end
		end
		local mb_ok, base, mb_err = await({ "merge-base", head, target }, dirs.mirror)
		if not mb_ok then
			return ("could not find the base of PR #%d: %s"):format(n, mb_err)
		end

		local dir = dirs.pr(n)
		if vim.uv.fs_stat(dir .. "/.git") then
			-- このworktreeはagent-review専用なので、手元の変更があっても上書きしてPRの先頭に合わせる。
			ok, _, e = await({ "checkout", "--quiet", "--force", "--detach", head }, dir)
		else
			vim.fn.delete(dir, "rf")
			await({ "worktree", "prune" }, dirs.mirror)
			ok, _, e = await({ "worktree", "add", "--quiet", "--force", "--detach", dir, head }, dirs.mirror)
		end
		if not ok then
			return ("could not check out PR #%d: %s"):format(n, e)
		end
		return nil, { root = dir, head = head, base = base }
	end, cb)
end

---PRのworktreeを消す。
---@param cb fun(err: string|nil)
function M.remove(repo, number, cb)
	local dirs = paths.for_key(repo.key)
	local dir = dirs.pr(number)
	run(function(await)
		local ok = vim.fn.isdirectory(dirs.mirror) == 1
			and await({ "worktree", "remove", "--force", dir }, dirs.mirror)
		if not ok then
			vim.fn.delete(dir, "rf")
			if vim.fn.isdirectory(dirs.mirror) == 1 then
				await({ "worktree", "prune" }, dirs.mirror)
			end
		end
		return nil
	end, cb)
end

---このリポジトリで取ってきてあるPRの番号。
---@return integer[]
function M.checkouts(repo)
	local dirs = paths.for_key(repo.key)
	local numbers = {}
	if vim.fn.isdirectory(dirs.repo) == 0 then
		return numbers
	end
	for _, name in ipairs(vim.fn.readdir(dirs.repo)) do
		if name:match("^%d+$") and vim.uv.fs_stat(dirs.repo .. "/" .. name .. "/.git") then
			table.insert(numbers, tonumber(name))
		end
	end
	table.sort(numbers)
	return numbers
end

return M
