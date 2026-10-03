local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local fx, repo, state_dir, saved_gitconfig

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			saved_gitconfig = vim.env.GIT_CONFIG_GLOBAL
			fx = H.github_fixture(7)
			vim.env.GIT_CONFIG_GLOBAL = fx.gitconfig
			state_dir = vim.fn.tempname()
			require("agent-review.config").setup({ pr = { gh = H.FAKE_GH, state_dir = state_dir } })
			repo = { root = fx.user, url = fx.url, host = "github.com", owner = "o", name = "r", nwo = "o/r", key = "github.com/o/r" }
		end,
		post_case = function()
			vim.env.GIT_CONFIG_GLOBAL = saved_gitconfig
		end,
	},
})

local function mirror()
	return require("agent-review.pr.mirror")
end

local function prepare(meta)
	local done, err, wt = false, nil, nil
	mirror().prepare(repo, vim.tbl_extend("force", { number = 7, base_ref = "main", state = "OPEN" }, meta or {}), function(e, w)
		done, err, wt = true, e, w
	end)
	eq(done, false)
	eq(vim.wait(20000, function()
		return done
	end, 20), true)
	return err, wt
end

local function lines(path)
	return vim.fn.readfile(path)
end

local function git(dir, args)
	return vim.trim(H.git(dir, args))
end

T["prepare() checks the PR out under the state directory at its head"] = function()
	local err, wt = prepare()
	eq(err, nil)
	eq(wt.root, state_dir .. "/github.com/o/r/7")
	eq(wt.head, fx.head)
	eq(git(wt.root, { "rev-parse", "HEAD" }), fx.head)
	eq(lines(wt.root .. "/app.go"), { "package app", "func A() int { return 2 }" })
	eq(vim.fn.filereadable(wt.root .. "/gone.go"), 0)
	eq(vim.fn.isdirectory(state_dir .. "/github.com/o/r/repo.git"), 1)
end

T["prepare() uses the merge-base with the target branch, like GitHub"] = function()
	local _, wt = prepare()
	-- main はPRの分岐後に進んでいるが、比較元は分岐点になる
	eq(wt.base, fx.fork_point)
end

T["prepare() leaves the user's repository untouched"] = function()
	local refs_before = git(fx.user, { "for-each-ref" })
	prepare()
	eq(git(fx.user, { "for-each-ref" }), refs_before)
	eq(#vim.split(git(fx.user, { "worktree", "list" }), "\n"), 1)
	eq(git(fx.user, { "status", "--porcelain" }), "")
end

T["prepare() reuses the checkout and moves it to a new push"] = function()
	local _, first = prepare()
	local new_head = H.push_pr_update(fx, 7, "app.go", { "package app", "func A() int { return 3 }" })
	local err, second = prepare()
	eq(err, nil)
	eq(second.root, first.root)
	eq(second.head, new_head)
	eq(lines(second.root .. "/app.go"), { "package app", "func A() int { return 3 }" })
end

T["prepare() skips fetching when the PR head is already checked out"] = function()
	local _, first = prepare({ head_sha = fx.head })
	-- GitHubに届かなくても、同じ先頭なら手元のものだけで開ける
	vim.fn.delete(fx.origin, "rf")
	local err, second = prepare({ head_sha = fx.head })
	eq(err, nil)
	eq(second.head, fx.head)
	eq(second.base, first.base)
end

T["prepare() still fetches when GitHub reports a new head"] = function()
	prepare({ head_sha = fx.head })
	local new_head = H.push_pr_update(fx, 7, "app.go", { "package app", "func A() int { return 3 }" })
	local err, wt = prepare({ head_sha = new_head })
	eq(err, nil)
	eq(wt.head, new_head)
end

T["prepare() uses the recorded base commit for merged PRs"] = function()
	-- main にマージコミットで取り込むと、main との merge-base はPRの先頭そのものになり差分が消える
	H.git(fx.work, { "fetch", "-q", "origin", "refs/pull/7/head" })
	H.git(fx.work, { "merge", "-q", "--no-ff", "-m", "merge #7", "FETCH_HEAD" })
	H.git(fx.work, { "push", "-q", "origin", "main" })
	local err, wt = prepare({ state = "MERGED", base_sha = fx.main })
	eq(err, nil)
	eq(wt.base, fx.fork_point)
end

T["prepare() reports a PR that cannot be fetched"] = function()
	local done, err = false, nil
	mirror().prepare(repo, { number = 404, base_ref = "main", state = "OPEN" }, function(e)
		done, err = true, e
	end)
	vim.wait(20000, function()
		return done
	end, 20)
	eq(err ~= nil, true)
	eq(err:match("#404") ~= nil, true)
end

T["remove() deletes the checkout"] = function()
	local _, wt = prepare()
	local done = false
	mirror().remove(repo, 7, function()
		done = true
	end)
	vim.wait(10000, function()
		return done
	end, 20)
	eq(vim.fn.isdirectory(wt.root), 0)
	eq(git(state_dir .. "/github.com/o/r/repo.git", { "worktree", "list" }):find("github.com/o/r/7", 1, true), nil)
end

T["checkouts() lists the PRs checked out for the repository"] = function()
	prepare()
	eq(mirror().checkouts(repo), { 7 })
end

return T
