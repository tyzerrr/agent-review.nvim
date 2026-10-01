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
	local root = H.make_repo({ ["a.lua"] = { "one", "two", "three", "four" } })
	H.write(root, "a.lua", { "one", "TWO", "three", "four", "five" })
	child.lua("vim.cmd.cd(...)", { root })
	child.lua([[require("agent-review").open()]])
	return root
end

local function widths()
	return child.lua([[
		local s = require("agent-review")._session
		return { vim.api.nvim_win_get_width(s.left_win), vim.api.nvim_win_get_width(s.right_win) }
	]])
end

local function open_fake_claude(width)
	child.lua(
		[[
		vim.cmd("botright vsplit")
		vim.cmd.terminal("sleep 100")
		vim.api.nvim_buf_set_name(0, "term://claude-fake")
		vim.cmd("vertical resize " .. ...)
	]],
		{ width }
	)
	child.lua("vim.wait(100)")
end

T["resize"] = MiniTest.new_set()

T["resize"]["re-balances the diff windows when a Claude terminal opens"] = function()
	setup_repo()
	open_fake_claude(60)
	local w = widths()
	eq(math.abs(w[1] - w[2]) <= 1, true)
	-- 200列 - 60列(claude) - 区切り2本 を左右で分ける
	eq(w[1] + w[2], 200 - 60 - 2)
	eq(child.lua_get("vim.api.nvim_win_get_width(0)"), 60)
end

T["resize"]["re-balances when the Claude terminal is resized or closed"] = function()
	setup_repo()
	open_fake_claude(60)
	child.lua([[vim.api.nvim_win_set_width(0, 100)]])
	child.lua([[vim.api.nvim__redraw({ flush = true })]])
	child.lua("vim.wait(100)")
	local w = widths()
	eq(math.abs(w[1] - w[2]) <= 1, true)
	child.lua([[vim.api.nvim_win_close(0, true)]])
	child.lua("vim.wait(100)")
	w = widths()
	eq(math.abs(w[1] - w[2]) <= 1, true)
	eq(w[1] + w[2], 199)
end

T["resize"]["respects manual resizing of the diff windows"] = function()
	setup_repo()
	child.lua([[vim.api.nvim_win_set_width(require("agent-review")._session.left_win, 50)]])
	child.lua([[vim.api.nvim__redraw({ flush = true })]])
	child.lua("vim.wait(100)")
	eq(widths()[1], 50)
end

T["claude"] = MiniTest.new_set()

local function mock_claudecode()
	child.lua([[
		_G.sent = {}
		package.loaded.claudecode = {
			send_at_mention = function(path, s, e, ctx)
				table.insert(_G.sent, { path = path, s = s, e = e, ctx = ctx })
				return true
			end,
		}
	]])
end

T["claude"]["<C-l> on the base side sends the selection as a file mention"] = function()
	local root = setup_repo()
	mock_claudecode()
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.left_win)]])
	child.type_keys("gg", "j", "V", "j", "<C-l>")
	local sent = child.lua_get("_G.sent")
	eq(#sent, 1)
	eq(sent[1].s, 1)
	eq(sent[1].e, 2)
	local sha = vim.trim(H.git(root, { "rev-parse", "HEAD" })):sub(1, 8)
	eq(sent[1].path, root .. "/.git/agent-review/base-" .. sha .. "/a.lua")
	eq(vim.fn.readfile(sent[1].path), { "one", "two", "three", "four" })
	eq(child.fn.mode(), "n")
end

T["claude"]["focuses the Claude terminal after sending"] = function()
	setup_repo()
	open_fake_claude(60)
	mock_claudecode()
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.left_win)]])
	child.type_keys("V", "<C-l>")
	child.lua("vim.wait(50)")
	eq(child.lua_get([[vim.api.nvim_buf_get_name(0):match("claude") ~= nil]]), true)
end

T["claude"]["warns when claudecode.nvim is not installed"] = function()
	setup_repo()
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.left_win)]])
	child.lua([[_G.notes = {}; vim.notify = function(m) table.insert(_G.notes, m) end]])
	child.type_keys("V", "<C-l>")
	eq(child.lua_get("_G.notes[1]:match('claudecode') ~= nil"), true)
end

T["claude"]["does not touch the working side's existing <C-l> mapping"] = function()
	setup_repo()
	child.lua([[vim.keymap.set("x", "<C-l>", "<cmd>let g:global_cl = 1<cr>")]])
	child.type_keys("V", "<C-l>")
	eq(child.g.global_cl, 1)
end

T["claude terminal"] = MiniTest.new_set()

-- claudecode.terminalのタブを区別しない可視判定を再現するモック（外部依存）。
local function mock_claude_terminal()
	child.lua([[
		local buf
		local function wins() return buf and vim.fn.win_findbuf(buf) or {} end
		package.loaded["claudecode.terminal"] = {
			get_active_terminal_bufnr = function() return buf end,
			simple_toggle = function()
				if #wins() > 0 then
					for _, w in ipairs(wins()) do vim.api.nvim_win_close(w, true) end
				else
					local cur = vim.api.nvim_get_current_win()
					vim.cmd("botright 60vsplit")
					vim.api.nvim_win_set_buf(0, buf)
					vim.api.nvim_set_current_win(cur)
				end
			end,
			ensure_visible = function()
				if #wins() == 0 then package.loaded["claudecode.terminal"].simple_toggle() end
			end,
		}
		package.loaded.claudecode = { send_at_mention = function() return true end }
		vim.cmd("botright 60vsplit")
		vim.cmd.terminal("sleep 100")
		vim.api.nvim_buf_set_name(0, "term://claude-fake")
		buf = vim.api.nvim_get_current_buf()
		vim.cmd("wincmd p")
	]])
end

local function claude_tabs()
	return child.lua([[
		local buf = package.loaded["claudecode.terminal"].get_active_terminal_bufnr()
		return vim.tbl_map(function(w) return vim.api.nvim_tabpage_get_number(vim.api.nvim_win_get_tabpage(w)) end, vim.fn.win_findbuf(buf))
	]])
end

T["claude terminal"]["is brought into the review tab and balanced"] = function()
	local root = H.make_repo({ ["a.lua"] = { "x" } })
	H.write(root, "a.lua", { "y" })
	child.lua("vim.cmd.cd(...)", { root })
	mock_claude_terminal()
	eq(claude_tabs(), { 1 })
	child.lua([[require("agent-review").open()]])
	child.lua("vim.wait(100)")
	eq(claude_tabs(), { 2 })
	local w = widths()
	eq(math.abs(w[1] - w[2]) <= 1, true)
	eq(child.lua_get([[vim.api.nvim_get_current_win() == require("agent-review")._session.right_win]]), true)
end

T["claude terminal"]["is restored to the original tab on close"] = function()
	local root = H.make_repo({ ["a.lua"] = { "x" } })
	H.write(root, "a.lua", { "y" })
	child.lua("vim.cmd.cd(...)", { root })
	mock_claude_terminal()
	child.lua([[require("agent-review").open()]])
	child.lua("vim.wait(100)")
	child.lua([[require("agent-review").close()]])
	child.lua("vim.wait(100)")
	eq(claude_tabs(), { 1 })
end

T["claude terminal"]["opened inside the review tab survives close"] = function()
	local root = H.make_repo({ ["a.lua"] = { "x" } })
	H.write(root, "a.lua", { "y" })
	child.lua("vim.cmd.cd(...)", { root })
	child.lua([[require("agent-review").open()]])
	mock_claude_terminal()
	eq(claude_tabs(), { 2 })
	child.lua([[require("agent-review").close()]])
	child.lua("vim.wait(100)")
	eq(claude_tabs(), { 1 })
	eq(child.lua_get("vim.api.nvim_get_current_tabpage()"), child.lua_get("vim.api.nvim_list_tabpages()[1]"))
end

T["claude terminal"]["stays visible across toggling the review off and on"] = function()
	local root = H.make_repo({ ["a.lua"] = { "x" } })
	H.write(root, "a.lua", { "y" })
	child.lua("vim.cmd.cd(...)", { root })
	child.lua([[require("agent-review").toggle()]])
	mock_claude_terminal()
	child.lua([[require("agent-review").toggle()]])
	child.lua("vim.wait(100)")
	eq(claude_tabs(), { 1 })
	child.lua([[require("agent-review").toggle()]])
	child.lua("vim.wait(100)")
	eq(claude_tabs(), { 2 })
	child.lua([[require("agent-review").toggle()]])
	child.lua("vim.wait(100)")
	eq(claude_tabs(), { 1 })
end

T["claude terminal"]["is left alone when it was hidden"] = function()
	local root = H.make_repo({ ["a.lua"] = { "x" } })
	H.write(root, "a.lua", { "y" })
	child.lua("vim.cmd.cd(...)", { root })
	mock_claude_terminal()
	child.lua([[package.loaded["claudecode.terminal"].simple_toggle()]])
	eq(claude_tabs(), {})
	child.lua([[require("agent-review").open()]])
	child.lua("vim.wait(100)")
	eq(claude_tabs(), {})
	child.lua([[require("agent-review").close()]])
	child.lua("vim.wait(100)")
	eq(claude_tabs(), {})
end

T["other windows"] = MiniTest.new_set()

local function tab_buf_names()
	return child.lua([[
		return vim.tbl_map(function(w)
			return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
		end, vim.api.nvim_tabpage_list_wins(0))
	]])
end

T["other windows"]["opened in the review tab are moved back on close"] = function()
	local root = H.make_repo({ ["a.lua"] = { "x" } })
	H.write(root, "a.lua", { "y" })
	H.write(root, "notes.md", { "memo" })
	child.lua("vim.cmd.cd(...)", { root })
	child.lua([[require("agent-review").open()]])
	child.cmd("botright 40vsplit " .. root .. "/notes.md")
	child.lua([[require("agent-review").close()]])
	child.lua("vim.wait(100)")
	eq(child.lua_get("#vim.api.nvim_list_tabpages()"), 1)
	local names = tab_buf_names()
	eq(vim.tbl_contains(names, root .. "/notes.md"), true)
	eq(child.lua_get([[vim.fn.winwidth(vim.fn.bufwinid(...))]], { root .. "/notes.md" }), 40)
end

T["other windows"]["review-owned windows are not carried over"] = function()
	local root = H.make_repo({ ["a.lua"] = { "x" } })
	H.write(root, "a.lua", { "y" })
	child.lua("vim.cmd.cd(...)", { root })
	child.lua([[require("agent-review").open()]])
	eq(child.lua_get([[vim.fn.getqflist({ winid = 0 }).winid ~= 0]]), true)
	child.lua([[require("agent-review").close()]])
	child.lua("vim.wait(100)")
	eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), 1)
	eq(child.lua_get([[vim.fn.getqflist({ winid = 0 }).winid]]), 0)
end

return T
