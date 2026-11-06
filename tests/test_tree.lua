local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality
local child = H.new_child()

local T = MiniTest.new_set({
	hooks = {
		pre_case = child.setup,
		post_once = child.stop,
	},
})

-- 作業ツリーで lua/x.lua・lua/y.lua・a.lua を変更、del.lua を削除、new.lua を追加。c.lua は未変更。
-- ツリーの並び: lua/ → x.lua, y.lua → a.lua, del.lua, new.lua
local function setup_repo()
	local root = H.make_repo({
		["a.lua"] = { "local a = 1", "return a" },
		["c.lua"] = { "return 3" },
		["del.lua"] = { "return 'deleted'" },
		["lua/x.lua"] = { "return 'x'" },
		["lua/y.lua"] = { "return 'y'" },
	})
	H.write(root, "a.lua", { "local a = 2", "return a" })
	H.write(root, "lua/x.lua", { "return 'x2'" })
	H.write(root, "lua/y.lua", { "return 'y2'" })
	vim.fn.delete(root .. "/del.lua")
	H.write(root, "new.lua", { "return 'new'" })
	child.lua("vim.cmd.cd(...)", { root })
	return root
end

local function wait_for(expr)
	return child.lua(("return vim.wait(3000, function() return %s end, 20)"):format(expr))
end

local function tree_lines()
	return child.lua([[
		local s = require("agent-review")._session
		return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(s.tree_win), 0, -1, false)
	]])
end

local function right_name()
	return child.lua([[
		local s = require("agent-review")._session
		return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(s.right_win))
	]])
end

local function current_win()
	return child.lua([[
		local s = require("agent-review")._session
		local w = vim.api.nvim_get_current_win()
		return w == s.tree_win and "tree" or w == s.right_win and "right" or w == s.left_win and "left" or "other"
	]])
end

local function focus_tree()
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.tree_win)]])
end

local function tree_cursor()
	return child.lua_get([[vim.api.nvim_win_get_cursor(require("agent-review")._session.tree_win)[1] ]])
end

local function open()
	child.lua([[require("agent-review").open()]])
end

T["layout"] = MiniTest.new_set()

T["layout"]["opens a file tree on the left of the diff, without quickfix"] = function()
	setup_repo()
	open()
	eq(tree_lines(), { "▾ lua/", "    x.lua", "    y.lua", "  a.lua", "  del.lua", "  new.lua" })
	local layout = child.lua([[
		local s = require("agent-review")._session
		local function col(w) return vim.api.nvim_win_get_position(w)[2] end
		local wins = vim.api.nvim_tabpage_list_wins(0)
		local qf = vim.tbl_filter(function(w) return vim.fn.getwininfo(w)[1].quickfix == 1 end, wins)
		return {
			order = col(s.tree_win) < col(s.left_win) and col(s.left_win) < col(s.right_win),
			n_wins = #wins,
			qf = #qf,
			fixed = vim.wo[s.tree_win].winfixwidth,
			width = vim.api.nvim_win_get_width(s.tree_win),
			ft = vim.bo[vim.api.nvim_win_get_buf(s.tree_win)].filetype,
		}
	]])
	eq(layout.order, true)
	eq(layout.n_wins, 3)
	eq(layout.qf, 0)
	eq(layout.fixed, true)
	eq(layout.width, 32)
	eq(layout.ft, "agent-review-tree")
end

T["layout"]["shows the mode and a summary in the tree's winbar"] = function()
	setup_repo()
	open()
	local bar = child.lua_get([[vim.wo[require("agent-review")._session.tree_win].winbar]])
	eq(bar:find("Uncommitted", 1, true) ~= nil, true)
	eq(bar:find("5 files", 1, true) ~= nil, true)
end

T["layout"]["]f follows the order of the tree"] = function()
	local root = setup_repo()
	child.cmd("edit " .. root .. "/lua/y.lua")
	open()
	child.lua([[require("agent-review").next_file()]])
	eq(right_name(), root .. "/a.lua")
	child.lua([[require("agent-review").prev_file()]])
	child.lua([[require("agent-review").prev_file()]])
	eq(right_name(), root .. "/lua/x.lua")
end

T["layout"]["the quickfix list can still be turned on"] = function()
	setup_repo()
	child.lua([[require("agent-review").setup({ quickfix = { auto = true } })]])
	open()
	eq(child.lua_get("#vim.fn.getqflist()"), 5)
end

T["layout"]["the tree can be turned off"] = function()
	setup_repo()
	child.lua([[require("agent-review").setup({ tree = { enabled = false } })]])
	open()
	eq(child.lua_get([[require("agent-review")._session.tree_win]]), vim.NIL)
	eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), 2)
end

T["navigation"] = MiniTest.new_set()

T["navigation"]["moving the cursor in the tree shows that file's diff"] = function()
	local root = setup_repo()
	open()
	focus_tree()
	child.lua([[vim.api.nvim_win_set_cursor(0, { 4, 0 })]])
	child.type_keys("j")
	eq(right_name(), "agent-review://deleted/del.lua")
	child.type_keys("j")
	eq(right_name(), root .. "/new.lua")
	-- フォーカスはツリーに残る
	eq(current_win(), "tree")
	eq(child.lua_get([[vim.wo[require("agent-review")._session.right_win].diff]]), true)
end

T["navigation"]["files shown from the tree get their filetype (so LSP and tree-sitter start)"] = function()
	setup_repo()
	open()
	focus_tree()
	child.lua([[vim.api.nvim_win_set_cursor(0, { 4, 0 })]])
	child.type_keys("j")
	child.type_keys("j")
	eq(right_name():match("new%.lua$") ~= nil, true)
	eq(child.lua_get([[vim.bo[vim.api.nvim_win_get_buf(require("agent-review")._session.right_win)].filetype]]), "lua")
end

T["navigation"]["<CR> on a file focuses the diff at its first change"] = function()
	local root = setup_repo()
	H.write(root, "c.lua", { "return 3", "", "", "", "-- changed far below" })
	open()
	focus_tree()
	child.lua([[vim.api.nvim_win_set_cursor(0, { 5, 0 })]]) -- c.lua（新たに一覧へ）
	eq(tree_lines()[5], "  c.lua")
	child.type_keys("<CR>")
	eq(current_win(), "right")
	eq(right_name(), root .. "/c.lua")
	eq(child.lua_get("vim.fn.line('.')"), 2)
end

T["navigation"]["<CR> on a folder collapses and expands it"] = function()
	setup_repo()
	open()
	focus_tree()
	child.lua([[vim.api.nvim_win_set_cursor(0, { 1, 0 })]])
	child.type_keys("<CR>")
	eq(tree_lines(), { "▸ lua/", "  a.lua", "  del.lua", "  new.lua" })
	eq(tree_cursor(), 1)
	child.type_keys("<CR>")
	eq(tree_lines()[2], "    x.lua")
end

T["navigation"]["the tree cursor follows the file shown on the right"] = function()
	local root = setup_repo()
	open()
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.right_win)]])
	child.cmd("edit " .. root .. "/new.lua")
	eq(tree_cursor(), 6)
	local marked = child.lua([[
		local s = require("agent-review")._session
		local ns = vim.api.nvim_get_namespaces()["agent-review-tree-current"]
		local marks = vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(s.tree_win), ns, 0, -1, {})
		return vim.tbl_map(function(m) return m[2] + 1 end, marks)
	]])
	eq(marked, { 6 })
end

T["navigation"]["files opened from the tree window go to the right"] = function()
	local root = setup_repo()
	open()
	focus_tree()
	child.cmd("edit " .. root .. "/c.lua")
	child.lua("vim.wait(50)")
	eq(right_name(), root .. "/c.lua")
	eq(tree_lines()[1], "▾ lua/")
	eq(current_win(), "right")
end

T["navigation"]["<Tab> marks the file under the cursor as viewed"] = function()
	setup_repo()
	open()
	focus_tree()
	child.lua([[vim.api.nvim_win_set_cursor(0, { 4, 0 })]])
	child.type_keys("<Tab>")
	eq(child.lua_get([[require("agent-review")._session:is_viewed("a.lua")]]), true)
	local bar = child.lua_get([[vim.wo[require("agent-review")._session.tree_win].winbar]])
	eq(bar:find("1/5 viewed", 1, true) ~= nil, true)
end

T["navigation"]["<Tab> on a folder marks every file inside"] = function()
	setup_repo()
	open()
	focus_tree()
	child.lua([[vim.api.nvim_win_set_cursor(0, { 1, 0 })]])
	child.type_keys("<Tab>")
	eq(child.lua_get([[require("agent-review")._session:is_viewed("lua/x.lua")]]), true)
	eq(child.lua_get([[require("agent-review")._session:is_viewed("lua/y.lua")]]), true)
	eq(child.lua_get([[require("agent-review")._session:is_viewed("a.lua")]]), false)
	child.type_keys("<Tab>")
	eq(child.lua_get([[require("agent-review")._session:is_viewed("lua/x.lua")]]), false)
end

T["navigation"]["closing the tree keeps the review, and it can be reopened"] = function()
	setup_repo()
	open()
	focus_tree()
	child.cmd("close")
	child.lua("vim.wait(50)")
	eq(child.lua_get([[require("agent-review")._session ~= nil]]), true)
	child.lua([[require("agent-review").tree_focus()]])
	eq(current_win(), "tree")
	eq(tree_lines()[1], "▾ lua/")
	-- ツリーにいる時はdiffへ戻る
	child.lua([[require("agent-review").tree_focus()]])
	eq(current_win(), "right")
end

T["navigation"]["q in the tree closes the review"] = function()
	setup_repo()
	open()
	focus_tree()
	child.type_keys("q")
	child.lua("vim.wait(50)")
	eq(child.lua_get([[require("agent-review")._session]]), vim.NIL)
	eq(child.lua_get("#vim.api.nvim_list_tabpages()"), 1)
	eq(child.lua_get([[vim.fn.bufnr("agent-review://tree")]]), -1)
end

T["auto refresh"] = MiniTest.new_set()

local function commit(root, paths)
	H.git(root, vim.list_extend({ "add", "-A", "--" }, paths))
	H.git(root, { "commit", "-q", "-m", "agent commit" })
end

T["auto refresh"]["adds files the agent changes to the tree"] = function()
	local root = setup_repo()
	open()
	H.write(root, "c.lua", { "return 4" })
	eq(wait_for([[#vim.api.nvim_buf_get_lines(vim.fn.bufnr("agent-review://tree"), 0, -1, false) == 7]]), true)
	eq(tree_lines()[5], "  c.lua")
end

T["auto refresh"]["updates the line counts while the agent keeps editing"] = function()
	local root = setup_repo()
	open()
	H.write(root, "a.lua", { "local a = 2", "local more = 1", "local more2 = 1", "return a" })
	eq(
		wait_for([=[(function()
			local s = require("agent-review")._session
			local r = s.tree_render
			local virt = r and r.virt[r.file_line["a.lua"]]
			return virt and virt[1][1] == "+3 "
		end)()]=]),
		true
	)
end

T["auto refresh"]["drops committed files and moves to the next file"] = function()
	local root = setup_repo()
	child.cmd("edit " .. root .. "/a.lua")
	open()
	commit(root, { "a.lua" })
	eq(wait_for([[require("agent-review")._session:file("a.lua") == nil]]), true)
	child.lua("vim.wait(100)")
	eq(tree_lines(), { "▾ lua/", "    x.lua", "    y.lua", "  del.lua", "  new.lua" })
	eq(right_name(), "agent-review://deleted/del.lua")
	eq(tree_cursor(), 4)
end

T["auto refresh"]["keeps the tree cursor on a folder while the user is in the tree"] = function()
	local root = setup_repo()
	open()
	focus_tree()
	child.lua([[vim.api.nvim_win_set_cursor(0, { 1, 0 })]])
	H.write(root, "a.lua", { "local a = 3", "return a" })
	child.lua("vim.wait(600)")
	eq(tree_cursor(), 1)
end

return T
