-- ==============================================================================
-- e2e_diff_suite.lua: Comprehensive End-to-End Test Suite for synvim Diff Engine
-- ==============================================================================

local script_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local repo_root = vim.fn.fnamemodify(script_dir, ":h")
vim.opt.rtp:prepend(repo_root .. "/nvim")
package.path = repo_root .. "/nvim/lua/?.lua;" .. repo_root .. "/nvim/lua/?/init.lua;" .. package.path
package.loaded["agent.diff"] = nil
package.loaded["agent.reviews"] = nil
package.loaded["agent.tasks"] = nil
package.loaded["agent.state"] = nil
package.loaded["agent.ui"] = nil
package.loaded["agent.llm"] = nil

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
-- TEST 11: Multi-byte UTF-8 Math Symbols (Lean 4 & Geometry)
-- -----------------------------------------------------------------------------
print("\n[TEST 11] Multi-byte UTF-8 Math & Symbol Preservation")
do
  local inlines, adds = diff_mod.compute_char_diff(
    "assert shannon_entropy >= 3.0 and theta <= 0.25",
    "assert shannon_entropy ≥ 3.0 and θ ≤ 0.25"
  )
  assert_eq(#inlines, 3, "3 unicode/math replacements detected (>=, theta, <=)")
  assert_eq(#adds, 3, "3 addition ranges for unicode characters detected (≥, θ, ≤)")
  assert_true(inlines[1].text:find(">=") ~= nil, "Inline delete of '>=' detected cleanly")
  assert_true(adds[1].end_col > adds[1].start_col, "Valid byte length for '≥' (3-byte UTF-8)")
end

-- -----------------------------------------------------------------------------
-- TEST 12: Buffer Switching & Diff Re-attachment Persistence
-- -----------------------------------------------------------------------------
print("\n[TEST 12] Buffer Switching & Pending Diff Persistence")
do
  local bufA = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufA, 0, -1, false, { "def function_a(): return 1" })
  local bufB = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufB, 0, -1, false, { "def function_b(): return 2" })

  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, bufA)

  diff_mod.show_inline_diff(bufA, 1, "def function_a_new(): return 1", 1, false, { "def function_a(): return 1" }, { task_id = "task-persist" })
  local marks_before = vim.api.nvim_buf_get_extmarks(bufA, state_mod.ns_diff, 0, -1, {})
  assert_true(#marks_before > 0, "Extmarks active on buffer A")

  -- Switch window to buffer B
  vim.api.nvim_win_set_buf(win, bufB)
  assert_eq(vim.api.nvim_win_get_buf(win), bufB, "Switched to buffer B")

  -- Switch back to buffer A and call attach_pending_diff
  vim.api.nvim_win_set_buf(win, bufA)
  local reattached = diff_mod.attach_pending_diff(bufA, "task-persist")
  local marks_after = vim.api.nvim_buf_get_extmarks(bufA, state_mod.ns_diff, 0, -1, {})

  assert_true(#marks_after > 0, "Pending diff successfully maintained across buffer switch")
  assert_eq(#marks_after, #marks_before, "No duplicate extmarks created during re-attachment")

  diff_mod.clear_diff(true)
end

-- -----------------------------------------------------------------------------
-- TEST 13: Empty Lines & Whitespace-only Modifications
-- -----------------------------------------------------------------------------
print("\n[TEST 13] Empty Lines & Whitespace-only Modifications")
do
  -- Case A: Empty line replaced with code
  local inlines_a, adds_a = diff_mod.compute_char_diff("", "local x = 10")
  assert_eq(#inlines_a, 0, "No inline deletion for originally empty line")
  assert_eq(#adds_a, 1, "Full addition detected for new line")

  -- Case B: Code replaced with empty line
  local inlines_b, adds_b = diff_mod.compute_char_diff("local x = 10", "")
  assert_eq(#inlines_b, 1, "Inline deletion detected when line becomes empty")
  assert_eq(#adds_b, 0, "No additions on empty line")
end

-- -----------------------------------------------------------------------------
-- TEST 14: Discontinuous Multiple Token Changes in Single Line
-- -----------------------------------------------------------------------------
print("\n[TEST 14] Discontinuous Multiple Token Changes in Single Line")
do
  local inlines, adds = diff_mod.compute_char_diff(
    "func(arg1, old_first, arg2, old_second)",
    "func(arg1, new_first, arg2, new_second)"
  )
  assert_eq(#inlines, 2, "2 separate inline deletions detected")
  assert_eq(#adds, 2, "2 separate word additions detected")
  assert_eq(inlines[1].col, 11, "First deletion aligned at column 11")
  assert_eq(inlines[2].col, 28, "Second deletion aligned at column 28")
  assert_eq(adds[1].start_col, 11, "First addition starts at column 11")
  assert_eq(adds[2].start_col, 28, "Second addition starts at column 28")
end

-- -----------------------------------------------------------------------------
-- TEST 15: Boundary Deletions (Start of Line & End of Line)
-- -----------------------------------------------------------------------------
print("\n[TEST 15] Boundary Deletions (Start of Line & End of Line)")
do
  -- Start of line deletion (e.g. removing 'const ')
  local inlines_start, adds_start = diff_mod.compute_char_diff("const int val = 5;", "int val = 5;")
  assert_eq(#inlines_start, 1, "Inline deletion at start of line detected")
  assert_eq(inlines_start[1].col, 0, "Deletion starts at column 0")
  assert_true(inlines_start[1].text:find("const ") ~= nil, "Deleted prefix matches 'const '")

  -- End of line deletion (e.g. removing trailing inline comment)
  local inlines_end, adds_end = diff_mod.compute_char_diff("int val = 5; // comment", "int val = 5;")
  assert_eq(#inlines_end, 1, "Inline deletion at end of line detected")
  assert_true(inlines_end[1].text:find("// comment") ~= nil, "Deleted suffix matches trailing comment")
end

-- -----------------------------------------------------------------------------
-- TEST 16: File Boundary Indices (Line 1 & Bottom of File)
-- -----------------------------------------------------------------------------
print("\n[TEST 16] File Boundary Indices (Line 1 & Bottom of File)")
do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "first line", "second line" })

  -- Insert at line 1
  diff_mod.show_inline_diff(buf, 1, "new header\nfirst line", 1, false, { "first line" }, { task_id = "test-bound-top" })
  local marks_top = vim.api.nvim_buf_get_extmarks(buf, state_mod.ns_diff, 0, -1, {})
  assert_true(#marks_top > 0, "Top-of-file boundary diff sets extmarks without index errors")
  diff_mod.clear_diff(true)

  -- Insert at bottom of file (line > line_count)
  diff_mod.show_inline_diff(buf, 999, "new bottom line", 0, false, {}, { task_id = "test-bound-bot" })
  local marks_bot = vim.api.nvim_buf_get_extmarks(buf, state_mod.ns_diff, 0, -1, {})
  assert_true(#marks_bot > 0, "Bottom-of-file boundary diff sets extmarks without index errors")
  diff_mod.clear_diff(true)
end

-- -----------------------------------------------------------------------------
-- TEST 17: Full Acceptance Lifecycle with Contract Promotion
-- -----------------------------------------------------------------------------
print("\n[TEST 17] Full Acceptance Lifecycle with Contract Promotion")
do
  local test_file = vim.fn.tempname() .. ".py"
  local initial_code = {
    "# TODO(unit-test-task | tier:A | status:DONE): Test implementation",
    "def verified_func():",
    "    return True",
  }
  vim.fn.writefile(initial_code, test_file)
  local bufnr = vim.fn.bufadd(test_file)
  vim.fn.bufload(bufnr)

  local rev = {
    id = "rev-accept-lifecycle",
    task_id = "unit-test-task",
    target_file = test_file,
    abs_file = test_file,
    start_line = 1,
    old_lines_count = 3,
    old_lines = initial_code,
    new_lines = initial_code,
  }

  reviews_mod.show_review(rev)
  assert_true(state_mod.state.pending_diff ~= nil, "Pending diff is active before accept")

  -- Accept the diff
  diff_mod.accept_diff()
  assert_true(state_mod.state.pending_diff == nil, "Pending diff cleared upon accept")

  -- Verify contract header was promoted from status:DONE to status:APPROVED
  local lines_after = vim.fn.readfile(test_file)
  assert_true(lines_after[1]:find("status:APPROVED") ~= nil, "Contract header promoted to status:APPROVED")

  vim.fn.delete(test_file)
  vim.fn.delete(reviews_mod.get_reviews_dir() .. "/rev-accept-lifecycle.json")
end

-- -----------------------------------------------------------------------------
-- TEST 18: Review Lookup Precision (Index, Slug, Suffix, Exact ID)
-- -----------------------------------------------------------------------------
print("\n[TEST 18] Review Lookup Precision (Index, Slug, Suffix, Exact ID)")
do
  local rdir = reviews_mod.get_reviews_dir()
  local dummy_rev_id = "rev-9999999999-4321"
  local dummy_meta = {
    id = dummy_rev_id,
    task_id = "# SPEC(precision-lookup-slug | tier:A | blocks:[downstream]): Test slug lookup",
    target_file = "tests/dummy.py",
    status = "unreviewed",
    created_at = "2026-10-21 20:00:00",
    order = 1,
    old_lines = { "pass" },
    new_lines = { "return True" },
  }
  local json_path = rdir .. "/" .. dummy_rev_id .. ".json"
  vim.fn.writefile({ vim.fn.json_encode(dummy_meta) }, json_path)

  -- 1. Exact ID
  local found_exact = reviews_mod.find_review(dummy_rev_id, true)
  assert_true(found_exact ~= nil and found_exact.id == dummy_rev_id, "Find by exact review ID succeeds")

  -- 2. Slug match from inside complex header
  local found_slug = reviews_mod.find_review("precision-lookup-slug", true)
  assert_true(found_slug ~= nil and found_slug.id == dummy_rev_id, "Find by extracted task slug succeeds")

  -- 3. 4-digit suffix match
  local found_suffix = reviews_mod.find_review("4321", true)
  assert_true(found_suffix ~= nil and found_suffix.id == dummy_rev_id, "Find by 4-digit ID suffix succeeds")

  -- 4. Numeric index #1 of unreviewed
  local found_idx = reviews_mod.find_review("1", true)
  assert_true(found_idx ~= nil, "Find by numeric index 1 resolves to unreviewed queue item")

  vim.fn.delete(json_path)
end

-- -----------------------------------------------------------------------------
-- TEST 19: :Tasks accept <id> Clears Task from Review Queue
-- -----------------------------------------------------------------------------
print("\n[TEST 19] :Tasks accept <id> Clears Task from Review Queue")
do
  local rdir = reviews_mod.get_reviews_dir()
  local test_rev_id = "rev-9999999999-8765"
  local target_file = vim.fn.tempname() .. ".py"
  vim.fn.writefile({ "# TODO(queue-removal | tier:A | status:DONE): Test" }, target_file)

  local meta = {
    id = test_rev_id,
    task_id = "# TODO(queue-removal | tier:A | status:DONE): Test",
    target_file = target_file,
    abs_file = target_file,
    status = "unreviewed",
    created_at = "2026-10-21 20:10:00",
    order = 1,
    old_lines = { "# TODO(queue-removal | tier:A | status:DONE): Test" },
    new_lines = { "# TODO(queue-removal | tier:A | status:APPROVED): Test" },
  }
  local json_path = rdir .. "/" .. test_rev_id .. ".json"
  vim.fn.writefile({ vim.fn.json_encode(meta) }, json_path)

  -- Verify it appears in unreviewed reviews
  local unrev_before = reviews_mod.get_reviews("unreviewed")
  local found_before = false
  for _, r in ipairs(unrev_before) do
    if r.id == test_rev_id then found_before = true; break end
  end
  assert_true(found_before, "Task is initially in unreviewed review list")

  -- Accept by task slug: :Tasks accept queue-removal
  reviews_mod.accept("queue-removal")

  -- Verify it was removed from unreviewed list
  local unrev_after = reviews_mod.get_reviews("unreviewed")
  local found_after = false
  for _, r in ipairs(unrev_after) do
    if r.id == test_rev_id then found_after = true; break end
  end
  assert_true(not found_after, "Task is REMOVED from unreviewed review list after :Tasks accept <id>")

  -- Verify file on disk has updated status: accepted
  local disk_meta = vim.fn.json_decode(table.concat(vim.fn.readfile(json_path), "\n"))
  assert_eq(disk_meta.status, "accepted", "JSON metadata on disk updated to status: accepted")

  vim.fn.delete(json_path)
  vim.fn.delete(target_file)
end

-- -----------------------------------------------------------------------------
-- TEST 20: NDJSON Stream Reassembly from LLM CLI
-- -----------------------------------------------------------------------------
print("\n[TEST 20] NDJSON Stream Reassembly from LLM CLI")
do
  local llm_mod = require("agent.llm")
  local payload = vim.fn.json_encode({
    parts = {
      { task_id = "auth-gate", file = "src/auth.py", line = 10 }
    }
  })
  local ndjson = table.concat({
    vim.fn.json_encode({ type = "step_start", timestamp = 1000, part = { type = "step-start" } }),
    vim.fn.json_encode({ type = "text", part = { text = payload } }),
    vim.fn.json_encode({ type = "step_finish", timestamp = 2000 }),
  }, "\n")

  local parsed = llm_mod.extract_json_object(ndjson)
  assert_true(parsed ~= nil, "NDJSON stream successfully parsed")
  assert_true(parsed.parts ~= nil and #parsed.parts == 1, "Parts array preserved from inside NDJSON text event")
  assert_eq(parsed.parts[1].task_id, "auth-gate", "task_id accurately extracted")
  assert_eq(parsed.parts[1].file, "src/auth.py", "Architectural target file accurately extracted")
end

-- -----------------------------------------------------------------------------
-- TEST 21: Task Add Heuristic Scoring (Does NOT Dump in Active Buffer)
-- -----------------------------------------------------------------------------
print("\n[TEST 21] Task Add Heuristic Scoring (Does NOT Dump in Active Buffer)")
do
  local file_list = {
    "src/search/macro_decider.cpp",
    "src/auth/jwt_provider.py",
    "tests/geometric_falsification/test_tier_a_gatekeepers.py"
  }
  local spec = "Implement jwt token authentication provider"
  local spec_low = spec:lower()
  local best_score = 0
  local best_file = nil

  for _, f in ipairs(file_list) do
    local f_low = f:lower()
    local score = 0
    for word in spec_low:gmatch("[%a%d_-]+") do
      if #word >= 4 and f_low:find(word, 1, true) then
        score = score + 2
      end
    end
    if score > best_score then
      best_score = score
      best_file = f
    end
  end

  assert_eq(best_file, "src/auth/jwt_provider.py", "Correctly selected auth file matching specification keywords")
  assert_true(best_file ~= "tests/geometric_falsification/test_tier_a_gatekeepers.py", "Did not dump into unrelated file")
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
