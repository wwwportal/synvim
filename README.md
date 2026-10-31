# synvim

> **Sovereign, Minimalist Neovim Environment with Monochrome Aesthetics, Tiling Terminal Multiplexer & Instant Voice Navigation**

---

## 1. Overview

`synvim` is a sovereign text editor focused entirely on speed, distraction-free editing, and ergonomic window management.

- **Monochrome Aesthetics**: Tailored high-contrast greyscale colorscheme (`mono.lua`) adhering to WCAG AA readability standards.
- **Hyprland-Style Terminal Multiplexing**: Window splits, instant terminal spawning, and directory tracking across editor buffers and terminal sessions.
- **Instant Voice Input (`:Listen` / `<leader>v`)**: Integrated microphone transcription via the native [`scribe`](https://github.com/Syntra-Labs/scribe) CLI.
- **Hybrid Symbol & File Search (`:Find` / `<leader>f`)**: High-throughput C++20 hybrid code search powered by [`router`](https://github.com/Syntra-Labs/router) (`librouter_search.so`).
- **Visited File History (`:History` / `<leader>h`)**: LRU-tracked file navigation graph with edit statistics and quickfix export.

---

## 2. Installation

```bash
git clone https://github.com/Syntra-Labs/synvim.git
cd synvim
./setup.sh
```

This provisions the configuration to `~/.config/nvim` and bootstraps plugins via `lazy.nvim`.

---

## 3. Core Commands

Run `:Synvim help` inside Neovim at any time to view this quick reference.

| Command | Keymap | Action |
| :--- | :--- | :--- |
| `:Find [query]` | `<leader>f` | Hybrid C++20 search (FZF + BM25 + AST symbols) |
| `:Find @deps <query>` | | Search in project dependencies (`node_modules`, `.venv`, `.lake`) |
| `:Find @algo <query>` | | Search CP-Algorithms and data structures |
| `:Find @loogle <query>` | | Search Lean 4 & Mathlib theorems |
| `:Find @docs <query>` | | Search programming language documentation |
| `:History` | `<leader>h` | Open visited files list in recent order |
| `:History clear` | | Reset visited files history |
| `:Listen` | `<leader>v` | Voice-to-text dictation into active buffer via `scribe` |
| `:Synvim help` | | Open floating command and keybinding reference |

---

## 4. Tiling & Split Keybindings

| Keybinding | Action |
| :--- | :--- |
| `Alt + Arrow` | Move focus across splits |
| `Alt + h/j/k/l` | Swap active split with adjacent neighbor |
| `Alt + z` | Toggle zoom / maximize active split |
| `Alt + q` / `Alt + w` | Close active split |
| `Alt + +` | Split right with a new terminal |
| `Alt + _` | Split down with a new terminal |
| `Esc` | Return to Normal mode when at a shell prompt |

---

## 5. Ecosystem Integrations

`synvim` relies on dedicated, modular Syntra Labs tools:
- **Task Management**: Use [`Syntra-Labs/taskflow`](https://github.com/Syntra-Labs/taskflow) for source-first task tracking, DAG dependency resolution, and Two-Layer task specifications.
- **Voice Transcription**: Powered by [`Syntra-Labs/scribe`](https://github.com/Syntra-Labs/scribe).
- **Code Search**: Powered by [`Syntra-Labs/router`](https://github.com/Syntra-Labs/router).
- **Practice & Clean-Room Slicing**: Use [`Syntra-Labs/tutor`](https://github.com/Syntra-Labs/tutor).
