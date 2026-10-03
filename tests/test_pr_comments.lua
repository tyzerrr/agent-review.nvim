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

local function comment(id, login, body, opts)
	return vim.tbl_extend("force", {
		id = "C" .. id,
		databaseId = id,
		author = { login = login, avatarUrl = "https://avatars/" .. login },
		body = body,
		createdAt = "2026-10-01T00:00:00Z",
		url = "https://github.com/o/r/pull/7#discussion_r" .. id,
		replyTo = vim.NIL,
	}, opts or {})
end

local function thread(id, path, line, side, comments, opts)
	return vim.tbl_extend("force", {
		id = id,
		path = path,
		line = line,
		startLine = vim.NIL,
		originalLine = line,
		diffSide = side,
		startDiffSide = vim.NIL,
		isResolved = false,
		isOutdated = false,
		subjectType = "LINE",
		comments = { nodes = comments },
	}, opts or {})
end

local THREADS = {
	thread("T1", "app.go", 2, "RIGHT", {
		comment(1, "bob", "Why 2?\nIt used to be 1."),
		comment(2, "alice", "Product asked for it.", { replyTo = { id = "C1" } }),
	}),
	thread("T2", "gone.go", 4, "LEFT", { comment(3, "carol", "Is Old() still used anywhere?") }),
	thread("T3", "new.go", 2, "RIGHT", { comment(4, "bob", "nit: doc comment") }, { isResolved = true }),
	thread("T4", "app.go", vim.NIL, "RIGHT", { comment(5, "dave", "This was on an older commit") }, { isOutdated = true, originalLine = 9 }),
}

local function graphql_body(threads, page)
	return {
		data = {
			repository = {
				pullRequest = {
					title = "Feature 7",
					body = "This PR changes A.\n\nPlease review.",
					createdAt = "2026-09-30T00:00:00Z",
					updatedAt = "2026-10-01T00:00:00Z",
					author = { login = "alice" },
					reviewThreads = { pageInfo = page or { hasNextPage = false, endCursor = vim.NIL }, nodes = threads },
					reviews = {
						nodes = {
							{ author = { login = "bob" }, state = "CHANGES_REQUESTED", body = "A few things.", submittedAt = "2026-10-01T01:00:00Z" },
							{ author = { login = "carol" }, state = "COMMENTED", body = "", submittedAt = "2026-10-01T02:00:00Z" },
						},
					},
					comments = { nodes = { { author = { login = "erin" }, body = "Looks exciting!", createdAt = "2026-10-01T03:00:00Z" } } },
				},
			},
		},
	}
end

local function set_gh(rules)
	gh_dir = H.fake_gh(rules)
	child.lua("vim.env.FAKE_GH_DIR = ...", { gh_dir })
end

local function default_rules(threads)
	return {
		{ match = { "repos/o/r/pulls/7" }, headers = { ETag = '"h1"' }, body = pull(7, fx.head) },
		{ match = { "graphql", "reviewThreads" }, body = graphql_body(threads or THREADS) },
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
			set_gh(default_rules())
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

local function wt(rel)
	return state_dir .. "/github.com/o/r/7/" .. rel
end

---窓のバッファにある agent-review のコメントのextmark（行は1始まり）。
local function marks(side)
	return child.lua(
		[[
		local side = ...
		local s = require("agent-review")._session
		local win = side == "left" and s.left_win or s.right_win
		local buf = vim.api.nvim_win_get_buf(win)
		local ns = vim.api.nvim_get_namespaces()["agent-review-comments"]
		local out = {}
		for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns or -1, 0, -1, { details = true })) do
			local text = table.concat(vim.tbl_map(function(c) return c[1] end, m[4].virt_text or {}), "")
			table.insert(out, { line = m[2] + 1, sign = vim.trim(m[4].sign_text or ""), text = text })
		end
		return out
	]],
		{ side }
	)
end

local function show(rel)
	child.lua([[require("agent-review")._session:show(...)]], { rel })
	child.lua("vim.wait(50)")
end

T["fetch"] = MiniTest.new_set()

T["fetch"]["one GraphQL request returns threads and the conversation"] = function()
	open_pr()
	local pr = child.lua([[
		local pr = require("agent-review")._session.pr
		local t = pr.threads[1]
		return {
			n = #pr.threads,
			first = { t.path, t.line, t.side, t.resolved, t.outdated, #t.comments, t.comments[1].author, t.comments[2].body },
			outdated = { pr.threads[4].line == nil, pr.threads[4].original_line, pr.threads[4].outdated },
			description = pr.conversation.body,
			timeline = vim.tbl_map(function(i) return i.kind .. ":" .. i.author end, pr.conversation.timeline),
		}
	]])
	eq(pr.n, 4)
	eq(pr.first, { "app.go", 2, "RIGHT", false, false, 2, "bob", "Product asked for it." })
	eq(pr.outdated, { true, 9, true })
	eq(pr.description, "This PR changes A.\n\nPlease review.")
	eq(pr.timeline, { "review:bob", "review:carol", "comment:erin" })
	local graphql = vim.tbl_filter(function(c)
		return c.args[2] == "graphql"
	end, H.gh_calls(gh_dir))
	eq(#graphql, 1)
end

T["fetch"]["follows pagination of review threads"] = function()
	set_gh({
		{ match = { "repos/o/r/pulls/7" }, body = pull(7, fx.head) },
		{ match = { "graphql", '"cursor":"c1"' }, body = graphql_body({ THREADS[3], THREADS[4] }) },
		{ match = { "graphql" }, body = graphql_body({ THREADS[1], THREADS[2] }, { hasNextPage = true, endCursor = "c1" }) },
	})
	open_pr()
	eq(child.lua_get([[#require("agent-review")._session.pr.threads]]), 4)
end

T["inline"] = MiniTest.new_set()

T["inline"]["shows a sign and a summary on the commented line of the PR side"] = function()
	open_pr()
	show("app.go")
	local m = marks("right")
	eq(#m, 1)
	eq(m[1].line, 2)
	eq(m[1].text:find("bob", 1, true) ~= nil, true)
	eq(m[1].text:find("Why 2?", 1, true) ~= nil, true)
	eq(m[1].text:find("+1", 1, true) ~= nil, true)
	-- 古いコミットへのスレッド（outdated）は行に出さない
	eq(#marks("left"), 0)
end

T["inline"]["shows LEFT side threads on the base window"] = function()
	open_pr()
	show("gone.go")
	local m = marks("left")
	eq(#m, 1)
	eq(m[1].line, 4)
	eq(m[1].text:find("carol", 1, true) ~= nil, true)
end

T["inline"]["marks resolved threads differently"] = function()
	open_pr()
	show("new.go")
	local m = marks("right")
	eq(#m, 1)
	eq(m[1].text:find("resolved", 1, true) ~= nil, true)
end

T["thread"] = MiniTest.new_set()

T["thread"]["<leader>dc opens the whole thread under the cursor"] = function()
	open_pr()
	show("app.go")
	child.lua([[local s = require("agent-review")._session
		vim.api.nvim_set_current_win(s.right_win)
		vim.api.nvim_win_set_cursor(s.right_win, { 2, 0 })]])
	child.type_keys(" dc")
	local float = child.lua([[
		local win = vim.api.nvim_get_current_win()
		return {
			floating = vim.api.nvim_win_get_config(win).relative ~= "",
			ft = vim.bo.filetype,
			text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"),
		}
	]])
	eq(float.floating, true)
	eq(float.ft, "markdown")
	for _, part in ipairs({ "@bob", "Why 2?", "It used to be 1.", "@alice", "Product asked for it." }) do
		eq({ part, float.text:find(part, 1, true) ~= nil }, { part, true })
	end
	child.type_keys("q")
	eq(child.lua_get([[vim.api.nvim_win_get_config(0).relative]]), "")
end

T["thread"]["<leader>dc on a line without comments says so"] = function()
	open_pr()
	show("app.go")
	child.lua([[local s = require("agent-review")._session
		vim.api.nvim_set_current_win(s.right_win)
		vim.api.nvim_win_set_cursor(s.right_win, { 1, 0 })]])
	child.type_keys(" dc")
	eq(child.lua_get([[vim.api.nvim_win_get_config(0).relative]]), "")
	eq(child.lua_get("_G.msgs[#_G.msgs][1]"):find("no comments", 1, true) ~= nil, true)
end

T["quickfix"] = MiniTest.new_set()

T["quickfix"][":AgentReviewQuickfix comments lists threads, unresolved first"] = function()
	open_pr()
	child.cmd("AgentReviewQuickfix comments")
	local qf = child.lua([[
		local info = vim.fn.getqflist({ title = 1, items = 1 })
		return { title = info.title, texts = vim.tbl_map(function(i) return i.text end, info.items), lnums = vim.tbl_map(function(i) return i.lnum end, info.items) }
	]])
	eq(qf.title, "Agent Review: PR #7 (comments)")
	eq(#qf.texts, 4)
	eq(qf.texts[1]:find("bob", 1, true) ~= nil and qf.texts[1]:find("Why 2?", 1, true) ~= nil, true)
	eq(qf.texts[2]:find("carol", 1, true) ~= nil, true)
	eq(qf.texts[3]:find("outdated", 1, true) ~= nil, true)
	eq(qf.texts[4]:find("resolved", 1, true) ~= nil, true)
	eq(qf.lnums, { 2, 4, 9, 2 })
end

T["quickfix"]["<CR> on a base-side thread shows the file with the base at that line"] = function()
	open_pr()
	child.cmd("AgentReviewQuickfix comments")
	child.lua([[vim.api.nvim_set_current_win(vim.fn.getqflist({ winid = 0 }).winid)
		vim.api.nvim_win_set_cursor(0, { 2, 0 })]])
	child.type_keys("<CR>")
	child.lua("vim.wait(100)")
	local st = child.lua([[
		local s = require("agent-review")._session
		return {
			right = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(s.right_win)),
			left_side = vim.b[vim.api.nvim_win_get_buf(s.left_win)].agent_review_side,
			left_cursor = vim.api.nvim_win_get_cursor(s.left_win)[1],
		}
	]])
	eq(st.right, "agent-review://deleted/gone.go")
	eq(st.left_side, "base")
	eq(st.left_cursor, 4)
end

T["conversation"] = MiniTest.new_set()

T["conversation"][":AgentReviewPRConversation shows the description and the timeline"] = function()
	open_pr()
	child.cmd("AgentReviewPRConversation")
	local buf = child.lua([[return {
		ft = vim.bo.filetype,
		text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"),
		modifiable = vim.bo.modifiable,
	}]])
	eq(buf.ft, "markdown")
	eq(buf.modifiable, false)
	for _, part in ipairs({ "Feature 7", "This PR changes A.", "@bob", "requested changes", "A few things.", "@carol", "@erin", "Looks exciting!" }) do
		eq({ part, buf.text:find(part, 1, true) ~= nil }, { part, true })
	end
end

T["refresh"] = MiniTest.new_set()

T["refresh"]["does not ask for comments again when the PR did not change"] = function()
	open_pr()
	child.cmd("AgentReviewRefresh")
	child.lua("vim.wait(800)")
	local graphql = vim.tbl_filter(function(c)
		return c.args[2] == "graphql"
	end, H.gh_calls(gh_dir))
	eq(#graphql, 1)
end

T["refresh"]["picks up new comments when the PR changed"] = function()
	open_pr()
	local more = vim.deepcopy(THREADS)
	table.insert(more, thread("T5", "new.go", 1, "RIGHT", { comment(6, "frank", "New one") }))
	set_gh({
		{ match = { "repos/o/r/pulls/7" }, headers = { ETag = '"h2"' }, body = pull(7, fx.head) },
		{ match = { "graphql", "reviewThreads" }, body = graphql_body(more) },
	})
	child.cmd("AgentReviewRefresh")
	eq(child.lua([[return vim.wait(10000, function() return #require("agent-review")._session.pr.threads == 5 end, 20)]]), true)
	show("new.go")
	eq(#marks("right"), 2)
end

return T
