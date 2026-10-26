-- ==============================================================================
-- e2e_tasks_add_suite.lua: Comprehensive End-to-End Edge Case Tests for :Tasks add
-- ==============================================================================

local script_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local repo_root = vim.fn.fnamemodify(script_dir, ":h")
vim.opt.rtp:prepend(repo_root .. "/nvim")
package.path = repo_root .. "/nvim/lua/?.lua;" .. repo_root .. "/nvim/lua/?/init.lua;" .. package.path
package.loaded["agent.tasks"] = nil
package.loaded["agent.reviews"] = nil
package.loaded["agent.diff"] = nil
package.loaded["agent.llm"] = nil
package.loaded["agent.state"] = nil
package.loaded["agent.ui"] = nil

local tasks_mod = require("agent.tasks")
local reviews_mod = require("agent.reviews")
local diff_mod = require("agent.diff")
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
print("  Running synvim :Tasks add Comprehensive Edge Case Test Suite    ")
print("==================================================================")

local tmp_dir = vim.fn.tempname()
vim.fn.mkdir(tmp_dir, "p")
vim.fn.system({ "git", "-C", tmp_dir, "init" })
vim.fn.chdir(tmp_dir)

-- -----------------------------------------------------------------------------
-- SCENARIO 1: Direct File Insertion with Non-Existent Nested Path
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 1] Direct File Insertion with Non-Existent Nested Path")
do
  local nested_file = tmp_dir .. "/deep/nested/sub/module.py"
  local desc = "Implement deep nested feature gate"
  local arg = string.format("%s:1 %s", nested_file, desc)

  tasks_mod.add_task(arg)

  assert_true(vim.fn.filereadable(nested_file) == 1, "Nested file and parent directories created successfully")
  local lines = vim.fn.readfile(nested_file)
  assert_true(#lines >= 1, "File contains written task stub")
  assert_true(lines[1]:find("^# TODO%(implement%-deep%-nested%-feature%-gate | status:TODO%):") ~= nil, "Task stub has proper header and slug")

  -- Verify review record was created
  local unrev = reviews_mod.get_reviews("unreviewed")
  local found = nil
  for _, r in ipairs(unrev) do
    if r.task_id and r.task_id:find("implement-deep-nested-feature-gate", 1, true) then
      found = r
      break
    end
  end
  assert_true(found ~= nil, "Task stub registered in unreviewed review queue")
  assert_true(found.is_task_stub == true, "Review record marked as is_task_stub = true")

  -- Accept review by slug
  reviews_mod.accept("implement-deep-nested-feature-gate")
  local unrev_after = reviews_mod.get_reviews("unreviewed")
  local still_there = false
  for _, r in ipairs(unrev_after) do
    if r.id == found.id then still_there = true; break end
  end
  assert_true(not still_there, "Accepted task stub removed from review queue")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 2: Out-of-bounds Line Indices (0 and beyond EOF)
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 2] Out-of-bounds Line Indices (0 and beyond EOF)")
do
  local test_file = tmp_dir .. "/boundary_lines.py"
  vim.fn.writefile({ "line 1", "line 2", "line 3" }, test_file)

  -- Insert with line = 0 (should clamp to top of file)
  tasks_mod.add_task(string.format("%s:0 Top boundary task", test_file))
  local lines_step1 = vim.fn.readfile(test_file)
  assert_eq(#lines_step1, 4, "File line count incremented by 1")
  assert_true(lines_step1[1]:find("Top boundary task") ~= nil, "Line 0 clamped cleanly to top of file")
  assert_eq(lines_step1[2], "line 1", "Original line 1 preserved right below injected stub")

  -- Insert with line = 99999 (should clamp to end of file)
  tasks_mod.add_task(string.format("%s:99999 Bottom boundary task", test_file))
  local lines_step2 = vim.fn.readfile(test_file)
  assert_eq(#lines_step2, 5, "File line count incremented to 5")
  assert_true(lines_step2[5]:find("Bottom boundary task") ~= nil, "Line 99999 clamped cleanly to end of file")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 3: Complex Characters, Quotes, Colons & Unicode in Description
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 3] Complex Characters, Quotes, Colons & Unicode in Description")
do
  local test_file = tmp_dir .. "/math_symbols.py"
  vim.fn.writefile({ "import math" }, test_file)

  local complex_desc = 'Compute curvature: assert α >= 0.50 and θ <= 0.25 | check: [x, y]'
  local arg = string.format('%s:2 "%s"', test_file, complex_desc)

  tasks_mod.add_task(arg)
  local lines = vim.fn.readfile(test_file)
  assert_eq(#lines, 2, "Task stub inserted at line 2")
  assert_true(lines[2]:find("Compute curvature: assert α >= 0.50 and θ <= 0.25", 1, true) ~= nil, "Unicode symbols α, θ, colons, and operators preserved intact")
  assert_true(lines[2]:find("TODO%([a-zA-Z0-9_%-]+ | status:TODO%)") ~= nil, "Valid sanitized slug generated from unicode description")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 4: Comment Leaders for Diverse Programming Languages
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 4] Comment Leaders for Diverse Programming Languages")
do
  local test_cases = {
    { ext = "cpp", expected_leader = "//" },
    { ext = "rs",  expected_leader = "//" },
    { ext = "lua", expected_leader = "--" },
    { ext = "py",  expected_leader = "#" },
    { ext = "sh",  expected_leader = "#" },
    { ext = "lean", expected_leader = "--" },
    { ext = "md",  expected_leader = "- [ ]" },
  }

  for _, tc in ipairs(test_cases) do
    local f = string.format("%s/lang_test.%s", tmp_dir, tc.ext)
    tasks_mod.add_task(string.format("%s:1 Language leader test for %s", f, tc.ext))
    local lines = vim.fn.readfile(f)
    assert_true(#lines >= 1, string.format("Stub created for .%s", tc.ext))
    assert_true(lines[1]:find(tc.expected_leader, 1, true) ~= nil, string.format("Correct comment leader '%s' used for .%s", tc.expected_leader, tc.ext))
  end
end

-- -----------------------------------------------------------------------------
-- SCENARIO 5: Type Normalization for String depends_on and blocks in Decomposition
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 5] Type Normalization for String depends_on and blocks in Decomposition")
do
  -- Test that tasks_mod safely normalizes string dependencies into formatted list
  local dep_single = "prereq-auth-setup"
  local blk_single = "downstream-endpoint"

  local dep_list = type(dep_single) == "table" and dep_single or { dep_single }
  local blk_list = type(blk_single) == "table" and blk_single or { blk_single }

  local dep_str = string.format(" | depends_on:[%s]", table.concat(dep_list, ", "))
  local blk_str = string.format(" | blocks:[%s]", table.concat(blk_list, ", "))

  assert_eq(dep_str, " | depends_on:[prereq-auth-setup]", "Single string dependency normalized without Lua concat error")
  assert_eq(blk_str, " | blocks:[downstream-endpoint]", "Single string blocks normalized without Lua concat error")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 6: Multi-Part Topological Review Queue & Unblocking Flow
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 6] Multi-Part Topological Review Queue & Unblocking Flow")
do
  local f_a = tmp_dir .. "/stage_a.py"
  local f_b = tmp_dir .. "/stage_b.py"
  vim.fn.writefile({ "pass" }, f_a)
  vim.fn.writefile({ "pass" }, f_b)

  -- Create prerequisite task A
  tasks_mod.add_task(string.format("%s:1 Foundational component A", f_a))
  -- Create dependent task B
  tasks_mod.add_task(string.format("%s:1 Dependent component B", f_b))

  local unrev = reviews_mod.get_reviews("unreviewed")
  assert_true(#unrev >= 2, "Multiple task stubs present in unreviewed queue")

  -- Accept component A
  reviews_mod.accept("foundational-component-a")

  local lines_a = vim.fn.readfile(f_a)
  assert_true(lines_a[1]:find("foundational-component-a", 1, true) ~= nil, "Component A stub remains in file A")

  -- Accept component B
  reviews_mod.accept("dependent-component-b")

  local lines_b = vim.fn.readfile(f_b)
  assert_true(lines_b[1]:find("dependent-component-b", 1, true) ~= nil, "Component B stub remains in file B")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 7: In-line Preservation of Existing Surrounding Code
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 7] In-line Preservation of Existing Surrounding Code")
do
  local test_file = tmp_dir .. "/surrounding_code.py"
  local original_lines = {
    "def existing_function_alpha():",
    "    return 'alpha'",
    "",
    "def existing_function_beta():",
    "    return 'beta'",
  }
  vim.fn.writefile(original_lines, test_file)

  -- Insert between alpha and beta (line 4)
  tasks_mod.add_task(string.format("%s:4 Implement gamma feature", test_file))
  local new_lines = vim.fn.readfile(test_file)

  assert_eq(#new_lines, 6, "File line count increased from 5 to 6")
  assert_eq(new_lines[1], "def existing_function_alpha():", "Existing alpha function line 1 preserved")
  assert_eq(new_lines[2], "    return 'alpha'", "Existing alpha function body preserved")
  assert_true(new_lines[4]:find("implement-gamma-feature", 1, true) ~= nil, "Injected task stub placed at line 4")
  assert_eq(new_lines[5], "def existing_function_beta():", "Existing beta function header preserved")
  assert_eq(new_lines[6], "    return 'beta'", "Existing beta function body preserved")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 8: Multi-line Description and Embedded Newlines
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 8] Multi-line Description and Embedded Newlines")
do
  local test_file = tmp_dir .. "/multiline_desc.py"
  vim.fn.writefile({ "def placeholder():", "    pass" }, test_file)

  -- Pass a description with newlines
  tasks_mod.add_task(string.format("%s:2 First step\nSecond step\nThird step", test_file))
  local lines = vim.fn.readfile(test_file)

  -- The header should be cleanly collapsed on a single commented line
  assert_true(lines[2]:find("# TODO", 1, true) ~= nil, "Stub line 2 starts with comment leader")
  assert_true(lines[2]:find("First step Second step Third step", 1, true) ~= nil, "Newlines collapsed into single comment line without broken raw code")
  assert_eq(lines[3], "    pass", "Existing code following stub is intact")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 9: Path Traversal and Relative Path Sanitization
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 9] Path Traversal and Relative Path Sanitization")
do
  -- Pass ./ prefix
  local rel_dot = "./tests/dummy_dot_test.py"
  tasks_mod.add_task(string.format("%s:1 Test dot slash prefix", rel_dot))
  local full_rel = vim.fn.fnamemodify(rel_dot, ":p")
  assert_true(vim.fn.filereadable(full_rel) == 1, "File with ./ prefix created and written correctly")
  pcall(vim.fn.delete, full_rel)

  -- Pass ../ path traversal attempting to escape project root
  local bad_path = "../../../outside_escape.py"
  tasks_mod.add_task(string.format("%s:1 Escaped file attempt", bad_path))
  local root = require("agent.ui").get_root_dir()
  assert_true(vim.fn.filereadable("/outside_escape.py") ~= 1, "Traversal path was not allowed to escape outside project root")
  -- Fell back safely to TODO.md
  assert_true(vim.fn.filereadable(root .. "/TODO.md") == 1, "Fell back safely to project TODO.md")
  pcall(vim.fn.delete, root .. "/TODO.md")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 10: Slug Collision Disambiguation
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 10] Slug Collision Disambiguation")
do
  local test_file = tmp_dir .. "/collision.py"
  vim.fn.writefile({ "x = 1" }, test_file)

  tasks_mod.add_task(string.format("%s:1 Unique Token Auth", test_file))
  tasks_mod.add_task(string.format("%s:1 Unique Token Auth", test_file))

  local lines = vim.fn.readfile(test_file)
  assert_true(lines[1]:find("unique-token-auth-2", 1, true) ~= nil or lines[2]:find("unique-token-auth-2", 1, true) ~= nil, "Duplicate slug disambiguated with -2 suffix")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 11: Indentation Inheritance
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 11] Indentation Inheritance")
do
  local test_file = tmp_dir .. "/indented.py"
  local code = {
    "class MyHandler:",
    "    def handle(self):",
    "        return 42",
  }
  vim.fn.writefile(code, test_file)

  -- Insert inside handle at line 3 (indentation is 8 spaces)
  tasks_mod.add_task(string.format("%s:3 Validate input parameters", test_file))
  local lines = vim.fn.readfile(test_file)

  assert_true(lines[3]:match("^%s%s%s%s%s%s%s%s# TODO") ~= nil, "Injected stub inherited 8-space indentation from target scope")
  assert_eq(lines[4], "        return 42", "Subsequent indented line preserved")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 12: Two-Layer Hoare & DTL Policy Generation in Tasks Add
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 12] Two-Layer Hoare & DTL Policy Generation in Tasks Add")
do
  local target_file = tmp_dir .. "/service_auth.py"
  vim.fn.writefile({ "# service authentication module" }, target_file)

  local mock_parts = {
    {
      task_id = "token-verification-service",
      file = "service_auth.py",
      line = 1,
      tier = "A",
      depends_on = {},
      blocks = {},
      action = "Implement token verification service",
      ensures = "Token verification service passes test suite",
      allow = { "service_auth.py" },
      forbid = { ".env*", "*.pem", "*.key" },
      always = "Authentication invariants preserved",
      repair = "on_violation -> (auto_revert, mark:REVISE)",
    }
  }

  tasks_mod.decompose_and_add_tasks("implement token verification service", nil, mock_parts)

  local all_tasks = tasks_mod.scan_repository_tasks(tmp_dir)
  local found_task = nil
  for _, t in ipairs(all_tasks) do
    if t.description and t.description:find("token verification") then
      found_task = t
      break
    end
  end

  assert_true(found_task ~= nil, "Added task parsed by scan_repository_tasks")
  if found_task then
    assert_true(found_task.contract ~= nil, "Task has contract object")
    assert_true(#(found_task.contract.allow or {}) >= 1, "Task contract has DTL allow patterns")
    assert_true(#(found_task.contract.forbid or {}) >= 1, "Task contract has DTL forbid patterns")
    assert_true(found_task.contract.ensures ~= nil, "Task contract has Hoare ensures postcondition")
    assert_true(found_task.contract.repair ~= nil, "Task contract has DTL repair policy")
  end
end

-- -----------------------------------------------------------------------------
-- SCENARIO 13: Duplicate Slugs, Positional Resolution & FFI Nearest-Block/Task Lookup
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 13] Duplicate Slugs, Positional Resolution & FFI Nearest-Block/Task Lookup")
do
  local anchor_mod = require("agent.anchor")
  local dup_file = tmp_dir .. "/dup_tasks.lua"
  vim.fn.writefile({
    "-- header",
    "-- TODO(dup-gate | tier:A | status:TODO): First duplicate gate",
    "local function first() return 1 end",
    "-- middle",
    "-- TODO(dup-gate | tier:A | status:TODO): Second duplicate gate",
    "local function second() return 2 end",
  }, dup_file)

  local l1 = anchor_mod.find_task_line(vim.fn.readfile(dup_file), "dup-gate", 2)
  local l2 = anchor_mod.find_task_line(vim.fn.readfile(dup_file), "dup-gate", 5)
  assert_eq(l1, 2, "FFI find_task_line resolves first duplicate near line 2")
  assert_eq(l2, 5, "FFI find_task_line resolves second duplicate near line 5")

  -- Find which agenda indices correspond to the two dup-gate tasks
  local sorted = tasks_mod.sort_tasks(tasks_mod.scan_repository_tasks(tmp_dir))
  local idxs = {}
  for idx, t in ipairs(sorted) do
    if t.task_id == "dup-gate" then table.insert(idxs, idx) end
  end
  assert_eq(#idxs, 2, "Both duplicate-slug tasks discovered in agenda")
  local rec1 = tasks_mod.resolve_task_record(tostring(idxs[1]))
  local rec2 = tasks_mod.resolve_task_record(tostring(idxs[2]))
  assert_eq(rec1 and rec1.line, 2, "Numeric index 1 resolves to first occurrence (line 2)")
  assert_eq(rec2 and rec2.line, 5, "Numeric index 2 resolves to second occurrence (line 5)")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 14: Content-Anchored Review Revert & Accept Under Line Drift
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 14] Content-Anchored Review Revert & Accept Under Line Drift")
do
  local drift_file = tmp_dir .. "/drift_target.lua"
  local orig_block = {
    "-- TODO(drift-task | tier:A | status:TODO): compute value",
    "local function compute() return 0 end",
  }
  local new_block = {
    "-- TODO(drift-task | tier:A | status:DONE): compute value",
    "local function compute() return 42 end",
  }
  vim.fn.writefile({
    "-- line 1",
    new_block[1],
    new_block[2],
    "-- footer",
  }, drift_file)
  local b = vim.fn.bufadd(drift_file)
  vim.fn.bufload(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.fn.readfile(drift_file))

  -- Create review recorded at start_line = 2
  local rev = reviews_mod.create_review(drift_file, 2, #orig_block, orig_block, new_block, "drift-task", "compute 42", "unreviewed", 1, false)

  -- Now insert 15 lines at the top of the file AND buffer (simulating upstream edits shifting lines by +15)
  local shifted = {}
  for i = 1, 15 do table.insert(shifted, "-- prepended line " .. i) end
  for _, l in ipairs(vim.fn.readfile(drift_file)) do table.insert(shifted, l) end
  vim.fn.writefile(shifted, drift_file)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, shifted)

  -- Rejecting the review must revert the block at its new shifted position (line 17), NOT line 2!
  local ok_rev = reviews_mod.revert_review(rev.id)
  assert_true(ok_rev, "Content-anchored revert succeeded despite +15 line drift")
  local after_revert = vim.fn.readfile(drift_file)
  assert_eq(after_revert[1], "-- prepended line 1", "Prepended header lines untouched by revert")
  assert_eq(after_revert[17], orig_block[1], "Original TODO line restored at shifted line 17")
  assert_eq(after_revert[18], orig_block[2], "Original function restored at shifted line 18")
  assert_eq(after_revert[19], "-- footer", "Footer preserved after revert")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 15: Conflict Refusal, Bogus Review ID Guard & Discard Escape Hatch
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 15] Conflict Refusal, Bogus Review ID Guard & Discard Escape Hatch")
do
  local conf_file = tmp_dir .. "/conflict_target.lua"
  vim.fn.writefile({
    "local x = 1",
    "local y = 2",
  }, conf_file)
  local b = vim.fn.bufadd(conf_file)
  vim.fn.bufload(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "local x = 1", "local y = 2" })

  local rev = reviews_mod.create_review(
    conf_file, 1, 2,
    { "local x = 1", "local y = 2" },
    { "local x = 10", "local y = 20" },
    "conflict-task", "update x and y", "unreviewed", 1, false
  )

  -- User completely rewrites the file so neither old_lines nor new_lines exists
  local user_lines = { "local completely_different = 999" }
  vim.fn.writefile(user_lines, conf_file)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, user_lines)

  -- Bogus ID must NEVER fall back to accepting/rejecting `rev`
  local state_mod = require("agent.state")
  state_mod.state.current_review = rev
  local bogus_ok = reviews_mod.accept_review("rev-nonexistent-9999")
  assert_true(not bogus_ok, "Bogus review ID rejected without falling back to current_review")

  -- Accepting conflicted review must refuse to clobber user_lines
  local acc_ok = reviews_mod.accept_review(rev.id)
  assert_true(not acc_ok, "Accepting conflicted review refused safely")
  assert_eq(vim.fn.readfile(conf_file)[1], "local completely_different = 999", "User file was not corrupted on conflict")

  -- Discard escape hatch marks review rejected without touching the file
  local disc_ok = reviews_mod.discard_review(rev.id)
  assert_true(disc_ok, "discard_review succeeded on conflicted review")
  assert_eq(vim.fn.readfile(conf_file)[1], "local completely_different = 999", "Discard left file intact")

  -- Second accept/reject on already-rejected review is a safe no-op
  local dup_ok = reviews_mod.accept_review(rev.id)
  assert_true(not dup_ok, "Re-accepting an already-reviewed item is refused")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 16: Deleted Target File & New-File Cleanup on Reject
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 16] Deleted Target File & New-File Cleanup on Reject")
do
  -- 1. Rejecting a task stub that created a brand-new file deletes the file
  local brand_new_rel = "ephemeral_dir/brand_new_stub.lua"
  local brand_new_abs = tmp_dir .. "/" .. brand_new_rel
  tasks_mod.add_task(brand_new_rel .. ":1 Temporary stub in brand new file")
  assert_eq(vim.fn.filereadable(brand_new_abs), 1, "New file created by :Tasks add")
  local found_rev = reviews_mod.find_review("temporary-stub-in-brand-new-file", true)
  assert_true(found_rev ~= nil, "Review created for brand-new file stub")
  if found_rev then
    reviews_mod.revert_review(found_rev.id)
    assert_eq(vim.fn.filereadable(brand_new_abs), 0, "Rejecting new-file stub deleted the file from disk")
  end

  -- 2. Deleting a file externally before rejecting its review handles missing file cleanly
  local vanish_file = tmp_dir .. "/vanishing.lua"
  vim.fn.writefile({ "-- vanishing" }, vanish_file)
  local rev_v = reviews_mod.create_review(vanish_file, 1, 1, { "-- vanishing" }, { "-- gone" }, "vanish-task", "vanish", "unreviewed", 1, false)
  vim.fn.delete(vanish_file)
  local v_buf = vim.fn.bufnr(vanish_file)
  if v_buf ~= -1 then pcall(vim.api.nvim_buf_delete, v_buf, { force = true }) end
  local ok_v = reviews_mod.revert_review(rev_v.id)
  assert_true(ok_v, "Reverting review whose target file was deleted succeeds cleanly")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 17: :Tasks start Adjacent Task Boundary & agy JSON Envelope Parsing
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 17] :Tasks start Adjacent Task Boundary & agy JSON Envelope Parsing")
do
  local llm_mod = require("agent.llm")
  local anchor_mod = require("agent.anchor")

  -- 1. Verify parse_solution_from_raw does NOT confuse agy's outer { status, response }
  --    or spinner text with the inner solution JSON
  local raw_agy_envelope = vim.fn.json_encode({
    status = "SUCCESS",
    response = vim.fn.json_encode({
      start_line = 200,
      old_lines_count = 2,
      content = "function M.delete_task(id)\n  return true\nend",
      description = "Implement delete_task",
    }),
  })
  local parsed_env = llm_mod.parse_solution_from_raw(raw_agy_envelope)
  assert_true(parsed_env ~= nil, "Parsed agy JSON envelope")
  assert_eq(parsed_env.start_line, 200, "Extracted inner start_line from agy response envelope")
  assert_eq(parsed_env.old_lines_count, 2, "Extracted inner old_lines_count from agy response envelope")
  assert_true(parsed_env.content:find("function M.delete_task", 1, true) ~= nil, "Extracted inner content from agy response envelope")

  -- 2. Verify multi-region edits array parsing
  local raw_multi_edits = vim.fn.json_encode({
    status = "SUCCESS",
    response = vim.fn.json_encode({
      start_line = 1,
      old_lines_count = 1,
      content = "-- DONE",
      description = "Multi-region implementation",
      edits = {
        { start_line = 1, old_lines_count = 1, content = "-- TODO(task-1 | tier:A | status:DONE): done" },
        { start_line = 50, old_lines_count = 1, content = "function M.new_cmd()\n  return 1\nend" },
      },
    }),
  })
  local parsed_multi = llm_mod.parse_solution_from_raw(raw_multi_edits)
  assert_true(parsed_multi ~= nil and type(parsed_multi.edits) == "table" and #parsed_multi.edits == 2, "Parsed multi-region edits array cleanly")

  -- 3. Verify adjacent tasks on lines 1 and 2 are strictly isolated by FFI find_task_block_span
  local adj_lines = {
    "-- TODO(support-for-tasks-delete-and-tasks-modify | tier:A | status:TODO): support for ':Tasks delete' and ':Tasks modify'",
    "-- TODO(review-todo-routing-decomposition-model | tier:B | status:TODO): Review and optimize TODO routing",
    "--   [HOARE CODE CONTRACT]",
    "--   requires:  []",
    "--   action:    Review and optimize TODO routing",
    "--   ensures:   review: \"Smart TODO placement heuristics\"",
    "--",
    "--   [DTL AGENT POLICY]",
    "--   allow:     [nvim/lua/agent/tasks.lua]",
    "--   forbid:    [.env*, *.pem, *.key]",
    "--   always:    review: \"Existing task scanning remains functional\"",
    "--   repair:    on_violation -> (auto_revert, mark:REVISE)",
    "local M = {}",
  }
  local span_first = anchor_mod.find_task_block_span(adj_lines, 1, "support-for-tasks-delete-and-tasks-modify")
  assert_eq(span_first.line_count, 1, "First task on line 1 has old_lines_count == 1 (never swallows task 2 on line 2)")

  local span_second = anchor_mod.find_task_block_span(adj_lines, 2, "review-todo-routing-decomposition-model")
  assert_eq(span_second.line_count, 11, "Second task on line 2 spans 11 lines (lines 2..12)")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 18: Form-Based Single & Multi-Task Creation with Blank Field Auto-Fill
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 18] Form-Based Single & Multi-Task Creation with Blank Field Auto-Fill")
do
  -- User fills ONLY 'action:' across two Two-Layer CONTRACT blocks separated by '---', leaving everything else blank
  local multi_form = table.concat({
    "# ── Two-Layer Task Contract Form ──",
    "CONTRACT():",
    "  [HOARE CODE CONTRACT]",
    "  requires:  []",
    "  action:    Define token bucket rate limiter struct",
    "  ensures:   ",
    "",
    "  [DTL AGENT POLICY]",
    "  allow:     []",
    "  forbid:    [.env*, *.pem, *.key]",
    "  always:    ",
    "  repair:    ",
    "---",
    "CONTRACT():",
    "  [HOARE CODE CONTRACT]",
    "  requires:  []",
    "  action:    Integrate token bucket middleware into HTTP router",
    "  ensures:   ",
    "",
    "  [DTL AGENT POLICY]",
    "  allow:     []",
    "  forbid:    [.env*, *.pem, *.key]",
    "  always:    ",
    "  repair:    ",
  }, "\n")

  local raw_specs = tasks_mod.parse_task_form(multi_form)
  assert_eq(#raw_specs, 2, "Parsed 2 task blocks separated by '---' from form")
  assert_eq(raw_specs[1].action, "Define token bucket rate limiter struct", "First task action extracted")
  assert_eq(raw_specs[2].action, "Integrate token bucket middleware into HTTP router", "Second task action extracted")

  local finalized = tasks_mod.finalize_task_specs(raw_specs, "src/limiter.py", {})
  assert_eq(#finalized, 2, "Finalized 2 task specs")
  assert_eq(finalized[1].task_id, "define-token-bucket-rate-limiter-struct", "Blank task_id 1 auto-filled from action")
  assert_eq(finalized[2].task_id, "integrate-token-bucket-middleware-into-http-rout", "Blank task_id 2 auto-filled from action")
  assert_eq(#finalized[1].requires, 0, "First task has no requires")
  assert_eq(finalized[2].requires[1], finalized[1].task_id, "Second task auto-wired to require first task in Hoare contract")
  assert_true(finalized[1].ensures ~= "" and finalized[1].always ~= "", "Blank ensures and always auto-filled")

  -- Round-trip back into Two-Layer form lines
  local form_lines = tasks_mod.format_specs_as_form(finalized)
  local reparsed = tasks_mod.parse_task_form(table.concat(form_lines, "\n"))
  assert_eq(#reparsed, 2, "Round-tripped form text parses back into 2 complete task specs")
  assert_eq(reparsed[1].task_id, finalized[1].task_id, "Round-tripped CONTRACT(task_id) preserved")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 19: Interactive Placement Mode Across Multiple Files & Virtual Preview
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 19] Interactive Placement Mode Across Multiple Files & Virtual Preview")
do
  local file_one = tmp_dir .. "/place_one.py"
  local file_two = tmp_dir .. "/place_two.lua"
  vim.fn.writefile({
    "class RateLimiter:",
    "    def check(self):",
    "        return True",
  }, file_one)
  vim.fn.writefile({
    "local M = {}",
    "function M.route(req)",
    "  return req",
    "end",
    "return M",
  }, file_two)

  local win = vim.api.nvim_get_current_win()
  local buf_one = vim.fn.bufadd(file_one)
  vim.fn.bufload(buf_one)
  vim.api.nvim_win_set_buf(win, buf_one)
  vim.api.nvim_win_set_cursor(win, { 3, 8 })

  -- Submit a 2-task form; this enters Interactive Placement Mode
  local form_submission = table.concat({
    "CONTRACT():",
    "  [HOARE CODE CONTRACT]",
    "  action: Implement token bucket check inside RateLimiter",
    "---",
    "CONTRACT():",
    "  [HOARE CODE CONTRACT]",
    "  action: Call RateLimiter check inside M.route",
  }, "\n")
  local specs = tasks_mod.process_task_form_submission(form_submission, win, false)
  assert_eq(#specs, 2, "Form submission created 2 queued tasks")
  assert_true(state_mod.state.placement_active == true, "Interactive placement mode is active")
  assert_eq(#state_mod.state.placement_queue, 2, "Placement queue holds 2 tasks")

  -- Verify virtual-lines preview extmark is rendered on buf_one at cursor
  tasks_mod.render_placement_preview()
  local extmarks = vim.api.nvim_buf_get_extmarks(buf_one, state_mod.ns_placement, 0, -1, { details = true })
  assert_true(#extmarks >= 1, "Live virtual-lines task preview extmark rendered at cursor during placement mode")

  -- Drop Task 1 at cursor (line 3 of place_one.py, inside `def check(self):` with 8-space indent)
  local dropped_1 = tasks_mod.drop_current_task_at_cursor()
  assert_true(dropped_1, "First queued task dropped at cursor in place_one.py")
  assert_true(state_mod.state.placement_active == true, "Placement mode remains active for Task 2")
  assert_eq(#state_mod.state.placement_queue, 1, "1 task remaining in placement queue")

  local lines_one = vim.fn.readfile(file_one)
  assert_true(lines_one[3]:match("^        # CONTRACT%(implement%-token%-bucket%-check%-inside") ~= nil, "Task 1 placed at line 3 with 8-space Python indentation and '# CONTRACT(...):' header")
  assert_eq(lines_one[14], "        return True", "Original line 3 pushed cleanly below the 11-line task contract")

  -- Now navigate to file_two.lua line 3 (`  return req`) and drop Task 2
  local buf_two = vim.fn.bufadd(file_two)
  vim.fn.bufload(buf_two)
  vim.api.nvim_win_set_buf(win, buf_two)
  vim.api.nvim_win_set_cursor(win, { 3, 2 })
  tasks_mod.render_placement_preview()

  local dropped_2 = tasks_mod.drop_current_task_at_cursor()
  assert_true(dropped_2, "Second queued task dropped at cursor in place_two.lua")
  assert_true(state_mod.state.placement_active == false, "Placement mode automatically exited after placing final task")
  assert_eq(#state_mod.state.placement_queue, 0, "Placement queue is now empty")

  local lines_two = vim.fn.readfile(file_two)
  assert_true(lines_two[3]:match("^  %-%- CONTRACT%(call%-ratelimiter%-check%-inside%-mroute") ~= nil, "Task 2 placed at line 3 with 2-space Lua indentation and '-- CONTRACT(...):' header")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 20: Task Repositioning (:Tasks move) Across Lines & Files
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 20] Task Repositioning (:Tasks move) Across Lines & Files")
do
  local move_file = tmp_dir .. "/reposition_target.lua"
  local initial_lines = {
    "local M = {}",
    "-- CONTRACT(misplaced-task):",
    "--   [HOARE CODE CONTRACT]",
    "--   requires:  []",
    "--   action:    Misplaced task that belongs inside helper()",
    "--   ensures:   review: \"Helper logic verified\"",
    "--",
    "--   [DTL AGENT POLICY]",
    "--   allow:     [reposition_target.lua]",
    "--   forbid:    [.env*, *.pem, *.key]",
    "--   always:    review: \"Module intact\"",
    "--   repair:    on_violation -> (auto_revert, mark:REVISE)",
    "function M.first()",
    "  return 1",
    "end",
    "function M.helper()",
    "  return 2",
    "end",
    "return M",
  }
  vim.fn.writefile(initial_lines, move_file)

  local win = vim.api.nvim_get_current_win()
  local buf = vim.fn.bufadd(move_file)
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_cursor(win, { 2, 0 })

  -- Pick up the task at line 2 via move_task
  local picked_up = tasks_mod.move_task("")
  assert_true(picked_up, "move_task picked up multi-line task at cursor")
  assert_true(state_mod.state.placement_active == true, "move_task entered interactive placement mode")

  -- Verify the 11-line task block was cleanly removed from line 2
  local after_pickup = vim.fn.readfile(move_file)
  assert_eq(#after_pickup, 8, "11-line task block removed from old position (19 - 11 = 8 lines)")
  assert_eq(after_pickup[2], "function M.first()", "Code immediately following removed task is now at line 2")

  -- Move cursor inside `M.helper()` (line 6: `  return 2`) and drop the task there!
  vim.api.nvim_win_set_cursor(win, { 6, 2 })
  local dropped = tasks_mod.drop_current_task_at_cursor()
  assert_true(dropped, "Picked-up task dropped at new cursor location inside M.helper()")
  assert_true(state_mod.state.placement_active == false, "Placement mode exited after dropping moved task")

  local after_drop = vim.fn.readfile(move_file)
  assert_eq(#after_drop, 19, "11-line task block re-inserted at new location (8 + 11 = 19 lines)")
  assert_true(after_drop[6]:match("^  %-%- CONTRACT%(misplaced%-task%):") ~= nil, "Moved task placed at line 6 with 2-space indentation inside M.helper()")
  assert_eq(after_drop[17], "  return 2", "Original line 6 (`  return 2`) preserved right below moved task block")
end

-- Clean up temporary directory
pcall(vim.fn.delete, tmp_dir, "rf")

-- -----------------------------------------------------------------------------
-- SUMMARY
-- -----------------------------------------------------------------------------
print("\n==================================================================")
print(string.format("  TASKS ADD TEST RUN COMPLETE: %d Passed, %d Failed", passed, failed))
print("==================================================================")

if failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qall!")
end
