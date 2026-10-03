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

local function comments_body(opts)
	opts = opts or {}
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
					reviewThreads = { pageInfo = { hasNextPage = false }, nodes = {} },
					reviews = { nodes = {} },
					comments = { nodes = {} },
					files = {
						nodes = opts.files or {
							{ path = "app.go", viewerViewedState = "VIEWED" },
							{ path = "gone.go", viewerViewedState = "UNVIEWED" },
							{ path = "long.go", viewerViewedState = "DISMISSED" },
							{ path = "new.go", viewerViewedState = "UNVIEWED" },
						},
					},
					commits = {
						nodes = {
							{
								commit = {
									oid = fx.head,
									statusCheckRollup = opts.checks or {
										state = "FAILURE",
										contexts = {
											nodes = {
												{ __typename = "CheckRun", name = "test (stable)", status = "COMPLETED", conclusion = "SUCCESS", detailsUrl = "https://ci/1" },
												{ __typename = "CheckRun", name = "test (nightly)", status = "COMPLETED", conclusion = "FAILURE", detailsUrl = "https://ci/2" },
												{ __typename = "StatusContext", context = "deploy/preview", state = "PENDING", targetUrl = "https://ci/3" },
											},
										},
									},
								},
							},
						},
					},
				},
			},
		},
	}
end

local function set_gh(rules)
	gh_dir = H.fake_gh(rules)
	child.lua("vim.env.FAKE_GH_DIR = ...", { gh_dir })
end

local function rules(opts)
	return {
		{ match = { "repos/o/r/pulls/7" }, headers = { ETag = '"h1"' }, body = pull(7, fx.head) },
		{ match = { "graphql", "mutation" }, body = { data = { viewed1 = { clientMutationId = vim.NIL }, viewed2 = { clientMutationId = vim.NIL } } } },
		{ match = { "graphql", "reviewThreads" }, body = comments_body(opts) },
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

local function viewed(rel)
	return child.lua_get([[require("agent-review")._session:is_viewed(...)]], { rel })
end

local function mutations()
	return vim.tbl_map(
		function(c)
			return vim.json.decode(c.stdin)
		end,
		vim.tbl_filter(function(c)
			return c.args[2] == "graphql" and c.stdin:find("mutation", 1, true) ~= nil
		end, H.gh_calls(gh_dir))
	)
end

T["viewed"] = MiniTest.new_set()

T["viewed"]["files marked viewed on GitHub are viewed in Neovim"] = function()
	open_pr()
	eq(viewed("app.go"), true)
	eq(viewed("gone.go"), false)
	-- GitHubで見た後に変わったファイル（DISMISSED）は未レビュー
	eq(viewed("long.go"), false)
	eq(child.lua_get([[vim.fn.getqflist({ title = 1 }).title]]):find("1/4 viewed", 1, true) ~= nil, true)
end

T["viewed"]["toggling is queued, not sent right away"] = function()
	open_pr()
	child.lua([[require("agent-review")._session:show("new.go")]])
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.right_win)]])
	child.type_keys(" dv")
	eq(viewed("new.go"), true)
	eq(#mutations(), 0)
	eq(child.lua_get([[require("agent-review.pr.draft").load(require("agent-review")._session.pr.repo, 7).viewed]]), { ["new.go"] = true })
end

T["viewed"]["queued changes go out with the submit"] = function()
	open_pr()
	child.lua([[require("agent-review")._session:show("new.go")]])
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.right_win)]])
	child.type_keys(" dv")
	child.lua([[require("agent-review")._session:show("app.go")]])
	child.type_keys(" dv")
	child.cmd("AgentReviewPRSubmit")
	child.lua("vim.wait(1000)")
	local m = mutations()
	eq(#m, 1)
	eq(m[1].query:find("markFileAsViewed", 1, true) ~= nil, true)
	eq(m[1].query:find("unmarkFileAsViewed", 1, true) ~= nil, true)
	eq(m[1].variables.prId, "PR_node_7")
	local paths = { m[1].variables.viewed1, m[1].variables.viewed2 }
	table.sort(paths)
	eq(paths, { "app.go", "new.go" })
	eq(child.lua_get([[require("agent-review.pr.draft").load(require("agent-review")._session.pr.repo, 7).viewed]]), {})
end

T["viewed"]["queued changes are sent when the review closes"] = function()
	open_pr()
	child.lua([[require("agent-review")._session:show("new.go")]])
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.right_win)]])
	child.type_keys(" dv")
	child.lua([[require("agent-review").close()]])
	child.lua("vim.wait(1000)")
	local m = mutations()
	eq(#m, 1)
	eq(m[1].query:find("markFileAsViewed", 1, true) ~= nil, true)
	eq(m[1].variables.viewed1, "new.go")
end

T["viewed"]["a local change waiting to be sent wins over GitHub's state"] = function()
	open_pr()
	child.lua([[require("agent-review")._session:show("app.go")]])
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.right_win)]])
	child.type_keys(" dv")
	eq(viewed("app.go"), false)
	child.lua([[require("agent-review.pr.open").load_comments(require("agent-review")._session)]])
	child.lua("vim.wait(500)")
	eq(viewed("app.go"), false)
end

T["checks"] = MiniTest.new_set()

T["checks"]["the winbar shows the CI state"] = function()
	open_pr()
	local bar = child.lua_get([[vim.wo[require("agent-review")._session.left_win].winbar]])
	eq(bar:find("CI failed", 1, true) ~= nil, true)
	-- quickfix のタイトルは変えない
	eq(child.lua_get([[vim.fn.getqflist({ title = 1 }).title]]):find("CI", 1, true), nil)
end

T["checks"]["the conversation lists every check"] = function()
	open_pr()
	child.cmd("AgentReviewPRConversation")
	local text = child.lua_get([[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")]])
	for _, part in ipairs({ "Checks", "✓ test (stable)", "✗ test (nightly)", "… deploy/preview" }) do
		eq({ part, text:find(part, 1, true) ~= nil }, { part, true })
	end
end

T["checks"]["passing checks show as such"] = function()
	set_gh(rules({ checks = { state = "SUCCESS", contexts = { nodes = {} } } }))
	open_pr()
	eq(child.lua_get([[vim.wo[require("agent-review")._session.left_win].winbar]]):find("✓ CI", 1, true) ~= nil, true)
end

return T
