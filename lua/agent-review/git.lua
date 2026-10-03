local M = {}

local function run(cwd, args)
	local res = vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, text = true }):wait()
	return res.code == 0, res.stdout or "", res.stderr or ""
end

local function split_lines(text)
	if text == "" then
		return {}
	end
	local lines = vim.split(text, "\n", { plain = true })
	if lines[#lines] == "" then
		table.remove(lines)
	end
	return lines
end

---@param dir string
---@return string|nil
function M.root(dir)
	if vim.fn.isdirectory(dir) == 0 then
		dir = vim.fs.dirname(dir)
	end
	local ok, out = run(dir, { "rev-parse", "--show-toplevel" })
	if not ok then
		return nil
	end
	return vim.fn.resolve(vim.trim(out))
end

---@return string|nil
function M.git_dir(root)
	local ok, out = run(root, { "rev-parse", "--absolute-git-dir" })
	return ok and vim.fn.resolve(vim.trim(out)) or nil
end

---refsやobjectsがある共通のgitディレクトリ。worktreeでは作業フォルダの外（元リポジトリの.git）になる。
---@return string|nil
function M.common_dir(root)
	local ok, out = run(root, { "rev-parse", "--path-format=absolute", "--git-common-dir" })
	return ok and vim.fn.resolve(vim.trim(out)) or nil
end

---作業ツリーのファイル内容のハッシュ。存在しないファイルはnil。
---@param rels string[] root相対パス
---@return table<string, string>
function M.hash_files(root, rels)
	local present = vim.tbl_filter(function(rel)
		return vim.uv.fs_stat(root .. "/" .. rel) ~= nil
	end, rels)
	if #present == 0 then
		return {}
	end
	local ok, out = run(root, vim.list_extend({ "hash-object", "--" }, present))
	if not ok then
		return {}
	end
	local hashes = {}
	for i, h in ipairs(split_lines(out)) do
		hashes[present[i]] = h
	end
	return hashes
end

---@return string|nil sha
function M.resolve_rev(root, rev)
	local ok, out = run(root, { "rev-parse", "--verify", "--quiet", rev .. "^{commit}" })
	return ok and vim.trim(out) or nil
end

---@class AgentReviewFile
---@field path string root相対パス（変更後）
---@field status "M"|"A"|"D"|"R"|"C"|"T"|"?"
---@field old_path? string リネーム・コピー元

---@return AgentReviewFile[]
function M.changed_files(root, base)
	local files = {}
	-- -zで区切ることで、空白や非ASCIIを含むパスもクォートされずに扱える。
	local ok, out = run(root, { "diff", "--name-status", "-z", "-M", base, "--" })
	if ok then
		local fields = vim.split(out, "\0", { plain = true })
		local i = 1
		while i <= #fields and fields[i] ~= "" do
			local status = fields[i]:sub(1, 1)
			if status == "R" or status == "C" then
				table.insert(files, { status = status, old_path = fields[i + 1], path = fields[i + 2] })
				i = i + 3
			else
				table.insert(files, { status = status, path = fields[i + 1] })
				i = i + 2
			end
		end
	end

	local ok_u, out_u = run(root, { "ls-files", "--others", "--exclude-standard", "-z" })
	if ok_u then
		for _, path in ipairs(vim.split(out_u, "\0", { plain = true })) do
			if path ~= "" then
				table.insert(files, { status = "?", path = path })
			end
		end
	end

	table.sort(files, function(a, b)
		return a.path < b.path
	end)
	return files
end

---@return string[]|nil base時点に存在しなければnil
function M.show(root, base, path)
	local ok, out = run(root, { "show", base .. ":" .. path })
	if not ok then
		return nil
	end
	return split_lines(out)
end

return M
