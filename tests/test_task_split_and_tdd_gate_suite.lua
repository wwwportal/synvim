-- ==============================================================================
-- tests/test_task_split_and_tdd_gate_suite.lua: Line-Anchored Placement, Task Split & Test-First Gate
-- ==============================================================================

local script_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local repo_root = vim.fn.fnamemodify(script_dir, ":h")
vim.opt.rtp:prepend(repo_root .. "/nvim")
package.path = repo_root .. "/nvim/lua/?.lua;" .. repo_root .. "/nvim/lua/?/init.lua;" .. package.path
package.loaded["agent.tasks"] = nil
package.loaded["agent.state"] = nil
package.loaded["agent.ui"] = nil

local tasks = require("agent.tasks")
local state_mod = require("agent.state")

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

print("\n=== [1/4] Testing Test-First Gate in Two-Layer Contract Form & Finalizer ===")
do
  local tmpl = tasks.get_task_form_template("Implement parser token stream", "nvim/lua/agent/tasks.lua")
  assert_true(tmpl:find("test:%s*") ~= nil, "Task form template includes 'test:' field under Hoare contract")

  local parsed = tasks.parse_task_form([[
CONTRACT(lexer-token-stream):
  [HOARE CODE CONTRACT]
  requires:  []
  test:      tests/test_lexer_token_stream.lua
  action:    Implement lexer token stream
  ensures:   Token stream emits EOF token cleanly

  [DTL AGENT POLICY]
  allow:     [nvim/lua/agent/tasks.lua]
  forbid:    [.env*]
  always:    Existing APIs preserved
  repair:    on_violation -> (auto_revert, mark:REVISE)
]])
  assert_eq(#parsed, 1, "Parsed 1 task block")
  assert_eq(parsed[1].test, "tests/test_lexer_token_stream.lua", "Explicit 'test:' field parsed from form")

  local finalized = tasks.finalize_task_specs({
    { task_id = "auto-test-slug", action = "Add binary search helper" },
  }, "nvim/lua/agent/search.lua", {})
  assert_eq(finalized[1].test, "tests/test_auto_test_slug_suite.lua", "Missing 'test:' auto-populated with canonical test suite path")
  assert_true(tasks.validate_task_has_test(finalized[1]), "validate_task_has_test confirms valid test path")
  assert_true(vim.tbl_contains(finalized[1].allow, "tests/test_auto_test_slug_suite.lua"), "DTL allow list automatically permits the associated test file")
end

print("\n=== [2/4] Testing Interactive Task Splitting When Single Location is Ambiguous ===")
do
  local broad_spec = tasks.finalize_task_specs({
    {
      task_id = "broad-cross-cutting-task",
      action = "Refactor parser and update UI renderer",
      allow = { "nvim/lua/agent/tasks.lua", "nvim/lua/agent/ui.lua" },
    },
  }, "nvim/lua/agent/tasks.lua", {})

  tasks.start_placement_mode(broad_spec)
  assert_eq(state_mod.state.placement_active, true, "Placement mode started with 1 broad task")
  assert_eq(#state_mod.state.placement_queue, 1, "1 task initially in placement queue")

  -- Verify <M-s> split keymap is bound in placement mode
  local maps = vim.api.nvim_get_keymap("n")
  local has_split_key = false
  for _, m in ipairs(maps) do
    if m.lhs == "<M-s>" or m.lhs == "<A-s>" then
      has_split_key = true
      break
    end
  end
  assert_true(has_split_key, "In-placement split keybinding (<M-s>) is bound")

  -- Split the ambiguous task into 2 focused, single-location tasks
  local split_tasks = tasks.split_current_placement_task({
    {
      task_id = "refactor-parser-core",
      test = "tests/test_parser_core_suite.lua",
      action = "Refactor parser state machine in tasks.lua",
      allow = { "nvim/lua/agent/tasks.lua" },
    },
    {
      task_id = "update-ui-renderer",
      test = "tests/test_ui_renderer_suite.lua",
      action = "Update UI renderer in ui.lua",
      allow = { "nvim/lua/agent/ui.lua" },
    },
  })

  assert_eq(#split_tasks, 2, "Broad task split into 2 smaller tasks")
  assert_eq(#state_mod.state.placement_queue, 2, "Placement queue now holds the 2 split sub-tasks")
  assert_eq(state_mod.state.placement_queue[1].task_id, "refactor-parser-core", "First split task is active at placement index")
  assert_eq(state_mod.state.placement_queue[2].requires[1], "refactor-parser-core", "Second split task automatically requires first split task")
  assert_eq(state_mod.state.placement_queue[1].test, "tests/test_parser_core_suite.lua", "First split task has dedicated test")
  assert_eq(state_mod.state.placement_queue[2].test, "tests/test_ui_renderer_suite.lua", "Second split task has dedicated test")
  tasks.stop_placement_mode(true)
end

print("\n=== [3/4] Testing Carve & Drop at Location A -> Carry Remainder to Location B ===")
do
  local tmp_dir = vim.fn.tempname()
  vim.fn.mkdir(tmp_dir, "p")
  vim.fn.system({ "git", "-C", tmp_dir, "init" })
  local prev_cwd = vim.fn.getcwd()
  vim.fn.chdir(tmp_dir)

  local file_a = tmp_dir .. "/module_a.lua"
  local file_b = tmp_dir .. "/module_b.lua"
  vim.fn.writefile({
    "local M = {}",
    "",
    "function M.parse()",
    "  return true",
    "end",
    "",
    "return M",
  }, file_a)
  vim.fn.writefile({
    "local UI = {}",
    "function UI.render()",
    "  return nil",
    "end",
    "return UI",
  }, file_b)

  local buf_a = vim.fn.bufadd(file_a)
  vim.fn.bufload(buf_a)
  local buf_b = vim.fn.bufadd(file_b)
  vim.fn.bufload(buf_b)
  vim.api.nvim_set_current_buf(buf_a)

  -- Start placement mode with a single cross-cutting task
  local single_broad = tasks.finalize_task_specs({
    {
      task_id = "cross-cutting-feature",
      action = "Add parser AST node in module_a and render it in module_b",
    },
  }, "module_a.lua", {})
  tasks.start_placement_mode(single_broad)
  assert_eq(#state_mod.state.placement_queue, 1, "Started with 1 broad task on cursor")

  -- At Location A (module_a.lua:3), press <M-s> / carve_and_drop_at_cursor:
  -- Carves off 'refactor-parser-core' and drops it immediately at module_a.lua:3,
  -- while keeping 'update-ui-renderer' on the cursor in Placement Mode for Location B!
  tasks.carve_and_drop_at_cursor(
    {
      task_id = "refactor-parser-core",
      test = "tests/test_parser_core_suite.lua",
      action = "Refactor parser state machine in module_a.lua",
      allow = { "module_a.lua" },
    },
    {
      task_id = "update-ui-renderer",
      test = "tests/test_ui_renderer_suite.lua",
      action = "Update UI renderer in module_b.lua",
      allow = { "module_b.lua" },
    },
    buf_a,
    3
  )

  assert_eq(state_mod.state.placement_active, true, "Placement mode remains active after carving & dropping at Location A")
  assert_eq(#state_mod.state.placement_queue, 1, "Remainder task is now the active queued task on cursor")
  assert_eq(state_mod.state.placement_queue[1].task_id, "update-ui-renderer", "Remainder task on cursor is 'update-ui-renderer'")
  assert_eq(state_mod.state.placement_queue[1].requires[1], "refactor-parser-core", "Remainder task Hoare precondition requires the carved sub-task dropped at Location A")

  -- Navigate to Location B (module_b.lua:2) and drop the remainder with <M-p>
  vim.api.nvim_set_current_buf(buf_b)
  tasks.drop_current_task_at_cursor(buf_b, 2)
  assert_eq(state_mod.state.placement_active, false, "Placement mode exited after dropping remainder at Location B")

  print("\n=== [4/4] Testing Scanner Extraction of Associated Test & Multi-File Anchors ===")
  local scanned = tasks.scan_repository_tasks(tmp_dir)
  local by_id = {}
  for _, t in ipairs(scanned) do
    by_id[t.task_id] = t
  end

  assert_true(by_id["refactor-parser-core"] ~= nil, "Scanner found carved task in module_a.lua")
  assert_eq(by_id["refactor-parser-core"].file, "module_a.lua", "Carved task placed in module_a.lua")
  assert_eq(by_id["refactor-parser-core"].test, "tests/test_parser_core_suite.lua", "Scanner extracted 'test:' field for carved task")
  assert_eq(by_id["refactor-parser-core"].line, 3, "Carved task anchored at exact target line 3 in module_a.lua")

  assert_true(by_id["update-ui-renderer"] ~= nil, "Scanner found remainder task in module_b.lua")
  assert_eq(by_id["update-ui-renderer"].file, "module_b.lua", "Remainder task placed in module_b.lua")
  assert_eq(by_id["update-ui-renderer"].test, "tests/test_ui_renderer_suite.lua", "Scanner extracted 'test:' field for remainder task")
  assert_eq(by_id["update-ui-renderer"].requires[1], "refactor-parser-core", "Remainder task in module_b.lua requires carved task in module_a.lua")

  pcall(vim.api.nvim_buf_delete, buf_a, { force = true })
  pcall(vim.api.nvim_buf_delete, buf_b, { force = true })
  vim.fn.chdir(prev_cwd)
  pcall(vim.fn.delete, tmp_dir, "rf")
end

if failed > 0 then
  error(string.format("%d test(s) failed in test_task_split_and_tdd_gate_suite.lua", failed))
end
print(string.format("\n=== ALL %d TASK SPLIT & TEST-FIRST GATE TESTS PASSED ===", passed))
