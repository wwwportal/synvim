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
| `:Grep <pattern>` | Local regex search across files; opens results in quickfix |
| `:Find <concept>` | Semantic LLM search; jumps directly to relevant code |
| `:Ask <question>` | Jump to relevant code and insert an in-line explanatory comment |
| `:Add <desc>` | Insert a `// TODO(slug): desc` comment at the cursor line |
| `:Task add <desc>` | Alias for `:Add` |
| `:Do` | Implement the nearest task visible in the active window |
| `:Do <id\|prompt>` | Implement specified task contract or instruction |
| `:Stop` | Abort running background LLM job and clear preview diffs |
| `:Review` | Open side-by-side Git Diffview for pending changes |
| `:Accept [file\|all]` | Stage current file or commit all reviewed changes |
| `:Reject [file\|all]` | Revert pending changes |
| `:Revise <prompt>` | Request adjustments to current diff in natural language |
| `:Tasks` (or `:Queue`) | Open task queue / search results |

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
