local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality
local child = H.new_child()

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.setup()
			child.g.mapleader = " "
		end,
		post_once = child.stop,
	},
})

local function setup_repo()
	local root = H.make_repo({ ["a.lua"] = { "a" }, ["b.lua"] = { "b" }, ["c.lua"] = { "c" } })
	H.write(root, "a.lua", { "A" })
	H.write(root, "b.lua", { "B" })
	H.write(root, "c.lua", { "C" })
	child.lua("vim.cmd.cd(...)", { root })
	return root
end

local function setup(opts)
	child.lua([[require("agent-review").setup(...)]], { opts or {} })
end

local function has_map(lhs, mode, buffer_local)
	return child.lua(
		[[
		local lhs, mode, buffer_local = ...
		local m = vim.fn.maparg(lhs, mode, false, true)
		if vim.tbl_isempty(m) then return false end
		if buffer_local ~= nil then return (m.buffer == 1) == buffer_local end
		return true
	]],
		{ lhs, mode or "n", buffer_local }
	)
end

local function right_name()
	return child.lua_get(
		[[vim.fs.basename(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(require("agent-review")._session.right_win)))]]
	)
end

T["global"] = MiniTest.new_set()

T["global"]["defaults are mapped by setup()"] = function()
	setup()
	for _, lhs in ipairs({ "<leader>dr", "<leader>dR", "<leader>dl", "<leader>dh" }) do
		eq({ lhs, has_map(lhs, "n", false) }, { lhs, true })
	end
end

T["global"]["are not mapped without setup()"] = function()
	eq(has_map("<leader>dr"), false)
end

T["global"]["can be remapped, disabled and given several keys"] = function()
	setup({ keymaps = { global = { toggle = { "<leader>rr", "<F5>" }, files = false } } })
	eq(has_map("<leader>rr"), true)
	eq(has_map("<F5>"), true)
	eq(has_map("<leader>dr"), false)
	eq(has_map("<leader>dl"), false)
	eq(has_map("<leader>dh"), true)
end

T["global"]["calling setup() again replaces previous mappings"] = function()
	setup()
	setup({ keymaps = { global = { toggle = "<leader>rr" } } })
	eq(has_map("<leader>dr"), false)
	eq(has_map("<leader>rr"), true)
end

T["global"]["keymaps = false disables every mapping"] = function()
	setup_repo()
	setup({ keymaps = false })
	eq(has_map("<leader>dr"), false)
	child.lua([[require("agent-review").open()]])
	eq(has_map("]f", "n", true), false)
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.left_win)]])
	eq(has_map("q", "n", true), false)
end

T["global"]["toggle key opens and closes the review"] = function()
	setup_repo()
	setup()
	child.type_keys(" dr")
	eq(child.lua_get([[require("agent-review")._session ~= nil]]), true)
	child.type_keys(" dr")
	eq(child.lua_get([[require("agent-review")._session]]), vim.NIL)
end

T["review"] = MiniTest.new_set()

T["review"]["default review keys are buffer-local on both sides"] = function()
	setup_repo()
	setup()
	child.lua([[require("agent-review").open()]])
	eq(has_map("]f", "n", true), true)
	eq(has_map("[f", "n", true), true)
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.left_win)]])
	eq(has_map("]f", "n", true), true)
	eq(has_map("q", "n", true), true)
	eq(has_map("<C-l>", "x", true), true)
end

T["review"]["remapped keys work and the old ones are not set"] = function()
	setup_repo()
	setup({ keymaps = { review = { next_file = { "<Tab>", "gn" } }, base = { close = "Q" } } })
	child.lua([[require("agent-review").open()]])
	eq(right_name(), "a.lua")
	child.type_keys("<Tab>")
	eq(right_name(), "b.lua")
	child.type_keys("gn")
	eq(right_name(), "c.lua")
	eq(has_map("]f", "n", true), false)
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.left_win)]])
	eq(has_map("q", "n", true), false)
	child.type_keys("Q")
	child.lua("vim.wait(50)")
	eq(child.lua_get([[require("agent-review")._session]]), vim.NIL)
end

T["review"]["custom actions receive the session"] = function()
	local root = setup_repo()
	child.lua([[require("agent-review").setup({
		keymaps = {
			review = {
				where = { "gW", function(session) vim.g.custom_root = session.root end, desc = "custom" },
			},
		},
	})]])
	child.lua([[require("agent-review").open()]])
	child.type_keys("gW")
	eq(child.g.custom_root, root)
end

T["review"]["old flat keymaps config is still accepted"] = function()
	setup_repo()
	setup({ keymaps = { next_file = "gn", close = "Q" } })
	child.lua([[require("agent-review").open()]])
	child.type_keys("gn")
	eq(right_name(), "b.lua")
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.left_win)]])
	eq(has_map("Q", "n", true), true)
end

T["plug"] = MiniTest.new_set()

T["plug"]["<Plug> mappings are available without setup()"] = function()
	setup_repo()
	child.lua([[vim.keymap.set("n", "<F6>", "<Plug>(agent-review-toggle)")]])
	child.lua([[vim.keymap.set("n", "<F7>", "<Plug>(agent-review-next-file)")]])
	child.type_keys("<F6>")
	eq(right_name(), "a.lua")
	child.type_keys("<F7>")
	eq(right_name(), "b.lua")
end

T["events"] = MiniTest.new_set()

T["events"]["User AgentReviewOpen/Close fire with session data"] = function()
	local root = setup_repo()
	child.lua([[
		_G.events = {}
		vim.api.nvim_create_autocmd("User", {
			pattern = { "AgentReviewOpen", "AgentReviewClose" },
			callback = function(a) table.insert(_G.events, { a.match, a.data and a.data.root }) end,
		})
	]])
	child.lua([[require("agent-review").open()]])
	child.lua([[require("agent-review").close()]])
	eq(child.lua_get("_G.events"), { { "AgentReviewOpen", root }, { "AgentReviewClose", root } })
end

T["readme"] = MiniTest.new_set()

T["readme"]["the customizing example from README works"] = function()
	setup_repo()
	child.lua([[require("agent-review").setup({
		keymaps = {
			global = {
				toggle = "<leader>gr",
				open_rev = false,
				files = { "<leader>df", "<F7>" },
				hunks = "<leader>dh",
			},
			review = {
				next_file = { "]f", "<Tab>" },
				prev_file = { "[f", "<S-Tab>" },
				refresh = "<leader>du",
				quickfix_hunks = "<leader>dq",
				copy_base_path = {
					"<leader>dy",
					function(session)
						vim.fn.setreg("a", session.root .. " @ " .. session.base_sha)
					end,
					desc = "Copy review base",
				},
			},
			base = {
				close = { "q", "<Esc>" },
				send_to_claude = "<C-l>",
			},
		},
	})]])
	eq(has_map("<leader>gr"), true)
	eq(has_map("<leader>dR"), false)
	eq(has_map("<F7>"), true)
	child.type_keys(" gr")
	for _, lhs in ipairs({ "<Tab>", "<S-Tab>", "<leader>du", "<leader>dq", "<leader>dy" }) do
		eq({ lhs, has_map(lhs, "n", true) }, { lhs, true })
	end
	child.type_keys(" dy")
	eq(child.fn.getreg("a"):match(" @ %x+$") ~= nil, true)
	child.type_keys(" dq")
	eq(child.lua_get([[vim.fn.getqflist({ title = 1 }).title]]), "Agent Review: HEAD (hunks)")
	child.lua([[vim.api.nvim_set_current_win(require("agent-review")._session.left_win)]])
	child.type_keys("<Esc>")
	child.lua("vim.wait(50)")
	eq(child.lua_get([[require("agent-review")._session]]), vim.NIL)
end

T["readme"]["the keymaps = false + <Plug> example from README works"] = function()
	setup_repo()
	child.lua([[
		require("agent-review").setup({ keymaps = false })
		vim.keymap.set("n", "<leader>r", "<Plug>(agent-review-toggle)")
		vim.keymap.set("n", "<Tab>", function() require("agent-review").next_file() end)
	]])
	child.type_keys(" r")
	eq(right_name(), "a.lua")
	child.type_keys("<Tab>")
	eq(right_name(), "b.lua")
end

return T
