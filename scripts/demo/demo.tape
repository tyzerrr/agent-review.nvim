# README用デモの台本。scripts/demo/render.sh から使う（vhsでフレームを書き出し、ffmpegでmp4にする）。
# 前提: nvim + gopls + telescope.nvim の設定と、agent-review.nvim のデフォルトキー（<leader> = Space）。
# エージェントの動き（ファイルを足す・commitする）は映さずに jobstart で起こし、ツリーが追従する様子を見せる。
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
# エージェントのブランチ: store・format の変更はcommit済み、service と main.go は作業中（未commit）
Type "scripts/demo/setup.sh /tmp/agent-review-demo && cd /tmp/agent-review-demo && git switch -qc agent/email-validation && git add internal/store && git commit -qm 'store: FindByEmail' && clear && nvim main.go"
Enter
Sleep 5s
# 設定由来の起動時の通知（agent-review とは無関係）を消してから映す
Type ":lua pcall(function() require('notify').dismiss({ silent = true, pending = true }) end)"
Enter
Sleep 0.5s
Type ":echo ''"
Enter
Show

# レビューを開く: 左端=変更ファイルのツリー（未commitの変更）、中=HEAD、右=作業ツリー
Sleep 1s
Type " dr"
Sleep 3s

# ツリーへ移り、j/k でたどると右のdiffが切り替わる
Type " de"
Sleep 1.5s
Type "k"
Sleep 2s
Type "k"
Sleep 2s

# <CR> でdiffへ。LSPの定義ジャンプで別ファイルへ行くと、左もツリーも追従する
Enter
Sleep 2s
Type "/validateEmail("
Enter
Sleep 1s
Type "gd"
Sleep 3s
Ctrl+O
Sleep 2s

# エージェントがテストを書き足す → ツリーに自動で現れる
Hide
Type `:call jobstart(['sh', '-c', 'printf "package service\n\nimport \"testing\"\n\nfunc TestValidateEmail(t *testing.T) {\n\tif validateEmail(\"x\") == nil {\n\t\tt.Fatal(\"want error\")\n\t}\n}\n" > internal/service/validate_test.go'])`
Enter
Type ":echo ''"
Enter
Show
Sleep 3s

# ツリーで既読（Viewed）の印を付ける
Type " de"
Sleep 1s
Type "gg"
Sleep 0.5s
Type "j"
Sleep 1.5s
Tab
Sleep 2s

# エージェントが全部commitする → 未commitのモードでは一覧から消える
Hide
Type `:call jobstart(['sh', '-c', 'git add -A && git commit -qm "service: validate emails"'])`
Enter
Type ":echo ''"
Enter
Show
Sleep 3.5s

# m でブランチ全体（mainから分かれてからの変更。commit済みも含む）に切り替え
Type "m"
Sleep 3s
Type "j"
Sleep 1.5s
Type "j"
Sleep 1.5s
Type "j"
Sleep 1.5s
Type "j"
Sleep 2s

# Telescope: 変更箇所（hunk）単位。構文ハイライト付きのdiffプレビュー
Type " dh"
Sleep 2.5s
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
