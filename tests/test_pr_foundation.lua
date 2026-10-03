local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local state_dir

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			state_dir = vim.fn.tempname()
			require("agent-review.config").setup({ pr = { gh = H.FAKE_GH, state_dir = state_dir } })
		end,
	},
})

local paths = function()
	return require("agent-review.pr.paths")
end
local gh = function()
	return require("agent-review.pr.gh")
end
local store = function()
	return require("agent-review.pr.store")
end

---非同期の呼び出しを待って結果を返す。コールバックが同期的に呼ばれていないことも確かめる。
local function await(start)
	local done, result = false, nil
	start(function(...)
		done, result = true, { ... }
	end)
	eq(done, false)
	eq(vim.wait(10000, function()
		return done
	end, 10), true)
	return unpack(result)
end

T["paths"] = MiniTest.new_set()

T["paths"]["repo_key() turns remote URLs into ghq-style keys"] = function()
	local key = paths().repo_key
	eq(key("https://github.com/VCL-in/zeimee2"), "github.com/VCL-in/zeimee2")
	eq(key("https://github.com/VCL-in/zeimee2.git"), "github.com/VCL-in/zeimee2")
	eq(key("https://user@github.com/VCL-in/zeimee2.git/"), "github.com/VCL-in/zeimee2")
	eq(key("git@github.com:VCL-in/zeimee2.git"), "github.com/VCL-in/zeimee2")
	eq(key("ssh://git@github.com/VCL-in/zeimee2.git"), "github.com/VCL-in/zeimee2")
	eq(key("ssh://git@github.example.co.jp:2222/team/app.git"), "github.example.co.jp/team/app")
	eq(key("not a url"), nil)
	eq(key("https://github.com/../../etc"), nil)
end

T["paths"]["state_root() uses pr.state_dir, then XDG_STATE_HOME, then ~/.local/state"] = function()
	eq(paths().state_root(), state_dir)
	require("agent-review.config").setup({})
	local xdg = vim.env.XDG_STATE_HOME
	vim.env.XDG_STATE_HOME = "/tmp/xdg-state"
	eq(paths().state_root(), "/tmp/xdg-state/agent-review")
	vim.env.XDG_STATE_HOME = nil
	eq(paths().state_root(), vim.fs.normalize("~/.local/state/agent-review"))
	vim.env.XDG_STATE_HOME = xdg
end

T["paths"]["mirror and PR directories live under the repository key"] = function()
	local url = "git@github.com:VCL-in/zeimee2.git"
	eq(paths().repo_dir(url), state_dir .. "/github.com/VCL-in/zeimee2")
	eq(paths().mirror_dir(url), state_dir .. "/github.com/VCL-in/zeimee2/repo.git")
	eq(paths().pr_dir(url, 123), state_dir .. "/github.com/VCL-in/zeimee2/123")
end

T["gh"] = MiniTest.new_set()

T["gh"]["json() runs gh asynchronously and decodes the output"] = function()
	vim.env.FAKE_GH_DIR = H.fake_gh({ { match = { "pr", "list" }, body = { { number = 1, title = "Fix" } } } })
	local err, data = await(function(cb)
		gh().json({ "pr", "list", "--json", "number,title" }, cb)
	end)
	eq(err, nil)
	eq(data, { { number = 1, title = "Fix" } })
	eq(H.gh_calls(vim.env.FAKE_GH_DIR)[1].args, { "pr", "list", "--json", "number,title" })
end

T["gh"]["reports a missing gh executable"] = function()
	require("agent-review.config").setup({ pr = { gh = "/nonexistent/gh" } })
	local err = await(function(cb)
		gh().json({ "pr", "list" }, cb)
	end)
	eq(err.kind, "missing")
end

T["gh"]["reports when gh is not logged in"] = function()
	vim.env.FAKE_GH_DIR = H.fake_gh({
		{ exit = 4, stderr = "To get started with GitHub CLI, please run:  gh auth login\n" },
	})
	local err = await(function(cb)
		gh().json({ "pr", "list" }, cb)
	end)
	eq(err.kind, "auth")
	eq(err.message:match("gh auth login") ~= nil, true)
end

T["gh"]["reports API errors with the status and message"] = function()
	vim.env.FAKE_GH_DIR = H.fake_gh({ { match = { "pulls/9" }, status = 404, body = { message = "Not Found" } } })
	local err = await(function(cb)
		gh().rest("repos/o/r/pulls/9", {}, cb)
	end)
	eq(err.kind, "api")
	eq(err.status, 404)
	eq(err.message, "Not Found")
end

T["gh"]["graphql() sends the query and variables on stdin"] = function()
	vim.env.FAKE_GH_DIR = H.fake_gh({ { match = { "graphql" }, body = { data = { viewer = { login = "me" } } } } })
	local err, data = await(function(cb)
		gh().graphql("query($n: Int!) { viewer { login } }", { n = 1 }, cb)
	end)
	eq(err, nil)
	eq(data, { viewer = { login = "me" } })
	local call = H.gh_calls(vim.env.FAKE_GH_DIR)[1]
	eq(vim.list_slice(call.args, 1, 2), { "api", "graphql" })
	eq(vim.json.decode(call.stdin), { query = "query($n: Int!) { viewer { login } }", variables = { n = 1 } })
end

T["gh"]["graphql() reports errors returned in the body"] = function()
	vim.env.FAKE_GH_DIR = H.fake_gh({
		{ match = { "graphql" }, body = { errors = { { message = "Field 'x' doesn't exist" } } } },
	})
	local err = await(function(cb)
		gh().graphql("{ x }", {}, cb)
	end)
	eq(err.kind, "graphql")
	eq(err.message, "Field 'x' doesn't exist")
end

T["gh"]["rest_cached() reuses the cached body when GitHub answers 304"] = function()
	local dir = H.fake_gh({
		{ match = { "repos/o/r/pulls/1" }, headers = { ETag = 'W/"v1"' }, body = { number = 1, title = "first" } },
	})
	vim.env.FAKE_GH_DIR = dir
	local err, body, info = await(function(cb)
		gh().rest_cached("github.com/o/r/pulls/1", "repos/o/r/pulls/1", cb)
	end)
	eq(err, nil)
	eq(body.title, "first")
	eq(info.from_cache, false)

	err, body, info = await(function(cb)
		gh().rest_cached("github.com/o/r/pulls/1", "repos/o/r/pulls/1", cb)
	end)
	eq(err, nil)
	eq(body.title, "first")
	eq(info.from_cache, true)
	local calls = H.gh_calls(dir)
	eq(#calls, 2)
	eq(calls[1].if_none_match, vim.NIL)
	eq(calls[2].if_none_match, 'W/"v1"')
end

T["gh"]["rest_cached() stores the new body when it changed"] = function()
	vim.env.FAKE_GH_DIR =
		H.fake_gh({ { match = { "pulls/1" }, headers = { ETag = 'W/"v1"' }, body = { title = "first" } } })
	await(function(cb)
		gh().rest_cached("k", "repos/o/r/pulls/1", cb)
	end)
	vim.env.FAKE_GH_DIR =
		H.fake_gh({ { match = { "pulls/1" }, headers = { ETag = 'W/"v2"' }, body = { title = "second" } } })
	local _, body, info = await(function(cb)
		gh().rest_cached("k", "repos/o/r/pulls/1", cb)
	end)
	eq(body.title, "second")
	eq(info.from_cache, false)
	eq(store().get("k").etag, 'W/"v2"')
end

T["store"] = MiniTest.new_set()

T["store"]["put() and get() round-trip the value, ETag and fetch time"] = function()
	local before = os.time()
	store().put("github.com/o/r/pulls", { { number = 1 } }, { etag = "e1" })
	local entry = store().get("github.com/o/r/pulls")
	eq(entry.value, { { number = 1 } })
	eq(entry.etag, "e1")
	eq(entry.fetched_at >= before, true)
	eq(vim.fn.filereadable(state_dir .. "/cache/github.com/o/r/pulls.json"), 1)
end

T["store"]["get() returns nil for missing and broken entries"] = function()
	eq(store().get("nothing/here"), nil)
	vim.fn.mkdir(state_dir .. "/cache", "p")
	vim.fn.writefile({ "{ not json" }, state_dir .. "/cache/broken.json")
	eq(store().get("broken"), nil)
end

T["store"]["put() leaves no temporary files behind"] = function()
	store().put("a/b", { x = 1 })
	store().put("a/b", { x = 2 })
	eq(vim.fn.readdir(state_dir .. "/cache/a"), { "b.json" })
	eq(store().get("a/b").value, { x = 2 })
end

T["store"]["keys cannot escape the cache directory"] = function()
	store().put("../../escape", { x = 1 })
	eq(vim.fn.filereadable(state_dir .. "/escape.json"), 0)
	eq(store().get("../../escape").value, { x = 1 })
end

return T
