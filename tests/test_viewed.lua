local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality
local child = H.new_child()

local T = MiniTest.new_set({
	hooks = {
		pre_case = child.setup,
		post_once = child.stop,
	},
})

-- base: a.go / a_test.go / b.go。作業ツリーで3つとも変更する。
local function setup_repo()
	local root = H.make_repo({
		["a.go"] = { "package a", "func A() int { return 1 }" },
		["a_test.go"] = { "package a", "func TestA() {}" },
		["b.go"] = { "package a", "func B() int { return 1 }" },
	})
	H.write(root, "a.go", { "package a", "func A() int { return 2 }" })
	H.write(root, "a_test.go", { "package a", "func TestA() { A() }" })
	H.write(root, "b.go", { "package a", "func B() int { return 2 }" })
	child.lua("vim.cmd.cd(...)", { root })
	return root
end

local function qf()
	return child.lua([[
		local info = vim.fn.getqflist({ title = 1, items = 1, idx = 0 })
		return {
			title = info.title,
			idx = info.idx,
			names = vim.tbl_map(function(i) return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(i.bufnr), ":t") end, info.items),
			texts = vim.tbl_map(function(i) return i.text end, info.items),
		}
	]])
end

local function right_name()
	return child.lua_get(
		[[vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(require("agent-review")._session.right_win)), ":t")]]
	)
end

local function right_winbar()
	return child.lua_get([[vim.wo[require("agent-review")._session.right_win].winbar]])
end

local function focus_qf(line)
	child.lua(
		[[vim.api.nvim_set_current_win(vim.fn.getqflist({ winid = 0 }).winid)
		vim.api.nvim_win_set_cursor(0, { ..., 0 })]],
		{ line }
	)
end

local function wait_for(expr)
	return child.lua(("return vim.wait(3000, function() return %s end, 20)"):format(expr))
end

T["tests.hide"] = MiniTest.new_set()

T["tests.hide"]["test files are listed by default"] = function()
	setup_repo()
	child.lua([[require("agent-review").open()]])
	eq(qf().names, { "a.go", "a_test.go", "b.go" })
end

T["tests.hide"]["leaves test files out of quickfix, ]f and the winbar count"] = function()
	setup_repo()
	child.lua([[require("agent-review").setup({ tests = { hide = true } })]])
	child.lua([[require("agent-review").open()]])
	local list = qf()
	eq(list.names, { "a.go", "b.go" })
	eq(list.title:match("1 test file hidden") ~= nil, true)
	eq(right_name(), "a.go")
	eq(right_winbar():match("%[1/2%]") ~= nil, true)
	child.lua([[require("agent-review").next_file()]])
	eq(right_name(), "b.go")
	child.lua([[require("agent-review").next_file()]])
	eq(right_name(), "a.go")
end

T["tests.hide"]["leaves test files out of the picker"] = function()
	setup_repo()
	child.lua([[require("agent-review").setup({ tests = { hide = true } })]])
	eq(child.lua_get([[vim.tbl_map(function(i) return i.path end, require("agent-review.picker").items())]]), { "a.go", "b.go" })
end

T["tests.hide"]["a test file opened directly still shows its diff"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").setup({ tests = { hide = true } })]])
	child.lua([[require("agent-review").open()]])
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.right_win)]])
	child.cmd("edit " .. root .. "/a_test.go")
	child.lua("vim.wait(50)")
	eq(child.lua_get([[vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require("agent-review")._session.left_win), 0, -1, false)]]), { "package a", "func TestA() {}" })
	eq(child.lua_get([[vim.wo[require("agent-review")._session.right_win].diff]]), true)
end

T["tests.hide"]["a change only in tests reports no changes"] = function()
	local root = H.make_repo({ ["a.go"] = { "package a" }, ["a_test.go"] = { "package a" } })
	H.write(root, "a_test.go", { "package a", "// more" })
	child.lua("vim.cmd.cd(...)", { root })
	child.lua([[require("agent-review").setup({ tests = { hide = true } })]])
	child.lua([[_G.msgs = {}; vim.notify = function(m) table.insert(_G.msgs, m) end]])
	child.lua([[require("agent-review").open()]])
	eq(child.lua_get([[require("agent-review")._session]]), vim.NIL)
	eq(child.lua_get([[_G.msgs[#_G.msgs] ]]):match("no changes") ~= nil, true)
end

T["viewed"] = MiniTest.new_set()

T["viewed"]["<Tab> in the quickfix window marks the file under the cursor"] = function()
	setup_repo()
	child.lua([[require("agent-review").open()]])
	focus_qf(2)
	child.type_keys("<Tab>")
	local list = qf()
	eq(vim.startswith(list.texts[2], "✓ "), true)
	eq(vim.startswith(list.texts[1], "✓ "), false)
	eq(list.title:match("%(1/3 viewed%)") ~= nil, true)
	-- カーソルも選択位置も動かさない
	eq(child.lua_get("vim.api.nvim_win_get_cursor(0)[1]"), 2)
	eq(list.idx, 1)
	child.type_keys("<Tab>")
	list = qf()
	eq(vim.startswith(list.texts[2], "✓ "), false)
	eq(list.title:match("viewed") == nil, true)
end

T["viewed"]["<leader>dv in the review windows marks the shown file"] = function()
	setup_repo()
	child.lua([[vim.g.mapleader = " "]])
	child.lua([[require("agent-review").open()]])
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.right_win)]])
	child.type_keys(" dv")
	eq(vim.startswith(qf().texts[1], "✓ "), true)
	eq(right_winbar():match("viewed") ~= nil, true)
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.left_win)]])
	child.type_keys(" dv")
	eq(vim.startswith(qf().texts[1], "✓ "), false)
	eq(right_winbar():match("viewed") == nil, true)
end

T["viewed"]["is cleared when the agent changes the file again"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	focus_qf(3)
	child.type_keys("<Tab>")
	eq(vim.startswith(qf().texts[3], "✓ "), true)
	H.write(root, "b.go", { "package a", "func B() int { return 3 }" })
	eq(wait_for([[not vim.startswith(vim.fn.getqflist()[3].text, "✓ ")]]), true)
end

T["viewed"]["survives closing and reopening the review"] = function()
	setup_repo()
	child.lua([[require("agent-review").open()]])
	focus_qf(3)
	child.type_keys("<Tab>")
	child.lua([[require("agent-review").close()]])
	child.lua([[require("agent-review").open()]])
	eq(vim.startswith(qf().texts[3], "✓ "), true)
	eq(vim.startswith(qf().texts[1], "✓ "), false)
end

T["viewed"]["marks every hunk of the file in hunks mode"] = function()
	local root = H.make_repo({ ["a.go"] = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" }, ["b.go"] = { "x" } })
	H.write(root, "a.go", { "ONE", "2", "3", "4", "5", "6", "7", "8", "9", "TEN" })
	H.write(root, "b.go", { "y" })
	child.lua("vim.cmd.cd(...)", { root })
	child.lua([[require("agent-review").open()]])
	child.cmd("AgentReviewQuickfix hunks")
	focus_qf(1)
	child.type_keys("<Tab>")
	local texts = qf().texts
	eq(#texts, 3)
	eq(vim.startswith(texts[1], "✓ "), true)
	eq(vim.startswith(texts[2], "✓ "), true)
	eq(vim.startswith(texts[3], "✓ "), false)
end

T["viewed"]["<Tab> on another quickfix list is left alone"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	child.lua([[vim.fn.setqflist({}, " ", { title = "grep", items = { { filename = ..., lnum = 1, text = "hit" } } })]], { root .. "/b.go" })
	focus_qf(1)
	child.type_keys("<Tab>")
	eq(child.lua_get([[vim.fn.getqflist()[1].text]]), "hit")
	eq(child.lua_get("vim.v.errmsg"), "")
end

T["viewed"]["is stored inside .git"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	focus_qf(1)
	child.type_keys("<Tab>")
	local stored = vim.json.decode(table.concat(vim.fn.readfile(root .. "/.git/agent-review/viewed.json"), "\n"))
	eq(stored["a.go"] ~= nil, true)
	eq(vim.trim(H.git(root, { "status", "--porcelain", "--", ".git" })), "")
end

return T
