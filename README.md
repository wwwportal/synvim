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
| `:Grep <pattern>` | Local regex search across files; opens results in Quickfix |
| `:Ask <question>` | Jump to relevant code and insert an in-line explanatory comment |

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
