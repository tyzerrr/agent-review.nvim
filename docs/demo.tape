# README用デモの台本。scripts/demo/render.sh から使う（vhsでフレームを書き出し、ffmpegでmp4にする）。
# 前提: nvim + gopls + telescope.nvim の設定と、agent-review.nvim のデフォルトキー（<leader> = Space）。
Output .demo-frames/

Require nvim
Require gopls

Set Shell zsh
Set FontFamily "Hack Nerd Font Mono"
Set FontSize 15
Set Width 1600
Set Height 900
Set Padding 12
Set Framerate 24
Set TypingSpeed 70ms

Hide
Type "scripts/demo/setup.sh /tmp/agent-review-demo && cd /tmp/agent-review-demo && clear && nvim main.go"
Enter
Sleep 5s
Show

# レビューを開く: 左=HEAD、右=作業ツリー、下=変更ファイルのquickfix
Sleep 1s
Type " dr"
Sleep 3s

# 右側でLSPの定義ジャンプ → 左側も同じファイルの変更前に追従
Type "/Register("
Enter
Sleep 1s
Type "gd"
Sleep 3s

# 別ファイルの定義へ
Type "/FindByEmail"
Enter
Sleep 1s
Type "gd"
Sleep 3s

# References（参照が多いのでTelescopeの一覧が開く）から別ファイルへ移動しても追従する
Type "/User struct"
Enter
Sleep 1s
Type "gr"
Sleep 3s
Type "service"
Sleep 2s
Enter
Sleep 3s

# ジャンプ履歴を戻ると左側も戻る
Escape
Ctrl+O
Sleep 2.5s

# quickfix で変更ファイルを巡回
Escape
Type "]q"
Sleep 2s
Type "]q"
Sleep 2s

# Telescope: 変更ファイル一覧（構文ハイライト付きdiffプレビュー）
Escape
Type " dl"
Sleep 2.5s
Ctrl+N
Sleep 2s
Ctrl+N
Sleep 2s
Type "valid"
Sleep 1.5s
Enter
Sleep 3s

# Telescope: 変更箇所（hunk）単位
Escape
Type " dh"
Sleep 2s
Ctrl+N
Sleep 1.5s
Ctrl+N
Sleep 1.5s
Ctrl+N
Sleep 1.5s
Enter
Sleep 3s

# 閉じる
Escape
Type " dr"
Sleep 2s
