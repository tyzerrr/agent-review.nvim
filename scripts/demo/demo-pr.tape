# README用のPRレビューのデモの台本。scripts/demo/render.sh scripts/demo/demo-pr.tape assets/demo-pr.mp4 で使う。
# GitHubはつながず、scripts/demo/setup-pr.sh が用意する偽のGitHub（ローカルのリポジトリと偽gh）で動かす。
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
Set TypingSpeed 60ms

Hide
Type "source <(scripts/demo/setup-pr.sh /tmp/agent-review-pr-demo) && clear && nvim main.go"
Enter
Sleep 5s
# 設定由来の起動時の通知（agent-review とは無関係）を消してから映す
Type ":lua pcall(function() require('notify').dismiss({ silent = true, pending = true }) end)"
Enter
Sleep 0.5s
Type ":echo ''"
Enter
Show

# PR一覧: 自分のPRと、自分（チーム）がレビューを頼まれたPR。プレビューは説明文
Sleep 1s
Type " dp"
Sleep 3.5s
Type "email"
Sleep 1.5s
Enter
Sleep 4s

# レビューコメントの一覧から最初のスレッドへ。行末にコメントの要約が出る
Type ":AgentReviewQuickfix comments"
Enter
Sleep 2s
Type ":cfirst"
Enter
Sleep 2.5s

# スレッド全体を開いて、返信を下書き
Type " dc"
Sleep 3s
Type "r"
Sleep 1s
Type "Good catch, switched to net/mail.ParseAddress."
Sleep 0.5s
Escape
Type ":w"
Enter
Sleep 2s

# 次のスレッド（解決済み）。LSPの定義ジャンプで別ファイルへ行くと左も追従する
Type ":cnext"
Enter
Sleep 2s
Type "/normalize("
Enter
Sleep 2.5s
Type "gd"
Sleep 3s
Ctrl+O
Sleep 1.5s

# 行にコメントを下書きして、ファイルを Viewed にする
Type ":21"
Enter
Sleep 0.5s
Type " da"
Sleep 1s
Type "Wrap this with the email so the log says which one failed?"
Sleep 0.5s
Escape
Type ":w"
Enter
Sleep 2s
Type " dv"
Sleep 2s

# PRの会話: 説明文・レビュー・CI
Type " dC"
Sleep 4s
Type "q"
Sleep 1s

# 下書き（返信・コメント・Viewed）とApproveを1回のリクエストで送る
Type ":AgentReviewPRSubmit approve"
Enter
Sleep 1.5s
Type "LGTM, two small notes inline."
Sleep 0.5s
Escape
Type ":w"
Enter
Sleep 3.5s

# 閉じる
Type " dr"
Sleep 2s
