<div align="center">

# agent-review.nvim

**Review what your AI agent wrote with a side-by-side diff where LSP still works,<br>and the base side follows you wherever you jump.**

[![test](https://github.com/tyzerrr/agent-review.nvim/actions/workflows/test.yml/badge.svg)](https://github.com/tyzerrr/agent-review.nvim/actions/workflows/test.yml)
![Neovim](https://img.shields.io/badge/Neovim-0.12%2B-57A143?logo=neovim&logoColor=white)
![Lua](https://img.shields.io/badge/Lua-2C2D72?logo=lua&logoColor=white)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

[![Demo](assets/demo.jpg)](assets/demo.mp4)

<sub>▶ Click the image to watch the demo (54s, mp4)</sub>

</div>

---

## Why

Coding agents (Claude Code, Codex, Cursor, …) change many files at once. Reviewing that in a plain diff viewer
leaves out the most useful part of an editor: you can't **go to definition** or **find references** to check
how the new code fits into the rest of the codebase. If you open the file normally to navigate, you lose the diff.

`agent-review.nvim` keeps both:

```
┌─ BASE  HEAD  store.go ──────────────┬─ WORKING  [5/6] M store.go ──────────┐
│ type Store interface {              │ type Store interface {               │
│   Save(u User) User                 │   Save(u User) User                  │
│   All() []User                      │   All() []User                       │
│ ╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱ │   FindByEmail(email string) …  ◀ gd  │
│ }                                   │ }                                    │
│   read-only, at the base revision   │   your real buffer: LSP, edit, save  │
└─────────────────────────────────────┴──────────────────────────────────────┘
  quickfix: changed files / hunks                     Claude Code terminal →
```

- **Right**: the real working-tree buffer. Your language server, keymaps and edits all work as usual.
- **Left**: the same file at the base revision (`HEAD` by default), read-only, with syntax highlighting.
- **Left follows right**: when you `gd`, `gr`, `<C-o>`, `:e`, `:cnext` or pick a Telescope entry on the right,
  the left side switches to that file at the base revision, and the cursor positions stay aligned.

## Features

- 🧭 **LSP-aware navigation**: go to definition, references and implementations across files, and the diff follows
- 🎨 **VSCode-style colors**: removed lines are red and added lines are green, with stronger color on the changed characters (`inline:char`, `linematch`)
- 🌳 **Syntax highlighting on both sides**: tree-sitter on the base side too, with no LSP diagnostics there
- 📋 **Quickfix integration**: every changed file (or every hunk) goes into a quickfix list, so `]q` walks the whole review and wraps around at either end
- ✅ **Viewed marks**: mark files as reviewed, like GitHub's "Viewed" checkbox. The mark clears itself when the agent changes the file again
- 🧪 **Implementation-only review**: optionally leave test files (Go, JS/TS, Python, Lua, Rust conventions) out of the review
- 🔄 **Auto refresh**: when the agent edits, creates or reverts files, the file list, quickfix, buffers and diff update by themselves, so you don't need to reopen the review
- 🔭 **Telescope pickers**: changed files and changed hunks, with a syntax-highlighted inline diff preview
- 🧹 **Handles every git status**: modified, added, untracked, deleted, renamed (diffed against the old path), gitignored and outside-repo files
- 🤖 **Claude Code integration** ([claudecode.nvim](https://github.com/coder/claudecode.nvim)):
  - Select base-side lines and press `<C-l>` to send them to Claude
  - The Claude terminal moves into the review tab, and the windows re-balance when it opens, closes or resizes
- 🛡️ **Safe**: it never writes to your working tree; base snapshots live under `.git/agent-review/`. Closing the review keeps your other windows (the Claude terminal, help, other files) on screen
- ⌨️ **Fully remappable**: per-action keys, lists of keys, `false` to disable, custom actions, `<Plug>` mappings and `User` events

## Requirements

- Neovim **0.12+** (uses `diffopt=inline:char` and `vim.lsp.enable`-era behavior)
- `git`
- Optional:
  - [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) for the pickers (falls back to `vim.ui.select`)
  - [claudecode.nvim](https://github.com/coder/claudecode.nvim) for the Claude Code integration
  - tree-sitter parsers for your languages

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "tyzerrr/agent-review.nvim",
  event = "VeryLazy", -- keeps `:Telescope agent_review` available; plugin/ is tiny
  opts = {},
}
```

### Other plugin managers

Add the repository and call `require("agent-review").setup()` somewhere in your config.
Commands and `<Plug>` mappings work without `setup()`; the default global keymaps are only created by `setup()`.

## Quick start

1. Let your agent edit some files.
2. Press `<leader>dr` (or `:AgentReview`). A new tab opens: base on the left, working tree on the right, the changed files in quickfix.
3. Navigate as you normally would: `gd`, `gr`, `<C-o>`, `]q`, `]f`, `<leader>dl`, and the left side keeps up.
4. Press `<leader>dr` again (or `q` in the base window) to close the review.

Review against something other than `HEAD`:

```vim
:AgentReview HEAD~3        " everything the agent committed in the last 3 commits, plus uncommitted work
:AgentReview origin/main   " the whole branch
```

When a branch name like `HEAD` moves to another commit (you or the agent commit, reset or check out), the base moves with it, so committed changes drop out of the review. A commit hash given directly stays put. Set `auto_refresh.follow_base = false` to keep the commit the review opened with.

## Keymaps

### Defaults

| Scope | Key | Action |
| --- | --- | --- |
| global | `<leader>dr` | Toggle the review (`HEAD`) |
| global | `<leader>dR` | Type `:AgentReview ` so you can enter a revision |
| global | `<leader>dl` | Changed files picker |
| global | `<leader>dh` | Changed hunks picker |
| global | `<leader>dp` | GitHub pull requests (`:AgentReviewPR`) |
| review (both sides) | `]f` / `[f` | Next / previous changed file |
| review (both sides + quickfix) | `]q` / `[q` | Next / previous quickfix entry, wrapping around at the ends |
| base side | `q` | Close the review |
| base side, visual | `<C-l>` | Send the selection to Claude Code |
| review (both sides) | `<leader>dv` | Mark the shown file as viewed / not viewed |
| review (both sides) | `<leader>dc` / `<leader>dC` | PR: comments on the cursor line / the PR conversation |
| review (both sides) | `<leader>da` (normal, visual) / `<leader>dS` | PR: draft a comment / submit the review |
| quickfix window | `<Tab>` | Mark the file under the cursor as viewed / not viewed |
| quickfix window | `<CR>` | Open the entry under the cursor in the review (even if another plugin maps `<CR>` globally) |

Built-in diff motions also work: `]c` / `[c` (next / previous hunk).
On the working side, your normal mappings stay in place. Buffer-local mappings that the review replaces are restored when it closes.
Outside the review tab, or on a quickfix list that agent-review didn't create, these keys do what they would do without agent-review: your global mapping if you have one (for example flash.nvim on `<CR>`), otherwise the built-in command.

### Customizing

Every action takes a key (`"<leader>x"`), a list of keys (`{ "]f", "<Tab>" }`) or `false`.

```lua
require("agent-review").setup({
  keymaps = {
    global = {
      toggle = "<leader>gr",            -- remap
      open_rev = false,                 -- disable
      files = { "<leader>df", "<F7>" }, -- several keys
      hunks = "<leader>dh",
    },
    review = {
      next_file = { "]f", "<Tab>" },
      prev_file = { "[f", "<S-Tab>" },
      -- any action can be put in any scope
      refresh = "<leader>du",
      quickfix_hunks = "<leader>dq",
      -- custom action: { key, function(session) ... end, desc = ..., mode = ... }
      copy_base_path = {
        "<leader>dy",
        function(session)
          vim.fn.setreg("+", session.root .. " @ " .. session.base_sha)
        end,
        desc = "Copy review base",
      },
    },
    base = {
      close = { "q", "<Esc>" },
      send_to_claude = "<C-l>",
    },
    quickfix = {
      qf_open = { "<CR>", "o" },
    },
  },
})
```

Turn off every mapping with `keymaps = false`, then build your own from `<Plug>` mappings or the Lua API:

```lua
require("agent-review").setup({ keymaps = false })
vim.keymap.set("n", "<leader>r", "<Plug>(agent-review-toggle)")
vim.keymap.set("n", "<Tab>", function() require("agent-review").next_file() end)
```

<details>
<summary>All actions and <code>&lt;Plug&gt;</code> mappings</summary>

| Action | `<Plug>` mapping | Description |
| --- | --- | --- |
| `toggle` | `<Plug>(agent-review-toggle)` | Open / close the review |
| `open` | `<Plug>(agent-review-open)` | Open the review against the default base |
| `open_rev` | none | Type `:AgentReview ` on the command line |
| `close` | `<Plug>(agent-review-close)` | Close the review |
| `files` | `<Plug>(agent-review-files)` | Changed files picker |
| `hunks` | `<Plug>(agent-review-hunks)` | Changed hunks picker |
| `pr_list` | `<Plug>(agent-review-pr-list)` | GitHub pull requests |
| `next_file` | `<Plug>(agent-review-next-file)` | Next changed file |
| `prev_file` | `<Plug>(agent-review-prev-file)` | Previous changed file |
| `qf_next` | `<Plug>(agent-review-qf-next)` | Next quickfix entry; after the last one, go back to the first |
| `qf_prev` | `<Plug>(agent-review-qf-prev)` | Previous quickfix entry; before the first one, go to the last |
| `pr_thread` | `<Plug>(agent-review-pr-thread)` | PR: open the comment threads on the cursor line |
| `pr_conversation` | `<Plug>(agent-review-pr-conversation)` | PR: description, reviews and comments |
| `pr_comment` | `<Plug>(agent-review-pr-comment)` (normal, visual) | PR: draft a comment on the line(s) |
| `pr_submit` | `<Plug>(agent-review-pr-submit)` | PR: submit the drafted review |
| `toggle_viewed` | `<Plug>(agent-review-toggle-viewed)` | Mark the file as viewed / not viewed (quickfix: the line under the cursor) |
| `qf_open` | `<Plug>(agent-review-qf-open)` | Open the review quickfix entry under the cursor in the working window |
| `refresh` | `<Plug>(agent-review-refresh)` | Reload the changed files and the diff |
| `quickfix_files` | `<Plug>(agent-review-quickfix-files)` | Quickfix: one entry per file |
| `quickfix_hunks` | `<Plug>(agent-review-quickfix-hunks)` | Quickfix: one entry per hunk |
| `send_to_claude` | `<Plug>(agent-review-send-to-claude)` (visual) | Send the base selection to Claude Code |

</details>

## Commands

| Command | Description |
| --- | --- |
| `:AgentReview [rev]` | Open a review of the working tree against `rev` (default `HEAD`). Untracked files are included |
| `:AgentReviewToggle [rev]` | Toggle the review |
| `:AgentReviewClose` | Close the review tab |
| `:AgentReviewFiles` | Pick a changed file |
| `:AgentReviewPR [preset\|number]` | List GitHub pull requests (the default lists, or a preset from `pr.presets`), or review PR `<number>` |
| `:AgentReviewPRClean` | Remove checked-out PRs that are not being reviewed |
| `:AgentReviewPRConversation` | Show the PR's description, reviews and comments |
| `:AgentReviewPRSubmit [approve\|request_changes\|comment]` | Send the drafted comments, replies and resolves in one request |
| `:AgentReviewHunks` | Pick a changed hunk |
| `:AgentReviewQuickfix [files\|hunks\|comments]` | Rebuild the quickfix list and open it (`comments`: PR review threads) |
| `:AgentReviewRefresh` | Reload the changed files and buffers now (normally done for you, see `auto_refresh`) |

## Telescope

`:Telescope agent_review` loads the extension on demand. To load it explicitly:

```lua
require("telescope").load_extension("agent_review")
```

| Picker | Description |
| --- | --- |
| `:Telescope agent_review` / `files` | Changed files with status and `+added -removed` counts |
| `:Telescope agent_review hunks` | Every hunk across all files; the preview scrolls to the hunk |

The preview shows the working-tree code with tree-sitter highlighting. Added lines are green, and removed lines are drawn inline in red with **their own syntax highlighting**.
Both pickers work without an open review; picking an entry opens the review right at that spot.
Entries carry `filename`/`lnum`, so Telescope's `<C-q>` (send to quickfix) works too.

## Quickfix

When the review opens, the changed files go into a quickfix list (`Agent Review: HEAD`) at the bottom of the review tab:

```
internal/format/legacy.go|1 col 1| deleted   +0 -8
internal/service/normalize.go|1 col 1| renamed   +0 -0  (from internal/service/util.go)
internal/service/user.go|3 col 1| modified  +16 -3
```

- Each entry points at the first changed line.
- `:AgentReviewQuickfix hunks` switches to one entry per hunk, so `]q` walks every change in the review.
- `<CR>` in the quickfix window opens the entry in the working window, even when another plugin (such as flash.nvim) maps `<CR>` globally. On other quickfix lists your own `<CR>` still runs.
- In the review windows and the quickfix window, `]q` / `[q` wrap around: after the last entry comes the first one, and before the first comes the last. A count works too (`3]q`).
- Refreshing updates the same list instead of stacking new ones, and keeps the entry you are on selected.
- Files opened from quickfix, Telescope or `:e` while the base window has focus are moved to the working window automatically, so the layout never breaks.

## Claude Code integration

With [claudecode.nvim](https://github.com/coder/claudecode.nvim) installed:

- **Send base code**: select lines on the left and press `<C-l>`. The base version is written to `.git/agent-review/base-<sha>/<path>` (inside `.git`, so your working tree stays clean) and sent as a file mention with the line range. On the right side your own `ClaudeCodeSend` mapping works as usual.
- **Terminal follows the review**: claudecode.nvim treats a terminal shown in another tab as visible, so toggling it from the review tab would hide it there instead. When a review opens, a visible Claude terminal moves into the review tab, and it goes back to its original tab when the review closes. A Claude terminal you opened inside the review tab stays open too: it moves to the tab you came from.
- **Other windows are kept**: any window you opened in the review tab that isn't part of the review (help, another file, another agent's terminal) is reopened in the tab you return to, so closing the review only closes the diff.
- **Balanced layout**: opening, closing or resizing the Claude terminal re-balances the two diff windows. Resizing the diff windows yourself is left alone.

## Pull requests

Review anyone's pull request in the same layout: the PR's code on the right with your language server, the base on the left, every changed file in quickfix, the review comments right on the lines they belong to, and your own review: comments, replies, resolves and approval, sent to GitHub in one request.

- `:AgentReviewPR 123` (or pick one from the list) opens PR #123 for review.
- The diff is the same as GitHub's "Files changed": against the merge-base with the target branch (for merged PRs, the target branch as GitHub recorded it).
- `:AgentReviewRefresh` picks up new commits pushed to the PR.
- `:AgentReviewPRClean` removes the checked-out PRs you are not reviewing.

### Review comments

- Commented lines get a sign and a one-line summary at the end of the line: `💬 bob: Why 2?  (+1)`. Each author always gets the same color. Comments on removed lines show on the base (left) side. Resolved threads are dimmed (`✓ resolved`).
- `<leader>dc` opens every thread on the cursor line in a floating window (markdown, `q` to close).
- `<leader>dC` / `:AgentReviewPRConversation` shows the description, reviews (approved / requested changes) and comments in time order.
- `:AgentReviewQuickfix comments` lists every thread: unresolved first, then outdated (comments on an older commit, which aren't placed on lines, like on GitHub), then resolved. `<CR>` on a comment about a removed line opens the file with the base side scrolled to that line.
- All of it comes from **one** GraphQL request per PR (more only past 100 threads). `:AgentReviewRefresh` asks again only when the PR changed: the PR's ETag check comes back 304 otherwise, which is free.

### Writing a review

Everything you write is a **draft** first, kept per PR under the state directory (it survives closing Neovim), and goes to GitHub in **one request** when you submit:

- `<leader>da` comments on the cursor line, or on the selected lines in visual mode. On the right it comments on the PR's code, on the left on the removed side. A small markdown window opens: `:w` (or `<C-s>`) saves the draft, `q` cancels. On the same line again you edit the draft; saving it empty deletes it. GitHub only accepts comments on lines it shows in the diff (changes and 3 lines around them), so other lines are refused right away.
- In the thread window (`<leader>dc`): `r` drafts a reply, `R` toggles resolving the thread.
- Drafts show inline (`📝 draft: …`, `📝 draft reply`, `(will resolve)`) and at the top of `:AgentReviewQuickfix comments`.
- `:AgentReviewPRSubmit approve` / `request_changes` / `comment` (or `<leader>dS`) opens a window for the review's summary; `:w` sends the review with all drafted comments, the replies and the resolves together. Without a verdict, drafted comments go out as a "Comment" review, and replies/resolves alone are sent as they are.
- If GitHub rejects part of it (for example, you can't approve your own PR), what went through leaves the draft and the rest stays, so you can fix it and submit again.

### Where the PR's code lives

Nothing is written to your repository: no worktree, no branch, no ref, nothing under `.git`.

```
~/.local/state/agent-review/github.com/owner/repo/   ($XDG_STATE_HOME or pr.state_dir)
├── repo.git/   a private copy of your repository (cloned locally once, hard-linked, ~ the size of .git)
├── 123/        PR #123 checked out from it
└── 456/
```

- The PR's commits are fetched into `repo.git` with `git fetch`, so the diff costs no API calls. Only the PR's metadata (title, head, base) comes from the GitHub API, with an ETag so an unchanged PR doesn't count against the rate limit.
- Reopening a PR whose head hasn't moved skips the fetch entirely (about 1s on a real repository).
- Your language server runs on the PR's checkout like on any other project. Untracked dependencies (for example `node_modules`) aren't there, so a TypeScript server may need them installed in the checkout.

### Listing pull requests

- `:AgentReviewPR` (or `<leader>dp`) lists the pull requests of the repository you opened Neovim in. It uses the `origin` remote (`pr.remote`) and needs the [GitHub CLI](https://cli.github.com) (`gh auth login`).
- By default you see open PRs **you opened** plus open PRs where **you or one of your teams** is asked to review.
- Each line shows the number, title, author, draft/merged/closed, review state, CI, `+added -removed`, the number of files and how long ago it was updated. The preview shows the description.
- `<CR>` opens the PR for review; `<C-b>` (Telescope) opens it in the browser instead.

You describe the lists with plain keys instead of GitHub's search syntax:

```lua
require("agent-review").setup({
  pr = {
    -- each entry is one search; the results are merged without duplicates
    lists = {
      { author = "@me" },
      { reviewer = "@me" },           -- includes requests to your teams
    },
    state = "open",                   -- "open" | "closed" | "merged" | "all"
    presets = {                       -- :AgentReviewPR <name>
      team = { { reviewer = "@me", draft = false, base = "main" } },
      bugs = { { label = { "bug", "regression" } } },
      urgent = "is:open label:urgent", -- a raw GitHub query also works
    },
  },
})
```

Keys: `author`, `reviewer`, `assignee`, `involves`, `mentions`, `label` (string or list), `base`, `head`, `draft` (`true`/`false`) and `state` (overrides the shared one).

All the searches go to GitHub in **one** GraphQL request. Results are cached under the state directory: reopening within `pr.list_ttl` seconds (60 by default) makes no request at all; after that the cached list shows immediately and is replaced when the fresh one arrives.

## Viewed marks

Like the "Viewed" checkbox on a GitHub pull request, you can mark each file as reviewed:

- `<Tab>` in the quickfix window toggles the file under the cursor; `<leader>dv` in the diff windows toggles the file on screen.
- Marked files get a `✓` in quickfix (every hunk of the file in hunks mode), the quickfix title shows the progress (`Agent Review: HEAD (3/8 viewed)`), and the winbar says `✓ viewed`.
- The mark remembers the file's content. When the agent changes the file again, the mark goes away, so you only re-read what changed.
- Marks are saved in `.git/agent-review/viewed.json` (per worktree) and survive closing and reopening the review.

## Reviewing implementation only

Most of the time you want to read what the agent built, not every test it wrote. Set `tests.hide = true` to leave test files out of quickfix, `]f`/`[f`, the pickers and the `[i/n]` count. The quickfix title shows how many were left out (`(4 test files hidden)`). A test file you open yourself (for example with `gd`) still gets its diff.

Built-in patterns:

| Language | Test files |
| --- | --- |
| Go | `*_test.go`, `testdata/` |
| JS / TS | `*.test.{js,jsx,ts,tsx,mjs,cjs,mts,cts}`, `*.spec.*` (same extensions), `__tests__/` |
| Python | `test_*.py`, `*_test.py`, `conftest.py`, `tests/` |
| Lua | `*_spec.lua`, `*_test.lua`, `test_*.lua`, `spec/`, `tests/` |
| Rust | `tests/` (integration tests), `*_test.rs`, `tests.rs` |

Unit tests inside the same file (Rust's `#[cfg(test)] mod tests`) can't be told apart per file and stay in the review. Patterns are Lua patterns matched against `"/" .. path` (the path relative to the repository root), so `"^/e2e/"` matches a top-level `e2e` directory:

```lua
require("agent-review").setup({
  tests = { hide = true, extra_patterns = { "^/e2e/", "%.stories%.tsx$" } },
})
```

## Auto refresh

While a review is open, the repository is watched for file changes (`.git/` is ignored). When the agent writes files, the review refreshes after a short debounce:

- New changes are added to the file list and quickfix, and reverted files drop out.
- After a commit, the base moves to the new commit, so the committed files drop out. This works in `git worktree` checkouts too, where the refs live outside the working directory.
- If the file you are looking at drops out (committed or reverted), both windows move to the entry quickfix now selects: the next file in the list. A file you opened yourself that was never in the list (for example via `gd`) stays on screen. When nothing is left, both windows are cleared (the winbar says "no changes") and the review stays open; the next change the agent makes shows up there automatically.
- Buffers changed on disk are reloaded (`:checktime`) and the diff is recomputed.
- It also refreshes on `FocusGained` and when you leave a terminal (`TermLeave`). On Linux, file watching only covers the top-level directory, so these events fill the gap.

If you have unsaved edits in a buffer that the agent also changed, Neovim asks which version to keep as usual (`W12`); nothing is overwritten silently.
Turn it off with `auto_refresh = false` and use `:AgentReviewRefresh` instead.

## Configuration

<details open>
<summary>Defaults</summary>

```lua
require("agent-review").setup({
  base = "HEAD",
  -- Applied only while a review is open and restored afterwards.
  -- Items your Neovim doesn't support are skipped.
  diffopt = { "internal", "filler", "closeoff", "inline:char", "linematch:60", "algorithm:histogram", "indent-heuristic" },
  fold_unchanged = false, -- true: fold unchanged regions like plain :diffthis
  fillchar = "╱",         -- filler shown opposite added/removed lines
  winbar = true,          -- " BASE  HEAD  path" / " WORKING  [3/6] M path"
  picker = "auto",        -- "auto" | "telescope" | "ui_select"
  quickfix = {
    auto = true,          -- fill the quickfix list when the review opens
    open = true,          -- open the quickfix window in the review tab
    height = 8,
    mode = "files",       -- "files" | "hunks"
  },
  tests = {
    hide = false,         -- true: leave test files out of quickfix, ]f/[f and the pickers
    patterns = nil,       -- replace the built-in test file patterns (Lua patterns)
    extra_patterns = {},  -- add to the built-in patterns
  },
  auto_refresh = {        -- false to disable
    enabled = true,
    debounce = 200,       -- ms to wait so a burst of writes refreshes once
    follow_base = true,   -- move the base when HEAD (or the given ref) moves
  },
  keymaps = {
    global = { toggle = "<leader>dr", open_rev = "<leader>dR", files = "<leader>dl", hunks = "<leader>dh" },
    review = {
      next_file = "]f", prev_file = "[f", qf_next = "]q", qf_prev = "[q", toggle_viewed = "<leader>dv",
      pr_thread = "<leader>dc", pr_conversation = "<leader>dC", pr_comment = "<leader>da", pr_submit = "<leader>dS",
    },
    base = { close = "q", send_to_claude = "<C-l>" },
    quickfix = { qf_open = "<CR>", toggle_viewed = "<Tab>" }, -- only in the review tab's quickfix window
  },
  pr = {
    gh = "gh",            -- GitHub CLI
    state_dir = nil,      -- default: $XDG_STATE_HOME/agent-review or ~/.local/state/agent-review
    remote = "origin",    -- the remote whose GitHub repository has the PRs ("upstream" for forks)
    lists = { { author = "@me" }, { reviewer = "@me" } },
    state = "open",
    presets = {},
    list_ttl = 60,        -- seconds a cached PR list is used without asking GitHub
    limit = 50,           -- PRs per search
    comment_sign = "💬",  -- sign on lines with review comments
    resolved_sign = "✓",
    draft_sign = "📝",
  },
  claude = {
    focus_after_send = true,     -- jump into the Claude terminal after <C-l>
    terminal_pattern = "claude", -- how the Claude terminal buffer is recognized
    follow_terminal = true,      -- move the Claude terminal into the review tab
  },
  highlights = {},               -- see below
})
```

</details>

### Highlights

By default, colors are derived from your `Normal` background, so they fit any colorscheme. You can override them:

```lua
require("agent-review").setup({
  highlights = {
    AgentReviewAdd = { bg = "#1f3a28" },
    AgentReviewDelete = { bg = "#3d1f24" },
  },
})
```

| Group | Used for |
| --- | --- |
| `AgentReviewAdd` / `AgentReviewAddText` | Added or changed lines on the working side / the changed characters |
| `AgentReviewDelete` / `AgentReviewDeleteText` | Removed or changed lines on the base side / the changed characters |
| `AgentReviewFiller` | The `╱╱╱` filler opposite one-sided lines |
| `AgentReviewWinbarBase` / `AgentReviewWinbarWork` | `BASE` / `WORKING` labels in the winbar |

## Lua API

```lua
local ar = require("agent-review")

ar.setup(opts)
ar.open(base?, { path? })   -- open (or focus) a review, optionally at a root-relative path
ar.open_at(path, lnum?)     -- open the review at a file and line (used by the pickers)
ar.close()
ar.toggle(base?)
ar.next_file() / ar.prev_file()
ar.files() / ar.hunks()     -- pickers
ar.quickfix("files" | "hunks")
ar.qf_next() / ar.qf_prev() -- quickfix, wrapping around
ar.toggle_viewed()          -- mark the file as viewed / not viewed
ar.refresh()
```

### Events

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = { "AgentReviewOpen", "AgentReviewClose" },
  callback = function(ev)
    -- ev.data = { root, base, base_sha, tab, left_win, right_win }
  end,
})
```

## How it works

- The right window shows real file buffers, so language servers attach as usual.
- The left window shows `nofile` scratch buffers built from `git show <base>:<path>`. Neovim's LSP auto-attach skips them, so you get no duplicate diagnostics.
- A `BufWinEnter`/`BufEnter` autocmd on the right window rebuilds the left side and re-runs `:diffthis` on both. Each time the pair changes, `:diffoff!` clears hidden buffers first, which keeps Neovim's 8-buffer diff limit (`E96`) from being reached.
- Files outside the repository and gitignored files turn the diff off; new files get an empty base.

## FAQ

<details>
<summary>Why doesn't <code>gd</code> work on the left side?</summary>

The base side is a snapshot rather than a file on disk, so no language server is attached to it.
Navigate on the right side; the left side follows.
</details>

<details>
<summary>The agent changed more files after I opened the review</summary>

`]f`, the pickers and the quickfix list pick up new files automatically. Run `:AgentReviewRefresh` to update the counts and reload modified buffers.
</details>

<details>
<summary>Can I review without the quickfix window?</summary>

Set `quickfix = { open = false }` to only fill the list, or `quickfix = { auto = false }` to skip it entirely.
</details>

## Development

```sh
make test                                   # all tests (mini.test, headless; clones test deps into ./deps)
make test-file FILE=tests/test_session.lua  # a single file
nix shell nixpkgs#vhs nixpkgs#ttyd nixpkgs#ffmpeg -c scripts/demo/render.sh  # re-record assets/demo.mp4
```

Tests run against real git repositories in temp directories. Only external plugins (claudecode.nvim) are stubbed.

## License

MIT
