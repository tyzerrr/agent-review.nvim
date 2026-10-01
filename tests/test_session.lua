local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality
local child = H.new_child()

local T = MiniTest.new_set({
	hooks = {
		pre_case = child.setup,
		post_once = child.stop,
	},
})

-- base: a.lua / b.lua / c.lua / del.lua。作業ツリーでa,bを変更、delを削除、newを追加。
local function setup_repo()
	local root = H.make_repo({
		["a.lua"] = { "local M = {}", "function M.f() return 1 end", "return M" },
		["b.lua"] = { "local b = 1", "return b" },
		["c.lua"] = { "-- unchanged", "return 3" },
		["del.lua"] = { "return 'deleted'" },
		["ignored.log"] = {},
	})
	H.write(root, ".gitignore", { "*.log", "build/" })
	H.git(root, { "add", ".gitignore" })
	H.git(root, { "commit", "-q", "-m", "ignore" })
	H.write(root, "a.lua", { "local M = {}", "function M.f() return 2 end", "return M" })
	H.write(root, "b.lua", { "local b = 1", "local extra = 2", "return b" })
	vim.fn.delete(root .. "/del.lua")
	H.write(root, "new.lua", { "return 'new'" })
	H.write(root, "build/out.lua", { "generated" })
	child.lua("vim.cmd.cd(...)", { root })
	return root
end

local function state()
	return child.lua([[
		local s = require("agent-review")._session
		if not s then return nil end
		local function info(win)
			local buf = vim.api.nvim_win_get_buf(win)
			return {
				name = vim.api.nvim_buf_get_name(buf),
				lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
				buftype = vim.bo[buf].buftype,
				filetype = vim.bo[buf].filetype,
				diff = vim.wo[win].diff,
				winhl = vim.wo[win].winhighlight,
			}
		end
		return {
			tab_is_current = vim.api.nvim_get_current_tabpage() == s.tab,
			left = info(s.left_win),
			right = info(s.right_win),
			current_is_right = vim.api.nvim_get_current_win() == s.right_win,
		}
	]])
end

local function edit_right(path)
	child.lua(
		[[local s = require("agent-review")._session
		vim.api.nvim_set_current_win(s.right_win)
		vim.cmd.edit(vim.fn.fnameescape(...))]],
		{ path }
	)
end

T["open"] = MiniTest.new_set()

T["open"]["creates a new tab with base on the left and working tree on the right"] = function()
	local root = setup_repo()
	child.cmd("edit " .. root .. "/a.lua")
	child.lua([[require("agent-review").open()]])
	local s = state()
	eq(s.tab_is_current, true)
	eq(child.lua_get("#vim.api.nvim_list_tabpages()"), 2)
	eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), 2)
	eq(s.current_is_right, true)
	eq(s.right.name, root .. "/a.lua")
	eq(s.right.buftype, "")
	eq(s.left.buftype, "nofile")
	eq(s.left.filetype, "lua")
	eq(s.left.lines, { "local M = {}", "function M.f() return 1 end", "return M" })
	eq(s.left.diff, true)
	eq(s.right.diff, true)
end

T["open"]["starts on the first changed file when current buffer is unchanged"] = function()
	local root = setup_repo()
	child.cmd("edit " .. root .. "/c.lua")
	child.lua([[require("agent-review").open()]])
	eq(state().right.name, root .. "/a.lua")
end

T["open"]["colors base side red and working side green"] = function()
	setup_repo()
	child.lua([[require("agent-review").open()]])
	local s = state()
	MiniTest.expect.no_equality(s.left.winhl:find("DiffAdd:AgentReviewDelete", 1, true), nil)
	MiniTest.expect.no_equality(s.left.winhl:find("DiffChange:AgentReviewDelete", 1, true), nil)
	MiniTest.expect.no_equality(s.right.winhl:find("DiffAdd:AgentReviewAdd", 1, true), nil)
	MiniTest.expect.no_equality(s.right.winhl:find("DiffChange:AgentReviewAdd", 1, true), nil)
	eq(child.lua_get([[vim.api.nvim_get_hl(0, { name = "AgentReviewAdd" }).bg ~= nil]]), true)
	eq(child.lua_get([[vim.api.nvim_get_hl(0, { name = "AgentReviewDelete" }).bg ~= nil]]), true)
end

T["open"]["applies diffopt and restores it on close"] = function()
	setup_repo()
	child.o.diffopt = "internal,filler"
	child.lua([[require("agent-review").open()]])
	MiniTest.expect.no_equality(child.o.diffopt:find("linematch", 1, true), nil)
	child.lua([[require("agent-review").close()]])
	eq(child.o.diffopt, "internal,filler")
end

T["open"]["notifies and does nothing when there are no changes"] = function()
	local root = H.make_repo({ ["a.lua"] = { "x" } })
	child.lua("vim.cmd.cd(...)", { root })
	child.lua([[require("agent-review").open()]])
	eq(child.lua_get([[require("agent-review")._session]]), vim.NIL)
	eq(child.lua_get("#vim.api.nvim_list_tabpages()"), 1)
end

T["open"]["errors on an unknown base"] = function()
	setup_repo()
	child.lua([[require("agent-review").open("no-such-ref")]])
	eq(child.lua_get([[require("agent-review")._session]]), vim.NIL)
end

T["open"]["accepts an explicit base revision"] = function()
	local root = setup_repo()
	-- HEAD~1 には .gitignore が無いので、.gitignore が新規ファイルとして差分に含まれる。
	child.lua([[require("agent-review").open("HEAD~1")]])
	local files = child.lua_get([[vim.tbl_map(function(f) return f.path end, require("agent-review")._session.files)]])
	eq(vim.tbl_contains(files, ".gitignore"), true)
	eq(root ~= nil, true)
end

T["follow"] = MiniTest.new_set()

T["follow"]["switches the base side when the right window edits another changed file"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	edit_right(root .. "/b.lua")
	local s = state()
	eq(s.right.name, root .. "/b.lua")
	eq(s.left.lines, { "local b = 1", "return b" })
	eq(s.left.diff, true)
	eq(s.right.diff, true)
end

T["follow"]["shows the base of unchanged files too (LSP jump into helper)"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	edit_right(root .. "/c.lua")
	local s = state()
	eq(s.left.lines, { "-- unchanged", "return 3" })
	eq(s.left.diff, true)
end

T["follow"]["shows an empty base for a new file"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	edit_right(root .. "/new.lua")
	local s = state()
	eq(s.left.lines, { "" })
	eq(s.left.diff, true)
	eq(s.right.diff, true)
end

T["follow"]["turns diff off for files outside the repository"] = function()
	setup_repo()
	local outside = vim.fn.tempname() .. ".lua"
	vim.fn.writefile({ "return 'outside'" }, outside)
	child.lua([[require("agent-review").open()]])
	edit_right(outside)
	local s = state()
	eq(s.left.diff, false)
	eq(s.right.diff, false)
	eq(s.left.buftype, "nofile")
end

T["follow"]["turns diff off for gitignored files inside the repository"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	edit_right(root .. "/build/out.lua")
	local s = state()
	eq(s.left.diff, false)
	eq(s.right.diff, false)
end

T["follow"]["re-enables diff when coming back from outside"] = function()
	local root = setup_repo()
	local outside = vim.fn.tempname() .. ".lua"
	vim.fn.writefile({ "x" }, outside)
	child.lua([[require("agent-review").open()]])
	edit_right(outside)
	edit_right(root .. "/a.lua")
	local s = state()
	eq(s.left.diff, true)
	eq(s.right.diff, true)
	eq(s.left.lines[2], "function M.f() return 1 end")
end

T["follow"]["follows jumplist navigation (<C-o>)"] = function()
	local root = setup_repo()
	child.cmd("edit " .. root .. "/a.lua")
	child.lua([[require("agent-review").open()]])
	edit_right(root .. "/b.lua")
	eq(state().left.lines, { "local b = 1", "return b" })
	child.type_keys("<C-o>")
	local s = state()
	eq(s.right.name, root .. "/a.lua")
	eq(s.left.lines[2], "function M.f() return 1 end")
end

T["follow"]["follows an LSP-style jump (vim.lsp.util.show_document)"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	child.lua(
		[[
		local uri = vim.uri_from_fname(...)
		vim.lsp.util.show_document({ uri = uri, range = {
			start = { line = 1, character = 0 }, ["end"] = { line = 1, character = 0 } } }, "utf-8", { focus = true })
	]],
		{ root .. "/b.lua" }
	)
	child.lua("vim.wait(50)")
	local s = state()
	eq(s.right.name, root .. "/b.lua")
	eq(s.left.lines, { "local b = 1", "return b" })
	eq(s.left.diff, true)
end

T["follow"]["uses the old path as base for renamed files"] = function()
	local root = H.make_repo({ ["old.lua"] = { "a", "b", "c", "d", "e" } })
	H.git(root, { "mv", "old.lua", "renamed.lua" })
	child.lua("vim.cmd.cd(...)", { root })
	child.lua([[require("agent-review").open()]])
	local s = state()
	eq(s.right.name, root .. "/renamed.lua")
	eq(s.left.lines, { "a", "b", "c", "d", "e" })
end

T["follow"]["shows deleted files with an empty working side"] = function()
	setup_repo()
	child.lua([[require("agent-review").show_file("del.lua")]])
	eq(child.lua_get([[require("agent-review")._session]]), vim.NIL)
	child.lua([[require("agent-review").open()]])
	child.lua([[require("agent-review").show_file("del.lua")]])
	local s = state()
	eq(s.left.lines, { "return 'deleted'" })
	eq(s.right.lines, { "" })
	eq(s.right.buftype, "nofile")
	eq(s.left.diff, true)
	eq(s.right.diff, true)
end

T["navigation"] = MiniTest.new_set()

T["navigation"]["next_file/prev_file cycle through changed files"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	-- 変更ファイルはパス順に a.lua, b.lua, del.lua, new.lua
	eq(state().right.name, root .. "/a.lua")
	child.lua([[require("agent-review").next_file()]])
	eq(state().right.name, root .. "/b.lua")
	child.lua([[require("agent-review").next_file()]])
	eq(state().left.lines, { "return 'deleted'" })
	child.lua([[require("agent-review").next_file()]])
	eq(state().right.name, root .. "/new.lua")
	child.lua([[require("agent-review").next_file()]])
	eq(state().right.name, root .. "/a.lua")
	child.lua([[require("agent-review").prev_file()]])
	eq(state().right.name, root .. "/new.lua")
end

T["navigation"]["]f and [f are mapped in the review windows"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	child.type_keys("]f")
	eq(state().right.name, root .. "/b.lua")
	child.type_keys("[f")
	eq(state().right.name, root .. "/a.lua")
end

T["navigation"]["picks up files created after opening"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	H.write(root, "zzz_late.lua", { "late" })
	child.lua([[require("agent-review").prev_file()]])
	eq(state().right.name, root .. "/zzz_late.lua")
end

T["close"] = MiniTest.new_set()

T["close"]["closes the tab, wipes base buffers and restores keymaps"] = function()
	local root = setup_repo()
	child.cmd("edit " .. root .. "/a.lua")
	child.lua([[vim.keymap.set("n", "]f", "<cmd>let g:orig_mapping = 1<cr>", { buffer = 0 })]])
	child.lua([[require("agent-review").open()]])
	child.lua([[require("agent-review").close()]])
	eq(child.lua_get("#vim.api.nvim_list_tabpages()"), 1)
	eq(child.lua_get([[require("agent-review")._session]]), vim.NIL)
	local scratch = child.lua_get([[#vim.tbl_filter(function(b)
		return vim.api.nvim_buf_get_name(b):match("^agent%-review://") ~= nil
	end, vim.api.nvim_list_bufs())]])
	eq(scratch, 0)
	child.type_keys("]f")
	eq(child.g.orig_mapping, 1)
end

T["close"]["closing the right window ends the session"] = function()
	setup_repo()
	child.lua([[require("agent-review").open()]])
	child.lua([[vim.api.nvim_win_close(require("agent-review")._session.right_win, true)]])
	child.lua("vim.wait(50)")
	eq(child.lua_get([[require("agent-review")._session]]), vim.NIL)
	eq(child.lua_get("#vim.api.nvim_list_tabpages()"), 1)
end

T["close"]["q in the base window closes the session"] = function()
	setup_repo()
	child.lua([[require("agent-review").open()]])
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.left_win)]])
	child.type_keys("q")
	child.lua("vim.wait(50)")
	eq(child.lua_get([[require("agent-review")._session]]), vim.NIL)
end

T["close"]["toggle opens and closes"] = function()
	setup_repo()
	child.lua([[require("agent-review").toggle()]])
	eq(child.lua_get([[require("agent-review")._session ~= nil]]), true)
	child.lua([[require("agent-review").toggle()]])
	eq(child.lua_get([[require("agent-review")._session]]), vim.NIL)
end

T["commands"] = MiniTest.new_set()

T["commands"][":AgentReview and :AgentReviewClose work"] = function()
	setup_repo()
	child.cmd("AgentReview")
	eq(child.lua_get([[require("agent-review")._session ~= nil]]), true)
	child.cmd("AgentReviewClose")
	eq(child.lua_get([[require("agent-review")._session]]), vim.NIL)
end

return T
