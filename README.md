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
| `:History` | Open visited files list in recent order with time spent, edits & context (`<leader>h`) |
| `:History qf` / `:History list` | Export visited files to Quickfix list |
| `:History clear` | Reset visited files history |
| `:Tasks` | Toggle repository task agenda in Quickfix (`<leader>q`) |
| `:Tasks list` | List in-tree tasks in Quickfix |
| `:Tasks add` | Review architectural PlantUML models, then open Two-Layer Task Form |
| `:Tasks form` | Open Two-Layer Task Specification Form directly (`<C-l>` fill, `<C-n>` +task) |
| `:Tasks drop` | Place/drop active queued task directly at cursor (`<M-p>`) |
| `:Tasks cancel` | Cancel active task placement mode (`<M-q>`) |
| `:Tasks test [id]` | Run (or scaffold test-first) test suite for task `<id>` or closest cursor task |
| `:Find [query] [in ..]` | Native C++20 hybrid search bar with live AST/FZF/BM25 results and code context inspector |
| `:Find @algo <query>` | Search language-agnostic algorithms & data structures (CP-Algorithms + NIST DADS) |
| `:Find @deps <query>` | Search installed dependencies (`.lake/packages`, `.venv`, `node_modules`, `$VIMRUNTIME`) |
| `:Find @loogle <query>` | Search Lean 4 & Mathlib4 theorems/definitions by type signature or name |
| `:Find @docs <query>` | Search language and library documentation + cheat sheets (DevDocs + cht.sh) |
| `:Find @code <query>` | Search open-source usage across public repositories (grep.app) |
| `:Find @tag1 @tag2 ...` | Multi-tag hybrid search (e.g. `:Find @algo @code fenwick`, `:Find @loogle @deps RingHom`) |
| `:Ask [question]` | Jump to relevant code and insert an in-line explanatory comment |
| `:Listen` | Voice-to-text dictation into active buffer (`<leader>v`) |

## Multi-Line & Multi-Question Entry

- **Docked Bottom Split (`:Ask` / `:Tasks add` with no args)**:
  - Opens a clean 4-line docked split at the very bottom of the screen (`botright split`), pushing code up instead of floating over it.
  - **`Enter`**: Inserts a new line.
  - **`Ctrl+Enter`** or **`<C-s>`**: Submits the query immediately.
  - **`Esc`** or **`q`** (in Normal mode): Cancels and restores your previous window layout.
- **One-Liner Execution (`:Ask <query>`)**:
  - Typing a question directly on the command line executes immediately without opening any splits or popups.
- **Visual Range Selection (`:'<,'>Ask`)**:
  - Visually select lines in your buffer and run `:Ask` to ask about selected text.
- **Multi-Question Queue**:
  - When multiple questions are asked, the agent locates the answer to Question 1 and queues subsequent questions into the agent agenda. Navigate through all answered locations using `<C-n>` and `<C-p>` (or `:Tasks next` and `:Tasks prev`).

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
