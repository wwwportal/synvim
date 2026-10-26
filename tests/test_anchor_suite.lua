local script_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local repo_root = vim.fn.fnamemodify(script_dir, ":h")
package.path = repo_root .. "/nvim/lua/?.lua;" .. repo_root .. "/nvim/lua/?/init.lua;" .. package.path

local anchor = require("agent.anchor")
assert(anchor.is_available(), "Native Anchor engine (libsynvim_anchor.so) must be available")

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

print("\n=== [1/6] Testing Native Anchor Engine Initialization ===")
assert_eq(anchor.version(), "1.0.0-anchor-ffi", "Native Anchor FFI version")

print("\n=== [2/6] Testing 3-Point Sandwich Matching ===")
local buf1 = [[
import pytest
import os

def setup_env():
    os.environ["TEST"] = "1"

def test_feature():
    assert True
]]

local res1 = anchor.find_anchor(buf1, {
  context_before = "def setup_env():\n    os.environ[\"TEST\"] = \"1\"",
  target_lines = "def test_feature():\n    assert True",
  context_after = "",
})
assert_eq(res1.start_line, 7, "Found target block start line")
assert_eq(res1.end_line, 8, "Found target block end line")
assert_eq(res1.match_mode, "sandwich", "Matched via sandwich mode")
assert_eq(res1.confidence, 1.0, "Confidence is 1.0")

print("\n=== [3/6] Testing Line Drift & Stale Offset Tolerance ===")
-- Buffer with 50 extra lines inserted at top
local drift_lines = {}
for i = 1, 50 do
  table.insert(drift_lines, "# padding line " .. i)
end
table.insert(drift_lines, "def run_ci():")
table.insert(drift_lines, "    pytest.main()")
local buf_drift = table.concat(drift_lines, "\n")

local res_drift = anchor.find_anchor(buf_drift, {
  context_before = "# padding line 50",
  target_lines = "def run_ci():\n    pytest.main()",
  context_after = "",
})
assert_eq(res_drift.start_line, 51, "Found target despite 50-line shift")
assert_eq(res_drift.match_mode, "sandwich", "Sandwich matched shifted location")

print("\n=== [4/6] Testing Pure Insertion Junction (0-line replacement) ===")
local buf_junction = [[
steps:
  - uses: actions/checkout@v4
  - name: Run Tests
    run: pytest
]]

local res_junc = anchor.find_anchor(buf_junction, {
  context_before = "- uses: actions/checkout@v4",
  target_lines = "",
  context_after = "- name: Run Tests",
})
assert_eq(res_junc.start_line, 3, "Junction insertion point is line 3")
assert_eq(res_junc.match_mode, "junction", "Matched via junction mode")

print("\n=== [5/6] Testing Anti-Reduplication Duplicate Sentinel ===")
local buf_dup = [[
# step 1
# TODO(ci-verify-markers-clean | tier:A): Verify pytest markers
# step 2
run: pytest
]]

-- Agent asks to insert ci-verify-markers-clean at a stale position
local res_dup = anchor.find_anchor(buf_dup, {
  context_before = "run: pytest",
  target_lines = "",
  context_after = "",
  identifier_slug = "ci-verify-markers-clean",
})
assert_eq(res_dup.duplicate_line, 2, "Duplicate sentinel flagged existing task at line 2")
assert_eq(res_dup.start_line, 2, "Snapped to existing duplicate line instead of appending")

-- Testing is_already_applied verbatim detection
local res_applied = anchor.find_anchor(buf_dup, {
  new_lines = "# TODO(ci-verify-markers-clean | tier:A): Verify pytest markers",
  identifier_slug = "ci-verify-markers-clean",
})
assert_true(res_applied.is_already_applied, "Detected new_lines is already applied verbatim")
assert_eq(res_applied.start_line, 2, "Start line matches existing application")

print("\n=== [6/6] Microsecond Latency Benchmark ===")
local start_clock = vim.loop.hrtime()
local iters = 20000
for _ = 1, iters do
  anchor.find_anchor(buf1, {
    context_before = "def setup_env():",
    target_lines = "def test_feature():",
    context_after = "",
    identifier_slug = "test_feature",
  })
end
local end_clock = vim.loop.hrtime()
local total_ms = (end_clock - start_clock) / 1e6
local us_per_call = (total_ms * 1000) / iters

print(string.format("  ✓ Executed %d anchor lookups in %.2f ms", iters, total_ms))
print(string.format("  ✓ Latency per FFI anchor lookup: %.3f µs", us_per_call))
assert_true(us_per_call < 50.0, "FFI anchor latency is sub-50 microseconds")

print("\n==================================================================")
print(string.format("  ANCHOR SUITE COMPLETE: %d Passed, %d Failed", passed, failed))
print("==================================================================")

if failed > 0 then
  vim.cmd("cquit 1")
end
