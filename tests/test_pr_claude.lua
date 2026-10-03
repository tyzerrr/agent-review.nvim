local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality
local child = H.new_child()

local fx, state_dir

local function pull(number, head)
	return {
		number = number,
		title = "Feature " .. number,
		html_url = "https://github.com/o/r/pull/" .. number,
		state = "open",
		merged_at = vim.NIL,
		user = { login = "alice" },
		head = { ref = "feature", sha = head },
		base = { ref = "main", sha = fx.main },
	}
end

local function comments_body()
	return {
		data = {
			repository = {
				pullRequest = {
					id = "PR_node_7",
					title = "Feature 7",
					body = "desc",
					createdAt = "2026-09-30T00:00:00Z",
					updatedAt = "2026-10-01T00:00:00Z",
					author = { login = "alice" },
					reviewThreads = {
						pageInfo = { hasNextPage = false },
						nodes = {
							{
								id = "T1",
								path = "app.go",
								line = 2,
								startLine = vim.NIL,
								originalLine = 2,
								diffSide = "RIGHT",
								isResolved = false,
								isOutdated = false,
								subjectType = "LINE",
								comments = {
									nodes = {
										{ id = "C1", databaseId = 1, author = { login = "bob" }, body = "Return a named constant instead of 2.", createdAt = "2026-10-01T00:00:00Z", url = "https://github.com/o/r/pull/7#discussion_r1" },
										{ id = "C2", databaseId = 2, author = { login = "alice" }, body = "Will do.", createdAt = "2026-10-01T01:00:00Z", url = "u2" },
									},
								},
							},
						},
					},
					reviews = { nodes = {} },
					comments = { nodes = {} },
				},
			},
		},
	}
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.setup()
			fx = H.github_fixture(7)
			state_dir = vim.fn.resolve(vim.fn.tempname())
			local gh_dir = H.fake_gh({
				{ match = { "repos/o/r/pulls/7" }, body = pull(7, fx.head) },
				{ match = { "graphql", "reviewThreads" }, body = comments_body() },
			})
			child.lua(
				[[
				local user, gitconfig, gh, state, gh_dir = ...
				vim.env.GIT_CONFIG_GLOBAL = gitconfig
				vim.env.FAKE_GH_DIR = gh_dir
				vim.cmd.cd(user)
				vim.g.mapleader = " "
				require("agent-review").setup({ pr = { gh = gh, state_dir = state } })
				_G.msgs = {}
				vim.notify = function(m, l) table.insert(_G.msgs, { m, l }) end
				-- claudecode.nvim は外部依存なので、送られた内容を記録するだけのモックにする。
				_G.sent = {}
				package.loaded.claudecode = {
					send_at_mention = function(path, s, e, ctx)
						table.insert(_G.sent, { path = path, s = s or vim.NIL, e = e or vim.NIL })
						return true
					end,
				}
			]],
				{ fx.user, fx.gitconfig, H.FAKE_GH, state_dir, gh_dir }
			)
		end,
		post_once = child.stop,
	},
})

local function open_thread_window()
	child.cmd("AgentReviewPR 7")
	eq(child.lua([[return vim.wait(20000, function()
		local s = require("agent-review")._session
		return s ~= nil and s:valid() and s.pr.threads ~= nil
	end, 20)]]), true)
	child.lua([[local s = require("agent-review")._session
		s:show("app.go")
		vim.api.nvim_set_current_win(s.right_win)
		vim.api.nvim_win_set_cursor(s.right_win, { 2, 0 })]])
	child.type_keys(" dc")
end

local function sent()
	return child.lua_get("_G.sent")
end

T["c in the thread window sends the thread and the code to Claude"] = function()
	open_thread_window()
	child.type_keys("c")
	local s = sent()
	eq(#s, 2)
	-- 1つ目はスレッドの内容を書いたmarkdown
	eq(s[1].path:match("%.md$") ~= nil, true)
	local text = table.concat(vim.fn.readfile(s[1].path), "\n")
	for _, part in ipairs({ "PR #7", "app.go:2", "@bob", "Return a named constant instead of 2.", "@alice", "Will do." }) do
		eq({ part, text:find(part, 1, true) ~= nil }, { part, true })
	end
	-- 2つ目はコメントされたコードの行（claudecode は0始まり）
	eq({ s[2].s, s[2].e }, { 1, 1 })
	eq(s[2].path, state_dir .. "/github.com/o/r/7/app.go")
	-- 浮動窓は閉じる
	eq(child.lua_get([[vim.api.nvim_win_get_config(0).relative]]), "")
end

T["prefers a local worktree that has the PR branch checked out"] = function()
	local wt = vim.fn.resolve(vim.fn.tempname())
	H.git(fx.user, { "worktree", "add", "-q", "-b", "feature", wt })
	open_thread_window()
	child.type_keys("c")
	local s = sent()
	eq(s[2].path, wt .. "/app.go")
	local text = table.concat(vim.fn.readfile(s[1].path), "\n")
	eq(text:find(wt, 1, true) ~= nil, true)
end

T["without the PR branch locally, the note says where the code is"] = function()
	open_thread_window()
	child.type_keys("c")
	local text = table.concat(vim.fn.readfile(sent()[1].path), "\n")
	eq(text:find("feature", 1, true) ~= nil, true)
	eq(text:find("read-only", 1, true) ~= nil, true)
end

T["warns when claudecode.nvim is not installed"] = function()
	child.lua("package.loaded.claudecode = nil; package.preload.claudecode = function() error('not installed') end")
	open_thread_window()
	child.type_keys("c")
	eq(child.lua_get("_G.msgs[#_G.msgs][1]"):find("claudecode", 1, true) ~= nil, true)
end

return T
