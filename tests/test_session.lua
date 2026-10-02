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
	-- 左右のdiff窓 + 下部のquickfix
	eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), 3)
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

T["auto refresh"] = MiniTest.new_set()

local function wait_for(expr)
	return child.lua(("return vim.wait(3000, function() return %s end, 20)"):format(expr))
end

local function count_refreshes()
	child.lua([[
		_G.refreshes = 0
		local ar = require("agent-review")
		local orig = ar.refresh
		ar.refresh = function(...) _G.refreshes = _G.refreshes + 1; return orig(...) end
	]])
end

T["auto refresh"]["picks up files the agent changes after opening"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	local before = child.lua_get("#vim.fn.getqflist()")
	H.write(root, "c.lua", { "-- changed by the agent", "return 3" })
	eq(wait_for(("#vim.fn.getqflist() == %d"):format(before + 1)), true)
	eq(child.lua_get([[require("agent-review")._session:file("c.lua") ~= nil]]), true)
end

T["auto refresh"]["drops files the agent reverts"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	H.write(root, "b.lua", { "local b = 1", "return b" })
	eq(wait_for([[require("agent-review")._session:file("b.lua") == nil]]), true)
end

T["auto refresh"]["reloads the working buffer shown on the right"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	edit_right(root .. "/a.lua")
	H.write(root, "a.lua", { "local M = {}", "function M.f() return 42 end", "return M" })
	eq(wait_for([[vim.api.nvim_buf_get_lines(0, 1, 2, false)[1] == "function M.f() return 42 end"]]), true)
	eq(state().right.diff, true)
end

T["auto refresh"]["ignores changes inside .git"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	child.lua("vim.wait(300)")
	count_refreshes()
	H.git(root, { "status" })
	H.write(root, ".git/agent-review-test", { "x" })
	child.lua("vim.wait(500)")
	eq(child.lua_get("_G.refreshes"), 0)
end

T["auto refresh"]["debounces a burst of writes into a single refresh"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	child.lua("vim.wait(300)")
	count_refreshes()
	for i = 1, 5 do
		H.write(root, "c.lua", { "-- edit " .. i })
	end
	eq(wait_for("_G.refreshes > 0"), true)
	child.lua("vim.wait(500)")
	eq(child.lua_get("_G.refreshes"), 1)
end

T["auto refresh"]["also refreshes on FocusGained"] = function()
	setup_repo()
	child.lua([[require("agent-review").open()]])
	child.lua("vim.wait(300)")
	count_refreshes()
	child.cmd("doautocmd FocusGained")
	eq(wait_for("_G.refreshes > 0"), true)
end

T["auto refresh"]["can be disabled"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").setup({ auto_refresh = false })]])
	child.lua([[require("agent-review").open()]])
	local before = child.lua_get("#vim.fn.getqflist()")
	H.write(root, "c.lua", { "-- changed by the agent", "return 3" })
	child.lua("vim.wait(500)")
	eq(child.lua_get("#vim.fn.getqflist()"), before)
end

local function commit(root, paths)
	H.git(root, vim.list_extend({ "add", "-A", "--" }, paths))
	H.git(root, { "commit", "-q", "-m", "agent commit" })
end

local function qf_names()
	return child.lua_get([[vim.tbl_map(function(i)
		return i.module ~= "" and i.module or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(i.bufnr), ":t")
	end, vim.fn.getqflist())]])
end

T["auto refresh"]["drops files once they are committed"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	commit(root, { "a.lua" })
	eq(wait_for([[require("agent-review")._session:file("a.lua") == nil]]), true)
	eq(vim.tbl_contains(qf_names(), "a.lua"), false)
	eq(vim.tbl_contains(qf_names(), "b.lua"), true)
	eq(child.lua_get([[require("agent-review")._session.base_sha]]), vim.trim(H.git(root, { "rev-parse", "HEAD" })))
end

T["auto refresh"]["shows the new commit on the base side"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	edit_right(root .. "/b.lua")
	-- commitした後にエージェントがさらに書き換え、b.luaは一覧に残る
	commit(root, { "b.lua" })
	H.write(root, "b.lua", { "local b = 1", "local extra = 2", "local more = 3", "return b" })
	local head = vim.trim(H.git(root, { "rev-parse", "HEAD" }))
	eq(wait_for(("require('agent-review')._session.base_sha == %q"):format(head)), true)
	child.lua("vim.wait(100)")
	eq(state().right.name, root .. "/b.lua")
	eq(state().left.lines, { "local b = 1", "local extra = 2", "return b" })
	-- 古いbaseのバッファを残さない
	local stale = child.lua_get([[#vim.tbl_filter(function(b)
		return vim.api.nvim_buf_get_name(b):find(require("agent-review")._session.short_sha, 1, true) == nil
			and vim.api.nvim_buf_get_name(b):match("^agent%-review://%x+/") ~= nil
	end, vim.api.nvim_list_bufs())]])
	eq(stale, 0)
end

T["auto refresh"]["empties the list when everything is committed"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	child.lua([[_G.msgs = {}; vim.notify = function(m) table.insert(_G.msgs, m) end]])
	commit(root, { "." })
	eq(wait_for("#vim.fn.getqflist() == 0"), true)
	eq(child.lua_get("vim.v.errmsg"), "")
	eq(child.lua_get([[vim.tbl_contains(vim.tbl_map(function(m) return m:match("no changes") ~= nil end, _G.msgs), true)]]), true)
	eq(child.lua_get([[require("agent-review")._session ~= nil]]), true)
end

T["auto refresh"]["follows HEAD moving back (reset)"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	commit(root, { "a.lua" })
	eq(wait_for([[require("agent-review")._session:file("a.lua") == nil]]), true)
	H.git(root, { "reset", "-q", "--soft", "HEAD~1" })
	eq(wait_for([[require("agent-review")._session:file("a.lua") ~= nil]]), true)
end

local function qf_idx()
	return child.lua_get([[vim.fn.getqflist({ idx = 0 }).idx]])
end

T["auto refresh"]["moves to the next file when the shown file is committed"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.right_win)]])
	child.cmd("cfirst")
	child.cmd("cnext")
	child.lua("vim.wait(50)")
	eq(state().right.name, root .. "/b.lua")
	commit(root, { "b.lua" })
	eq(wait_for([[require("agent-review")._session:file("b.lua") == nil]]), true)
	child.lua("vim.wait(100)")
	-- quickfixは消えたb.luaの位置（次のdel.lua）を選び、左右もそれに合わせる
	eq(qf_idx(), 2)
	eq(qf_names()[2], "del.lua")
	local st = state()
	eq(st.right.name, "agent-review://deleted/del.lua")
	eq(st.left.lines, { "return 'deleted'" })
	eq(st.right.diff, true)
end

T["auto refresh"]["moves to the selected entry in hunks mode too"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	child.cmd("AgentReviewQuickfix hunks")
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.right_win)]])
	child.cmd("cfirst")
	child.lua("vim.wait(50)")
	eq(state().right.name, root .. "/a.lua")
	commit(root, { "a.lua" })
	eq(wait_for([[require("agent-review")._session:file("a.lua") == nil]]), true)
	child.lua("vim.wait(100)")
	eq(qf_idx(), 1)
	eq(state().right.name, root .. "/b.lua")
	eq(child.lua_get([[vim.api.nvim_win_get_cursor(require("agent-review")._session.right_win)[1] ]]), 2)
end

T["auto refresh"]["stays on a file outside the list (e.g. after an LSP jump)"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	edit_right(root .. "/c.lua")
	H.write(root, "b.lua", { "local b = 1", "local extra = 3", "return b" })
	child.lua("vim.wait(600)")
	eq(state().right.name, root .. "/c.lua")
end

local function winbars()
	return child.lua([[
		local s = require("agent-review")._session
		return { vim.wo[s.left_win].winbar, vim.wo[s.right_win].winbar }
	]])
end

local function commit_all_and_wait(root)
	commit(root, { "." })
	eq(wait_for("#vim.fn.getqflist() == 0"), true)
	child.lua("vim.wait(100)")
end

T["auto refresh"]["empties both windows when everything is committed"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	edit_right(root .. "/a.lua")
	commit_all_and_wait(root)
	local st = state()
	eq(st.left.lines, { "" })
	eq(st.right.lines, { "" })
	eq(st.left.diff, false)
	eq(st.right.diff, false)
	eq(st.right.buftype, "nofile")
	local bars = winbars()
	eq(bars[1]:match("no changes") ~= nil, true)
	eq(bars[2]:match("no changes") ~= nil, true)
	eq(child.lua_get("vim.v.errmsg"), "")
end

T["auto refresh"]["shows the next change the agent makes after the list was empty"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	edit_right(root .. "/a.lua")
	commit_all_and_wait(root)
	H.write(root, "c.lua", { "-- changed again", "return 3" })
	eq(wait_for(("vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(require('agent-review')._session.right_win)) == %q"):format(root .. "/c.lua")), true)
	child.lua("vim.wait(100)")
	local st = state()
	eq(st.left.lines, { "-- unchanged", "return 3" })
	eq(st.left.diff, true)
	eq(st.right.diff, true)
end

T["auto refresh"]["opening a file from the empty view follows as usual"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	edit_right(root .. "/a.lua")
	commit_all_and_wait(root)
	edit_right(root .. "/b.lua")
	child.lua("vim.wait(50)")
	local st = state()
	eq(st.right.name, root .. "/b.lua")
	eq(st.left.lines, { "local b = 1", "local extra = 2", "return b" })
	eq(st.left.diff, true)
end

T["auto refresh"]["navigating in the empty view does not error"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	edit_right(root .. "/a.lua")
	commit_all_and_wait(root)
	child.lua([[_G.levels = {}; vim.notify = function(_, l) table.insert(_G.levels, l) end]])
	child.type_keys("]q")
	child.type_keys("]f")
	eq(child.lua_get("vim.v.errmsg"), "")
	eq(child.lua_get("#_G.levels"), 2)
end

T["auto refresh"]["closing from the empty view leaves no review buffers"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	edit_right(root .. "/a.lua")
	commit_all_and_wait(root)
	child.lua([[require("agent-review").close()]])
	local left = child.lua_get([[#vim.tbl_filter(function(b)
		return vim.api.nvim_buf_get_name(b):match("^agent%-review://") ~= nil
	end, vim.api.nvim_list_bufs())]])
	eq(left, 0)
	eq(child.lua_get("vim.v.errmsg"), "")
end

T["auto refresh"]["keeps a file outside the list on screen even when the list empties"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	edit_right(root .. "/c.lua")
	commit_all_and_wait(root)
	eq(state().right.name, root .. "/c.lua")
end

T["auto refresh"]["drops committed files in a git worktree too"] = function()
	-- worktreeではcommitが書き換えるrefが作業フォルダの外（元リポジトリの.git）にある。
	local main = H.make_repo({ ["a.lua"] = { "a" }, ["b.lua"] = { "b" } })
	local wt = vim.fn.resolve(vim.fn.tempname())
	H.git(main, { "worktree", "add", "-q", "-b", "feature", wt })
	H.git(wt, { "config", "user.email", "test@example.com" })
	H.git(wt, { "config", "user.name", "test" })
	H.write(wt, "a.lua", { "A" })
	H.write(wt, "b.lua", { "B" })
	child.lua("vim.cmd.cd(...)", { wt })
	child.lua([[require("agent-review").open()]])
	eq(child.lua_get([[require("agent-review")._session:file("a.lua") ~= nil]]), true)
	commit(wt, { "a.lua" })
	eq(wait_for([[require("agent-review")._session:file("a.lua") == nil]]), true)
	eq(child.lua_get([[require("agent-review")._session:file("b.lua") ~= nil]]), true)
end

T["auto refresh"]["keeps an explicit commit as the base"] = function()
	local root = setup_repo()
	local sha = vim.trim(H.git(root, { "rev-parse", "HEAD" }))
	child.lua([[require("agent-review").open(...)]], { sha })
	commit(root, { "a.lua" })
	child.lua("vim.wait(600)")
	eq(child.lua_get([[require("agent-review")._session:file("a.lua") ~= nil]]), true)
end

T["auto refresh"]["follow_base = false keeps the commit the review opened with"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").setup({ auto_refresh = { follow_base = false } })]])
	child.lua([[require("agent-review").open()]])
	commit(root, { "a.lua" })
	child.lua("vim.wait(600)")
	eq(child.lua_get([[require("agent-review")._session:file("a.lua") ~= nil]]), true)
end

T["auto refresh"]["stops watching when the review is closed"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	child.lua([[require("agent-review").close()]])
	count_refreshes()
	H.write(root, "c.lua", { "-- changed after close" })
	child.lua("vim.wait(500)")
	eq(child.lua_get("_G.refreshes"), 0)
	eq(child.lua_get("vim.v.errmsg"), "")
end

T["commands"] = MiniTest.new_set()

T["commands"][":AgentReview and :AgentReviewClose work"] = function()
	setup_repo()
	child.cmd("AgentReview")
	eq(child.lua_get([[require("agent-review")._session ~= nil]]), true)
	child.cmd("AgentReviewClose")
	eq(child.lua_get([[require("agent-review")._session]]), vim.NIL)
end

T["navigation"]["walking through more than 8 files never hits E96"] = function()
	local files = {}
	for i = 1, 12 do
		files[("f%02d.lua"):format(i)] = { "x" }
	end
	local root = H.make_repo(files)
	for i = 1, 12 do
		H.write(root, ("f%02d.lua"):format(i), { "y" })
	end
	child.lua("vim.cmd.cd(...)", { root })
	child.lua([[_G.errors = {}
		local orig = vim.notify
		vim.notify = function(m, l) if l == vim.log.levels.ERROR then table.insert(_G.errors, m) end end]])
	child.lua([[require("agent-review").open()]])
	for _ = 1, 11 do
		child.cmd("cnext")
	end
	for _ = 1, 14 do
		child.lua([[require("agent-review").prev_file()]])
	end
	eq(child.lua_get("_G.errors"), {})
	eq(child.lua_get([[vim.wo[require("agent-review")._session.right_win].diff]]), true)
	eq(child.lua_get([[vim.wo[require("agent-review")._session.left_win].diff]]), true)
end

return T
