-- ==============================================================================
-- e2e_diff_suite.lua: Comprehensive End-to-End Test Suite for synvim Diff Engine
-- ==============================================================================

local diff_mod = require("agent.diff")
local reviews_mod = require("agent.reviews")
local tasks_mod = require("agent.tasks")
local state_mod = require("agent.state")
local ui = require("agent.ui")

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
print("  Running synvim Diff & Review Engine End-to-End Edge Case Tests  ")
print("==================================================================")

-- -----------------------------------------------------------------------------
-- TEST 1: Intra-line Word Replacement (Token Level)
-- -----------------------------------------------------------------------------
print("\n[TEST 1] Intra-line Word Replacement")
do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local val = compute_old_metric(data)" })
  local old_lines = { "local val = compute_old_metric(data)" }
  local new_content = "local val = compute_new_metric(data)"

  diff_mod.show_inline_diff(buf, 1, new_content, 1, false, old_lines, { task_id = "test-1" })

  local marks = vim.api.nvim_buf_get_extmarks(buf, state_mod.ns_diff, 0, -1, { details = true })
  local found_inline_del = false
  local found_add_hl = false
  for _, m in ipairs(marks) do
    local d = m[4]
    if d.virt_text_pos == "inline" and d.virt_text and d.virt_text[1][2] == "AgentDiffDeleteWord" then
      if d.virt_text[1][1]:find("compute_old_metric") then
        found_inline_del = true
      end
    end
    if d.hl_group == "AgentDiffAddWord" and m[3] == 12 then -- col 12 is 'compute_new_metric'
      found_add_hl = true
    end
  end

  assert_true(found_inline_del, "Inline delete extmark inserted for old word with AgentDiffDeleteWord")
  assert_true(found_add_hl, "Word addition highlight applied to new word with AgentDiffAddWord")

  diff_mod.clear_diff(true)
  local after_clear = vim.api.nvim_buf_get_extmarks(buf, state_mod.ns_diff, 0, -1, {})
  assert_eq(#after_clear, 0, "Namespace completely cleared after clear_diff")
end

-- -----------------------------------------------------------------------------
-- TEST 2: Intra-line Mid-String Pure Deletion
-- -----------------------------------------------------------------------------
print("\n[TEST 2] Intra-line Mid-String Pure Deletion")
do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "def query(user_id, deprecated_flag, timeout):" })
  local old_lines = { "def query(user_id, deprecated_flag, timeout):" }
  local new_content = "def query(user_id, timeout):"

  diff_mod.show_inline_diff(buf, 1, new_content, 1, false, old_lines, { task_id = "test-2" })

  local marks = vim.api.nvim_buf_get_extmarks(buf, state_mod.ns_diff, 0, -1, { details = true })
  local found_del = false
  for _, m in ipairs(marks) do
    local d = m[4]
    if d.virt_text_pos == "inline" and d.virt_text then
      if d.virt_text[1][1]:find("deprecated_flag") then
        found_del = true
      end
    end
  end

  assert_true(found_del, "Deleted argument rendered inline with strikethrough at exact column")
  diff_mod.clear_diff(true)
end

-- -----------------------------------------------------------------------------
-- TEST 3: Intra-line Pure Insertion at End of Call
-- -----------------------------------------------------------------------------
print("\n[TEST 3] Intra-line Pure Insertion at End of Call")
do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "def query(user_id):" })
  local old_lines = { "def query(user_id):" }
  local new_content = "def query(user_id, timeout=30):"

  diff_mod.show_inline_diff(buf, 1, new_content, 1, false, old_lines, { task_id = "test-3" })

  local marks = vim.api.nvim_buf_get_extmarks(buf, state_mod.ns_diff, 0, -1, { details = true })
  local found_add = false
  local found_del = false
  for _, m in ipairs(marks) do
    local d = m[4]
    if d.hl_group == "AgentDiffAddWord" then
      found_add = true
    end
    if d.virt_text_pos == "inline" then
      found_del = true
    end
  end

  assert_true(found_add, "Inserted parameter highlighted with AgentDiffAddWord")
  assert_true(not found_del, "No inline deletion text created for pure parameter addition")
  diff_mod.clear_diff(true)
end

-- -----------------------------------------------------------------------------
-- TEST 4: Punctuation / Operator Change (+ to -)
-- -----------------------------------------------------------------------------
print("\n[TEST 4] Punctuation / Operator Sensitivity (+ to -)")
do
  local inlines, adds = diff_mod.compute_char_diff("return a + b", "return a - b")
  assert_eq(#inlines, 1, "Exactly 1 inline deletion detected")
  assert_true(inlines[1].text:find("+") ~= nil, "Inline deletion contains '+' operator")
  assert_eq(#adds, 1, "Exactly 1 addition range detected")
  assert_eq(adds[1].start_col, 9, "Addition starts at column of '-' operator")
end

-- -----------------------------------------------------------------------------
-- TEST 5: Multi-line Pure Deletion (No replacement lines)
-- -----------------------------------------------------------------------------
print("\n[TEST 5] Multi-line Pure Deletion (No replacement lines)")
do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local a = 1", "local b = 2", "local c = 3", "local d = 4" })
  local old_lines = { "local a = 1", "local b = 2", "local c = 3", "local d = 4" }
  local new_content = "local a = 1\nlocal d = 4"

  diff_mod.show_inline_diff(buf, 1, new_content, 4, false, old_lines, { task_id = "test-5" })

  local marks = vim.api.nvim_buf_get_extmarks(buf, state_mod.ns_diff, 0, -1, { details = true })
  local virt_lines_count = 0
  for _, m in ipairs(marks) do
    local d = m[4]
    if d.virt_lines then
      virt_lines_count = virt_lines_count + #d.virt_lines
      assert_true(d.virt_lines[1][1][1]:find("- local b = 2") ~= nil, "Virtual line contains deleted line 'local b = 2'")
      assert_true(d.virt_lines[2][1][1]:find("- local c = 3") ~= nil, "Virtual line contains deleted line 'local c = 3'")
    end
  end

  assert_eq(virt_lines_count, 2, "Exactly 2 virtual deleted lines rendered at anchor")
  diff_mod.clear_diff(true)
end

-- -----------------------------------------------------------------------------
-- TEST 6: Multi-line Pure Addition
-- -----------------------------------------------------------------------------
print("\n[TEST 6] Multi-line Pure Addition")
do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local a = 1" })
  local old_lines = { "local a = 1" }
  local new_content = "local a = 1\nlocal b = 2\nlocal c = 3"

  diff_mod.show_inline_diff(buf, 1, new_content, 1, false, old_lines, { task_id = "test-6" })

  local marks = vim.api.nvim_buf_get_extmarks(buf, state_mod.ns_diff, 0, -1, { details = true })
  local added_line_hls = 0
  for _, m in ipairs(marks) do
    local d = m[4]
    if d.line_hl_group == "AgentDiffAdd" then
      added_line_hls = added_line_hls + 1
    end
  end

  assert_eq(added_line_hls, 2, "2 newly added lines highlighted with AgentDiffAdd")
  diff_mod.clear_diff(true)
end

-- -----------------------------------------------------------------------------
-- TEST 7: Guard Against LLM Repeating Function Signature on Comment Insertion
-- -----------------------------------------------------------------------------
print("\n[TEST 7] De-duplication Guard when LLM repeats function signature")
do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "// Existing file header",
    "void calculate_quaternion_metrics() {",
    "    return true;",
    "}",
  })

  -- LLM attempts to insert comment above line 2, but repeats line 2 in content!
  local new_content = "// Clarification comment\nvoid calculate_quaternion_metrics() {"

  diff_mod.show_inline_diff(buf, 2, new_content, 0, false, {}, { task_id = "test-7" })

  -- Check lines in buffer: must NOT have two calculate_quaternion_metrics lines!
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local sig_count = 0
  for _, l in ipairs(lines) do
    if l:find("calculate_quaternion_metrics") then
      sig_count = sig_count + 1
    end
  end

  assert_eq(sig_count, 1, "Redundant function signature was stripped; exactly 1 signature line exists")
  assert_true(lines[2]:find("// Clarification comment") ~= nil, "Comment inserted cleanly above signature")
  diff_mod.clear_diff(true)
end

-- -----------------------------------------------------------------------------
-- TEST 8: Contract Header Preservation Guard (No Multi-header Duplication)
-- -----------------------------------------------------------------------------
print("\n[TEST 8] Contract Header Preservation Guard")
do
  local orig = {
    "# TODO(gate-e8 | tier:A | blocks:[unify-bundle]): Test Conway-Sloane",
    "# Description: Test entropy",
    "# Criterion: assert entropy >= 3.0",
  }

  -- Case A: new_lines uses bracket syntax [gate-e8 | ...]
  local new_bracket = {
    "# [gate-e8 | tier:A | blocks:[unify-bundle] | status:DONE] Conway-Sloane",
    "# Description: Test entropy",
    "# Criterion: assert entropy >= 3.0",
    "def test_e8(): pass",
  }

  local res_bracket = diff_mod.ensure_contract_preserved_as_done(orig, new_bracket)
  assert_eq(#res_bracket, 4, "Bracket syntax contract NOT duplicated; length remains 4")
  assert_true(res_bracket[1]:find("gate%-e8") ~= nil, "Contract header preserved in place")

  -- Case B: new_lines has standard TODO(gate-e8)
  local new_todo = {
    "# TODO(gate-e8 | tier:A | blocks:[unify-bundle] | status:TODO): Test Conway-Sloane",
    "def test_e8(): pass",
  }
  local res_todo = diff_mod.ensure_contract_preserved_as_done(orig, new_todo)
  assert_eq(#res_todo, 2, "TODO contract NOT duplicated; length remains 2")
  assert_true(res_todo[1]:find("status:DONE") ~= nil, "Status updated to DONE in place")
end

-- -----------------------------------------------------------------------------
-- TEST 9: Quickfix Window Protection (Never Hijack Task List)
-- -----------------------------------------------------------------------------
print("\n[TEST 9] Quickfix Window Protection")
do
  local cur_win = vim.api.nvim_get_current_win()
  state_mod.state.origin_win = cur_win

  -- Open quickfix window
  vim.cmd("botright copen 5")
  local qf_win = vim.api.nvim_get_current_win()
  local qf_buf = vim.api.nvim_win_get_buf(qf_win)
  assert_eq(vim.bo[qf_buf].buftype, "quickfix", "Quickfix window opened successfully")

  -- Call get_primary_editor_win while focused inside quickfix
  local resolved_win = ui.get_primary_editor_win()
  assert_true(resolved_win ~= qf_win, "get_primary_editor_win NEVER returns quickfix window")
  assert_eq(resolved_win, cur_win, "get_primary_editor_win routes back to calling origin window")

  vim.cmd("cclose")
end

-- -----------------------------------------------------------------------------
-- TEST 10: Full Preview & Revert Lifecycle
-- -----------------------------------------------------------------------------
print("\n[TEST 10] Full Preview & Revert Lifecycle")
do
  local test_file = vim.fn.tempname() .. ".py"
  local original_content = "def initial_function():\n    return 42\n"
  vim.fn.writefile(vim.split(original_content, "\n"), test_file)

  local bufnr = vim.fn.bufadd(test_file)
  vim.fn.bufload(bufnr)

  local rev = {
    id = "rev-test-lifecycle",
    target_file = test_file,
    abs_file = test_file,
    start_line = 1,
    old_lines_count = 2,
    old_lines = { "def initial_function():", "    return 42" },
    new_lines = { "def updated_function():", "    return 100" },
  }

  reviews_mod.show_review(rev)

  local during = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
  assert_true(during:find("updated_function") ~= nil, "Preview shows updated lines during active diff")

  -- Reject and revert
  diff_mod.clear_diff(false)

  local after = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
  assert_true(after:find("initial_function") ~= nil, "Buffer lines fully reverted back to original after reject")

  local on_disk = vim.fn.readfile(test_file)[1]
  assert_true(on_disk:find("initial_function") ~= nil, "File on disk fully reverted back to original")

  vim.fn.delete(test_file)
end

-- -----------------------------------------------------------------------------
-- SUMMARY
-- -----------------------------------------------------------------------------
print("\n==================================================================")
print(string.format("  TEST RUN COMPLETE: %d Passed, %d Failed", passed, failed))
print("==================================================================")

if failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qall")
end
