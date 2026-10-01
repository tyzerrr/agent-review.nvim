local config = require("agent-review.config")
local git = require("agent-review.git")
local highlight = require("agent-review.highlight")

local api = vim.api

local M = {}

---@type AgentReviewSession|nil
M._session = nil

local function notify(msg, level)
	vim.notify("[agent-review] " .. msg, level or vim.log.levels.INFO)
end

function M.setup(opts)
	config.setup(opts)
	highlight.setup()
	require("agent-review.keymaps").apply_global(config.options.keymaps)
end

local function emit(event, s)
	api.nvim_exec_autocmds("User", {
		pattern = event,
		modeline = false,
		data = {
			root = s.root,
			base = s.base,
			base_sha = s.base_sha,
			tab = s.tab,
			left_win = s.left_win,
			right_win = s.right_win,
		},
	})
end

local function active()
	local s = M._session
	if s and s:valid() then
		return s
	end
	if s then
		M._session = nil
		s:close()
	end
	return nil
end

local function detect_root()
	local name = api.nvim_buf_get_name(0)
	if name ~= "" and vim.bo.buftype == "" then
		local root = git.root(vim.fs.dirname(vim.fn.fnamemodify(name, ":p")))
		if root then
			return root
		end
	end
	return git.root(vim.fn.getcwd())
end

---比較に必要な情報を解決する。セッションが無くてもピッカー等から使えるようにしている。
---@return { root: string, base: string, base_sha: string }|nil, string|nil err
function M.resolve(base)
	base = base or config.options.base
	local root = detect_root()
	if not root then
		return nil, "not inside a git repository"
	end
	local sha = git.resolve_rev(root, base)
	if not sha then
		return nil, "unknown revision: " .. base
	end
	return { root = root, base = base, base_sha = sha }
end

---@param base? string 比較元のrev。省略時はconfig.base
---@param opts? { path?: string } 最初に表示するroot相対パス
function M.open(base, opts)
	opts = opts or {}
	local s = active()
	if s then
		if base == nil or base == s.base then
			api.nvim_set_current_tabpage(s.tab)
			if opts.path then
				s:show(opts.path)
			end
			return
		end
		M.close()
	end

	local ctx, err = M.resolve(base)
	if not ctx then
		return notify(err, vim.log.levels.ERROR)
	end

	highlight.setup()
	local Session = require("agent-review.session")
	s = Session.new(ctx.root, ctx.base, ctx.base_sha)
	s:refresh_files()
	if #s.files == 0 then
		pcall(api.nvim_del_augroup_by_id, s.augroup)
		return notify("no changes against " .. ctx.base)
	end

	local initial = opts.path or s:rel_path(api.nvim_get_current_buf())
	if not (initial and (opts.path or s:file(initial))) then
		initial = s.files[1].path
	end
	M._session = s
	s:open(initial)
	emit("AgentReviewOpen", s)
end

---レビューを（必要なら開いて）指定ファイル・行へ移動する。ピッカーからの遷移先。
---@param rel string root相対パス
---@param lnum? integer
function M.open_at(rel, lnum)
	M.open(nil, { path = rel })
	local s = active()
	if not s then
		return
	end
	api.nvim_set_current_win(s.right_win)
	if lnum then
		local last = api.nvim_buf_line_count(api.nvim_win_get_buf(s.right_win))
		pcall(api.nvim_win_set_cursor, s.right_win, { math.min(math.max(lnum, 1), last), 0 })
		vim.cmd("normal! zz")
	end
end

function M.close()
	local s = M._session
	M._session = nil
	if s and not s.closed then
		s:close()
		emit("AgentReviewClose", s)
	end
end

function M.toggle(base)
	if active() then
		M.close()
	else
		M.open(base)
	end
end

local function with_session(fn)
	return function(...)
		local s = active()
		if not s then
			return notify("no active review session", vim.log.levels.WARN)
		end
		return fn(s, ...)
	end
end

M.next_file = with_session(function(s)
	s:step(1)
end)

M.prev_file = with_session(function(s)
	s:step(-1)
end)

function M.files()
	require("agent-review.picker").pick()
end

function M.hunks()
	require("agent-review.picker").pick_hunks()
end

---@param mode? "files"|"hunks"
M.quickfix = with_session(function(s, mode)
	s:refresh_files()
	s:update_quickfix(mode)
	s:open_quickfix_window()
end)

---@param rel string root相対パス
M.show_file = with_session(function(s, rel)
	s:show(rel)
end)

M.refresh = with_session(function(s)
	s:refresh_files()
	if s.qf_id then
		s:update_quickfix()
	end
	vim.cmd("checktime")
	s:sync()
	if vim.wo[s.right_win].diff then
		vim.cmd("diffupdate")
	end
end)

return M
