local config = require("agent-review.config")
local store = require("agent-review.pr.store")

-- gh CLI の非同期呼び出し。ネットワーク待ちでNeovimを固めないよう、結果はすべてコールバックで返す。
-- 認証は gh に任せ、トークンは扱わない。
local M = {}

---@class AgentReviewGhError
---@field kind "missing"|"auth"|"api"|"graphql"|"parse"
---@field message string
---@field status? integer HTTPステータス（kind = "api" の時）

local function executable()
	return (config.options.pr or {}).gh or "gh"
end

---@return AgentReviewGhError
local function classify(stderr)
	stderr = vim.trim(stderr or "")
	if stderr:find("gh auth login", 1, true) then
		return { kind = "auth", message = "gh is not logged in. Run `gh auth login`.\n" .. stderr }
	end
	return { kind = "api", message = stderr ~= "" and stderr or "gh failed" }
end

---@param args string[]
---@param opts { stdin?: string }
---@param cb fun(err: AgentReviewGhError|nil, stdout: string, code: integer)
function M.run(args, opts, cb)
	local exe = executable()
	if vim.fn.executable(exe) == 0 then
		return vim.schedule(function()
			cb({ kind = "missing", message = ("gh CLI not found (%s). Install it from https://cli.github.com"):format(exe) }, "", -1)
		end)
	end
	vim.system(vim.list_extend({ exe }, args), { text = true, stdin = opts.stdin }, function(res)
		vim.schedule(function()
			if res.code ~= 0 then
				return cb(classify(res.stderr), res.stdout or "", res.code)
			end
			cb(nil, res.stdout or "", 0)
		end)
	end)
end

local function decode(text)
	local ok, data = pcall(vim.json.decode, text ~= "" and text or "null", { luanil = { object = true, array = true } })
	if not ok then
		return nil, { kind = "parse", message = "gh returned invalid JSON: " .. tostring(data) }
	end
	return data
end

---gh を実行して標準出力をJSONとして返す。
---@param cb fun(err: AgentReviewGhError|nil, data: any)
function M.json(args, cb)
	M.run(args, {}, function(err, out)
		if err then
			return cb(err)
		end
		local data, perr = decode(out)
		cb(perr, data)
	end)
end

---@param cb fun(err: AgentReviewGhError|nil, data: any)
---@param opts? { hostname?: string } GitHub Enterprise のホスト
function M.graphql(query, variables, cb, opts)
	local body = vim.json.encode({ query = query, variables = vim.tbl_isempty(variables or {}) and vim.empty_dict() or variables })
	local args = { "api", "graphql", "--input", "-" }
	local host = (opts or {}).hostname
	if host and host ~= "github.com" then
		vim.list_extend(args, { "--hostname", host })
	end
	M.run(args, { stdin = body }, function(err, out)
		local data, perr = decode(out)
		-- GraphQLのエラーは本文の errors に入り、gh の終了コードだけでは中身がわからない。
		if data and data.errors and data.errors[1] then
			return cb({ kind = "graphql", message = data.errors[1].message or "GraphQL error" })
		end
		if err then
			return cb(err)
		end
		cb(perr, data and data.data)
	end)
end

---`gh api -i` の出力をステータス・ヘッダ・本文に分ける。
local function parse_response(out)
	local status = tonumber(out:match("^HTTP/[%d.]+ (%d+)"))
	if not status then
		return nil
	end
	local head, body = out:match("^(.-)\r?\n\r?\n(.*)$")
	head, body = head or out, body or ""
	local headers = {}
	for line in head:gmatch("[^\r\n]+") do
		local k, v = line:match("^([%w-]+):%s*(.*)$")
		if k then
			headers[k:lower()] = v
		end
	end
	return { status = status, headers = headers, body = body }
end

---@class AgentReviewRestResponse
---@field status integer
---@field etag? string
---@field body any 304なら nil
---@field not_modified boolean

---REST APIを呼ぶ。etag を渡すと If-None-Match を付け、変わっていなければ not_modified を返す
---（304はGitHubのレート制限に数えられない）。
---@param opts { etag?: string }
---@param cb fun(err: AgentReviewGhError|nil, res: AgentReviewRestResponse|nil)
function M.rest(path, opts, cb)
	local args = { "api", "-i", path }
	if opts.etag then
		vim.list_extend(args, { "-H", "If-None-Match: " .. opts.etag })
	end
	M.run(args, {}, function(err, out)
		-- gh は304でも終了コード1を返すので、終了コードではなくステータス行で判断する。
		local res = parse_response(out)
		if not res then
			return cb(err or { kind = "parse", message = "unexpected gh output" })
		end
		if res.status == 304 then
			return cb(nil, { status = 304, etag = opts.etag, not_modified = true })
		end
		local body, perr = decode(res.body)
		if res.status >= 300 then
			local message = type(body) == "table" and body.message or (err and err.message) or ("HTTP " .. res.status)
			return cb({ kind = "api", status = res.status, message = message })
		end
		if perr then
			return cb(perr)
		end
		cb(nil, { status = res.status, etag = res.headers.etag, body = body, not_modified = false })
	end)
end

---キャッシュ付きのREST呼び出し。前回のETagで問い合わせ、変わっていなければキャッシュを返す。
---@param key string キャッシュのキー（例: "github.com/o/r/pulls/12"）
---@param cb fun(err: AgentReviewGhError|nil, body: any, info: { from_cache: boolean })
function M.rest_cached(key, path, cb)
	local cached = store.get(key)
	M.rest(path, { etag = cached and cached.etag }, function(err, res)
		if err then
			return cb(err)
		end
		if res.not_modified and cached then
			return cb(nil, cached.value, { from_cache = true })
		end
		store.put(key, res.body, { etag = res.etag })
		cb(nil, res.body, { from_cache = false })
	end)
end

return M
