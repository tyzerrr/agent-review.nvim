local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local state_dir

local function setup(pr)
	state_dir = vim.fn.tempname()
	require("agent-review.config").setup({
		pr = vim.tbl_extend("force", { gh = H.FAKE_GH, state_dir = state_dir }, pr or {}),
	})
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			setup()
		end,
	},
})

local function await(start)
	local done, result = false, nil
	start(function(...)
		done, result = true, { ... }
	end)
	eq(vim.wait(10000, function()
		return done
	end, 10), true)
	return unpack(result)
end

---GitHubのsearchが返すPRのノード。
local function pr(number, opts)
	return vim.tbl_extend("force", {
		number = number,
		title = "PR " .. number,
		url = "https://github.com/o/r/pull/" .. number,
		isDraft = false,
		state = "OPEN",
		createdAt = "2026-10-01T00:00:00Z",
		updatedAt = "2026-10-02T00:00:00Z",
		additions = 10,
		deletions = 2,
		changedFiles = 3,
		headRefName = "feature-" .. number,
		baseRefName = "main",
		body = "Body of " .. number,
		reviewDecision = "REVIEW_REQUIRED",
		author = { login = "alice" },
		commits = { nodes = { { commit = { statusCheckRollup = { state = "SUCCESS" } } } } },
	}, opts or {})
end

local REPO = { host = "github.com", owner = "o", name = "r", nwo = "o/r", key = "github.com/o/r" }

T["query"] = MiniTest.new_set()

local function build(filter, state)
	return require("agent-review.pr.query").build(filter, { repo = "o/r", state = state or "open" })
end

T["query"]["turns a filter table into a search query"] = function()
	eq(build({ author = "@me" }), "is:pr repo:o/r is:open author:@me sort:updated-desc")
	eq(build({ reviewer = "@me" }), "is:pr repo:o/r is:open review-requested:@me sort:updated-desc")
	eq(
		build({ assignee = "bob", involves = "@me", base = "main", draft = false }),
		"is:pr repo:o/r is:open assignee:bob involves:@me base:main draft:false sort:updated-desc"
	)
end

T["query"]["accepts lists and quotes values with spaces"] = function()
	eq(
		build({ label = { "bug", "needs review" } }),
		'is:pr repo:o/r is:open label:bug label:"needs review" sort:updated-desc'
	)
end

T["query"]["state can be overridden per filter or turned off"] = function()
	eq(build({ author = "@me", state = "merged" }), "is:pr repo:o/r is:merged author:@me sort:updated-desc")
	eq(build({ author = "@me" }, "all"), "is:pr repo:o/r author:@me sort:updated-desc")
end

T["query"]["a raw string gets the repository and is:pr added when missing"] = function()
	eq(build("is:open label:urgent"), "is:pr repo:o/r is:open label:urgent")
	eq(build("is:pr repo:x/y is:closed"), "is:pr repo:x/y is:closed")
end

T["repo"] = MiniTest.new_set()

T["repo"]["detects owner and name from the origin remote"] = function()
	local root = H.make_repo({})
	H.git(root, { "remote", "add", "origin", "git@github.com:VCL-in/zeimee2.git" })
	local repo = require("agent-review.pr.repo").detect(root .. "/")
	eq({ repo.host, repo.owner, repo.name, repo.nwo, repo.key }, {
		"github.com",
		"VCL-in",
		"zeimee2",
		"VCL-in/zeimee2",
		"github.com/VCL-in/zeimee2",
	})
end

T["repo"]["uses pr.remote"] = function()
	setup({ remote = "upstream" })
	local root = H.make_repo({})
	H.git(root, { "remote", "add", "origin", "https://github.com/me/fork.git" })
	H.git(root, { "remote", "add", "upstream", "https://github.com/org/app.git" })
	eq(require("agent-review.pr.repo").detect(root).nwo, "org/app")
end

T["repo"]["explains what is missing"] = function()
	local root = H.make_repo({})
	local repo, err = require("agent-review.pr.repo").detect(root)
	eq(repo, nil)
	eq(err:match("remote 'origin'") ~= nil, true)
	repo, err = require("agent-review.pr.repo").detect(vim.fn.tempname())
	eq(repo, nil)
	eq(err:match("git repository") ~= nil, true)
end

T["fetch"] = MiniTest.new_set()

local function fetch(name, opts)
	local results = {}
	local done = false
	require("agent-review.pr.list").fetch(REPO, name, opts or {}, function(err, items, info)
		table.insert(results, { err = err, items = items, info = info })
		done = info == nil or info.final
	end)
	vim.wait(10000, function()
		return done
	end, 10)
	return results
end

local function numbers(items)
	return vim.tbl_map(function(i)
		return i.number
	end, items)
end

T["fetch"]["runs every default list in one GraphQL call, deduped and newest first"] = function()
	local dir = H.fake_gh({
		{
			match = { "graphql" },
			body = {
				data = {
					q1 = { nodes = { pr(1, { updatedAt = "2026-10-01T00:00:00Z" }), pr(2, { updatedAt = "2026-10-03T00:00:00Z" }) } },
					q2 = { nodes = { pr(2, { updatedAt = "2026-10-03T00:00:00Z" }), pr(3, { updatedAt = "2026-10-02T00:00:00Z" }) } },
				},
			},
		},
	})
	vim.env.FAKE_GH_DIR = dir
	local results = fetch(nil)
	local last = results[#results]
	eq(last.err, nil)
	eq(numbers(last.items), { 2, 3, 1 })
	local calls = H.gh_calls(dir)
	eq(#calls, 1)
	local sent = vim.json.decode(calls[1].stdin)
	eq(sent.variables.q1, "is:pr repo:o/r is:open author:@me sort:updated-desc")
	eq(sent.variables.q2, "is:pr repo:o/r is:open review-requested:@me sort:updated-desc")
end

T["fetch"]["normalizes the fields the picker shows"] = function()
	vim.env.FAKE_GH_DIR = H.fake_gh({
		{
			match = { "graphql" },
			body = { data = { q1 = { nodes = { pr(7, { isDraft = true, reviewDecision = "APPROVED" }) } }, q2 = { nodes = {} } } },
		},
	})
	local item = fetch(nil)[1].items[1]
	eq({ item.number, item.title, item.author, item.draft, item.review, item.checks, item.additions, item.deletions, item.changed_files, item.head, item.base, item.body }, {
		7,
		"PR 7",
		"alice",
		true,
		"APPROVED",
		"SUCCESS",
		10,
		2,
		3,
		"feature-7",
		"main",
		"Body of 7",
	})
end

T["fetch"]["selects a preset by name"] = function()
	setup({ presets = { bugs = { { label = "bug" } }, urgent = "is:open label:urgent" } })
	local dir = H.fake_gh({ { match = { "graphql" }, body = { data = { q1 = { nodes = { pr(5) } } } } } })
	vim.env.FAKE_GH_DIR = dir
	eq(numbers(fetch("bugs")[1].items), { 5 })
	eq(vim.json.decode(H.gh_calls(dir)[1].stdin).variables, { q1 = "is:pr repo:o/r is:open label:bug sort:updated-desc" })
	fetch("urgent")
	eq(vim.json.decode(H.gh_calls(dir)[2].stdin).variables, { q1 = "is:pr repo:o/r is:open label:urgent" })
end

T["fetch"]["rejects an unknown preset"] = function()
	local results = fetch("nope")
	eq(results[1].err.message:match("unknown preset") ~= nil, true)
end

T["fetch"]["uses a fresh cache without calling GitHub"] = function()
	local dir = H.fake_gh({ { match = { "graphql" }, body = { data = { q1 = { nodes = { pr(1) } }, q2 = { nodes = {} } } } } })
	vim.env.FAKE_GH_DIR = dir
	fetch(nil)
	local results = fetch(nil)
	eq(#results, 1)
	eq(results[1].info.from_cache, true)
	eq(numbers(results[1].items), { 1 })
	eq(#H.gh_calls(dir), 1)
end

T["fetch"]["shows a stale cache first, then the fresh list"] = function()
	setup({ list_ttl = 0 })
	vim.env.FAKE_GH_DIR = H.fake_gh({ { match = { "graphql" }, body = { data = { q1 = { nodes = { pr(1) } }, q2 = { nodes = {} } } } } })
	fetch(nil)
	vim.env.FAKE_GH_DIR =
		H.fake_gh({ { match = { "graphql" }, body = { data = { q1 = { nodes = { pr(1), pr(2) } }, q2 = { nodes = {} } } } } })
	local results = fetch(nil)
	eq(#results, 2)
	eq({ results[1].info.from_cache, results[1].info.final }, { true, false })
	eq(numbers(results[1].items), { 1 })
	eq({ results[2].info.from_cache, results[2].info.final }, { false, true })
	eq(numbers(results[2].items), { 1, 2 })
end

T["fetch"]["force skips the cache"] = function()
	local dir = H.fake_gh({ { match = { "graphql" }, body = { data = { q1 = { nodes = { pr(1) } }, q2 = { nodes = {} } } } } })
	vim.env.FAKE_GH_DIR = dir
	fetch(nil)
	local results = fetch(nil, { force = true })
	eq(results[#results].info.from_cache, false)
	eq(#H.gh_calls(dir), 2)
end

T["fetch"]["passes gh errors through"] = function()
	vim.env.FAKE_GH_DIR = H.fake_gh({ { exit = 4, stderr = "please run:  gh auth login" } })
	local results = fetch(nil)
	eq(results[1].err.kind, "auth")
end

T["picker"] = MiniTest.new_set()

T["picker"]["format() shows number, title, author, state, checks, size and age"] = function()
	local now = os.time({ year = 2026, month = 10, day = 3, hour = 12, min = 0, sec = 0 })
	local format = require("agent-review.pr.picker").format
	local item = {
		number = 12,
		title = "Add login",
		author = "alice",
		draft = true,
		review = "CHANGES_REQUESTED",
		checks = "FAILURE",
		additions = 30,
		deletions = 4,
		changed_files = 5,
		updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now - 2 * 3600),
	}
	local text = format(item, now)
	for _, part in ipairs({ "#12", "Add login", "@alice", "draft", "changes requested", "CI failed", "+30 -4", "5 files", "2h ago" }) do
		eq({ part, text:find(part, 1, true) ~= nil }, { part, true })
	end
end

T["picker"]["format() marks merged and closed PRs"] = function()
	local format = require("agent-review.pr.picker").format
	local base = { number = 1, title = "t", author = "a", additions = 0, deletions = 0, changed_files = 1, updated_at = "" }
	eq(format(vim.tbl_extend("force", base, { state = "MERGED" })):find("merged", 1, true) ~= nil, true)
	eq(format(vim.tbl_extend("force", base, { state = "CLOSED" })):find("closed", 1, true) ~= nil, true)
	eq(format(vim.tbl_extend("force", base, { state = "OPEN" })):find("open", 1, true) == nil, true)
end

T["picker"]["ui.select lists the PRs and selecting opens it for review"] = function()
	setup({})
	require("agent-review.config").options.picker = "ui_select"
	local root = H.make_repo({})
	H.git(root, { "remote", "add", "origin", "https://github.com/o/r.git" })
	local cwd = vim.fn.getcwd()
	local dir = H.fake_gh({
		{ match = { "graphql" }, body = { data = { q1 = { nodes = { pr(1), pr(2) } }, q2 = { nodes = {} } } } },
		{ match = { "repos/o/r/pulls/2" }, status = 404, body = { message = "Not Found" } },
	})
	vim.env.FAKE_GH_DIR = dir
	local orig = vim.ui.select
	local shown
	vim.ui.select = function(items, opts, on_choice)
		shown = vim.tbl_map(opts.format_item, items)
		on_choice(items[2])
	end
	vim.cmd.cd(root)
	require("agent-review.pr.picker").pick(nil)
	vim.wait(10000, function()
		return #H.gh_calls(dir) >= 2
	end, 10)
	vim.ui.select = orig
	vim.cmd.cd(cwd)
	eq(#shown, 2)
	eq(shown[1]:find("#1", 1, true) ~= nil, true)
	eq(H.gh_calls(dir)[2].args, { "api", "-i", "repos/o/r/pulls/2" })
end

local child = H.new_child()

T["ui"] = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.setup()
			local root = H.make_repo({})
			H.git(root, { "remote", "add", "origin", "https://github.com/o/r.git" })
			local dir = H.fake_gh({
				{ match = { "graphql" }, body = { data = { q1 = { nodes = { pr(1), pr(2, { body = "## Why\nbecause" }) } }, q2 = { nodes = {} } } } },
			})
			child.lua(
				[[
				local root, gh, state, dir = ...
				vim.cmd.cd(root)
				vim.env.FAKE_GH_DIR = dir
				require("agent-review").setup({
					presets = nil,
					pr = { gh = gh, state_dir = state, presets = { bugs = { { label = "bug" } }, mine = { { author = "@me" } } } },
				})
			]],
				{ root, H.FAKE_GH, vim.fn.tempname(), dir }
			)
		end,
		post_once = child.stop,
	},
})

T["ui"][":AgentReviewPR completes preset names"] = function()
	eq(child.lua_get([[vim.fn.getcompletion("AgentReviewPR ", "cmdline")]]), { "bugs", "mine" })
end

T["ui"]["<leader>dp opens the PR list"] = function()
	eq(child.lua_get([[vim.fn.maparg(vim.keycode("<leader>dp"), "n", false, true).desc]]), "Agent Review: Pull requests")
end

T["ui"]["telescope lists the PRs with the description in the preview"] = function()
	if vim.fn.isdirectory("deps/telescope.nvim") == 0 then
		MiniTest.skip("telescope.nvim not available")
	end
	child.lua(
		[[
		local deps = ...
		vim.opt.rtp:prepend(deps .. "/plenary.nvim")
		vim.opt.rtp:prepend(deps .. "/telescope.nvim")
		vim.cmd("runtime plugin/telescope.lua")
		require("telescope").setup({})
	]],
		{ vim.fn.getcwd() .. "/deps" }
	)
	child.cmd("AgentReviewPR")
	child.lua("vim.wait(3000, function() return vim.bo.filetype == 'TelescopePrompt' end)")
	eq(child.bo.filetype, "TelescopePrompt")
	child.lua([[vim.wait(3000, function()
		local picker = require("telescope.actions.state").get_current_picker(vim.api.nvim_get_current_buf())
		return picker and picker.manager and picker.manager:num_results() == 2
	end)]])
	eq(child.lua_get([[require("telescope.actions.state").get_current_picker(vim.api.nvim_get_current_buf()).manager:num_results()]]), 2)
	child.type_keys("#2")
	child.lua([[vim.wait(1000, function()
		local p = require("telescope.actions.state").get_current_picker(vim.api.nvim_get_current_buf())
		return p.previewer and p.previewer.state and p.previewer.state.bufnr
			and table.concat(vim.api.nvim_buf_get_lines(p.previewer.state.bufnr, 0, -1, false), "\n"):find("because") ~= nil
	end)]])
	local preview = child.lua_get([[table.concat(vim.api.nvim_buf_get_lines(
		require("telescope.actions.state").get_current_picker(vim.api.nvim_get_current_buf()).previewer.state.bufnr, 0, -1, false), "\n")]])
	eq(preview:find("because", 1, true) ~= nil, true)
	eq(preview:find("#2", 1, true) ~= nil, true)
end

return T
