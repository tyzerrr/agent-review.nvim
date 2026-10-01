local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality
local child = H.new_child()

local T = MiniTest.new_set({
	hooks = {
		pre_case = child.setup,
		post_once = child.stop,
	},
})

local function setup_repo()
	local root = H.make_repo({
		["a.lua"] = { "a1", "a2", "a3", "a4", "a5" },
		["b.lua"] = { "b1", "b2" },
		["c.lua"] = { "c1" },
		["d.lua"] = { "gone" },
	})
	H.write(root, "a.lua", { "a1", "a2", "a3", "A4", "a5" })
	H.write(root, "b.lua", { "b1", "b2", "b3" })
	vim.fn.delete(root .. "/d.lua")
	child.lua("vim.cmd.cd(...)", { root })
	return root
end

local function right_name()
	return child.lua_get(
		[[vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(require("agent-review")._session.right_win))]]
	)
end

local function left_lines()
	return child.lua_get(
		[[vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require("agent-review")._session.left_win), 0, -1, false)]]
	)
end

T["quickfix"] = MiniTest.new_set()

T["quickfix"]["is populated with changed files and opened in the review tab"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	local qf = child.lua([[
		local info = vim.fn.getqflist({ title = 1, items = 1, winid = 1 })
		return {
			title = info.title,
			files = vim.tbl_map(function(i) return vim.api.nvim_buf_get_name(i.bufnr) end, info.items),
			lnums = vim.tbl_map(function(i) return i.lnum end, info.items),
			win_in_tab = info.winid ~= 0 and vim.api.nvim_win_get_tabpage(info.winid) == require("agent-review")._session.tab,
		}
	]])
	eq(qf.title, "Agent Review: HEAD")
	eq(qf.files, { root .. "/a.lua", root .. "/b.lua", "agent-review://deleted/d.lua" })
	eq(qf.lnums, { 4, 3, 1 })
	eq(qf.win_in_tab, true)
	-- フォーカスは右のdiff窓に残す
	eq(child.lua_get([[vim.api.nvim_get_current_win() == require("agent-review")._session.right_win]]), true)
	-- 削除ファイルは実ファイルのバッファを作らず、編集できないnofileバッファを指す
	eq(child.lua_get([[vim.bo[vim.fn.getqflist()[3].bufnr].buftype]]), "nofile")
	-- 表示上は内部のバッファ名ではなく通常のパスを見せる
	eq(child.lua_get([[vim.fn.getqflist()[3].module]]), "d.lua")
end

T["quickfix"]["selecting an entry opens it in the right window and the base follows"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	child.cmd("copen")
	child.cmd("2")
	child.type_keys("<CR>")
	child.lua("vim.wait(50)")
	eq(right_name(), root .. "/b.lua")
	eq(left_lines(), { "b1", "b2" })
	eq(child.lua_get([[vim.api.nvim_win_get_cursor(require("agent-review")._session.right_win)[1] ]]), 3)
end

T["quickfix"][":cnext from the base window lands in the right window"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.left_win)]])
	child.cmd("cfirst")
	child.cmd("cnext")
	child.lua("vim.wait(50)")
	eq(right_name(), root .. "/b.lua")
	eq(left_lines(), { "b1", "b2" })
	eq(child.lua_get([[vim.api.nvim_get_current_win() == require("agent-review")._session.right_win]]), true)
	eq(child.lua_get([[vim.api.nvim_win_get_cursor(0)[1] ]]), 3)
end

T["quickfix"]["deleted files open as the empty working side"] = function()
	setup_repo()
	child.lua([[require("agent-review").open()]])
	child.cmd("clast")
	child.lua("vim.wait(50)")
	eq(left_lines(), { "gone" })
	eq(
		child.lua_get([[vim.bo[vim.api.nvim_win_get_buf(require("agent-review")._session.right_win)].buftype]]),
		"nofile"
	)
end

T["quickfix"]["refresh replaces the same list instead of stacking"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	local nr = child.lua_get([[vim.fn.getqflist({ nr = "$" }).nr]])
	H.write(root, "c.lua", { "c1", "c2" })
	child.lua([[require("agent-review").refresh()]])
	eq(child.lua_get([[vim.fn.getqflist({ nr = "$" }).nr]]), nr)
	eq(child.lua_get([[#vim.fn.getqflist()]]), 4)
end

T["quickfix"][":AgentReviewQuickfix hunks lists every hunk"] = function()
	local root = H.make_repo({ ["a.lua"] = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" } })
	H.write(root, "a.lua", { "ONE", "2", "3", "4", "5", "6", "7", "8", "9", "TEN" })
	child.lua("vim.cmd.cd(...)", { root })
	child.lua([[require("agent-review").open()]])
	child.cmd("AgentReviewQuickfix hunks")
	eq(child.lua_get([[vim.tbl_map(function(i) return i.lnum end, vim.fn.getqflist())]]), { 1, 10 })
end

T["quickfix"]["can be disabled"] = function()
	setup_repo()
	child.lua([[require("agent-review").setup({ quickfix = { auto = false } })]])
	child.lua([[require("agent-review").open()]])
	eq(child.lua_get([[vim.fn.getqflist({ title = 1 }).title]]), "")
end

T["quickfix"]["]q on the last entry wraps around to the first"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	child.cmd("clast")
	child.lua("vim.wait(50)")
	child.type_keys("]q")
	child.lua("vim.wait(50)")
	eq(right_name(), root .. "/a.lua")
	eq(child.lua_get([[vim.fn.getqflist({ idx = 0 }).idx]]), 1)
	eq(child.lua_get([[vim.api.nvim_win_get_cursor(0)[1] ]]), 4)
end

T["quickfix"]["[q on the first entry wraps around to the last"] = function()
	setup_repo()
	child.lua([[require("agent-review").open()]])
	child.cmd("cfirst")
	child.lua("vim.wait(50)")
	child.type_keys("[q")
	child.lua("vim.wait(50)")
	eq(right_name(), "agent-review://deleted/d.lua")
	eq(left_lines(), { "gone" })
end

T["quickfix"]["]q and [q step through entries in between"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	child.cmd("cfirst")
	child.lua("vim.wait(50)")
	child.type_keys("]q")
	child.lua("vim.wait(50)")
	eq(right_name(), root .. "/b.lua")
	child.type_keys("[q")
	child.lua("vim.wait(50)")
	eq(right_name(), root .. "/a.lua")
end

T["quickfix"]["]q from the base window opens the entry on the right"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	child.cmd("clast")
	child.lua("vim.wait(50)")
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.left_win)]])
	child.type_keys("]q")
	child.lua("vim.wait(50)")
	eq(right_name(), root .. "/a.lua")
	eq(left_lines(), { "a1", "a2", "a3", "a4", "a5" })
	eq(child.lua_get([[vim.api.nvim_get_current_win() == require("agent-review")._session.right_win]]), true)
end

T["quickfix"]["]q and [q wrap around from inside the quickfix window"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	child.cmd("clast")
	child.lua("vim.wait(50)")
	child.lua([[vim.api.nvim_set_current_win(vim.fn.getqflist({ winid = 0 }).winid)]])
	child.type_keys("]q")
	child.lua("vim.wait(50)")
	eq(child.lua_get("vim.v.errmsg"), "")
	eq(child.lua_get([[vim.fn.getqflist({ idx = 0 }).idx]]), 1)
	eq(right_name(), root .. "/a.lua")
	child.lua([[vim.api.nvim_set_current_win(vim.fn.getqflist({ winid = 0 }).winid)]])
	child.type_keys("[q")
	child.lua("vim.wait(50)")
	eq(child.lua_get([[vim.fn.getqflist({ idx = 0 }).idx]]), 3)
	eq(right_name(), "agent-review://deleted/d.lua")
end

T["quickfix"]["the quickfix window gets its normal ]q back after close"] = function()
	setup_repo()
	child.lua([[require("agent-review").open()]])
	local qf_buf = child.lua_get([[vim.api.nvim_win_get_buf(vim.fn.getqflist({ winid = 0 }).winid)]])
	local function qf_buf_maps_bracket_q()
		return child.lua_get(
			[[vim.api.nvim_buf_is_valid(...) and #vim.tbl_filter(function(m) return m.lhs == "]q" end, vim.api.nvim_buf_get_keymap(..., "n")) > 0]],
			{ qf_buf }
		)
	end
	eq(qf_buf_maps_bracket_q(), true)
	child.lua([[require("agent-review").close()]])
	eq(qf_buf_maps_bracket_q(), false)
end

T["quickfix"]["]q with an empty list warns instead of erroring"] = function()
	setup_repo()
	child.lua([[require("agent-review").open()]])
	child.lua([[vim.fn.setqflist({}, "r", { items = {} })]])
	child.lua([[_G.warned = nil; vim.notify = function(_, level) _G.warned = level end]])
	child.type_keys("]q")
	eq(child.lua_get("_G.warned"), vim.log.levels.WARN)
	eq(child.lua_get("vim.v.errmsg"), "")
end

T["quickfix"]["refresh keeps the current entry selected"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	child.cmd("clast")
	child.lua("vim.wait(50)")
	H.write(root, "c.lua", { "c1", "c2" })
	child.lua([[require("agent-review").refresh()]])
	eq(child.lua_get([[vim.fn.getqflist({ idx = 0 }).idx]]), 4)
	eq(child.lua_get([[vim.fn.getqflist()[vim.fn.getqflist({ idx = 0 }).idx].module]]), "d.lua")
end

T["redirect"] = MiniTest.new_set()

T["redirect"]["a file opened in the base window moves to the right window"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.left_win)]])
	child.cmd("edit +3 " .. root .. "/b.lua")
	child.lua("vim.wait(50)")
	eq(right_name(), root .. "/b.lua")
	eq(left_lines(), { "b1", "b2" })
	eq(child.lua_get([[vim.bo[vim.api.nvim_win_get_buf(require("agent-review")._session.left_win)].buftype]]), "nofile")
	eq(child.lua_get([[vim.api.nvim_get_current_win() == require("agent-review")._session.right_win]]), true)
	eq(child.lua_get([[vim.api.nvim_win_get_cursor(0)[1] ]]), 3)
end

T["picker"] = MiniTest.new_set()

T["picker"]["items() lists changed files with stats"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").open()]])
	local items = child.lua(
		[[return vim.tbl_map(function(i) return { i.path, i.lnum, i.display } end, require("agent-review.picker").items())]]
	)
	eq(items[1][1], "a.lua")
	eq(items[1][2], 4)
	eq(items[1][3]:match("%+1 %-1") ~= nil, true)
	eq(root ~= nil, true)
end

T["picker"]["select() opens the review when it is not open yet"] = function()
	local root = setup_repo()
	child.lua([[
		local picker = require("agent-review.picker")
		local item = vim.tbl_filter(function(i) return i.path == "b.lua" end, picker.items())[1]
		picker.select(item)
	]])
	eq(right_name(), root .. "/b.lua")
	eq(left_lines(), { "b1", "b2" })
	eq(child.lua_get([[vim.api.nvim_win_get_cursor(0)[1] ]]), 3)
end

T["picker"]["falls back to vim.ui.select without telescope"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").setup({ picker = "auto" })]])
	child.lua([[vim.ui.select = function(items, _, cb) _G.ui_count = #items; cb(items[2]) end]])
	child.lua([[require("agent-review").open()]])
	child.lua([[require("agent-review").files()]])
	eq(child.lua_get("_G.ui_count"), 3)
	eq(right_name(), root .. "/b.lua")
end

T["picker"]["telescope extension opens and selects"] = function()
	if vim.fn.isdirectory("deps/telescope.nvim") == 0 then
		MiniTest.skip("telescope.nvim not available")
	end
	local root = setup_repo()
	child.lua(
		[[
		local deps = ...
		vim.opt.rtp:prepend(deps .. "/plenary.nvim")
		vim.opt.rtp:prepend(deps .. "/telescope.nvim")
		vim.cmd("runtime plugin/telescope.lua")
		require("telescope").setup({})
		require("telescope").load_extension("agent_review")
	]],
		{ vim.fn.getcwd() .. "/deps" }
	)
	child.lua([[require("agent-review").open()]])
	child.cmd("Telescope agent_review")
	child.lua("vim.wait(500, function() return vim.bo.filetype == 'TelescopePrompt' end)")
	eq(child.bo.filetype, "TelescopePrompt")
	child.type_keys("b.lua")
	child.lua("vim.wait(300)")
	child.type_keys("<CR>")
	child.lua("vim.wait(300)")
	eq(right_name(), root .. "/b.lua")
	eq(left_lines(), { "b1", "b2" })
end

return T
