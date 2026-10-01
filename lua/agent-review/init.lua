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

---@param base? string 比較元のrev。省略時はconfig.base
function M.open(base)
	local s = active()
	if s then
		if base == nil or base == s.base then
			api.nvim_set_current_tabpage(s.tab)
			return
		end
		M.close()
	end
	base = base or config.options.base

	local root = detect_root()
	if not root then
		return notify("not inside a git repository", vim.log.levels.ERROR)
	end
	local sha = git.resolve_rev(root, base)
	if not sha then
		return notify("unknown revision: " .. base, vim.log.levels.ERROR)
	end

	highlight.setup()
	local Session = require("agent-review.session")
	s = Session.new(root, base, sha)
	s:refresh_files()
	if #s.files == 0 then
		pcall(api.nvim_del_augroup_by_id, s.augroup)
		return notify("no changes against " .. base)
	end

	local initial = s:rel_path(api.nvim_get_current_buf())
	if not (initial and s:file(initial)) then
		initial = s.files[1].path
	end
	M._session = s
	s:open(initial)
end

function M.close()
	local s = M._session
	M._session = nil
	if s then
		s:close()
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

M.files = with_session(function(s)
	s:pick()
end)

---@param rel string root相対パス
M.show_file = with_session(function(s, rel)
	s:show(rel)
end)

M.refresh = with_session(function(s)
	s:refresh_files()
	vim.cmd("checktime")
	s:sync()
	if vim.wo[s.right_win].diff then
		vim.cmd("diffupdate")
	end
end)

return M
