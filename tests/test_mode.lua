local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality
local child = H.new_child()

local T = MiniTest.new_set({
	hooks = {
		pre_case = child.setup,
		post_once = child.stop,
	},
})

-- main: base.lua。feature ブランチで committed.lua を追加・base.lua を変更してcommitし、
-- さらに作業ツリーで wip.lua を未commitのまま変更している。
local function setup_repo()
	local root = H.make_repo({ ["base.lua"] = { "return 1" }, ["wip.lua"] = { "return 'wip'" } })
	local fork = vim.trim(H.git(root, { "rev-parse", "HEAD" }))
	H.git(root, { "switch", "-q", "-c", "feature" })
	H.write(root, "committed.lua", { "return 'committed'" })
	H.write(root, "base.lua", { "return 2" })
	H.git(root, { "add", "-A" })
	H.git(root, { "commit", "-q", "-m", "agent: first step" })
	H.write(root, "wip.lua", { "return 'wip2'" })
	child.lua("vim.cmd.cd(...)", { root })
	return root, fork
end

local function wait_for(expr)
	return child.lua(("return vim.wait(3000, function() return %s end, 20)"):format(expr))
end

local function review_paths()
	return child.lua_get([[vim.tbl_map(function(f) return f.path end, require("agent-review")._session.review_files)]])
end

local function tree_bar()
	return child.lua_get([[vim.wo[require("agent-review")._session.tree_win].winbar]])
end

local function session(field)
	return child.lua_get(([[require("agent-review")._session.%s]]):format(field))
end

local function commit(root, paths)
	H.git(root, vim.list_extend({ "add", "-A", "--" }, paths))
	H.git(root, { "commit", "-q", "-m", "agent commit" })
end

T["the default mode shows only uncommitted changes"] = function()
	setup_repo()
	child.lua([[require("agent-review").open()]])
	eq(review_paths(), { "wip.lua" })
	eq(session("mode"), "working")
end

T["branch mode shows everything since the branch left main"] = function()
	local _, fork = setup_repo()
	child.cmd("AgentReviewBranch")
	eq(session("mode"), "branch")
	eq(session("base_sha"), fork)
	eq(review_paths(), { "base.lua", "committed.lua", "wip.lua" })
	eq(tree_bar():find("Branch", 1, true) ~= nil, true)
	eq(tree_bar():find("main", 1, true) ~= nil, true)
end

T["branch mode compares with the fork point, not with where main is now"] = function()
	local root, fork = setup_repo()
	H.git(root, { "stash", "-q" })
	H.git(root, { "switch", "-q", "main" })
	H.write(root, "other.lua", { "return 'someone else'" })
	H.git(root, { "add", "-A" })
	H.git(root, { "commit", "-q", "-m", "main moves on" })
	H.git(root, { "switch", "-q", "feature" })
	H.git(root, { "stash", "pop", "-q" })
	child.cmd("AgentReviewBranch")
	eq(session("base_sha"), fork)
	eq(vim.tbl_contains(review_paths(), "other.lua"), false)
end

T["the base branch can be given or configured"] = function()
	local root = setup_repo()
	H.git(root, { "branch", "-q", "-m", "main", "develop" })
	child.cmd("AgentReviewBranch develop")
	eq(review_paths(), { "base.lua", "committed.lua", "wip.lua" })
	child.lua([[require("agent-review").close()]])
	child.lua([[require("agent-review").setup({ branch = { base = "develop" } })]])
	child.cmd("AgentReviewBranch")
	eq(session("base"), "develop")
end

T["reports when no base branch can be found"] = function()
	local root = setup_repo()
	H.git(root, { "branch", "-q", "-m", "main", "trunk" })
	child.lua([[
		_G.notified = {}
		vim.notify = function(msg) table.insert(_G.notified, msg) end
	]])
	child.cmd("AgentReviewBranch")
	eq(child.lua_get([[require("agent-review")._session]]), vim.NIL)
	eq(child.lua_get("_G.notified")[1]:find("branch.base", 1, true) ~= nil, true)
end

T["m in the tree switches between uncommitted and branch"] = function()
	local root = setup_repo()
	child.cmd("edit " .. root .. "/wip.lua")
	child.lua([[require("agent-review").open()]])
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.tree_win)]])
	child.type_keys("m")
	eq(session("mode"), "branch")
	eq(review_paths(), { "base.lua", "committed.lua", "wip.lua" })
	eq(child.lua_get([[vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(require("agent-review")._session.tree_win))]]), 3)
	-- 表示中のファイルはそのまま
	eq(child.lua_get([[vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(require("agent-review")._session.right_win))]]), root .. "/wip.lua")
	child.type_keys("m")
	eq(session("mode"), "working")
	eq(review_paths(), { "wip.lua" })
end

T["switching to a mode where the shown file has no changes moves to the first file"] = function()
	local root = setup_repo()
	child.cmd("AgentReviewBranch")
	child.lua([[require("agent-review").show_file("committed.lua")]])
	child.lua([[require("agent-review").toggle_mode()]])
	eq(child.lua_get([[vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(require("agent-review")._session.right_win))]]), root .. "/wip.lua")
	-- 左右の比較も新しい比較元で作り直す
	eq(child.lua_get([[vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require("agent-review")._session.left_win), 0, -1, false)]]), { "return 'wip'" })
end

T["commits keep files in branch mode"] = function()
	local root = setup_repo()
	child.cmd("AgentReviewBranch")
	commit(root, { "wip.lua" })
	child.lua("vim.wait(600)")
	eq(review_paths(), { "base.lua", "committed.lua", "wip.lua" })
end

T["commits update the file status in branch mode"] = function()
	local root = setup_repo()
	H.write(root, "brand_new.lua", { "return 'new'" })
	child.cmd("AgentReviewBranch")
	eq(child.lua_get([[require("agent-review")._session:file("brand_new.lua").status]]), "?")
	commit(root, { "brand_new.lua" })
	eq(wait_for([[require("agent-review")._session:file("brand_new.lua").status == "A"]]), true)
end

T["commits drop files in uncommitted mode"] = function()
	local root = setup_repo()
	H.write(root, "base.lua", { "return 3" })
	child.lua([[require("agent-review").open()]])
	eq(review_paths(), { "base.lua", "wip.lua" })
	commit(root, { "wip.lua" })
	eq(wait_for([[#require("agent-review")._session.review_files == 1]]), true)
	eq(review_paths(), { "base.lua" })
end

T["opening with nothing uncommitted falls back to the branch"] = function()
	local root = setup_repo()
	commit(root, { "wip.lua" })
	child.lua([[require("agent-review").open()]])
	eq(session("mode"), "branch")
	eq(review_paths(), { "base.lua", "committed.lua", "wip.lua" })
end

T["is not offered for pull requests"] = function()
	setup_repo()
	child.cmd("AgentReviewBranch")
	child.lua([[require("agent-review")._session.pr = {}]])
	child.lua([[require("agent-review").toggle_mode()]])
	eq(session("mode"), "branch")
end

return T
