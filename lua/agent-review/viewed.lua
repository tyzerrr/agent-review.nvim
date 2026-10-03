local git = require("agent-review.git")

-- レビュー済み（viewed）の印。GitHubのPR画面の "Viewed" と同じく、印を付けた時のファイル内容を覚えておき、
-- 内容が変わったら印を外す。レビューを開き直しても残るよう .git/agent-review/viewed.json に保存する。
local M = {}

-- 削除されたファイルは内容が無いので、この値で「削除された状態を見た」ことを表す。
local DELETED = "deleted"

---@return string|nil
function M.path(root)
	local dir = git.git_dir(root)
	return dir and (dir .. "/agent-review/viewed.json") or nil
end

---@return table<string, string> rel -> 印を付けた時の内容のハッシュ
function M.load(path)
	if not (path and vim.uv.fs_stat(path)) then
		return {}
	end
	local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
	return ok and type(data) == "table" and data or {}
end

function M.save(path, marks)
	if not path then
		return
	end
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	-- 空のテーブルは "[]" になるので、読み込み側と形を揃えるため明示的にオブジェクトにする。
	vim.fn.writefile({ next(marks) and vim.json.encode(marks) or "{}" }, path)
end

---@param rels string[]
---@return table<string, string>
function M.fingerprints(root, rels)
	local hashes = git.hash_files(root, rels)
	for _, rel in ipairs(rels) do
		hashes[rel] = hashes[rel] or DELETED
	end
	return hashes
end

return M
