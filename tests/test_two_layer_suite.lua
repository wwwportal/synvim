-- ==============================================================================
-- tests/test_two_layer_suite.lua: End-to-End Verification of the 2-Layer Architecture
-- ==============================================================================

local tasks = require("agent.tasks")
local dtl = require("agent.dtl")

print("\n=== [1/4] Verifying In-Tree Two-Layer CONTRACT Parsing ===")
local all_tasks = tasks.scan_repository_tasks()
local contracts = {}
for _, t in ipairs(all_tasks) do
  if t.kind == "CONTRACT" then
    contracts[t.task_id] = t
  end
end

assert(contracts["precommit-env-setup"] ~= nil, "precommit-env-setup contract missing")
assert(contracts["precommit-lang-gates"] ~= nil, "precommit-lang-gates contract missing")

local c1 = contracts["precommit-env-setup"]
assert(#(c1.allow or {}) == 3, "Expected 3 allow patterns in c1, got " .. #(c1.allow or {}))
assert(#(c1.forbid or {}) == 3, "Expected 3 forbid patterns in c1, got " .. #(c1.forbid or {}))
assert(#(c1.requires or {}) == 0, "Expected 0 requires in c1")
print(string.format("  ✓ Contract %s: Layer 1 (Hoare: requires:0) & Layer 2 (DTL: allow:%d, forbid:%d) OK",
  c1.task_id, #c1.allow, #c1.forbid))

local c2 = contracts["precommit-lang-gates"]
assert(#(c2.requires or {}) == 1 and c2.requires[1] == "precommit-env-setup", "Expected c2 to require c1")
print(string.format("  ✓ Contract %s: Hoare precondition requires ['%s'] OK", c2.task_id, c2.requires[1]))

print("\n=== [2/4] Verifying Layer 1: Hoare Pre-flight Check ===")
-- Attempting to run task 2 before task 1 is completed should flag unmet precondition
local unfulfilled = {}
for _, req_id in ipairs(c2.requires) do
  local dep_task = contracts[req_id]
  if dep_task and dep_task.status ~= "DONE" and dep_task.status ~= "APPROVED" then
    table.insert(unfulfilled, req_id)
  end
end
assert(#unfulfilled == 1 and unfulfilled[1] == "precommit-env-setup", "Expected precommit-env-setup to be unfulfilled")
print("  ✓ Hoare pre-flight caught unfulfilled prerequisite: " .. unfulfilled[1] .. " OK")

print("\n=== [3/4] Verifying Layer 2: DTL Trajectory Interception ===")
-- Test 1: Agent tries to edit forbidden file (e.g. .env or Cargo.lock)
local bad_patch = "+ SECRET_KEY = 'injected'"
local ok, err, ctd = dtl.validate_patch(c1, ".env", bad_patch)
assert(ok == false, "Expected .env edit to be blocked by DTL Layer 2")
assert(err:match("PROHIBITION VIOLATION"), "Expected prohibition error, got: " .. tostring(err))
assert(ctd == "auto_revert;mark_revise", "Expected auto_revert CTD action")
print("  ✓ DTL Interception (Forbidden file): " .. err .. " OK")

-- Test 2: Agent tries to leak private key into permitted file
local secret_patch = "+ RSA_KEY = '-----BEGIN RSA PRIVATE KEY-----'"
local ok_sec, err_sec, ctd_sec = dtl.validate_patch(c1, "bin/pre_commit_gates.sh", secret_patch)
assert(ok_sec == false, "Expected secret leak to be blocked by Invariant check")
assert(err_sec:match("INVARIANT VIOLATION"), "Expected invariant error, got: " .. tostring(err_sec))
assert(ctd_sec == "purge_diff;alert_human", "Expected purge_diff CTD action")
print("  ✓ DTL Interception (Secret leak invariant): " .. err_sec .. " OK")

print("\n=== [4/4] Verifying Total Correctness Path ===")
-- Compliant patch within allow scope
local good_patch = "+ pre-commit install"
local ok_good, err_good = dtl.validate_patch(c1, "bin/pre_commit_gates.sh", good_patch)
assert(ok_good == true, "Expected compliant patch to pass: " .. tostring(err_good))
print("  ✓ Compliant patch within Layer 2 policy passed cleanly OK")

print("\n=== ALL TWO-LAYER ARCHITECTURE TESTS PASSED ===")
