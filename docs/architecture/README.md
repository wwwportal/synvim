# synvim Architecture

This document describes the architectural layout, core subsystems, data flow, and interaction patterns of **synvim**—a Neovim configuration, terminal workspace, native C++20 acceleration layer, and source-anchored AI agent execution environment.

---

## 1. System Component Architecture

The following PlantUML diagram models the end-to-end component architecture, linking user interaction modalities, the Neovim agent runtime, the native C++20 FFI layer, external search providers, filesystem persistence, and AI backends.

Source file: [`docs/architecture/synvim_architecture.puml`](file:///home/yassine/code/synvim/docs/architecture/synvim_architecture.puml) | Rendered: [SVG](file:///home/yassine/code/synvim/docs/architecture/synvim_architecture.svg) / [PNG](file:///home/yassine/code/synvim/docs/architecture/synvim_architecture.png)

![synvim Architecture](file:///home/yassine/code/synvim/docs/architecture/synvim_architecture.svg)

---

## 2. System Use Case Diagram

Models user capabilities across the four core pillars: Unified Tasks & TDD Engineering, Hybrid Code & Knowledge Search (`:Find`), Session Analytics & Navigation (`:History`), and Interactive Voice Assistance.

Source file: [`docs/architecture/synvim_use_cases.puml`](file:///home/yassine/code/synvim/docs/architecture/synvim_use_cases.puml) | Rendered: [SVG](file:///home/yassine/code/synvim/docs/architecture/synvim_use_cases.svg) / [PNG](file:///home/yassine/code/synvim/docs/architecture/synvim_use_cases.png)

![synvim Use Cases](file:///home/yassine/code/synvim/docs/architecture/synvim_use_cases.svg)

---

## 3. In-Line Task & TDD Verification Activity Flow

Captures the decision points and state progression of the developer experience from initial architectural model review, through two-layer task specification, interactive placement, TDD test scaffolding and red-phase gating, agent synthesis, and character-level diff approval.

Source file: [`docs/architecture/task_activity.puml`](file:///home/yassine/code/synvim/docs/architecture/task_activity.puml) | Rendered: [SVG](file:///home/yassine/code/synvim/docs/architecture/task_activity.svg) / [PNG](file:///home/yassine/code/synvim/docs/architecture/task_activity.png)

![synvim Task Activity](file:///home/yassine/code/synvim/docs/architecture/task_activity.svg)

---

## 4. Core Domain Model & Class Architecture

Illustrates the underlying domain abstractions, relationships, interfaces, and native C++20 FFI bindings that power the system.

Source file: [`docs/architecture/synvim_domain_model.puml`](file:///home/yassine/code/synvim/docs/architecture/synvim_domain_model.puml) | Rendered: [SVG](file:///home/yassine/code/synvim/docs/architecture/synvim_domain_model.svg) / [PNG](file:///home/yassine/code/synvim/docs/architecture/synvim_domain_model.png)

![synvim Domain Model](file:///home/yassine/code/synvim/docs/architecture/synvim_domain_model.svg)

---

## 5. In-Line Task Specification & Review Sequence

Models the precise inter-component message exchange and execution timeline between Neovim UI, command dispatchers, image viewers, task engines, test runners, and AI execution backends.

Source file: [`docs/architecture/task_lifecycle.puml`](file:///home/yassine/code/synvim/docs/architecture/task_lifecycle.puml) | Rendered: [SVG](file:///home/yassine/code/synvim/docs/architecture/task_lifecycle.svg) / [PNG](file:///home/yassine/code/synvim/docs/architecture/task_lifecycle.png)

![synvim Task Lifecycle](file:///home/yassine/code/synvim/docs/architecture/task_lifecycle.svg)

---

## 6. Core Architectural Subsystems

### 6.1. Native C++20 FFI Engines (`c_src/` -> `libsynvim_*.so`)

synvim accelerates computational hot paths using native C++20 shared libraries loaded through LuaJIT FFI:
- **`libsynvim_search.so`**: High-performance in-memory search engine. Combines FZF Smith-Waterman subsequence scoring, Okapi BM25 natural-language term weighting, 5-line sliding-window proximity scoring, CamelCase/snake_case boundary tokenization, and symbol definition boosts.
- **`libsynvim_dtl.so`**: Eugene Myers $O(ND)$ difference algorithm implemented with linear-space divide-and-conquer refinement for token- and character-level diff computation.
- **`libsynvim_anchor.so`**: High-throughput regex anchor parser for in-tree task contracts, Hoare-logic clauses, and code symbols.
- **`libsynvim_image.so`**: Direct Kitty graphics protocol escape sequence encoder and LuaJIT FFI `libpng` rasterizer and bilinear scaler.

### 6.2. Neovim Agent Subsystem (`nvim/lua/agent/`)

- [`agent/init.lua`](file:///home/yassine/code/synvim/nvim/lua/agent/init.lua): Central initialization point. Maps user commands (`:Tasks`, `:Find`, `:History`, `:Ask`, `:Synvim`, `:Git`) and wires callbacks into submodules.
- [`agent/tasks.lua`](file:///home/yassine/code/synvim/nvim/lua/agent/tasks.lua): End-to-end task workflow manager. Enforces architectural model review, opens the Two-Layer Task Form, manages the interactive placement queue (`<M-p>` / `<M-s>`), maintains the dependency DAG in `.agent/task_index.json`, and drives the TDD test gate (`:Tasks test [id]`).
- [`agent/image.lua`](file:///home/yassine/code/synvim/nvim/lua/agent/image.lua): Native Kitty graphics protocol viewer (`z=1`). Powers side-by-side PlantUML live editing, zoom/pan controls, and terminal image rendering in Ghostty, Kitty, and Tmux.
- [`agent/search.lua`](file:///home/yassine/code/synvim/nvim/lua/agent/search.lua) & [`agent/algos.lua`](file:///home/yassine/code/synvim/nvim/lua/agent/algos.lua): Multi-tag hybrid search orchestrator. Queries native FFI repository indices, installed dependencies (`@deps`), Lean 4 Loogle (`@loogle`), documentation (`@docs`), public GitHub code (`@code`), and CP-Algorithms / NIST DADS catalog with Wikipedia REST API live fallback (`@algo`).
- [`agent/history.lua`](file:///home/yassine/code/synvim/nvim/lua/agent/history.lua): Tracks visited files as a clean, deduplicated vertical list in recent order. Logs active session time (`BufEnter`/`BufLeave`), character edits (`on_bytes`), nearest task/symbol context badges, and exports to Quickfix (`:History qf / list`).
- [`agent/diff.lua`](file:///home/yassine/code/synvim/nvim/lua/agent/diff.lua): Character- and line-level diff renderer using `libsynvim_dtl.so`. Applies extmarks and virtual lines above target regions and handles contract promotion to `(status:DONE)`.
- [`agent/reviews.lua`](file:///home/yassine/code/synvim/nvim/lua/agent/reviews.lua): Manages review records stored in `.agent/reviews/<id>.json`. Guarantees atomic staging and instant reverts (`revert_review`).
- [`agent/llm.lua`](file:///home/yassine/code/synvim/nvim/lua/agent/llm.lua): Non-blocking asynchronous task execution using `vim.fn.jobstart`. Parses raw stdout/stderr wire protocols and extracts structured JSON solutions.
- [`agent/ui.lua`](file:///home/yassine/code/synvim/nvim/lua/agent/ui.lua): UI layout managers handling docked bottom input splits (`open_docked_input`), two-layer forms, and the floating manual (`:Synvim help`).
- [`agent/state.lua`](file:///home/yassine/code/synvim/nvim/lua/agent/state.lua): Global singleton tracking active jobs, queue indices, pending diff extmarks, and terminal context.

### 6.3. Voice Input Subsystem (`nvim/lua/voice.lua`)

Provides hands-free voice-to-text queries. Captures audio via system recording tools (`rec` / `sox`) and invokes [`bin/agent_transcribe.py`](file:///home/yassine/code/synvim/bin/agent_transcribe.py) powered by Whisper. The transcribed prompt is automatically injected into `:Ask` or `:Tasks add`.

### 6.4. Standalone CLI Engine (`bin/agent`)

A source-first execution engine implemented in Python that mirrors Neovim's agent capabilities in headless terminal environments or CI pipelines:
- Inspects codebases for `SPEC(...)` and `TODO(...)` comments.
- Dispatches prompts to OpenCode or Antigravity (`agy`) with automatic failover.
- Connects to running Neovim sessions via Unix domain sockets located at `/run/user/<uid>/nvim.<pid>.0` to drive interactive in-editor diff reviews.

### 6.5. In-Tree Contract Format & Verification

Tasks are anchored directly into source files using language-appropriate comment syntax:

```text
# SPEC(<id> | tier:<A|B|C> | blocks:[<id>] | depends_on:[<id>]):
#   action:    <Task instruction>
#   requires:  [<prerequisites>]
#   ensures:   review: "<Verification criteria>"
#   invariant: "<Safety or architectural constraints>"
#   modifies:  [<affected files>]
```

This ensures that tasks remain persistent, version-controlled with the codebase, and immune to session crashes.

---

## 7. Diagram Generation Script

To render or update the SVG and PNG images from the `.puml` files at any time, run:

```bash
./docs/architecture/generate_diagrams.sh
```

### Options:
- **`--format <svg|png|all>`**: Select the output image format (defaults to `all`).
- **`--engine <auto|local|docker|kroki>`**: Choose the rendering engine (defaults to `auto`, which checks local `plantuml`, `docker`, and seamlessly falls back to Kroki API with zero dependencies required).
- **`-o, --output-dir <path>`**: Set custom output directory.
