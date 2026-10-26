local script_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local repo_root = vim.fn.fnamemodify(script_dir, ":h")
package.path = repo_root .. "/nvim/lua/?.lua;" .. repo_root .. "/nvim/lua/?/init.lua;" .. package.path

local workspaces = require("agent.workspaces")
local reviews = require("agent.reviews")

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

print("\n==================================================================")
print("  Running synvim Multi-Agent Workspace & Conflict Test Suite      ")
print("==================================================================")

-- [TEST 1] Workspace creation via git worktree & cleanup
print("\n[TEST 1] Ephemeral Workspace Isolation")
local test_task_id = "test-agent-worker-1"
local ws = workspaces.create_workspace(test_task_id)
assert_true(ws ~= nil and ws.path ~= nil, "Workspace created")
assert_true(vim.fn.isdirectory(ws.path) == 1, "Workspace directory exists on disk")
assert_true(ws.mode == "worktree" or ws.mode == "shadow", "Workspace has valid isolation mode")

workspaces.remove_workspace(test_task_id)
assert_true(vim.fn.isdirectory(ws.path) == 0, "Workspace directory cleanly removed")

-- [TEST 2] Base Hash Capture & Divergence Tracking
print("\n[TEST 2] Base Hash Capture & Divergence Detection")
local tmp_file = vim.fn.tempname() .. ".py"
vim.fn.writefile({ "def alpha():", "    return 1", "", "def beta():", "    return 2" }, tmp_file)

local base_snap = workspaces.capture_file_base(tmp_file)
assert_true(base_snap.hash ~= nil and #base_snap.hash == 64, "Captured valid SHA-256 base hash")
assert_eq(base_snap.lines[1], "def alpha():", "Base lines captured accurately")

-- [TEST 3] Automated Non-Overlapping 3-Way Merge (Agent A at top, Agent B at bottom)
print("\n[TEST 3] Non-Overlapping 3-Way Reconciliation (Clean Merge)")
local base_text = base_snap.content

-- Agent A modified alpha()
local cur_text = "def alpha():\n    return 42\n\ndef beta():\n    return 2\n"

-- Agent B modified beta() (non-overlapping)
local inc_text = "def alpha():\n    return 1\n\ndef beta():\n    return 99\n"

local rec_clean = workspaces.reconcile_changes(cur_text, base_text, inc_text)
assert_eq(rec_clean.status, "merged", "Status is 'merged'")
assert_true(not rec_clean.has_conflict, "No conflict reported")
assert_true(rec_clean.merged_content:find("return 42") ~= nil, "Agent A's change preserved (return 42)")
assert_true(rec_clean.merged_content:find("return 99") ~= nil, "Agent B's change preserved (return 99)")

-- [TEST 4] Direct Overlapping Conflict Detection (Both modified alpha())
print("\n[TEST 4] Direct Overlapping Conflict Detection")
-- Agent A modified alpha to 42
-- Agent B modified alpha to 100 (exact same lines)
local inc_conflict = "def alpha():\n    return 100\n\ndef beta():\n    return 2\n"

local rec_conf = workspaces.reconcile_changes(cur_text, base_text, inc_conflict)
assert_eq(rec_conf.status, "conflict", "Conflict accurately detected")
assert_true(rec_conf.has_conflict, "has_conflict is true")
assert_true(rec_conf.merged_content:find("<<<<<<<") ~= nil, "Conflict markers present (<<<<<<<)")
assert_true(rec_conf.merged_content:find("=======") ~= nil, "Conflict markers present (=======)")
assert_true(rec_conf.merged_content:find(">>>>>>>") ~= nil, "Conflict markers present (>>>>>>>)")
assert_true(rec_conf.merged_content:find("return 42") ~= nil, "Contains current buffer change (42)")
assert_true(rec_conf.merged_content:find("return 100") ~= nil, "Contains incoming agent change (100)")

-- [TEST 5] Idempotent Already-Applied Check
print("\n[TEST 5] Idempotency Check")
local rec_applied = workspaces.reconcile_changes(cur_text, base_text, cur_text)
assert_eq(rec_applied.status, "already_applied", "Detected already applied content")
assert_true(not rec_applied.has_conflict, "No conflict when already applied")

pcall(vim.fn.delete, tmp_file)

print("\n==================================================================")
print(string.format("  WORKSPACE & CONFLICT SUITE COMPLETE: %d Passed, %d Failed", passed, failed))
print("==================================================================")

if failed > 0 then
  vim.cmd("cquit 1")
end
