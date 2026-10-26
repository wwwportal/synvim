-- ==============================================================================
-- tests/test_tasks_cli_simplify_suite.lua: Simplified :Tasks CLI & ':Tasks test <id>' Suite
-- ==============================================================================

local script_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local repo_root = vim.fn.fnamemodify(script_dir, ":h")
vim.opt.rtp:prepend(repo_root .. "/nvim")
package.path = repo_root .. "/nvim/lua/?.lua;" .. repo_root .. "/nvim/lua/?/init.lua;" .. package.path
package.loaded["agent.tasks"] = nil
package.loaded["agent.state"] = nil
package.loaded["agent.ui"] = nil

local tasks = require("agent.tasks")

local passed = 0
local failed = 0

local function assert_eq(a, b, desc)
  if a == b then
    passed = passed + 1
    print(string.format("  ✓ %s: OK", desc))
  else
    failed = failed + 1
    print(string.format("  ✗ FAIL: %s (expected '%s', got '%s')", desc, tostring(b), tostring(a)))
  end
end

local function assert_true(cond, desc)
  if cond then
    passed = passed + 1
    print(string.format("  ✓ %s: OK", desc))
  else
    failed = failed + 1
    print(string.format("  ✗ FAIL: %s", desc))
  end
end

print("\n=== [1/4] Testing :Tasks Tab-Completion Subcommand Simplification ===")
do
  local completions = tasks.tasks_complete("", "Tasks ")
  local comp_set = {}
  for _, c in ipairs(completions) do
    comp_set[c:lower()] = true
  end

  assert_true(comp_set["list"] == true, "'list' subcommand present")
  assert_true(comp_set["add"] == true, "'add' subcommand present")
  assert_true(comp_set["test"] == true, "'test' subcommand present")

  local removed = { "move", "start", "maybe", "review", "yes", "no", "stop", "accept", "reject", "revise", "resolve", "rebase" }
  for _, r in ipairs(removed) do
    assert_true(comp_set[r] == nil, string.format("Removed subcommand '%s' is absent from tab-completion", r))
  end
end

print("\n=== [2/4] Testing Task ID Tab-Completion for ':Tasks test <id>' ===")
do
  local test_completions = tasks.tasks_complete("", "Tasks test ")
  local found_image_task = false
  for _, id in ipairs(test_completions) do
    if id == "image-viewer-zoom-pan" then
      found_image_task = true
      break
    end
  end
  assert_true(found_image_task, "':Tasks test <Tab>' completes repository task IDs")
end

print("\n=== [3/4] Testing Rejection of Removed Subcommands in tasks_command ===")
do
  local last_msg = nil
  local orig_notify = vim.notify
  vim.notify = function(msg)
    last_msg = msg
  end

  for _, r in ipairs({ "move", "start", "maybe", "review", "yes", "no", "stop" }) do
    last_msg = nil
    tasks.tasks_command(r)
    assert_true(last_msg ~= nil and last_msg:find("Unknown subcommand") ~= nil, string.format("':Tasks %s' rejected as unknown subcommand", r))
  end

  vim.notify = orig_notify
end

print("\n=== [4/4] Testing ':Tasks test <id>' Execution & Missing-Test Scaffolding ===")
do
  local tmp_dir = vim.fn.tempname()
  vim.fn.mkdir(tmp_dir .. "/tests", "p")
  vim.fn.system({ "git", "-C", tmp_dir, "init" })
  local prev_cwd = vim.fn.getcwd()
  vim.fn.chdir(tmp_dir)

  local src_file = tmp_dir .. "/calc.lua"
  vim.fn.writefile({
    "-- CONTRACT(calc-add):",
    "--   [HOARE CODE CONTRACT]",
    "--   requires:  []",
    "--   test:      tests/test_calc_add.lua",
    "--   action:    Implement add(a, b)",
    "--   ensures:   review: \"add(2, 3) == 5\"",
    "--",
    "--   [DTL AGENT POLICY]",
    "--   allow:     [calc.lua, tests/test_calc_add.lua]",
    "--   forbid:    [.env*]",
    "--   always:    review: \"Pure function\"",
    "--   repair:    on_violation -> (auto_revert, mark:REVISE)",
    "local M = {}",
    "function M.add(a, b) return a + b end",
    "return M",
  }, src_file)

  local src_buf = vim.fn.bufadd(src_file)
  vim.fn.bufload(src_buf)
  vim.api.nvim_set_current_buf(src_buf)

  -- 1. When test file does NOT exist yet, :Tasks test <id> scaffolds & opens it
  local res_scaffold = tasks.test_task("calc-add")
  assert_true(res_scaffold ~= nil and res_scaffold.scaffolded == true, "Missing test file scaffolded on first ':Tasks test calc-add'")
  assert_true(vim.fn.filereadable(tmp_dir .. "/tests/test_calc_add.lua") == 1, "Scaffolded test file written to disk")

  -- 2. Write a passing test into tests/test_calc_add.lua and run :Tasks test calc-add
  vim.fn.writefile({
    "local calc = dofile('calc.lua')",
    "assert(calc.add(2, 3) == 5, 'Expected 5')",
    "print('CALC_ADD_TEST_OK')",
  }, tmp_dir .. "/tests/test_calc_add.lua")

  local res_pass = tasks.test_task("calc-add")
  assert_true(res_pass ~= nil, "test_task returned execution result")
  assert_eq(res_pass.status, "PASSED", "':Tasks test calc-add' passed on valid test suite")
  assert_true(res_pass.output:find("CALC_ADD_TEST_OK", 1, true) ~= nil, "Captured test stdout")

  -- 3. Write a failing assertion and verify FAILED status
  vim.fn.writefile({
    "error('Intentional test-first failure')",
  }, tmp_dir .. "/tests/test_calc_add.lua")

  local res_fail = tasks.test_task("calc-add")
  assert_eq(res_fail.status, "FAILED", "':Tasks test calc-add' reports FAILED when test fails")

  pcall(vim.api.nvim_buf_delete, src_buf, { force = true })
  vim.fn.chdir(prev_cwd)
  pcall(vim.fn.delete, tmp_dir, "rf")
end

if failed > 0 then
  error(string.format("%d test(s) failed in test_tasks_cli_simplify_suite.lua", failed))
end
print(string.format("\n=== ALL %d TASKS CLI SIMPLIFY & TEST SUBCOMMAND TESTS PASSED ===", passed))
