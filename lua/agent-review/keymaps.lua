local api = vim.api

local M = {}

local function ar()
	return require("agent-review")
end

---@class AgentReviewAction
---@field desc string
---@field mode? string|string[]
---@field fn? fun(session?: AgentReviewSession)
---@field rhs? string 関数ではなくキー列として実行したい場合（コマンドラインに途中まで入力する等）
---@field plug? string

---どのキーにも割り当てられる操作の一覧。<Plug>マッピングもここから生成する。
---@type table<string, AgentReviewAction>
M.actions = {
	toggle = {
		desc = "Toggle review",
		fn = function()
			ar().toggle()
		end,
		plug = "toggle",
	},
	open = {
		desc = "Open review",
		fn = function()
			ar().open()
		end,
		plug = "open",
	},
	open_rev = { desc = "Open review against a revision", rhs = ":AgentReview " },
	pr_list = {
		desc = "Pull requests",
		fn = function()
			ar().pr_list()
		end,
		plug = "pr-list",
	},
	close = {
		desc = "Close review",
		fn = function()
			ar().close()
		end,
		plug = "close",
	},
	files = {
		desc = "Changed files",
		fn = function()
			ar().files()
		end,
		plug = "files",
	},
	hunks = {
		desc = "Changed hunks",
		fn = function()
			ar().hunks()
		end,
		plug = "hunks",
	},
	next_file = {
		desc = "Next changed file",
		fn = function()
			ar().next_file()
		end,
		plug = "next-file",
	},
	prev_file = {
		desc = "Previous changed file",
		fn = function()
			ar().prev_file()
		end,
		plug = "prev-file",
	},
	qf_next = {
		desc = "Next quickfix entry (wraps around)",
		fn = function()
			ar().qf_next()
		end,
		plug = "qf-next",
	},
	qf_prev = {
		desc = "Previous quickfix entry (wraps around)",
		fn = function()
			ar().qf_prev()
		end,
		plug = "qf-prev",
	},
	qf_open = {
		desc = "Open the quickfix entry under the cursor in the review",
		fn = function()
			return ar().qf_open()
		end,
		plug = "qf-open",
	},
	pr_thread = {
		desc = "PR: comments on this line",
		fn = function()
			ar().pr_thread()
		end,
		plug = "pr-thread",
	},
	pr_conversation = {
		desc = "PR: conversation",
		fn = function()
			ar().pr_conversation()
		end,
		plug = "pr-conversation",
	},
	toggle_viewed = {
		desc = "Toggle viewed (reviewed) mark",
		fn = function()
			return ar().toggle_viewed()
		end,
		plug = "toggle-viewed",
	},
	refresh = {
		desc = "Refresh review",
		fn = function()
			ar().refresh()
		end,
		plug = "refresh",
	},
	quickfix_files = {
		desc = "Quickfix: changed files",
		fn = function()
			ar().quickfix("files")
		end,
		plug = "quickfix-files",
	},
	quickfix_hunks = {
		desc = "Quickfix: changed hunks",
		fn = function()
			ar().quickfix("hunks")
		end,
		plug = "quickfix-hunks",
	},
	send_to_claude = {
		desc = "Send base selection to Claude",
		mode = "x",
		fn = function(session)
			session = session or ar()._session
			if session then
				require("agent-review.claude").send_visual(session)
			end
		end,
		plug = "send-to-claude",
	},
}

---@param value string|string[]|false|nil
---@return string[]
function M.lhs_list(value)
	if not value then
		return {}
	end
	if type(value) == "string" then
		return value ~= "" and { value } or {}
	end
	local out = {}
	for _, v in ipairs(value) do
		if type(v) == "string" and v ~= "" then
			table.insert(out, v)
		end
	end
	return out
end

---設定の1エントリを {mode, lhs[], fn, desc} に解決する。
---既知の操作名なら値はキー、未知の名前なら { lhs, fn, desc=, mode= } 形式のカスタム操作として扱う。
---@return { mode: string|string[], lhs: string[], fn?: function, rhs?: string, desc: string }|nil
function M.resolve(name, value)
	local action = M.actions[name]
	if action then
		return {
			mode = action.mode or "n",
			lhs = M.lhs_list(value),
			fn = action.fn,
			rhs = action.rhs,
			desc = action.desc,
		}
	end
	if type(value) == "table" and type(value[2]) == "function" then
		return {
			mode = value.mode or "n",
			lhs = M.lhs_list(value[1]),
			fn = value[2],
			desc = value.desc or name,
		}
	end
	return nil
end

-- 以前のフラットな設定（keymaps.next_file 等）を新しい構造へ移す。
local LEGACY = {
	next_file = "review",
	prev_file = "review",
	files = "review",
	hunks = "review",
	close = "base",
	send_to_claude = "base",
}

---@param km table|false
function M.normalize(km)
	if km == false then
		return false
	end
	km = vim.deepcopy(km or {})
	for name, section in pairs(LEGACY) do
		if km[name] ~= nil then
			km[section] = km[section] or {}
			km[section][name] = km[name]
			km[name] = nil
		end
	end
	return km
end

local global_maps = {}

function M.clear_global()
	for _, m in ipairs(global_maps) do
		pcall(vim.keymap.del, m.mode, m.lhs)
	end
	global_maps = {}
end

---@param km table|false 正規化済みのkeymaps設定
function M.apply_global(km)
	M.clear_global()
	if not km then
		return
	end
	for name, value in pairs(km.global or {}) do
		local spec = M.resolve(name, value)
		if spec then
			for _, lhs in ipairs(spec.lhs) do
				local rhs = spec.rhs or function()
					spec.fn()
				end
				vim.keymap.set(spec.mode, lhs, rhs, { desc = "Agent Review: " .. spec.desc, silent = spec.rhs == nil })
				for _, mode in ipairs(type(spec.mode) == "table" and spec.mode or { spec.mode }) do
					table.insert(global_maps, { mode = mode, lhs = lhs })
				end
			end
		end
	end
end

---<Plug>(agent-review-*) を定義する。setup()を呼ばなくても使えるよう plugin/ から呼ぶ。
function M.define_plugs()
	for _, action in pairs(M.actions) do
		if action.plug and action.fn then
			vim.keymap.set(action.mode or "n", "<Plug>(agent-review-" .. action.plug .. ")", function()
				action.fn()
			end, { desc = "Agent Review: " .. action.desc })
		end
	end
end

---バッファローカルの割り当てが無かった場合と同じ動きをする。
---グローバルの割り当て（flash.nvimの<CR>等）があればそれを、無ければ標準の動きを実行する。
function M.fallthrough(mode, lhs)
	local key = vim.keycode(lhs)
	for _, m in ipairs(api.nvim_get_keymap(mode)) do
		if vim.keycode(m.lhs) == key then
			if m.callback and m.expr ~= 1 then
				return m.callback()
			end
			local rhs = m.callback and m.callback() or (m.expr == 1 and api.nvim_eval(m.rhs) or m.rhs)
			api.nvim_feedkeys(vim.keycode(rhs or ""), m.noremap == 1 and "n" or "m", false)
			return
		end
	end
	api.nvim_feedkeys(key, "n", false)
end

---レビュータブ内のバッファへ設定するキーの一覧。
---@param side "base"|"work"|"quickfix"
---@return { mode: string|string[], lhs: string[], fn: function, desc: string }[]
function M.buffer_specs(km, side)
	if not km then
		return {}
	end
	local specs = {}
	local sections = side == "work" and { "review" } or { "review", side }
	for _, section in ipairs(sections) do
		for name, value in pairs(km[section] or {}) do
			local spec = M.resolve(name, value)
			if spec and spec.fn then
				table.insert(specs, spec)
			end
		end
	end
	return specs
end

return M
