local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality
local child = H.new_child()

local fx, state_dir, gh_dir

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

local THREAD = {
	id = "T1",
	path = "app.go",
	line = 2,
	startLine = vim.NIL,
	originalLine = 2,
	diffSide = "RIGHT",
	startDiffSide = vim.NIL,
	isResolved = false,
	isOutdated = false,
	subjectType = "LINE",
	comments = {
		nodes = {
			{
				id = "C1",
				databaseId = 1,
				author = { login = "bob" },
				body = "Why 2?",
				createdAt = "2026-10-01T00:00:00Z",
				url = "u",
				replyTo = vim.NIL,
			},
		},
	},
}

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
					reviewThreads = { pageInfo = { hasNextPage = false }, nodes = { THREAD } },
					reviews = { nodes = {} },
					comments = { nodes = {} },
				},
			},
		},
	}
end

local function set_gh(rules)
	gh_dir = H.fake_gh(rules)
	child.lua("vim.env.FAKE_GH_DIR = ...", { gh_dir })
end

-- 送信（mutation）への応答。data は alias ごとの結果、errors は失敗した alias。
local function rules(mutation)
	return {
		{ match = { "repos/o/r/pulls/7" }, headers = { ETag = '"h1"' }, body = pull(7, fx.head) },
		{
			match = { "graphql", "mutation" },
			body = mutation or {
				data = {
					review = { pullRequestReview = { id = "R1", url = "https://github.com/o/r/pull/7#pullrequestreview-1" } },
					reply1 = { comment = { id = "C9" } },
					resolve1 = { thread = { id = "T1", isResolved = true } },
				},
			},
		},
		{ match = { "graphql", "reviewThreads" }, body = comments_body() },
	}
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
				vim.g.mapleader = " "
				require("agent-review").setup({ pr = { gh = gh, state_dir = state } })
				_G.msgs = {}
				vim.notify = function(m, l) table.insert(_G.msgs, { m, l }) end
			]],
				{ fx.user, fx.gitconfig, H.FAKE_GH, state_dir }
			)
			set_gh(rules())
		end,
		post_once = child.stop,
	},
})

local function open_pr()
	child.cmd("AgentReviewPR 7")
	eq(child.lua([[return vim.wait(20000, function()
		local s = require("agent-review")._session
		return s ~= nil and s:valid() and s.pr.threads ~= nil
	end, 20)]]), true)
	child.lua("vim.wait(50)")
end

local function show(rel)
	child.lua([[require("agent-review")._session:show(...)]], { rel })
	child.lua("vim.wait(50)")
end

local function focus(side, line)
	child.lua(
		[[local side, line = ...
		local s = require("agent-review")._session
		local win = side == "left" and s.left_win or s.right_win
		vim.api.nvim_set_current_win(win)
		vim.api.nvim_win_set_cursor(win, { line, 0 })]],
		{ side, line }
	)
end

---入力窓に本文を書いて :w する。
local function write_compose(lines)
	eq(child.lua_get([[vim.api.nvim_win_get_config(0).relative ~= ""]]), true)
	child.lua([[vim.api.nvim_buf_set_lines(0, 0, -1, false, ...)]], { lines })
	child.cmd("write")
	child.lua("vim.wait(50)")
end

local function draft()
	return child.lua([[return require("agent-review.pr.draft").load(require("agent-review")._session.pr.repo, 7)]])
end

local function marks(side)
	return child.lua(
		[[
		local side = ...
		local s = require("agent-review")._session
		local buf = vim.api.nvim_win_get_buf(side == "left" and s.left_win or s.right_win)
		local out = {}
		for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, require("agent-review.pr.threads").ns, 0, -1, { details = true })) do
			table.insert(out, { line = m[2] + 1, text = table.concat(vim.tbl_map(function(c) return c[1] end, (m[4].virt_lines or {})[1] or {}), "") })
		end
		return out
	]],
		{ side }
	)
end

local function last_msg()
	return child.lua_get("_G.msgs[#_G.msgs]")
end

local function mutation_calls()
	return vim.tbl_filter(function(c)
		return c.args[2] == "graphql" and c.stdin:find("mutation", 1, true) ~= nil
	end, H.gh_calls(gh_dir))
end

T["comment"] = MiniTest.new_set()

T["comment"]["<leader>da drafts a comment on the cursor line of the PR side"] = function()
	open_pr()
	show("new.go")
	focus("right", 2)
	child.type_keys(" da")
	write_compose({ "Please add a doc comment.", "", "Thanks!" })
	local d = draft()
	eq(#d.comments, 1)
	eq({ d.comments[1].path, d.comments[1].line, d.comments[1].side, d.comments[1].body }, {
		"new.go",
		2,
		"RIGHT",
		"Please add a doc comment.\n\nThanks!",
	})
	-- 入力窓は閉じ、行には下書きの印が出る
	eq(child.lua_get([[vim.api.nvim_win_get_config(0).relative]]), "")
	local m = marks("right")
	eq(#m, 1)
	eq(m[1].line, 2)
	eq(m[1].text:find("draft", 1, true) ~= nil and m[1].text:find("Please add", 1, true) ~= nil, true)
end

T["comment"]["a visual selection drafts a multi-line comment"] = function()
	open_pr()
	show("long.go")
	focus("right", 2)
	child.type_keys("Vj", " da")
	write_compose({ "These two lines" })
	local c = draft().comments[1]
	eq({ c.start_line, c.line }, { 2, 3 })
end

T["comment"]["the base window drafts a comment on the removed side"] = function()
	open_pr()
	show("gone.go")
	focus("left", 4)
	child.type_keys(" da")
	write_compose({ "Was this used?" })
	local c = draft().comments[1]
	eq({ c.path, c.line, c.side }, { "gone.go", 4, "LEFT" })
	eq(#marks("left"), 1)
end

T["comment"]["refuses lines GitHub does not show in the diff"] = function()
	open_pr()
	show("long.go")
	focus("right", 14)
	child.type_keys(" da")
	eq(child.lua_get([[vim.api.nvim_win_get_config(0).relative]]), "")
	eq(last_msg()[1]:find("diff", 1, true) ~= nil, true)
	eq(#draft().comments, 0)
end

T["comment"]["q cancels without saving"] = function()
	open_pr()
	show("new.go")
	focus("right", 2)
	child.type_keys(" da")
	child.lua([[vim.api.nvim_buf_set_lines(0, 0, -1, false, { "not sent" })]])
	child.type_keys("<Esc>", "q")
	eq(child.lua_get([[vim.api.nvim_win_get_config(0).relative]]), "")
	eq(#draft().comments, 0)
end

T["comment"]["the same line reopens the draft; saving it empty deletes it"] = function()
	open_pr()
	show("new.go")
	focus("right", 2)
	child.type_keys(" da")
	write_compose({ "first" })
	focus("right", 2)
	child.type_keys(" da")
	eq(child.lua_get([[vim.api.nvim_buf_get_lines(0, 0, -1, false)]]), { "first" })
	write_compose({ "second" })
	eq(#draft().comments, 1)
	eq(draft().comments[1].body, "second")
	focus("right", 2)
	child.type_keys(" da")
	write_compose({ "" })
	eq(#draft().comments, 0)
	eq(#marks("right"), 0)
end

T["comment"]["drafts survive closing and reopening the PR"] = function()
	open_pr()
	show("new.go")
	focus("right", 2)
	child.type_keys(" da")
	write_compose({ "kept" })
	child.lua([[require("agent-review").close()]])
	open_pr()
	show("new.go")
	eq(#marks("right"), 1)
end

T["thread"] = MiniTest.new_set()

T["thread"]["r in the thread window drafts a reply and R toggles resolving"] = function()
	open_pr()
	show("app.go")
	focus("right", 2)
	child.type_keys(" dc")
	child.type_keys("r")
	write_compose({ "Product asked for it." })
	eq(draft().replies, { { thread_id = "T1", body = "Product asked for it." } })
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.right_win)]])
	child.type_keys(" dc")
	local float = child.lua_get([[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")]])
	eq(float:find("Product asked for it.", 1, true) ~= nil, true)
	child.type_keys("R")
	eq(draft().resolve, { T1 = true })
	child.type_keys("q")
	local m = marks("right")
	eq(m[1].text:find("will resolve", 1, true) ~= nil, true)
	eq(m[1].text:find("draft reply", 1, true) ~= nil, true)
end

T["quickfix"] = MiniTest.new_set()

T["quickfix"]["draft comments are listed with the threads"] = function()
	open_pr()
	show("new.go")
	focus("right", 2)
	child.type_keys(" da")
	write_compose({ "draft here" })
	child.cmd("AgentReviewQuickfix comments")
	local texts = child.lua_get([[vim.tbl_map(function(i) return i.text end, vim.fn.getqflist())]])
	eq(#texts, 2)
	eq(texts[1]:find("[draft]", 1, true) ~= nil and texts[1]:find("draft here", 1, true) ~= nil, true)
end

T["submit"] = MiniTest.new_set()

local function draft_everything()
	open_pr()
	show("new.go")
	focus("right", 2)
	child.type_keys(" da")
	write_compose({ "new comment" })
	show("app.go")
	focus("right", 2)
	child.type_keys(" dc", "r")
	write_compose({ "a reply" })
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.right_win)]])
	child.type_keys(" dc", "R", "q")
end

T["submit"][":AgentReviewPRSubmit approve sends everything in one request"] = function()
	draft_everything()
	child.cmd("AgentReviewPRSubmit approve")
	eq(child.lua_get([[vim.api.nvim_win_get_config(0).title[1][1] ]]):find("APPROVE", 1, true) ~= nil, true)
	write_compose({ "LGTM" })
	child.lua("vim.wait(1000, function() return #require('agent-review.pr.draft').load(require('agent-review')._session.pr.repo, 7).comments == 0 end)")
	local calls = mutation_calls()
	eq(#calls, 1)
	local sent = vim.json.decode(calls[1].stdin)
	eq(sent.query:find("addPullRequestReview", 1, true) ~= nil, true)
	eq(sent.query:find("addPullRequestReviewThreadReply", 1, true) ~= nil, true)
	eq(sent.query:find("resolveReviewThread", 1, true) ~= nil, true)
	eq(sent.variables.prId, "PR_node_7")
	eq(sent.variables.commit, fx.head)
	eq(sent.variables.event, "APPROVE")
	eq(sent.variables.body, "LGTM")
	eq(sent.variables.threads, { { path = "new.go", line = 2, side = "RIGHT", body = "new comment" } })
	eq(sent.variables.reply1, { pullRequestReviewThreadId = "T1", body = "a reply" })
	eq(sent.variables.resolve1, "T1")
	-- 送信できたら下書きは空になり、コメントを取り直す
	local d = draft()
	eq({ #d.comments, #d.replies, vim.tbl_count(d.resolve) }, { 0, 0, 0 })
	eq(last_msg()[1]:find("submitted", 1, true) ~= nil, true)
end

T["submit"]["keeps the drafts when GitHub rejects the request"] = function()
	set_gh(rules({ data = vim.NIL, errors = { { message = "Can not approve your own pull request", path = { "review" } } } }))
	draft_everything()
	child.cmd("AgentReviewPRSubmit approve")
	write_compose({ "" })
	child.lua("vim.wait(1000)")
	local d = draft()
	eq({ #d.comments, #d.replies, vim.tbl_count(d.resolve) }, { 1, 1, 1 })
	eq(last_msg()[1]:find("Can not approve your own pull request", 1, true) ~= nil, true)
	eq(last_msg()[2], vim.log.levels.ERROR)
end

T["submit"]["drops only the parts that went through"] = function()
	set_gh(rules({
		data = { review = { pullRequestReview = { id = "R1", url = "u" } }, reply1 = { comment = { id = "C9" } }, resolve1 = vim.NIL },
		errors = { { message = "Resource not accessible", path = { "resolve1" } } },
	}))
	draft_everything()
	child.cmd("AgentReviewPRSubmit comment")
	write_compose({ "see comments" })
	child.lua("vim.wait(1000)")
	local d = draft()
	eq({ #d.comments, #d.replies, d.resolve }, { 0, 0, { T1 = true } })
end

T["submit"]["without a verdict only replies and resolves are sent"] = function()
	open_pr()
	show("app.go")
	focus("right", 2)
	child.type_keys(" dc", "R", "q")
	child.cmd("AgentReviewPRSubmit")
	child.lua("vim.wait(1000)")
	local sent = vim.json.decode(mutation_calls()[1].stdin)
	eq(sent.query:find("addPullRequestReview(", 1, true), nil)
	eq(sent.variables.resolve1, "T1")
end

T["submit"]["nothing to submit says so"] = function()
	open_pr()
	child.cmd("AgentReviewPRSubmit")
	eq(last_msg()[1]:find("nothing to submit", 1, true) ~= nil, true)
	eq(#mutation_calls(), 0)
end

return T
