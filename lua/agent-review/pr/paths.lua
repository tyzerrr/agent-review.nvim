local config = require("agent-review.config")

-- PRレビュー用のファイルの置き場所。ユーザーのリポジトリ（.git を含む）には何も置かず、
-- ghq と同じ「ホスト/オーナー/リポジトリ」の形で state ディレクトリの下に分ける。
local M = {}

---@return string|nil host, string|nil path "owner/repo"
function M.parse(url)
	url = vim.trim(url or "")
	local host, path = url:match("^%a[%w+.-]*://([^/]+)/(.+)$")
	if host then
		host = host:gsub("^.*@", ""):gsub(":%d+$", "")
	else
		-- scp形式: git@github.com:owner/repo.git
		host, path = url:match("^[^@/:]+@([^:/]+):(.+)$")
	end
	if not (host and path) then
		return nil
	end
	path = path:gsub("/+$", ""):gsub("%.git$", ""):gsub("^/+", "")
	for segment in path:gmatch("[^/]+") do
		if segment == "." or segment == ".." then
			return nil
		end
	end
	if not path:find("/") then
		return nil
	end
	return host, path
end

---@return string|nil "github.com/owner/repo"
function M.repo_key(url)
	local host, path = M.parse(url)
	return host and (host .. "/" .. path) or nil
end

function M.state_root()
	local dir = (config.options.pr or {}).state_dir
	if dir then
		return vim.fs.normalize(dir)
	end
	local xdg = vim.env.XDG_STATE_HOME
	if xdg and xdg ~= "" then
		return vim.fs.normalize(xdg) .. "/agent-review"
	end
	return vim.fs.normalize("~/.local/state/agent-review")
end

---リポジトリのキー（"github.com/owner/name"）から各ディレクトリを返す。
---@return { repo: string, mirror: string, pr: fun(number: integer): string }
function M.for_key(key)
	local dir = M.state_root() .. "/" .. key
	return {
		repo = dir,
		mirror = dir .. "/repo.git",
		pr = function(number)
			return dir .. "/" .. number
		end,
	}
end

---@return string|nil
function M.repo_dir(url)
	local key = M.repo_key(url)
	return key and (M.state_root() .. "/" .. key) or nil
end

---リポジトリごとの専用の複製（bare）。PRのworktreeはここから作る。
function M.mirror_dir(url)
	local dir = M.repo_dir(url)
	return dir and (dir .. "/repo.git") or nil
end

---@param number integer PR番号
function M.pr_dir(url, number)
	local dir = M.repo_dir(url)
	return dir and (dir .. "/" .. number) or nil
end

return M
