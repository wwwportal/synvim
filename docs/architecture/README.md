# synvim Architecture

This document describes the architectural layout, core subsystems, data flow, and interaction patterns of **synvim**—a Neovim configuration, terminal workspace, and source-anchored AI agent execution environment.

---

## 1. System Component Architecture

The following PlantUML diagram models the end-to-end component architecture, linking the user interaction modalities, Neovim agent runtime, CLI engines, filesystem persistence, and external LLM backends.

Source file: [`docs/architecture/synvim_architecture.puml`](file:///home/yassine/code/synvim/docs/architecture/synvim_architecture.puml) | Rendered: [SVG](file:///home/yassine/code/synvim/docs/architecture/synvim_architecture.svg) / [PNG](file:///home/yassine/code/synvim/docs/architecture/synvim_architecture.png)

![synvim Architecture](file:///home/yassine/code/synvim/docs/architecture/synvim_architecture.svg)

```plantuml
@startuml synvim_architecture
!theme plain
skinparam backgroundColor #FFFFFF
skinparam defaultFontName "Helvetica, Arial, sans-serif"
skinparam defaultFontSize 12
skinparam roundCorner 8
skinparam shadowing false

skinparam package {
    BackgroundColor #F8FAFC
    BorderColor #64748B
    FontColor #0F172A
    FontStyle bold
}

skinparam node {
    BackgroundColor #F1F5F9
    BorderColor #475569
    FontColor #0F172A
}

skinparam component {
    BackgroundColor #FFFFFF
    BorderColor #334155
    FontColor #0F172A
    ArrowColor #2563EB
}

skinparam database {
    BackgroundColor #FEF3C7
    BorderColor #D97706
    FontColor #78350F
}

skinparam cloud {
    BackgroundColor #EFF6FF
    BorderColor #3B82F6
    FontColor #1E40AF
}

skinparam actor {
    BackgroundColor #F3E8FF
    BorderColor #7E22CE
    FontColor #581C87
}

title "synvim: System Architecture & Subsystem Interactions"

actor "Developer / User" as user

package "Input & Interaction Modalities" as input_layer {
    component "Terminal & Splits\n(Alt+Keybindings, Alt+z, Alt+h/j/k/l)" as term_mgr
    component "Docked Bottom Split\n(botright 4-line input, <C-s> / Enter)" as docked_split
    component "Live Commandline Preview\n(:Ask, :Find, :Tasks live parsing)" as cmdline_preview
    component "Voice Input Subsystem\n(nvim/lua/voice.lua)" as voice_subsys
}

package "Neovim Plugin Subsystem (nvim/lua/agent)" as nvim_core {
    component "Dispatcher & Command Registry\n(agent/init.lua)\n[:Tasks, :Ask, :Find, :Synvim, :Git]" as agent_init
    component "Shared State Hub\n(agent/state.lua)\n[Job tracking, queues, diff namespaces]" as state_hub
    
    component "Task & Agenda Engine\n(agent/tasks.lua)\n* Task scanner & DAG reindexing\n* Quickfix agenda (:Tasks list)\n* Contract scaffolding (:Tasks add)\n* Queue navigator (<C-n>/<C-p>)" as tasks_engine
    
    component "In-Line Diff Engine\n(agent/diff.lua)\n* Tokenizer & char-level diff\n* Extmarks & virtual staging lines\n* Contract promotion (:DONE)" as diff_engine
    
    component "Review & Staging Manager\n(agent/reviews.lua)\n* Review record builder\n* Atomic accept/reject\n* Rollback & patch applier" as reviews_engine
    
    component "Search & Retrieval\n(agent/search.lua)\n* Query keyword ranker\n* Multi-question splitter\n* Semantic context builder" as search_engine
    
    component "LLM Async Client\n(agent/llm.lua)\n* vim.fn.jobstart runner\n* JSON wire protocol parser\n* Response processor" as llm_client
    
    component "UI & View Components\n(agent/ui.lua)\n* Docked input window\n* Directory preview popup\n* Floating help manual" as ui_components
}

package "CLI Toolset & Scripts (bin/)" as cli_layer {
    component "agent CLI Engine\n(bin/agent)\n* Source scanner\n* Headless & interactive runner\n* LLM engine dispatcher\n* Socket IPC client" as agent_cli
    
    component "Speech Transcriber\n(bin/agent_transcribe.py)\n* Whisper / local speech-to-text" as transcribe_py
    
    component "Pre-Commit Gates & Verifiers\n(bin/pre_commit_gates.sh\nbin/verify_review.sh)" as gates_sh
}

database "Repository & In-Tree State\n(File System)" as storage_layer {
    folder "Source Files with In-Line Contracts\n[SPEC(...) | tier:A/B/C | blocks/depends_on]\n[TODO(...) | FIXME(...)]" as source_contracts
    folder ".agent/reviews/\n[<review_id>.json]\n(Patch, old/new lines, metadata)" as review_store
    file ".agent/task_index.json\n(Topological DAG indices)" as task_index_file
    folder ".git/\n(Hooks, branches, object database)" as git_repo
}

cloud "AI Provider Backends" as ai_cloud {
    component "OpenCode Engine\n(Subagent Execution)" as opencode_engine
    component "Google Antigravity (agy)\n(Failover / Enterprise Engine)" as agy_engine
    component "Local LLM / Custom Endpoints\n(Ollama, Anthropic, OpenAI)" as custom_llm
}

component "Microphone / sox / rec" as mic_hw

user --> term_mgr : Manipulate splits & terminals
user --> docked_split : Enter multi-line prompt / task
user --> cmdline_preview : Type :Ask, :Find, :Tasks
user --> agent_cli : Invoke via terminal / scripts
user --> mic_hw : Voice dictation

mic_hw --> voice_subsys : Capture raw audio
voice_subsys --> transcribe_py : Stream WAV/FLAC audio
transcribe_py --> voice_subsys : Return transcribed text
voice_subsys --> agent_init : Feed into :Ask / :Tasks

cmdline_preview --> agent_init : Dispatch command
docked_split --> agent_init : Submit user query
agent_init --> state_hub : Read / update agent state
agent_init --> tasks_engine : Execute :Tasks [list|add|start|revise]
agent_init --> search_engine : Execute :Find / :Ask
agent_init --> reviews_engine : Execute :Tasks [review|accept|reject]
agent_init --> ui_components : Open help / dir preview

tasks_engine --> source_contracts : Scan & write SPEC(...) contracts
tasks_engine --> task_index_file : Read / write topological index
tasks_engine --> llm_client : Submit task context for synthesis
search_engine --> source_contracts : Keyword & symbol search
search_engine --> llm_client : Ask questions about code

llm_client --> state_hub : Maintain job status & queue
llm_client --> opencode_engine : Stream prompt context via CLI / API
opencode_engine ..> agy_engine : Failover if unavailable
llm_client --> custom_llm : Optional API route

llm_client --> reviews_engine : Yield proposed code modifications
reviews_engine --> review_store : Persist review metadata & diffs
reviews_engine --> diff_engine : Render inline preview in editor
diff_engine --> source_contracts : Apply virtual extmarks & tokens

diff_engine --> reviews_engine : User accepts/rejects changes
reviews_engine --> source_contracts : Commit patch or revert buffer
reviews_engine --> git_repo : Stage approved changes

agent_cli --> source_contracts : Scan task contracts
agent_cli --> review_store : Create / verify / accept review
agent_cli --> opencode_engine : Run execution engine
agent_cli ..> agent_init : Connect via Unix domain socket\n(/run/user/<uid>/nvim.<pid>.0)
gates_sh --> git_repo : Enforce commit verification
@enduml
```

---

## 2. In-Line Task Execution & Review Staging Lifecycle

Source file: [`docs/architecture/task_lifecycle.puml`](file:///home/yassine/code/synvim/docs/architecture/task_lifecycle.puml) | Rendered: [SVG](file:///home/yassine/code/synvim/docs/architecture/task_lifecycle.svg) / [PNG](file:///home/yassine/code/synvim/docs/architecture/task_lifecycle.png)

![synvim Task Lifecycle](file:///home/yassine/code/synvim/docs/architecture/task_lifecycle.svg)

```plantuml
@startuml synvim_task_lifecycle
!theme plain
skinparam backgroundColor #FFFFFF
skinparam defaultFontName "Helvetica, Arial, sans-serif"
skinparam defaultFontSize 12
skinparam roundCorner 8
skinparam shadowing false

skinparam sequence {
    ArrowColor #2563EB
    ActorBorderColor #7E22CE
    LifeLineBorderColor #64748B
    LifeLineBackgroundColor #F1F5F9
    ParticipantBorderColor #334155
    ParticipantBackgroundColor #F8FAFC
    ParticipantFontColor #0F172A
    GroupBorderColor #94A3B8
    GroupBackgroundColor #F8FAFC
    BoxBorderColor #CBD5E1
    BoxBackgroundColor #F8FAFC
}

title "synvim: In-Line Task Execution & Review Staging Sequence"

actor "Developer" as user
box "Neovim Frontend" #F8FAFC
participant "UI / Docked Input\n(agent/ui.lua)" as ui
participant "Command Dispatcher\n(agent/init.lua)" as init
participant "Task Engine\n(agent/tasks.lua)" as tasks
participant "Diff Engine\n(agent/diff.lua)" as diff
participant "Review Manager\n(agent/reviews.lua)" as reviews
end box

box "Agent Runtime" #F1F5F9
participant "LLM Client\n(agent/llm.lua)" as llm
participant "Execution Engine\n(OpenCode / agy)" as engine
end box

box "Repository & Disk" #FEF3C7
participant "Source File\n(SPEC Contract)" as src
participant ".agent/reviews/\n(<id>.json)" as rstore
end box

== 1. Task Definition & Insertion ==
user -> ui : Run :Tasks add (or docked split)
ui -> tasks : insert_single_task_stub()
tasks -> src : Write SPEC(task-id | tier:B | blocks:[...])
tasks -> tasks : reindex_tasks() -> update .agent/task_index.json
tasks --> user : Display in Quickfix Agenda (<leader>q)

== 2. Task Execution ==
user -> init : Run :Tasks start [task-id]
init -> tasks : start_task(task-id)
tasks -> src : Read target SPEC contract & surrounding context
tasks -> llm : run(prompt, context)
llm -> engine : Async spawn via jobstart (wire protocol)
engine --> llm : Stream JSON solution payload {files, diff, contract}
llm -> reviews : process_agent_response()

== 3. Review Staging & In-Line Preview ==
reviews -> rstore : Persist metadata & diff (<id>.json, status: unreviewed)
reviews -> diff : show_inline_diff(bufnr, new_content, old_lines)
diff -> src : Attach extmarks & virtual lines (character-level diff)
diff --> user : Visual inline diff rendered directly in active buffer

== 4. Acceptance or Rejection ==
alt Accept Changes
    user -> init : Run :Tasks accept <id>
    init -> reviews : accept_review(<id>)
    reviews -> diff : accept_diff()
    diff -> src : Apply new lines directly to buffer & write to disk
    diff -> src : Promote contract header to (status:DONE)
    reviews -> rstore : Update status: accepted
    reviews --> user : Success notification & Quickfix refresh
else Reject / Revert Changes
    user -> init : Run :Tasks reject <id>
    init -> reviews : reject(id)
    reviews -> diff : clear_diff()
    diff -> src : Strip virtual lines & restore original buffer lines
    reviews -> rstore : Update status: rejected / reverted
    reviews --> user : Buffer restored to pristine state
end
@enduml
```

---

## 3. Core Architectural Subsystems

### 3.1. Neovim Agent Subsystem (`nvim/lua/agent/`)

- [`agent/init.lua`](file:///home/yassine/code/synvim/nvim/lua/agent/init.lua): Central initialization point. Maps user commands (`:Tasks`, `:Ask`, `:Find`, `:Synvim`, `:Git`) and wires callbacks into submodules.
- [`agent/tasks.lua`](file:///home/yassine/code/synvim/nvim/lua/agent/tasks.lua): Scans project files for in-tree `SPEC(...)` and `TODO(...)` comment contracts. Builds and maintains a topological dependency DAG in `.agent/task_index.json`. Manages the Quickfix agenda window and task decomposition.
- [`agent/diff.lua`](file:///home/yassine/code/synvim/nvim/lua/agent/diff.lua): High-fidelity inline diff renderer. Computes token- and character-level diffs (`compute_char_diff`), applies extmarks and virtual lines above target regions, and handles contract promotion to `(status:DONE)` upon acceptance.
- [`agent/reviews.lua`](file:///home/yassine/code/synvim/nvim/lua/agent/reviews.lua): Manages review records stored in `.agent/reviews/<id>.json`. Guarantees atomic staging and instant reverts (`revert_review`) without leaving dangling edits.
- [`agent/search.lua`](file:///home/yassine/code/synvim/nvim/lua/agent/search.lua): Query parsing, semantic symbol extraction, keyword ranking, and multi-question query splitting (`split_questions`) with question queue navigation (`<C-n>` / `<C-p>`).
- [`agent/llm.lua`](file:///home/yassine/code/synvim/nvim/lua/agent/llm.lua): Non-blocking asynchronous task execution using `vim.fn.jobstart`. Parses raw stdout/stderr wire protocols, extracts structured JSON solutions, and dispatches to OpenCode or Antigravity (`agy`).
- [`agent/cmdline.lua`](file:///home/yassine/code/synvim/nvim/lua/agent/cmdline.lua) & [`agent/ui.lua`](file:///home/yassine/code/synvim/nvim/lua/agent/ui.lua): UI layout managers handling docked bottom input splits (`open_docked_input`), directory tree previews, floating help, and statusline notifications.
- [`agent/state.lua`](file:///home/yassine/code/synvim/nvim/lua/agent/state.lua): Global singleton tracking active jobs, queue indices, pending diff extmarks, and terminal context.

### 3.2. Voice Input Subsystem (`nvim/lua/voice.lua`)

Provides hands-free voice-to-text queries. Captures audio via system recording tools (`rec` / `sox`) and invokes [`bin/agent_transcribe.py`](file:///home/yassine/code/synvim/bin/agent_transcribe.py) powered by Whisper. The transcribed prompt is automatically injected into `:Ask` or `:Tasks add`.

### 3.3. Standalone CLI Engine (`bin/agent`)

A source-first execution engine implemented in Python that mirrors Neovim's agent capabilities in headless terminal environments or CI pipelines:
- Inspects codebases for `SPEC(...)` and `TODO(...)` comments.
- Dispatches prompts to OpenCode or Antigravity (`agy`) with automatic failover.
- Connects to running Neovim sessions via Unix domain sockets located at `/run/user/<uid>/nvim.<pid>.0` to drive interactive in-editor diff reviews.

### 3.4. In-Tree Contract Format & Verification

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

## 4. Diagram Generation Script

To render or update the SVG and PNG images from the `.puml` files at any time, run:

```bash
./docs/architecture/generate_diagrams.sh
```

### Options:
- **`--format <svg|png|all>`**: Select the output image format (defaults to `all`).
- **`--engine <auto|local|docker|kroki>`**: Choose the rendering engine (defaults to `auto`, which checks local `plantuml`, `docker`, and seamlessly falls back to Kroki API with zero dependencies required).
- **`-o, --output-dir <path>`**: Set custom output directory.

