-- ==============================================================================
-- tests/test_concurrent_workspace_suite.lua: Multi-Agent Concurrent Stress Testing
-- ==============================================================================

local script_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local repo_root = vim.fn.fnamemodify(script_dir, ":h")
vim.opt.rtp:prepend(repo_root .. "/nvim")
package.path = repo_root .. "/nvim/lua/?.lua;" .. repo_root .. "/nvim/lua/?/init.lua;" .. package.path

local workspaces = require("agent.workspaces")
local reviews = require("agent.reviews")

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
print("  Running synvim Multi-Agent Concurrent Stress Test Suite        ")
print("==================================================================")

local tmp_repo = vim.fn.tempname()
vim.fn.mkdir(tmp_repo, "p")
vim.fn.system({ "git", "-C", tmp_repo, "init", "-b", "main" })
vim.fn.system({ "git", "-C", tmp_repo, "config", "user.name", "Synvim Test" })
vim.fn.system({ "git", "-C", tmp_repo, "config", "user.email", "test@synvim.agent" })

-- Seed git repository with an initial commit
local test_file = tmp_repo .. "/calculator.py"
local initial_code = {
  "import math",
  "",
  "def add(a, b):",
  "    return a + b",
  "",
  "def multiply(a, b):",
  "    return a * b",
  "",
  "def main():",
  "    print('Calculator v1.0')",
}
vim.fn.writefile(initial_code, test_file)
vim.fn.system({ "git", "-C", tmp_repo, "add", "." })
vim.fn.system({ "git", "-C", tmp_repo, "commit", "-m", "Initial calculator commit" })
vim.fn.chdir(tmp_repo)

-- -----------------------------------------------------------------------------
-- SCENARIO 1: Concurrent Ephemeral Worktree Isolation Across 3 Agents
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 1] Concurrent Ephemeral Worktree Isolation Across 3 Agents")
do
  local ws_a = workspaces.create_workspace("agent-task-alpha")
  local ws_b = workspaces.create_workspace("agent-task-beta")
  local ws_c = workspaces.create_workspace("agent-task-gamma")

  assert_true(ws_a ~= nil and ws_b ~= nil and ws_c ~= nil, "All 3 workspaces created successfully")
  assert_true(vim.fn.isdirectory(ws_a.path) == 1, "Workspace Alpha directory exists")
  assert_true(vim.fn.isdirectory(ws_b.path) == 1, "Workspace Beta directory exists")
  assert_true(vim.fn.isdirectory(ws_c.path) == 1, "Workspace Gamma directory exists")

  assert_true(ws_a.path ~= ws_b.path and ws_b.path ~= ws_c.path, "Workspace paths are completely distinct")
  assert_eq(ws_a.mode, "worktree", "Workspace Alpha uses git worktree isolation")
  assert_eq(ws_b.mode, "worktree", "Workspace Beta uses git worktree isolation")
  assert_eq(ws_c.mode, "worktree", "Workspace Gamma uses git worktree isolation")

  -- Clean up
  workspaces.remove_workspace(ws_a)
  workspaces.remove_workspace(ws_b)
  workspaces.remove_workspace(ws_c)

  assert_true(vim.fn.isdirectory(ws_a.path) == 0, "Workspace Alpha cleanly removed")
  assert_true(vim.fn.isdirectory(ws_b.path) == 0, "Workspace Beta cleanly removed")
  assert_true(vim.fn.isdirectory(ws_c.path) == 0, "Workspace Gamma cleanly removed")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 2: Non-Overlapping Concurrent Changes Reconciled via 3-Way Merge
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 2] Non-Overlapping Concurrent Changes Reconciled via 3-Way Merge")
do
  local base_snapshot = workspaces.capture_file_base(test_file)
  local base_content = base_snapshot.content

  -- Worker 1 adds subtract() right after add() (lines 4-5)
  local worker1_lines = {
    "import math",
    "",
    "def add(a, b):",
    "    return a + b",
    "",
    "def subtract(a, b):",
    "    return a - b",
    "",
    "def multiply(a, b):",
    "    return a * b",
    "",
    "def main():",
    "    print('Calculator v1.0')",
  }
  local worker1_content = table.concat(worker1_lines, "\n")

  -- Worker 2 adds divide() right after multiply() (lines 6-7)
  local worker2_lines = {
    "import math",
    "",
    "def add(a, b):",
    "    return a + b",
    "",
    "def multiply(a, b):",
    "    return a * b",
    "",
    "def divide(a, b):",
    "    if b == 0: raise ValueError('Zero division')",
    "    return a / b",
    "",
    "def main():",
    "    print('Calculator v1.0')",
  }
  local worker2_content = table.concat(worker2_lines, "\n")

  -- Worker 1 arrives first: current content on disk is updated
  local current_content = worker1_content

  -- Worker 2 reconciles against current_content with original base_content
  local reconciliation = workspaces.reconcile_changes(current_content, base_content, worker2_content)

  assert_eq(reconciliation.status, "merged", "Non-overlapping changes cleanly reconciled (status == 'merged')")
  assert_true(reconciliation.has_conflict == false, "No conflict flagged")

  local merged = reconciliation.merged_content
  assert_true(merged:find("def subtract(a, b):", 1, true) ~= nil, "Worker 1 subtract() preserved in merge")
  assert_true(merged:find("def divide(a, b):", 1, true) ~= nil, "Worker 2 divide() preserved in merge")
  assert_true(merged:find("Calculator v1.0", 1, true) ~= nil, "Original main() preserved in merge")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 3: Overlapping Concurrent Conflict Detection & Marker Injection
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 3] Overlapping Concurrent Conflict Detection & Marker Injection")
do
  local base_snapshot = workspaces.capture_file_base(test_file)
  local base_content = base_snapshot.content

  -- Worker A modifies line 'print(\'Calculator v1.0\')' to v2.0-Alpha
  local worker_a_lines = vim.deepcopy(initial_code)
  worker_a_lines[10] = "    print('Calculator v2.0-Alpha by Agent A')"
  local worker_a_content = table.concat(worker_a_lines, "\n")

  -- Worker B concurrently modifies the EXACT same line to v2.0-Beta
  local worker_b_lines = vim.deepcopy(initial_code)
  worker_b_lines[10] = "    print('Calculator v2.0-Beta by Agent B')"
  local worker_b_content = table.concat(worker_b_lines, "\n")

  -- Worker A writes first
  local current_disk_content = worker_a_content

  -- Worker B attempts to reconcile against original base
  local rec = workspaces.reconcile_changes(current_disk_content, base_content, worker_b_content)

  assert_eq(rec.status, "conflict", "Overlapping change flagged as conflict")
  assert_true(rec.has_conflict == true, "has_conflict is true")
  assert_true(rec.conflict_markers ~= nil, "Conflict markers generated")
  assert_true(rec.conflict_markers:find("<<<<<<< CURRENT_BUFFER", 1, true) ~= nil, "Contains CURRENT_BUFFER marker")
  assert_true(rec.conflict_markers:find(">>>>>>> INCOMING_AGENT", 1, true) ~= nil, "Contains INCOMING_AGENT marker")
  assert_true(rec.conflict_markers:find("Calculator v2.0-Alpha", 1, true) ~= nil, "Preserved Agent A version in conflict marker")
  assert_true(rec.conflict_markers:find("Calculator v2.0-Beta", 1, true) ~= nil, "Preserved Agent B version in conflict marker")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 4: Rapid Parallel Worktree Churn (Stress Test)
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 4] Rapid Parallel Worktree Churn (Stress Test)")
do
  local ws_list = {}
  for i = 1, 8 do
    local tid = string.format("stress-worker-%d-%d", i, os.time())
    local ws = workspaces.create_workspace(tid)
    assert_true(ws ~= nil, "Workspace " .. tid .. " created")
    table.insert(ws_list, ws)
  end

  assert_eq(#ws_list, 8, "All 8 concurrent workspaces active")

  -- Remove all concurrently
  for _, ws in ipairs(ws_list) do
    workspaces.remove_workspace(ws)
  end

  local remaining = vim.fn.globpath(tmp_repo .. "/.agent/worktrees", "stress-worker-*", false, true)
  assert_eq(#remaining, 0, "All 8 concurrent workspaces cleaned up without orphans")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 5: Multi-Review Queue Integrity Under Concurrent Tasks
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 5] Multi-Review Queue Integrity Under Concurrent Tasks")
do
  local r1 = reviews.create_review(test_file, 3, 2, { "def add(a, b):", "    return a + b" },
    { "def add(a, b):", "    # validated", "    return a + b" }, "task-validate-add", "validate add", "unreviewed", 1, false)

  local r2 = reviews.create_review(test_file, 6, 2, { "def multiply(a, b):", "    return a * b" },
    { "def multiply(a, b):", "    # fast path", "    return a * b" }, "task-fast-multiply", "fast multiply", "unreviewed", 2, false)

  assert_true(r1 ~= nil and r2 ~= nil, "Both concurrent reviews created")
  assert_true(r1.id ~= r2.id, "Review IDs are distinct")

  -- Find reviews by ID
  local found_r1 = reviews.find_review(r1.id, false)
  local found_r2 = reviews.find_review(r2.id, false)
  assert_true(found_r1 ~= nil, "Found Review 1")
  assert_true(found_r2 ~= nil, "Found Review 2")
  assert_eq(found_r1.task_id, "task-validate-add", "Review 1 has correct task_id")
  assert_eq(found_r2.task_id, "task-fast-multiply", "Review 2 has correct task_id")

  -- Accept review 1
  local ok1 = reviews.accept(r1.id)
  assert_true(ok1, "Accepted review 1 cleanly")

  -- Verify review 2 remains unreviewed in queue
  local unrev = reviews.get_reviews("unreviewed")
  local r2_still_unreviewed = false
  for _, u in ipairs(unrev) do
    if u.id == r2.id then r2_still_unreviewed = true; break end
  end
  assert_true(r2_still_unreviewed, "Review 2 remained unreviewed after Review 1 was accepted")

  -- Reject review 2
  local ok2 = reviews.revert_review(r2.id)
  assert_true(ok2, "Reverted review 2 cleanly")
end

print("\n==================================================================")
print(string.format("  CONCURRENT WORKSPACE SUITE COMPLETE: %d Passed, %d Failed", passed, failed))
print("==================================================================")

if failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qall!")
end
