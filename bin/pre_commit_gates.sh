#!/usr/bin/env bash
# pre_commit_gates.sh: Multi-Language Documentation Gates & Pre-Commit Pipeline Specification Stubs

# SPEC(precommit-env-setup | tier:A | blocks:[precommit-lang-gates]):
#   action:    Install pre-commit globally or via system package manager (pip/brew), create blank .pre-commit-config.yaml at repository root, and run pre-commit install to wire local .git/hooks/pre-commit.
#   requires:  []
#   ensures:   review: "pre-commit --version succeeds and .git/hooks/pre-commit executable exists"
#   invariant: "Existing repository git hooks and configuration files are preserved"
#   modifies:  [.pre-commit-config.yaml, .git/hooks/pre-commit]

# SPEC(precommit-lang-gates | tier:B | blocks:[precommit-central-pipeline]):
#   action:    Add #![deny(missing_docs)] and cargo clippy -- -D missing_docs for Rust; configure ruff rule codes D101, D102, D103 in pyproject.toml for Python; add set_option linter.missingDocs true in Lean 4 source files; configure Doxygen WARN_IF_UNDOCUMENTED = YES or clang-tidy rules for C++.
#   requires:  [precommit-env-setup]
#   ensures:   review: "Compiler/linter runs across all four languages flag undocumented symbols and succeed on documented code"
#   invariant: "Existing compiler build scripts and lakefile configurations remain unbroken"
#   modifies:  [pyproject.toml, src/lib.rs, specs/lakefile.toml]

# SPEC(precommit-central-pipeline | tier:B | blocks:[precommit-validation-testing]):
#   action:    Populate .pre-commit-config.yaml with repos block defining ruff (D101, D102, D103), local rust-docs hook executing cargo clippy -- -D missing_docs, and local lean-docs hook executing lake build.
#   requires:  [precommit-lang-gates]
#   ensures:   review: "pre-commit validate-config confirms valid YAML schema and all repo hook entrypoints resolve"
#   invariant: "Pre-commit configuration schema strictly conforms to pre-commit standard"
#   modifies:  [.pre-commit-config.yaml]

# SPEC(precommit-validation-testing | tier:B):
#   action:    Execute positive test run (pre-commit run --all-files) on documented codebase; execute negative test verifying bare function commit is aborted with exact line error; document git commit --no-verify emergency bypass.
#   requires:  [precommit-central-pipeline]
#   ensures:   review: "Negative test blocks git commit, positive test passes cleanly, and --no-verify bypasses hook"
#   invariant: "Emergency escape hatch --no-verify remains functional for WIP commits"
#   modifies:  [bin/pre_commit_gates.sh, specs/SPEC.md]
