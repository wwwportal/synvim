-- ==============================================================================
-- tests/test_dtl_suite.lua: Comprehensive Verification Suite for DTL FFI Engine
-- ==============================================================================

local dtl = require("agent.dtl")
assert(dtl.is_available(), "DTL native library must be available")

print("\n=== [1/5] Testing Permissions (P) & Prohibitions (F) ===")

-- 1. Valid modification within task scope
local task_auth = {
  id = "auth-login",
  allow = { "src/auth/*.py", "tests/test_auth.py" },
  deny = { "src/db/schema.sql" }
}

local ok, err = dtl.validate_patch(task_auth, "src/auth/jwt.py", "+ def refresh_token(): pass")
assert(ok == true, "Expected allowed file to pass: " .. tostring(err))
print("  ✓ Allowed file pass: OK")

-- 2. Permission violation: File not in allow list
local ok, err, ctd = dtl.validate_patch(task_auth, "src/billing/stripe.py", "+ def charge(): pass")
assert(ok == false, "Expected file outside allow list to be rejected")
assert(err:match("PERMISSION VIOLATION"), "Expected permission error: " .. tostring(err))
assert(ctd == "revert_patch;mark_revise", "Expected CTD repair action: " .. tostring(ctd))
print("  ✓ Permission violation caught: OK (" .. err .. ")")

-- 3. Prohibition violation: Global forbidden file (.env)
local ok, err, ctd = dtl.validate_patch(task_auth, ".env", "SECRET=123")
assert(ok == false, "Expected .env to be prohibited")
assert(err:match("PROHIBITION VIOLATION"), "Expected prohibition error: " .. tostring(err))
assert(ctd == "auto_revert;mark_revise", "Expected auto_revert: " .. tostring(ctd))
print("  ✓ Global prohibition caught (.env): OK")

-- 4. Prohibition violation: Task deny list
local ok, err, ctd = dtl.validate_patch(task_auth, "src/db/schema.sql", "DROP TABLE users;")
assert(ok == false, "Expected task deny list match to be rejected")
assert(err:match("PROHIBITION VIOLATION"), "Expected task deny error")
print("  ✓ Task deny list caught (schema.sql): OK")

print("\n=== [2/5] Testing Invariants (Box) & Secret Leakage ===")

-- 5. Invariant violation: Private key leaked in patch
local secret_patch = "--- a/keys.py\n+++ b/keys.py\n+ KEY = '''-----BEGIN RSA PRIVATE KEY-----\nMIIE...'''"
local ok, err, ctd = dtl.validate_patch(task_auth, "src/auth/jwt.py", secret_patch)
assert(ok == false, "Expected private key patch to be blocked by invariant check")
assert(err:match("INVARIANT VIOLATION"), "Expected invariant error")
assert(ctd == "purge_diff;alert_human", "Expected purge_diff CTD action")
print("  ✓ Invariant violation caught (Private Key): OK")

print("\n=== [3/5] Testing Topological DAG Sorting ===")

local tasks = {
  { id = "task-c", blocks = {}, depends_on = { "task-b" } },
  { id = "task-a", blocks = { "task-b" }, depends_on = {} },
  { id = "task-b", blocks = { "task-c" }, depends_on = { "task-a" } },
}

local sorted, cycle_err = dtl.sort_tasks(tasks)
assert(cycle_err == nil, "Expected no cycle: " .. tostring(cycle_err))
assert(#sorted == 3, "Expected 3 sorted tasks")
assert(sorted[1] == "task-a" and sorted[2] == "task-b" and sorted[3] == "task-c",
  "Incorrect topological order: " .. vim.inspect(sorted))
print("  ✓ Acyclic DAG topological order: " .. table.concat(sorted, " -> ") .. " OK")

print("\n=== [4/5] Testing Cycle & Deadlock Detection ===")

local cyclic_tasks = {
  { id = "task-1", blocks = { "task-2" }, depends_on = { "task-3" } },
  { id = "task-2", blocks = { "task-3" }, depends_on = { "task-1" } },
  { id = "task-3", blocks = { "task-1" }, depends_on = { "task-2" } },
}

local sorted, cycle_err = dtl.sort_tasks(cyclic_tasks)
assert(cycle_err ~= nil, "Expected cyclic deadlock to be detected")
assert(cycle_err:match("CYCLIC DEADLOCK DETECTED"), "Expected cyclic deadlock message: " .. tostring(cycle_err))
print("  ✓ Deadlock caught: " .. cycle_err .. " OK")

print("\n=== [5/5] Microsecond Latency Benchmark ===")

local iterations = 50000
local t0 = vim.uv.hrtime()

for _ = 1, iterations do
  dtl.validate_patch(task_auth, "src/auth/jwt.py", "+ def valid(): pass")
end

local t1 = vim.uv.hrtime()
local elapsed_us = (t1 - t0) / 1000
local per_call_us = elapsed_us / iterations

print(string.format("  ✓ Executed %d validations in %.2f ms", iterations, elapsed_us / 1000))
print(string.format("  ✓ Latency per FFI validation: %.3f µs (microseconds!)", per_call_us))
print("\n=== ALL DTL TESTS PASSED SUCCESSFULLY ===")
