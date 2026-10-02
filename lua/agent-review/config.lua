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
	-- エージェントがファイルを書き換えたら自動でrefreshする。false で無効。
	auto_refresh = {
		enabled = true,
		-- 連続した書き込みを1回のrefreshにまとめる待ち時間(ms)
		debounce = 200,
		-- base（HEAD等）が別のコミットを指したら比較元も移す。commitした変更はレビューから消える。
		-- false で開いた時のコミットに固定する。
		follow_base = true,
	},
	-- 値は "キー" | { "キー", ... } | false（無効）。keymaps = false で全て無効。
	-- 操作名の一覧は lua/agent-review/keymaps.lua の actions を参照。
	-- 未知の名前に { "キー", function(session) end, desc = "", mode = "n" } を渡すと独自の操作を追加できる。
	keymaps = {
		-- どこからでも使えるキー（setup()を呼んだ時に設定される）
		global = {
			toggle = "<leader>dr",
			open_rev = "<leader>dR",
			files = "<leader>dl",
			hunks = "<leader>dh",
		},
		-- レビュータブ内の左右両方のバッファに設定されるキー
		review = {
			next_file = "]f",
			prev_file = "[f",
			qf_next = "]q",
			qf_prev = "[q",
		},
		-- base側（左）のバッファだけに設定されるキー。
		-- 作業ツリー側にqを置かないのはマクロ記録と衝突するため。
		base = {
			close = "q",
			send_to_claude = "<C-l>",
		},
		-- レビュータブのquickfix窓だけに設定されるキー（reviewのキーもここで使える）。
		-- agent-reviewのリスト以外では、グローバルの割り当てや標準の動きに任せる。
		quickfix = {
			qf_open = "<CR>",
		},
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
	opts = opts or {}
	local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
	if opts.keymaps == false then
		merged.keymaps = false
	elseif type(opts.keymaps) == "table" then
		-- 旧形式（keymaps.next_file 等）を先に正規化してからデフォルトと合わせる。
		local user = require("agent-review.keymaps").normalize(opts.keymaps)
		merged.keymaps = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults.keymaps), user)
	end
	M.options = merged
	return M.options
end

return M
