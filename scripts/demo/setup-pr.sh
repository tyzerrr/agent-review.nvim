#!/usr/bin/env bash
# PRレビューのデモ用に、GitHubに見立てたリポジトリ・PR・コメントを用意する（scripts/demo/demo-pr.tape から使用）。
# 本物のGitHubには一切つながない:
#   - git: GIT_CONFIG_GLOBAL の insteadOf で https://github.com/acme/shop.git をローカルの bare リポジトリに向ける
#   - gh : tests/fixtures/gh（決まった応答を返す偽物）を PATH の先頭に置く
# 使い方: source <(scripts/demo/setup-pr.sh <dir>)   # 出力される export をシェルに読み込む
set -euo pipefail
dir="${1:?usage: setup-pr.sh <dir>}"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
rm -rf "$dir"
mkdir -p "$dir"
dir="$(cd "$dir" && pwd -P)"

# デモ用のGoリポジトリ（main）と、そこへの変更（= PR #42 の中身）は既存のデモと共通。
"$repo_root/scripts/demo/setup.sh" "$dir/work" >/dev/null
cd "$dir/work"
main_sha=$(git rev-parse HEAD)
git switch -q -c feature/email-validation
git add -A
git commit -q -m "Validate and normalize emails on registration"
head_sha=$(git rev-parse HEAD)

git init -q --bare -b main "$dir/origin.git"
git push -q "$dir/origin.git" "$main_sha:refs/heads/main" "$head_sha:refs/pull/42/head"

cat >"$dir/gitconfig" <<EOF
[url "$dir/origin.git"]
	insteadOf = https://github.com/acme/shop.git
[user]
	email = demo@example.com
	name = demo
[protocol "file"]
	allow = always
[advice]
	detachedHead = false
EOF
GIT_CONFIG_GLOBAL="$dir/gitconfig" git clone -q "$dir/origin.git" "$dir/shop"
git -C "$dir/shop" remote set-url origin https://github.com/acme/shop.git

mkdir -p "$dir/bin" "$dir/gh"
cat >"$dir/bin/gh" <<EOF
#!/usr/bin/env bash
exec "$repo_root/tests/fixtures/gh" "\$@"
EOF
chmod +x "$dir/bin/gh"

# 偽ghの応答。行番号は PR #42 の先頭（validate.go / user.go）に合わせてある。
sed -e "s/__HEAD__/$head_sha/g" -e "s/__MAIN__/$main_sha/g" >"$dir/gh/responses.json" <<'EOF'
[
  { "match": ["graphql", "mutation"],
    "body": { "data": {
      "review": { "pullRequestReview": { "id": "R1", "url": "https://github.com/acme/shop/pull/42#pullrequestreview-1" } },
      "reply1": { "comment": { "id": "C9" } },
      "viewed1": { "clientMutationId": null } } } },
  { "match": ["graphql", "search("],
    "body": { "data": {
      "q1": { "nodes": [
        { "number": 41, "title": "Make MemoryStore safe for concurrent use", "url": "https://github.com/acme/shop/pull/41",
          "isDraft": false, "state": "OPEN", "createdAt": "2026-10-01T09:00:00Z", "updatedAt": "2026-10-03T08:00:00Z",
          "additions": 24, "deletions": 3, "changedFiles": 1, "headRefName": "store-mutex", "baseRefName": "main",
          "body": "Guards the in-memory store with a RWMutex.", "reviewDecision": "APPROVED", "author": { "login": "bob" },
          "commits": { "nodes": [ { "commit": { "statusCheckRollup": { "state": "SUCCESS" } } } ] } } ] },
      "q2": { "nodes": [
        { "number": 42, "title": "Validate and normalize emails on registration", "url": "https://github.com/acme/shop/pull/42",
          "isDraft": false, "state": "OPEN", "createdAt": "2026-10-02T09:00:00Z", "updatedAt": "2026-10-03T10:30:00Z",
          "additions": 96, "deletions": 21, "changedFiles": 6, "headRefName": "feature/email-validation", "baseRefName": "main",
          "body": "## Why\nDuplicate and malformed emails slipped into the store.\n\n## What\n- normalize emails before saving\n- reject invalid ones with `ErrInvalidEmail`\n- reject duplicates with `ErrDuplicateEmail`\n- drop the unused `format.Upper`",
          "reviewDecision": "REVIEW_REQUIRED", "author": { "login": "alice" },
          "commits": { "nodes": [ { "commit": { "statusCheckRollup": { "state": "SUCCESS" } } } ] } },
        { "number": 39, "title": "Add pagination to List", "url": "https://github.com/acme/shop/pull/39",
          "isDraft": true, "state": "OPEN", "createdAt": "2026-09-28T09:00:00Z", "updatedAt": "2026-10-02T15:00:00Z",
          "additions": 58, "deletions": 9, "changedFiles": 3, "headRefName": "list-pages", "baseRefName": "main",
          "body": "Work in progress.", "reviewDecision": null, "author": { "login": "carol" },
          "commits": { "nodes": [ { "commit": { "statusCheckRollup": { "state": "PENDING" } } } ] } } ] } } } },
  { "match": ["repos/acme/shop/pulls/42"], "headers": { "ETag": "\"pr42\"" },
    "body": { "number": 42, "title": "Validate and normalize emails on registration", "html_url": "https://github.com/acme/shop/pull/42",
      "state": "open", "merged_at": null, "user": { "login": "alice" },
      "head": { "ref": "feature/email-validation", "sha": "__HEAD__" }, "base": { "ref": "main", "sha": "__MAIN__" } } },
  { "match": ["graphql", "reviewThreads"],
    "body": { "data": { "repository": { "pullRequest": {
      "id": "PR_42", "title": "Validate and normalize emails on registration",
      "body": "## Why\nDuplicate and malformed emails slipped into the store.\n\n## What\n- normalize emails before saving\n- reject invalid ones with `ErrInvalidEmail`\n- reject duplicates with `ErrDuplicateEmail`\n- drop the unused `format.Upper`",
      "createdAt": "2026-10-02T09:00:00Z", "updatedAt": "2026-10-03T10:30:00Z", "author": { "login": "alice" },
      "reviewThreads": { "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [
        { "id": "T1", "path": "internal/service/validate.go", "line": 12, "startLine": null, "originalLine": 12,
          "diffSide": "RIGHT", "startDiffSide": null, "isResolved": false, "isOutdated": false, "subjectType": "LINE",
          "comments": { "nodes": [
            { "id": "C1", "databaseId": 1, "author": { "login": "bob" }, "createdAt": "2026-10-03T09:10:00Z", "url": "u1", "replyTo": null,
              "body": "This accepts `a@b.` — a trailing dot after the domain. Should we reject it?" },
            { "id": "C2", "databaseId": 2, "author": { "login": "carol" }, "createdAt": "2026-10-03T09:40:00Z", "url": "u2", "replyTo": { "id": "C1" },
              "body": "+1, `net/mail.ParseAddress` might be simpler than hand-rolling it." } ] } },
        { "id": "T2", "path": "internal/service/user.go", "line": 24, "startLine": null, "originalLine": 24,
          "diffSide": "RIGHT", "startDiffSide": null, "isResolved": true, "isOutdated": false, "subjectType": "LINE",
          "comments": { "nodes": [
            { "id": "C3", "databaseId": 3, "author": { "login": "bob" }, "createdAt": "2026-10-03T09:15:00Z", "url": "u3", "replyTo": null,
              "body": "Nice, the duplicate check now runs after normalizing." } ] } } ] },
      "reviews": { "nodes": [
        { "author": { "login": "bob" }, "state": "COMMENTED", "body": "A couple of questions inline.", "submittedAt": "2026-10-03T09:16:00Z" },
        { "author": { "login": "carol" }, "state": "COMMENTED", "body": "", "submittedAt": "2026-10-03T09:41:00Z" } ] },
      "comments": { "nodes": [
        { "author": { "login": "alice" }, "body": "Ready for another look!", "createdAt": "2026-10-03T10:30:00Z" } ] },
      "files": { "nodes": [] },
      "commits": { "nodes": [ { "commit": { "oid": "__HEAD__", "statusCheckRollup": { "state": "SUCCESS", "contexts": { "nodes": [
        { "__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "SUCCESS", "detailsUrl": "https://github.com/acme/shop/actions/runs/1" },
        { "__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "SUCCESS", "detailsUrl": "https://github.com/acme/shop/actions/runs/2" } ] } } } } ] }
    } } } } }
]
EOF

# 呼び出し元のシェルに読み込ませる環境変数。
cat <<EOF
export PATH="$dir/bin:\$PATH"
export FAKE_GH_DIR="$dir/gh"
export GIT_CONFIG_GLOBAL="$dir/gitconfig"
export XDG_STATE_HOME="$dir/state"
cd "$dir/shop"
EOF
