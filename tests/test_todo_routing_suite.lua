-- ==============================================================================
-- tests/test_todo_routing_suite.lua: Verification of Smart Contextual TODO Routing
-- ==============================================================================

local script_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local repo_root = vim.fn.fnamemodify(script_dir, ":h")
vim.opt.rtp:prepend(repo_root .. "/nvim")
package.path = repo_root .. "/nvim/lua/?.lua;" .. repo_root .. "/nvim/lua/?/init.lua;" .. package.path

local tasks = require("agent.tasks")

local passed = 0
local failed = 0

local function assert_eq(actual, expected, msg)
  if actual == expected then
    passed = passed + 1
    print(string.format("  PASS: %s", msg))
  else
    failed = failed + 1
    print(string.format("  FAIL: %s (expected '%s', got '%s')", msg, tostring(expected), tostring(actual)))
  end
end

local function assert_true(cond, msg)
  if cond then
    passed = passed + 1
    print(string.format("  PASS: %s", msg))
  else
    failed = failed + 1
    print(string.format("  FAIL: %s", msg))
  end
end

print("==================================================================")
print("  Running synvim Smart Contextual TODO Routing Test Suite         ")
print("==================================================================")

local tmp_dir = vim.fn.tempname()
vim.fn.mkdir(tmp_dir, "p")

-- -----------------------------------------------------------------------------
-- TEST 1: Shebang Preservation in Shell Script
-- -----------------------------------------------------------------------------
print("\n[TEST 1] Shebang Preservation in Shell Script")
do
  local f = tmp_dir .. "/script.sh"
  vim.fn.writefile({
    "#!/usr/bin/env bash",
    "set -euo pipefail",
    "",
    "echo 'running script'",
  }, f)

  local bufnr = vim.fn.bufadd(f)
  vim.fn.bufload(bufnr)

  -- When LLM or user requests line 1 (or nil), shebang MUST NOT be overwritten
  local idx, indent = tasks.find_optimal_insertion_line(bufnr, f, "add health check", "add-health-check", 1)
  assert_true(idx >= 1, "Insertion index is at or after line 2 (0-based index >= 1)")
  assert_eq(idx, 1, "Placed immediately below shebang")

  -- Also test with requested_line = nil
  local idx_nil = tasks.find_optimal_insertion_line(bufnr, f, "add health check", "add-health-check", nil)
  assert_eq(idx_nil, 1, "Nil line also preserves shebang")
end

-- -----------------------------------------------------------------------------
-- TEST 2: Python Module Docstring & Imports Preservation
-- -----------------------------------------------------------------------------
print("\n[TEST 2] Python Module Docstring & Imports Preservation")
do
  local f = tmp_dir .. "/module.py"
  vim.fn.writefile({
    "#!/usr/bin/env python3",
    '"""',
    "Module level documentation docstring.",
    "Describes overall package architecture.",
    '"""',
    "import os",
    "import sys",
    "from typing import List, Dict",
    "",
    "def calculate_metrics():",
    "    return {}",
  }, f)

  local bufnr = vim.fn.bufadd(f)
  vim.fn.bufload(bufnr)

  -- General task without specific symbol: should be placed AFTER imports
  local idx, indent = tasks.find_optimal_insertion_line(bufnr, f, "implement telemetry export", "implement-telemetry-export", 1)
  assert_true(idx >= 8, "Placed after all import statements (expected index >= 8, got " .. tostring(idx) .. ")")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  assert_true(lines[1]:find("^#!") ~= nil, "Shebang remains at line 1")
  assert_true(lines[2]:find('^"""') ~= nil, "Docstring start remains at line 2")
  assert_true(lines[5]:find('^"""') ~= nil, "Docstring end remains at line 5")
end

-- -----------------------------------------------------------------------------
-- TEST 3: Target Symbol Contextual Placement (Functions & Classes)
-- -----------------------------------------------------------------------------
print("\n[TEST 3] Target Symbol Contextual Placement")
do
  local f = tmp_dir .. "/service.py"
  vim.fn.writefile({
    "import logging",
    "",
    "class AccountService:",
    "    def __init__(self):",
    "        pass",
    "",
    "    @decorator_one",
    "    @decorator_two",
    "    def update_balance(self, amount: float):",
    "        pass",
    "",
    "    def delete_account(self, uid: str):",
    "        pass",
  }, f)

  local bufnr = vim.fn.bufadd(f)
  vim.fn.bufload(bufnr)

  -- Action refers to 'update_balance'
  local action = "add input validation to update_balance method"
  local idx, indent = tasks.find_optimal_insertion_line(bufnr, f, action, "add-input-validation-to-update-balance", 1)
  -- Lines:
  -- 1: import logging
  -- 2:
  -- 3: class AccountService:
  -- 4:     def __init__(self):
  -- 5:         pass
  -- 6:
  -- 7:     @decorator_one (index 6)
  -- 8:     @decorator_two (index 7)
  -- 9:     def update_balance(self, amount: float): (index 8)
  assert_eq(idx, 6, "Placed directly above decorators for update_balance (index 6)")
  assert_eq(indent, "    ", "Inherited 4-space indentation from method definition")

  -- Action refers to 'AccountService'
  local action_cls = "refactor AccountService initialization"
  local idx_cls, indent_cls = tasks.find_optimal_insertion_line(bufnr, f, action_cls, "refactor-accountservice", 1)
  assert_eq(idx_cls, 2, "Placed directly above class AccountService (index 2)")
  assert_eq(indent_cls, "", "Inherited top-level indentation for class")
end

-- -----------------------------------------------------------------------------
-- TEST 4: Rust Inner Attributes & Symbol Routing
-- -----------------------------------------------------------------------------
print("\n[TEST 4] Rust Inner Attributes & Symbol Routing")
do
  local f = tmp_dir .. "/lib.rs"
  vim.fn.writefile({
    "//! Crate level inner doc comment",
    "#![deny(missing_docs)]",
    "",
    "use std::collections::HashMap;",
    "use std::sync::Arc;",
    "",
    "#[derive(Debug, Clone)]",
    "pub struct EngineConfig {",
    "    pub timeout: u64,",
    "}",
    "",
    "pub fn start_worker() {",
    "}",
  }, f)

  local bufnr = vim.fn.bufadd(f)
  vim.fn.bufload(bufnr)

  -- Action refers to 'EngineConfig'
  local idx, indent = tasks.find_optimal_insertion_line(bufnr, f, "add retries field to EngineConfig", "add-retries-to-engineconfig", 1)
  -- Lines:
  -- 1: //! (index 0)
  -- 2: #![deny] (index 1)
  -- 3:
  -- 4: use HashMap (index 3)
  -- 5: use Arc (index 4)
  -- 6:
  -- 7: #[derive] (index 6)
  -- 8: pub struct EngineConfig (index 7)
  assert_eq(idx, 6, "Placed directly above #[derive] for EngineConfig (index 6)")

  -- General action: should be placed after use statements
  local idx_gen = tasks.find_optimal_insertion_line(bufnr, f, "general maintenance task", "general-maintenance-task", 1)
  assert_eq(idx_gen, 5, "Placed after use statements (index 5)")
end

-- -----------------------------------------------------------------------------
-- TEST 5: YAML & GitHub Actions Workflow Indentation
-- -----------------------------------------------------------------------------
print("\n[TEST 5] YAML & GitHub Actions Workflow Indentation")
do
  local f = tmp_dir .. "/ci.yml"
  vim.fn.writefile({
    "name: CI Pipeline",
    "on: [push, pull_request]",
    "",
    "jobs:",
    "  build:",
    "    runs-on: ubuntu-latest",
    "    steps:",
    "      - uses: actions/checkout@v4",
    "      - name: Run Tests",
    "        run: cargo test",
  }, f)

  local bufnr = vim.fn.bufadd(f)
  vim.fn.bufload(bufnr)

  local idx, indent = tasks.find_optimal_insertion_line(bufnr, f, "add code coverage reporting step", "add-code-coverage-reporting-step", 1)
  assert_eq(idx, 7, "Placed inside steps: block (line index 7)")
  assert_true(#indent >= 6, "Inherited indented step formatting in YAML")
end

-- -----------------------------------------------------------------------------
-- TEST 6: Explicit User Line Requested
-- -----------------------------------------------------------------------------
print("\n[TEST 6] Explicit User Line Requested")
do
  local f = tmp_dir .. "/user_req.py"
  vim.fn.writefile({
    "#!/usr/bin/env python3",
    "line 2",
    "line 3",
    "line 4",
    "line 5",
  }, f)

  local bufnr = vim.fn.bufadd(f)
  vim.fn.bufload(bufnr)

  -- User explicitly requested line 4
  local idx, _ = tasks.find_optimal_insertion_line(bufnr, f, "user specific line", "user-specific-line", 4)
  assert_eq(idx, 3, "Explicit line 4 maps to 0-based index 3")

  -- User requested line 0 on file with shebang -> clamped past shebang (index 1)
  local idx_0, _ = tasks.find_optimal_insertion_line(bufnr, f, "top line with shebang", "top-line-with-shebang", 0)
  assert_eq(idx_0, 1, "Line 0 on file with shebang clamped to index 1 (line 2)")
end

print("\n==================================================================")
print(string.format("  SMART ROUTING SUITE COMPLETE: %d Passed, %d Failed", passed, failed))
print("==================================================================")

if failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qall!")
end
