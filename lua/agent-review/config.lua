local M = {}

---@class AgentReviewConfig
M.defaults = {
	-- 比較元。:AgentReview <rev> で上書きできる。
	base = "HEAD",
	-- セッション中だけ適用し、閉じたら元に戻す。
	diffopt = {
		"internal",
		"filler",
		"closeoff",
		"inline:char",
		"linematch:60",
		"algorithm:histogram",
		"indent-heuristic",
	},
	-- falseなら変更のない領域を畳まず、VSCodeのようにファイル全体を表示する。
	fold_unchanged = false,
	-- 片側にしかない行の反対側に表示する埋め草文字。
	fillchar = "╱",
	winbar = true,
	-- "auto": telescope.nvimがあれば使い、無ければvim.ui.select。"telescope" | "ui_select" で固定もできる。
	picker = "auto",
	quickfix = {
		-- レビューを開いた時に変更ファイルをquickfixリストへ入れる。
		auto = true,
		-- レビュータブの下部にquickfixウィンドウを開く。
		open = true,
		height = 8,
		-- "files": 1ファイル1行 / "hunks": 変更箇所ごとに1行
		mode = "files",
	},
	keymaps = {
		next_file = "]f",
		prev_file = "[f",
		files = "<leader>dl",
		hunks = "<leader>dh",
		close = "q", -- base側のウィンドウでのみ有効（作業ツリー側はマクロ記録と衝突するため）
		send_to_claude = "<C-l>", -- base側のビジュアル選択をClaude Codeに送る
	},
	claude = {
		-- 送信後にClaudeのターミナルへフォーカスしてInsertモードに入る。
		focus_after_send = true,
		-- このパターンにバッファ名がマッチするターミナルをClaudeのウィンドウとみなす。
		terminal_pattern = "claude",
		-- 別タブで表示中のClaudeターミナルをレビュータブへ移し、終了時に元のタブへ戻す。
		follow_terminal = true,
	},
	-- 色を明示したい場合に指定する（nvim_set_hlの引数）。省略時はNormalの背景色から算出する。
	highlights = {},
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
	return M.options
end

return M
