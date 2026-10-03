local paths = require("agent-review.pr.paths")

-- GitHubの応答のキャッシュ。今はキーごとのJSONファイルだが、後でSQLiteへ差し替えられるよう
-- 外からは get/put だけを使う。
local M = {}

---@class AgentReviewStoreEntry
---@field value any
---@field etag? string
---@field fetched_at integer os.time()

local function file(key)
	-- キーは "/" 区切りでディレクトリにする。".." 等でcacheの外に出ないよう、各要素を安全な文字に置き換える。
	local parts = {}
	for segment in key:gmatch("[^/]+") do
		segment = segment:gsub("[^%w%._%-#@]", "_")
		if segment:match("^%.+$") then
			segment = segment:gsub("%.", "_")
		end
		table.insert(parts, segment)
	end
	return paths.state_root() .. "/cache/" .. table.concat(parts, "/") .. ".json"
end

---@return AgentReviewStoreEntry|nil
function M.get(key)
	local path = file(key)
	if vim.fn.filereadable(path) == 0 then
		return nil
	end
	local ok, entry = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
	if not (ok and type(entry) == "table" and entry.fetched_at) then
		return nil
	end
	if entry.etag == vim.NIL then
		entry.etag = nil
	end
	return entry
end

---@param meta? { etag?: string }
function M.put(key, value, meta)
	local path = file(key)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	local data = vim.json.encode({ value = value, etag = (meta or {}).etag, fetched_at = os.time() })
	-- 書き込み途中で落ちても壊れたJSONを残さないよう、一時ファイルに書いてから置き換える。
	local tmp = ("%s.tmp.%d.%d"):format(path, vim.fn.getpid(), vim.uv.hrtime())
	vim.fn.writefile({ data }, tmp)
	local ok, err = vim.uv.fs_rename(tmp, path)
	if not ok then
		vim.uv.fs_unlink(tmp)
		error(err)
	end
end

return M
