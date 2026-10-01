# agent-review.nvim

A side-by-side diff viewer for Neovim, built for reviewing code written by AI agents.

- **Left**: the file at a base revision (default `HEAD`), read-only, with syntax highlighting
- **Right**: the real working-tree buffer, so **LSP works**: go to definition, references, hover, and so on
- **Left follows right**: when you jump to another file from the right side (`gd`, picking a reference, `<C-o>`, `:e`), the left side switches to that file at the base revision and the cursor positions stay aligned
- VSCode-style colors: removed lines have a red background and added lines a green one, with a stronger color on the changed characters (`diffopt=inline:char,linematch:60`)
- **Quickfix**: changed files (or every hunk) go into a quickfix list that opens at the bottom of the review tab, so `:cnext`, `]q` and trouble.nvim work as usual
- **Telescope**: `:Telescope agent_review` lists changed files with a syntax-highlighted preview (the working-tree code with added lines in green and removed lines overlaid as red virtual lines), and `:Telescope agent_review hunks` lists every hunk. Both work even when no review is open; picking an entry opens the review at that spot
- Files opened from Telescope, quickfix or `:e` while you are in the base window are moved to the working window, so the layout never breaks
- Integrates with [claudecode.nvim](https://github.com/coder/claudecode.nvim)
  - Select lines on the base side and press `<C-l>` to send them to Claude as a file mention with a line range
  - If the Claude terminal is open in another tab, it moves into the review tab and back again when you close the review
  - Opening, closing, or resizing the Claude terminal re-balances the two diff windows

Requires Neovim >= 0.12 and git.

## Install (lazy.nvim)

```lua
{
  "tyzerrr/agent-review.nvim",
  cmd = { "AgentReview", "AgentReviewToggle", "AgentReviewClose", "AgentReviewFiles", "AgentReviewRefresh" },
  keys = {
    { "<leader>dr", "<cmd>AgentReviewToggle<cr>", desc = "Agent Review" },
  },
  opts = {},
}
```

## Commands

| Command | Description |
| --- | --- |
| `:AgentReview [rev]` | Open a review of the working tree against `rev` (default `HEAD`). Untracked files are included |
| `:AgentReviewToggle [rev]` | Toggle the review |
| `:AgentReviewClose` | Close the review tab |
| `:AgentReviewFiles` | Pick a changed file (Telescope if available, otherwise `vim.ui.select`) |
| `:AgentReviewHunks` | Pick a changed hunk |
| `:AgentReviewQuickfix [files\|hunks]` | Rebuild the quickfix list (per file or per hunk) and open it |
| `:AgentReviewRefresh` | Reload the changed-file list and the buffers (e.g. after the agent made more edits) |

The base revision is resolved to a commit when the review opens, so commits the agent makes during the review do not move it.

## Keymaps (inside the review tab)

| Key | Where | Action |
| --- | --- | --- |
| `]f` / `[f` | both | Next / previous changed file |
| `]c` / `[c` | both | Next / previous hunk (built-in) |
| `<leader>dl` | both | Changed file picker |
| `<leader>dh` | both | Changed hunk picker |
| `]q` / `[q`, `:cnext` | anywhere | Walk the quickfix list (opens in the working window) |
| `q` | base side | Close the review |
| `<C-l>` (visual) | base side | Send the selection to Claude Code |

On the working side, your normal mappings stay in place. `<C-l>` there is whatever you mapped to `ClaudeCodeSend`.
Buffer-local mappings that the review replaces are restored when it closes.

## Telescope

The extension is loaded on demand by `:Telescope agent_review`. You can also load it explicitly:

```lua
require("telescope").load_extension("agent_review")
-- :Telescope agent_review          changed files (diff preview)
-- :Telescope agent_review hunks    every hunk (preview scrolls to the hunk)
```

Entries carry `filename`/`lnum`, so Telescope's built-in `<C-q>` (send to quickfix) works too.

## Configuration

```lua
require("agent-review").setup({
  base = "HEAD",
  diffopt = { "internal", "filler", "closeoff", "inline:char", "linematch:60", "algorithm:histogram", "indent-heuristic" },
  fold_unchanged = false, -- true: fold unchanged regions like plain `:diffthis`
  fillchar = "╱",
  winbar = true,
  picker = "auto", -- "auto" | "telescope" | "ui_select"
  quickfix = {
    auto = true,   -- fill the quickfix list when the review opens
    open = true,   -- open the quickfix window in the review tab
    height = 8,
    mode = "files", -- "files" | "hunks"
  },
  keymaps = {
    next_file = "]f",
    prev_file = "[f",
    files = "<leader>dl",
    hunks = "<leader>dh",
    close = "q",
    send_to_claude = "<C-l>",
  },
  claude = {
    focus_after_send = true,
    terminal_pattern = "claude",
    follow_terminal = true,
  },
  -- Override colors, e.g. { AgentReviewAdd = { bg = "#203020" } }
  highlights = {},
})
```

Highlight groups: `AgentReviewAdd`, `AgentReviewAddText`, `AgentReviewDelete`, `AgentReviewDeleteText`,
`AgentReviewFiller`, `AgentReviewWinbarBase`, `AgentReviewWinbarWork`. By default they are derived from your `Normal` background.

## How it works

- The right window shows real file buffers, so language servers attach as usual. The left window shows `nofile` scratch buffers built from `git show <base>:<path>`, so no language server attaches there and they don't produce diagnostics.
- A `BufWinEnter`/`BufEnter` autocmd on the right window rebuilds the left side and re-runs `:diffthis` on both. Files outside the repository and gitignored files turn the diff off. New files get an empty base.
- Selections sent to Claude from the base side are first written to `.git/agent-review/base-<sha>/<path>`, a real file that Claude Code can read without touching the working tree.

## Development

```sh
make test                                 # all tests (mini.test, headless)
make test-file FILE=tests/test_session.lua
```
