local config = require("agent-review.config")
local git = require("agent-review.git")
local paths = require("agent-review.pr.paths")

local M = {}

---@class AgentReviewRepo
---@field root string ローカルのリポジトリのルート
---@field url string リモートのURL
---@field host string
---@field owner string
---@field name string
---@field nwo string "owner/name"
---@field key string "github.com/owner/name"（キャッシュや置き場所のキー）

---ディレクトリが属するリポジトリと、PRを探すGitHubのリポジトリを決める。
---@return AgentReviewRepo|nil, string|nil err
function M.detect(dir)
	local root = git.root(dir or vim.fn.getcwd())
	if not root then
		return nil, "not inside a git repository"
	end
	local remote = (config.options.pr or {}).remote or "origin"
	local res = vim.system({ "git", "remote", "get-url", remote }, { cwd = root, text = true }):wait()
	if res.code ~= 0 then
		return nil, ("no git remote '%s' (set pr.remote)"):format(remote)
	end
	local url = vim.trim(res.stdout)
	local host, path = paths.parse(url)
	local owner, name = (path or ""):match("^([^/]+)/([^/]+)$")
	if not (host and owner) then
		return nil, ("remote '%s' is not a GitHub repository: %s"):format(remote, url)
	end
	return {
		root = root,
		url = url,
		host = host,
		owner = owner,
		name = name,
		nwo = owner .. "/" .. name,
		key = host .. "/" .. owner .. "/" .. name,
	}
end

return M
