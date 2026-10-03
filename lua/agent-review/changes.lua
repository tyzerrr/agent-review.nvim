local git = require("agent-review.git")

local M = {}

M.STATUS_LABELS = {
	M = "modified",
	A = "added",
	D = "deleted",
	R = "renamed",
	C = "copied",
	T = "type",
	["?"] = "untracked",
}

-- 巨大なファイルや生成物でdiff計算が固まらないようにする。
local MAX_BYTES = 2 * 1024 * 1024

local function to_text(lines)
	if #lines == 0 then
		return ""
	end
	return table.concat(lines, "\n") .. "\n"
end

---@return string[] base, string[] work
function M.contents(root, base_sha, file)
	local base = {}
	if file.status ~= "A" and file.status ~= "?" then
		base = git.show(root, base_sha, file.old_path or file.path) or {}
	end
	local abs = root .. "/" .. file.path
	local work = {}
	local size = vim.fn.getfsize(abs)
	if size > 0 and size <= MAX_BYTES then
		work = vim.fn.readfile(abs)
	end
	return base, work
end

---@class AgentReviewHunk
---@field base_start integer
---@field base_count integer
---@field work_start integer
---@field work_count integer

---@class AgentReviewChange
---@field file AgentReviewFile
---@field hunks AgentReviewHunk[]
---@field added integer
---@field removed integer
---@field lnum integer 作業ツリー側で最初の変更行
---@field base string[]
---@field work string[]

---@return AgentReviewChange
function M.compute(root, base_sha, file)
	local base, work = M.contents(root, base_sha, file)
	local indices = vim.diff(to_text(base), to_text(work), { result_type = "indices", algorithm = "histogram" }) or {}
	local hunks, added, removed = {}, 0, 0
	for _, h in ipairs(indices) do
		table.insert(hunks, { base_start = h[1], base_count = h[2], work_start = h[3], work_count = h[4] })
		removed = removed + h[2]
		added = added + h[4]
	end
	local lnum = hunks[1] and math.max(hunks[1].work_start, 1) or 1
	return { file = file, hunks = hunks, added = added, removed = removed, lnum = lnum, base = base, work = work }
end

---@return AgentReviewChange[]
function M.collect(root, base_sha, files)
	return vim.tbl_map(function(f)
		return M.compute(root, base_sha, f)
	end, files)
end

---@return string[]
function M.unified(root, base_sha, file)
	local base, work = M.contents(root, base_sha, file)
	local new_file = file.status == "A" or file.status == "?"
	local lines = {
		new_file and "--- /dev/null" or ("--- a/" .. (file.old_path or file.path)),
		file.status == "D" and "+++ /dev/null" or ("+++ b/" .. file.path),
	}
	local body =
		vim.diff(to_text(base), to_text(work), { result_type = "unified", ctxlen = 3, algorithm = "histogram" })
	for _, l in ipairs(vim.split(body or "", "\n", { plain = true, trimempty = true })) do
		table.insert(lines, l)
	end
	return lines
end

function M.describe(change)
	local f = change.file
	local label = M.STATUS_LABELS[f.status] or f.status
	local from = f.old_path and ("  (from " .. f.old_path .. ")") or ""
	return ("%-9s +%d -%d%s"):format(label, change.added, change.removed, from)
end

local function hunk_text(change, h)
	if h.work_count > 0 then
		return vim.trim(change.work[h.work_start] or "")
	end
	return "(removed) " .. vim.trim(change.base[h.base_start] or "")
end

---@param mode "files"|"hunks"
---@param resolve_bufnr? fun(file: AgentReviewFile): integer|nil 実ファイルが無い（削除）エントリの表示先
---@param is_viewed? fun(path: string): boolean 渡された時だけ、行頭にレビュー済みの印を付ける
function M.qf_items(root, list, mode, resolve_bufnr, is_viewed)
	local items = {}
	for _, c in ipairs(list) do
		-- 印の有無で列がずれないよう、印の無い行にも同じ幅の空白を入れる。
		local mark = is_viewed and (is_viewed(c.file.path) and "✓ " or "  ") or ""
		-- module を付けると quickfix にはこの文字列が出る。PRのコードは state ディレクトリにあり
		-- 絶対パスが長くなるので、常にリポジトリからの相対パスを見せる。
		local entry = { filename = root .. "/" .. c.file.path, module = c.file.path }
		local bufnr = resolve_bufnr and resolve_bufnr(c.file)
		if bufnr then
			-- moduleを指定すると、quickfix上は内部のバッファ名の代わりにこのパスが表示される。
			entry = { bufnr = bufnr, module = c.file.path }
		end
		if mode == "hunks" and #c.hunks > 0 then
			for _, h in ipairs(c.hunks) do
				table.insert(
					items,
					vim.tbl_extend("force", entry, {
						lnum = math.max(h.work_start, 1),
						col = 1,
						text = mark
							.. ("[%s] -%d +%d  %s"):format(c.file.status, h.base_count, h.work_count, hunk_text(c, h)),
					})
				)
			end
		else
			table.insert(items, vim.tbl_extend("force", entry, { lnum = c.lnum, col = 1, text = mark .. M.describe(c) }))
		end
	end
	return items
end

return M
