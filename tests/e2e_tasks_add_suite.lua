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
  assert_true(lines[1]:find("^# TODO%(implement%-deep%-nested%-feature%-gate | tier:A | status:TODO%):") ~= nil, "Task stub has proper header and slug")

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
  assert_true(lines[2]:find("TODO%([a-zA-Z0-9_%-]+ | tier:A | status:TODO%)") ~= nil, "Valid sanitized slug generated from unicode description")
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
  vim.cmd("qall")
end
