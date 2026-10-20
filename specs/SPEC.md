# Prover Geometric Engine & LeanDojo Application Specification

This document is the normative specification for the **Prover Theorem Proving System** (`prover`), integrating Casey Allard's **UOR-R4 214M Geometric Language Model** with **LeanDojo** for automated theorem proving in Lean 4.

## 1. Scope and End-to-End Application Architecture

The Prover application automates formal mathematical reasoning by coupling geometric deep learning with interactive Lean 4 kernel feedback:

```text
               ┌────────────────────────────────────────────────────────┐
               │              Lean 4 Theorem Target                     │
               │         (Statement, Context, Open Subgoals)            │
               └──────────────────────────┬─────────────────────────────┘
                                          │
                                          ▼
               ┌────────────────────────────────────────────────────────┐
               │                 LeanDojo Interface                     │
               │    (Environment Lifecycle, Goal Extraction, REPL)     │
               └──────────────────────────┬─────────────────────────────┘
                                          │
                        Active Goal State │ Normalized Syntax
                                          ▼
               ┌────────────────────────────────────────────────────────┐
               │           UOR-R4 214M Geometric Policy                 │
               │  - Tokenizer: Byte-Pair Encoding without UNK dropping   │
               │  - Associative Scan: S^3 Unit Quaternions / Cl(3,0)    │
               │  - Discrete Quantization: 8D Conway-Sloane E8 Snapping │
               │  - Emission: Top-k Candidate Tactics & Arguments       │
               └──────────────────────────┬─────────────────────────────┘
                                          │
                        Candidate Tactics │ Ranked Actions
                                          ▼
               ┌────────────────────────────────────────────────────────┐
               │              Proof Search State Machine                │
               │  - Search Frontier: Best-First Search with Confidence   │
               │  - Depth & Step Budget Bounds                          │
               │  - Kernel Execution via LeanDojo                       │
               │  - Goal Resolution: Proven / Exhausted / Backtrack     │
               └──────────────────────────┬─────────────────────────────┘
                                          │
                                          ▼
               ┌────────────────────────────────────────────────────────┐
               │           Certified Lean 4 Proof Script                │
               │       (Kernel-replayed with 0 sorry / 0 err)           │
               └────────────────────────────────────────────────────────┘
```

In accordance with the PrismPM standard:
- Application behavior, interaction states, and geometric transformations are derived strictly from formal `.lex.tex` specifications.
- State transitions and mathematical invariants are formally proven in Lean 4 (`leanprover/lean4:v4.32.1`) prior to artifact emission.
- Anti-drift git hooks mechanically enforce task DAG acyclicity (`lgcc --lint-tasks` / `tasks`) and LexLean formal compiler verification (`lexlean check` / `lgcc --verify-specs`) on every commit.

### 1.1 Formal Task Graph Nodes as Interpretations of Informal English Sentences

In Syntra, task nodes are not mere trackers or passive comments. Each node in the Task Graph DAG serves as a **formal, machine-checked interpretation of an informal English requirement sentence**:
1. **Semantic Grounding**: Unstructured natural language developer intent (`TODO: ...` / `FIXME: ...`) is lifted into structured AST contracts with explicit execution tiers (`Tier A`, `Tier B`, `Tier C`), unique IDs, and causal DAG edges (`depends_on`, `blocks`).
2. **Contractual Invariants**: Every task contract binds an English specification description to non-vacuous algebraic and logical properties formalized in LexLean and proven by Lean 4 kernel replay.
3. **Dual Execution Environment**: The verification and task navigation pipeline operates symmetrically across both editor and command line: inside Neovim via `:Tasks` and `:Lgcc`, and in the terminal via `tasks` and `lgcc`.

---

## 2. Core Subsystems

### 2.1 LeanDojo Interactive Kernel Interface
- **Environment Management**: Initializes sandbox Lean 4 project environments (`leanprover/lean4`).
- **Goal State Tracking**: Extracts active hypotheses, target propositions, and open subgoal indices (`GoalState`).
- **Tactic Execution**: Sends candidate tactic strings to the Lean 4 kernel via LeanDojo/Pantograph and parses kernel responses:
  - `GoalsClosed`: Current goal discharged with 0 remaining subgoals.
  - `SubgoalsOpen`: Tactic accepted, generating $k \ge 1$ new subgoals.
  - `KernelError`: Tactic rejected by Lean 4 kernel (syntax error, type mismatch, failed unifier).
  - `KernelTimeout`: Execution timed out beyond safety budget.

### 2.2 UOR-R4 Geometric Policy Engine
- **Representation**: Native Rust `uor-r4` runtime using associative prefix scans over unit quaternions $\mathbf{q} \in S^3 \subset \mathbb{H}$.
- **Discrete Quantization**: 64-dimensional hidden states are segmented into eight 8-dimensional blocks:
  $$\mathbf{x} = [\mathbf{b}_0, \mathbf{b}_1, \dots, \mathbf{b}_7], \quad \mathbf{b}_i \in \mathbb{R}^8$$
- **Conway-Sloane $E_8$ Snapping**:
  Each block is mapped to the nearest point in the Gosset root lattice $E_8$:
  $$E_8 = D_8 \cup \left(D_8 + \frac{1}{2}\mathbf{1}\right)$$
  where $D_8 = \left\{ \mathbf{x} \in \mathbb{Z}^8 : \sum_{i=1}^8 x_i \equiv 0 \pmod 2 \right\}$.
- **Tactic Selection**: Snapped lattice Voronoi cells map directly to the 50 canonical Mathlib 4 tactics (`intro`, `exact`, `apply`, `simp`, `rw`, `ring`, `omega`, `rfl`, `cases`, `induction`, etc.).

### 2.3 Search Engine & State Machine
- **State Space**: Search nodes track `(goalCount, depth, steps)` bounded by `SearchLimits(maxSteps, maxDepth)`.
- **Status Invariant**: Engine advances through formal lifecycle states:
  - `Searching`: Active exploration of proof branches.
  - `SuccessProven`: All initial and spawned subgoals closed by verified kernel tactics.
  - `BudgetExhausted`: Step or depth budget exceeded without closure.
  - `SearchFailed`: All search tree branches exhausted without finding a proof.

---

## 3. Formal Types in LexLean (`ProverEngine.lex.tex`)

The formal semantic module defines the exact machine-checked data structures and functions:

| Type / Constructor | Category | Semantics |
| :--- | :--- | :--- |
| `Quaternion4` | Structure | Four-coordinate $(w, x, y, z)$ quaternion in $\mathbb{R}^4$. |
| `LatticeVector8` | Structure | Eight-coordinate $(x_0, \dots, x_7)$ vector in $\mathbb{R}^8$. |
| `quaternionNormSq` | Definition | Squared Euclidean norm $\|q\|^2 = w^2 + x^2 + y^2 + z^2$ via checked arithmetic. |
| `isUnitQuaternion` | Definition | Boolean predicate verifying closure on the 3-sphere $\|q\|^2 = 1$. |
| `latticeCoordSum` | Definition | Checked 8-coordinate summation $\sum_{i=0}^7 x_i$. |
| `latticeParityValid` | Definition | Boolean predicate verifying $E_8$ Gosset root lattice parity closure ($\sum x_i \equiv 0 \pmod 2$). |
| `TacticKind` | Inductive | Canonical Lean 4 tactic vocabulary (`Intro`, `Exact`, `Apply`, `Simp`, etc.). |
| `isClosingTactic` | Definition | Identifies goal-discharging tactics (`Exact`, `Rfl`, `Assumption`). |
| `isSubgoalTactic` | Definition | Identifies subgoal-generating structural tactics (`Intro`, `Apply`, `Simp`, `Rw`, `Ring`, `Omega`, `Cases`). |
| `isClassifiedTactic` | Definition | Total taxonomy predicate verifying complete partition of the discrete tactic space. |
| `KernelStatus` | Inductive | Lean 4 kernel evaluation outcome (`GoalsClosed`, `SubgoalsOpen`, `KernelError`, `KernelTimeout`). |
| `SearchStatus` | Inductive | Application search state (`Searching`, `SuccessProven`, `BudgetExhausted`, `SearchFailed`). |
| `SearchState` | Structure | Runtime tracking: `(goalCount: int64, depth: int64, steps: int64)`. |
| `SearchLimits` | Structure | Exploration bounds: `(maxSteps: int64, maxDepth: int64)`. |
| `nextSearchStatus` | Definition | Deterministic state transition mapping `(current, feedback) -> next_status`. |
| `isTerminalStatus` | Definition | Boolean predicate identifying terminal search states (`SuccessProven`, `BudgetExhausted`, `SearchFailed`). |
| `isTerminalPreserved` | Definition | Universal preservation predicate mapping `(status, feedback) -> Bool`. |
| `isAdmissibleError` | Definition | Exhaustive error admissibility predicate ensuring total handling of `EngineError`. |
| `acceptance` | Definition | Root platform acceptance combining terminal search status, $S^3$ unit norm closure, and $E_8$ parity closure. |

---

## 4. Machine-Checked Theorems (Lean 4 Kernel Verified)

The formal specification proves nineteen machine-checked theorems verified by `lexlean check`, `lexlean verify`, and the Lean 4 kernel (`leanprover/lean4:v4.32.1`), comprising concrete witness checks and universal quantified closure proofs:

### 4.1 Universal Quantified Closure Theorems
1. **`calculate_coord_correct`**: $\forall \text{left}, \text{right} : \text{Int64}$, checked arithmetic evaluation is reflexively sound.
2. **`universal_engine_errors_admissible`**: $\forall \text{err} : \text{EngineError}$, total error admissibility holds via exhaustive case analysis (`cases err`).
3. **`universal_tactic_classification_complete`**: $\forall t : \text{TacticKind}$, every discrete tactic belongs to either the terminal or subgoal partition via exhaustive case analysis (`cases t`).
4. **`universal_success_proven_absorbing`**: $\forall k : \text{KernelStatus}, \text{nextSearchStatus}(\text{SuccessProven}, k) = \text{SuccessProven}$ (absorbing terminal closure under all possible kernel feedback).
5. **`universal_budget_exhausted_absorbing`**: $\forall k : \text{KernelStatus}, \text{nextSearchStatus}(\text{BudgetExhausted}, k) = \text{BudgetExhausted}$.
6. **`universal_search_failed_absorbing`**: $\forall k : \text{KernelStatus}, \text{nextSearchStatus}(\text{SearchFailed}, k) = \text{SearchFailed}$.
7. **`universal_terminal_success_is_terminal`**: $\forall k : \text{KernelStatus}, \text{isTerminalStatus}(\text{nextSearchStatus}(\text{SuccessProven}, k)) = \text{true}$.
8. **`universal_terminal_budget_is_terminal`**: $\forall k : \text{KernelStatus}, \text{isTerminalStatus}(\text{nextSearchStatus}(\text{BudgetExhausted}, k)) = \text{true}$.
9. **`universal_terminal_failed_is_terminal`**: $\forall k : \text{KernelStatus}, \text{isTerminalStatus}(\text{nextSearchStatus}(\text{SearchFailed}, k)) = \text{true}$.
10. **`universal_terminal_status_preserved`**: $\forall s : \text{SearchStatus}, \forall k : \text{KernelStatus}, \text{isTerminalPreserved}(s, k) = \text{true}$ (universal state machine invariant proven via `cases s`).

### 4.2 State Machine Transition Theorems
11. **`closed_goals_yields_success`**: $\text{nextSearchStatus}(\text{Searching}, \text{GoalsClosed}) = \text{SuccessProven}$.
12. **`terminal_success_is_terminal`**: $\text{isTerminalStatus}(\text{SuccessProven}) = \text{true}$.
13. **`initial_search_state_goals`**: Initial search state starts with exactly 1 active goal.

### 4.3 Geometric Witness & Acceptance Theorems
14. **`quaternion_identity_w`**: Scalar component of $\mathbf{1}_{S^3}$ equals $1$.
15. **`quaternion_identity_norm_sq`**: $\|\mathbf{1}_{S^3}\|^2 = 1^2 + 0^2 + 0^2 + 0^2 = 1$ under checked arithmetic.
16. **`quaternion_identity_is_unit`**: $\text{isUnitQuaternion}(\mathbf{1}_{S^3}) = \text{true}$, certifying $S^3$ unit norm closure.
17. **`lattice_origin_x0`**: Coordinate $x_0$ of $\mathbf{0}_{\mathbb{R}^8}$ equals $0$.
18. **`lattice_origin_coord_sum`**: Coordinate sum $\sum_{i=0}^7 (\mathbf{0}_{\mathbb{R}^8})_i$ equals $0$.
19. **`lattice_origin_even_parity`**: $\text{latticeParityValid}(\mathbf{0}_{\mathbb{R}^8}) = \text{true}$, certifying $E_8$ Gosset root lattice parity closure ($\sum x_i \equiv 0 \pmod 2$).
20. **`acceptance_is_true`**: Composite library acceptance predicate evaluates to $\text{true}$.

---

## 5. Continuous Conformance and Anti-Drift Verification

Every commit to the repository must satisfy:
1. `python3 scripts/lint_tasks.py`: Complete acyclicity of the 12-task DAG and anti-erasure log tracking.
2. `python3 scripts/lint_diff_size.py --staged`: Reviewability budget enforcement: max 300 modified lines per commit.
3. `python3 scripts/lint_diff_size.py --compare-base origin/leanDojo`: Reviewability budget enforcement: max 500 modified lines per Pull Request.
4. `./vendor/prismpm/vendor/lexlean/target/debug/lexlean --project specs/lexlean.toml check`: Complete semantic validation and canonical JSON link check of `specs/src/ProverEngine.lex.tex`.
5. `./vendor/prismpm/vendor/lexlean/target/debug/lexlean --project specs/lexlean.toml verify`: Complete Lean 4 kernel verification and attestation under pinned toolchain `leanprover/lean4:v4.32.1`.
6. `./vendor/prismpm/target/debug/prismpm --project specs check`: Holographic native library conformance and acceptance root validation.
7. Pre-push gate: Rejection of direct pushes to `leanDojo` or `prover`, requiring audited pull requests.
8. GitHub Actions CI: `.github/workflows/ci.yml` runs reviewability audits (task DAG and diff limits), LexLean kernel verification, PrismPM acceptance conformance, and pytest falsification tests on all PRs targeting `leanDojo`.

---

## 6. Multi-Language Documentation Gates & Pre-Commit Pipeline

### Phase 1: Environment Setup
First, install the framework globally or via your system package manager using the command pip install pre-commit or brew install pre-commit. Next, create a blank configuration file named .pre-commit-config.yaml at the root of your project directory. Finally, run pre-commit install in your terminal to register the pipeline hooks into your local .git/hooks/pre-commit binary structure.

### Phase 2: Configure Language-Specific Gates
For Rust configuration, add the directive #![deny(missing_docs)] to your root source files like src/lib.rs or src/main.rs. The local pipeline will execute cargo clippy -- -D missing_docs to find undocumented items.
For Python configuration, install ruff or pydocstyle locally. The pipeline will configure ruff via your pyproject.toml file to actively monitor rule codes D101 for Classes, D102 for Public Methods, and D103 for Public Functions.
For Lean 4 configuration, explicitly set your compilation parameters directly in your source files. Add the line set_option linter.missingDocs true to your source files to trigger native compiler errors during the execution of lake build.
For C++ configuration, set up a lightweight Doxyfile or configure a custom clang-tidy ruleset. Ensure the key WARN_IF_UNDOCUMENTED = YES is enabled inside your configuration profile, and pipe the validation output to fail the commit if missing documentation warnings are flagged.

### Phase 3: Centralized Configuration Pipeline
Write the master setup inside your .pre-commit-config.yaml schema file. Populate this configuration file with target entry blocks that match your project structure:
```yaml
repos:
  - repo: https://github.com
    rev: v0.3.0
    hooks:
      - id: ruff
        args: [ --select, "D101,D102,D103" ]

  - repo: local
    hooks:
      - id: rust-docs
        name: Rust Missing Docs Check
        entry: cargo clippy -- -D missing_docs
        language: system
        types: [rust]
        pass_filenames: false

  - repo: local
    hooks:
      - id: lean-docs
        name: Lean 4 Docs Check
        entry: lake build
        language: system
        types: [lean]
        pass_filenames: false
```

### Phase 4: Validation and Edge Case Testing
Perform a positive test passing case by writing fully documented functions across your active languages and executing pre-commit run --all-files to verify everything passes safely.
Perform a negative test blocking case by intentionally adding a bare function without any documentation comments. Attempt to run git commit to ensure the local pipeline aborts the tracking process and outputs the exact file error line.
Establish local escape hatches by documenting the usage of the command git commit --no-verify for emergencies when developers need to temporarily bypass checks locally, such as checking out a quick work-in-progress branch.
