local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality
local child = H.new_child()

local fx, state_dir, gh_dir

-- GitHubの REST /repos/o/r/pulls/<n> の応答。
local function pull(number, head, opts)
	return vim.tbl_extend("force", {
		number = number,
		title = "Feature " .. number,
		html_url = "https://github.com/o/r/pull/" .. number,
		state = "open",
		merged_at = vim.NIL,
		user = { login = "alice" },
		head = { ref = "feature", sha = head },
		base = { ref = "main", sha = fx.main },
	}, opts or {})
end

local function set_gh(rules)
	gh_dir = H.fake_gh(rules)
	child.lua("vim.env.FAKE_GH_DIR = ...", { gh_dir })
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.setup()
			fx = H.github_fixture(7)
			state_dir = vim.fn.resolve(vim.fn.tempname())
			child.lua(
				[[
				local user, gitconfig, gh, state = ...
				vim.env.GIT_CONFIG_GLOBAL = gitconfig
				vim.cmd.cd(user)
				require("agent-review").setup({ pr = { gh = gh, state_dir = state } })
				_G.msgs = {}
				local notify = vim.notify
				vim.notify = function(m, l) table.insert(_G.msgs, { m, l }); end
			]],
				{ fx.user, fx.gitconfig, H.FAKE_GH, state_dir }
			)
			set_gh({ { match = { "repos/o/r/pulls/7" }, headers = { ETag = '"h1"' }, body = pull(7, fx.head) } })
		end,
		post_once = child.stop,
	},
})

local function wait_session()
	return child.lua([[return vim.wait(20000, function()
		local s = require("agent-review")._session
		return s ~= nil and s:valid()
	end, 20)]])
end

local function state()
	return child.lua([[
		local s = require("agent-review")._session
		local function info(win)
			local buf = vim.api.nvim_win_get_buf(win)
			return { name = vim.api.nvim_buf_get_name(buf), lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false), diff = vim.wo[win].diff, winbar = vim.wo[win].winbar }
		end
		local qf = vim.fn.getqflist({ title = 1, items = 1 })
		return {
			left = info(s.left_win),
			right = info(s.right_win),
			qf_title = qf.title,
			qf = vim.tbl_map(function(i) return i.module ~= "" and i.module or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(i.bufnr), ":t") end, qf.items),
			pr = s.pr and { number = s.pr.meta.number, head = s.pr.head } or vim.NIL,
			tab_is_current = vim.api.nvim_get_current_tabpage() == s.tab,
		}
	]])
end

local function wt(rel)
	return state_dir .. "/github.com/o/r/7" .. (rel and ("/" .. rel) or "")
end

T[":AgentReviewPR <number> opens the PR in the review layout"] = function()
	child.cmd("AgentReviewPR 7")
	eq(wait_session(), true)
	local st = state()
	eq(st.tab_is_current, true)
	eq(st.pr.number, 7)
	eq(st.pr.head, fx.head)
	eq(st.right.name, wt("app.go"))
	eq(st.right.lines, { "package app", "func A() int { return 2 }" })
	eq(st.left.lines, { "package app", "func A() int { return 1 }" })
	eq(st.right.diff, true)
	eq(st.qf_title, "Agent Review: PR #7")
	-- PRの分岐後に main で変わった util.go は含まれない
	eq(st.qf, { "app.go", "gone.go", "long.go", "new.go" })
	eq(st.left.winbar:find("PR #7", 1, true) ~= nil, true)
	-- PRのコードは state ディレクトリにあるので、quickfix にはリポジトリからの相対パスを出す
	eq(child.lua_get([[vim.tbl_map(function(i) return i.module end, vim.fn.getqflist())]]), { "app.go", "gone.go", "long.go", "new.go" })
end

T["the base window follows the working window inside the PR checkout"] = function()
	child.cmd("AgentReviewPR #7")
	wait_session()
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.right_win)]])
	child.cmd("edit " .. wt("util.go"))
	child.lua("vim.wait(50)")
	local st = state()
	eq(st.right.lines, { "package app", "func U() int { return 1 }" })
	eq(st.left.lines, { "package app", "func U() int { return 1 }" })
end

T["the user's repository and working directory are untouched"] = function()
	local refs = vim.trim(H.git(fx.user, { "for-each-ref" }))
	child.cmd("AgentReviewPR 7")
	wait_session()
	eq(vim.trim(H.git(fx.user, { "for-each-ref" })), refs)
	eq(#vim.split(vim.trim(H.git(fx.user, { "worktree", "list" })), "\n"), 1)
	eq(child.lua_get("vim.fn.getcwd()"), fx.user)
end

T["refresh picks up new commits pushed to the PR"] = function()
	child.cmd("AgentReviewPR 7")
	wait_session()
	local new_head = H.push_pr_update(fx, 7, "app.go", { "package app", "func A() int { return 3 }" })
	set_gh({ { match = { "repos/o/r/pulls/7" }, headers = { ETag = '"h2"' }, body = pull(7, new_head) } })
	child.cmd("AgentReviewRefresh")
	eq(child.lua([[local head = ...
		return vim.wait(20000, function()
			return require("agent-review")._session.pr.head == head
		end, 20)]], { new_head }), true)
	child.lua("vim.wait(100)")
	eq(state().right.lines, { "package app", "func A() int { return 3 }" })
end

T["refresh asks GitHub with the cached ETag"] = function()
	child.cmd("AgentReviewPR 7")
	wait_session()
	child.cmd("AgentReviewRefresh")
	child.lua("vim.wait(500)")
	-- コメントの取得（GraphQL）は数えず、PRの情報を取るRESTだけを見る
	local calls = vim.tbl_filter(function(c)
		return c.args[2] == "-i"
	end, H.gh_calls(gh_dir))
	eq(#calls, 2)
	eq(calls[2].if_none_match, '"h1"')
end

T["reports a PR that does not exist"] = function()
	set_gh({ { match = { "repos/o/r/pulls/9" }, status = 404, body = { message = "Not Found" } } })
	child.cmd("AgentReviewPR 9")
	child.lua("vim.wait(1000)")
	eq(child.lua_get([[require("agent-review")._session]]), vim.NIL)
	local last = child.lua_get("_G.msgs[#_G.msgs]")
	eq(last[1]:find("#9", 1, true) ~= nil and last[1]:find("Not Found", 1, true) ~= nil, true)
	eq(last[2], vim.log.levels.ERROR)
end

T[":AgentReviewPRClean removes PR checkouts that are not open"] = function()
	child.cmd("AgentReviewPR 7")
	wait_session()
	child.cmd("AgentReviewPRClean")
	child.lua("vim.wait(500)")
	eq(vim.fn.isdirectory(wt()), 1)
	child.lua([[require("agent-review").close()]])
	child.cmd("AgentReviewPRClean")
	eq(child.lua([[local dir = ...
		return vim.wait(10000, function() return vim.fn.isdirectory(dir) == 0 end, 20)]], { wt() }), true)
end

T["closing the PR review returns to the user's tab"] = function()
	child.cmd("AgentReviewPR 7")
	wait_session()
	child.lua([[require("agent-review").close()]])
	eq(child.lua_get("#vim.api.nvim_list_tabpages()"), 1)
	eq(child.lua_get([[require("agent-review")._session]]), vim.NIL)
end

return T
