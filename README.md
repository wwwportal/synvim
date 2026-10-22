# synvim

Neovim configuration and toolset with terminal split management, local and semantic code search, task tracking, and diff review.

## Installation

```bash
./setup.sh
```

This installs configuration to `~/.config/nvim`, installs CLI binaries to `~/.local/bin`, and bootstraps plugins via `lazy.nvim`.

## Commands

Run `:Synvim help` inside Neovim at any time to view this list.

| Command | Action |
| :--- | :--- |
| `:Synvim help` | Show available commands and keybindings in a floating window |
| `:Tasks` | Toggle repository task agenda in Quickfix (`<leader>q`) |
| `:Tasks list` | List in-tree tasks in Quickfix |
| `:Tasks add <desc>` | Insert formatted task contract at cursor line |
| `:Tasks start [id]` | Implement nearest visible task or specified task contract by ID/index |
| `:Tasks revise [id]` | Mark task as `status:REVISE` and critique directly via in-line comments |
| `:Tasks review` | List pending changes and reviews with IDs/indexes in Quickfix |
| `:Tasks accept <id>` | Accept and approve specific review by ID (atomic; no batch accept) |
| `:Tasks reject <id>` | Reject and revert specific review by ID |
| `:Tasks stop` | Abort running background synthesis job and clear preview diffs |
| `:Find <concept>` | Semantic LLM search; jumps directly to relevant code |
| `:Ask <question>` | Jump to relevant code and insert an in-line explanatory comment (supports multi-line visual preview, multi-question queue navigation, and visual range selection) |

## Multi-Line & Multi-Question Entry

When typing `:Ask` or `:Tasks add` in the command line (`:`):
- **Live Visual Line Break Preview**: A non-focusable floating window dynamically appears flush directly above the command entry line as you type. It visually renders discrete questions (`[Q1]`, `[Q2]`) or tasks (`[T1]`, `[T2]`) with syntax highlighting and automatic word wrapping.
- **`<C-j>` / `<S-CR>` Shortcut**: Press `<C-j>` or `<S-CR>` while typing in the command line to insert an explicit newline break (`\n`).
- **Multi-Question Queue**: When multiple questions are asked, the agent locates the answer to Question 1 and queues subsequent questions into the agent agenda. Navigate through all answered locations using `<C-n>` and `<C-p>` (or `:Tasks next` and `:Tasks prev`).

## Split & Terminal Keybindings

| Keybinding | Action |
| :--- | :--- |
| `Alt + Arrow` | Move focus across splits |
| `Alt + h/j/k/l` | Swap active split with neighbor |
| `Alt + z` | Toggle maximize active split |
| `Alt + q` / `Alt + w` | Close active split |
| `Alt + +` | Split right with a new terminal |
| `Alt + _` | Split down with a new terminal |
| `Esc` | Return to Normal mode when at a shell prompt |
