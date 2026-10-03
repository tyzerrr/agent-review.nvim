local config = require("agent-review.config")

local M = {}

-- 先頭に "/" を付けたroot相対パスに対するLuaパターン。ディレクトリ名もファイル名も "/" から照合できる。
-- Rustの #[cfg(test)] のように実装と同じファイルに書くテストはファイル単位では区別できないので対象外。
M.DEFAULT_PATTERNS = {
	-- Go
	"_test%.go$",
	"/testdata/",
	-- JavaScript / TypeScript
	"%.test%.[cm]?[jt]sx?$",
	"%.spec%.[cm]?[jt]sx?$",
	"/__tests__/",
	-- Python
	"/test_[^/]*%.py$",
	"_test%.py$",
	"/conftest%.py$",
	-- Lua
	"_spec%.lua$",
	"_test%.lua$",
	"/test_[^/]*%.lua$",
	"/spec/",
	-- Rust
	"_test%.rs$",
	"/tests%.rs$",
	-- Python / Lua / Rust（統合テスト）のテスト用ディレクトリ
	"/tests?/",
}

local function patterns()
	local opts = config.options.tests or {}
	return vim.list_extend(vim.deepcopy(opts.patterns or M.DEFAULT_PATTERNS), opts.extra_patterns or {})
end

---@param rel string root相対パス
function M.is_test(rel)
	local path = "/" .. rel
	for _, pat in ipairs(patterns()) do
		if path:find(pat) then
			return true
		end
	end
	return false
end

---tests.hide が有効ならテストを除いた一覧を返す。
---@param files AgentReviewFile[]
---@return AgentReviewFile[] kept, integer hidden
function M.filter(files)
	if not (config.options.tests or {}).hide then
		return files, 0
	end
	local kept = vim.tbl_filter(function(f)
		return not M.is_test(f.path)
	end, files)
	return kept, #files - #kept
end

return M
