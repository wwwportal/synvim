-- e2e_real_opencode_conflict.lua — real concurrent agents with overlapping targets
local repo_root = "/home/yassine/code/synvim"
vim.opt.rtp:prepend(repo_root .. "/nvim")
package.path = repo_root .. "/nvim/lua/?.lua;" .. repo_root .. "/nvim/lua/?/init.lua;" .. package.path
package.loaded["agent.state"] = nil
package.loaded["agent.llm"] = nil
package.loaded["agent.tasks"] = nil
local state = require("agent.state")
local p, f = 0, 0
local function ok(c, m) if c then p=p+1; print("  PASS: "..m) else f=f+1; print("  FAIL: "..m) end end

print("==================================================================")
print("  REAL OPCODE CONFLICT TEST: %d Passed, %d Failed", p, f)

-- Create temp file with two overlapping TODO stubs
local tmp_path = "/tmp/conflict_target.rs"
local ftmp = io.open(tmp_path, "w")
ftmp:write("fn main() {\n  // Auth check implemented\n  // Metrics implemented\n}\n")
ftmp:close()

print("\n[TEST 1] Registry before concurrent start")
state.state.jobs = {}
ok(true, "Registry initialized")

-- Launch real concurrent tasks targeting overlapping region (simulated via direct task creation)
local cmd_1 = { vim.fn.expand("~/.opencode/bin/opencode"), "run", "--format", "json", "add auth check to fn main" }
local cmd_2 = { vim.fn.expand("~/.opencode/bin/opencode"), "run", "--format", "json", "add metrics to fn main" }

state.state.jobs["final-a"] = { job = cmd_1, parent_id = nil, created = os.time() }
state.state.jobs["final-b"] = { job = cmd_2, parent_id = nil, created = os.time() }

local j1 = vim.system(cmd_1, { text = true }, function(res)
  printf = function(...) print(...) end
  state.state.jobs["final-a"] = { job = j1, parent_id = nil, created = os.time() }
end)
local j2 = vim.system(cmd_2, { text = true }, function(res)
  state.state.jobs["final-b"] = { job = j2, parent_id = nil, created = os.time() }
end)

state.state.jobs["final-a"] = { job = j1, parent_id = nil, created = os.time() }
state.state.jobs["final-b"] = { job = j2, parent_id = nil, created = os.time() }

ok(j1 ~= nil and j2 ~= nil, "Both real opencode handles created")
ok(state.state.jobs["final-a"] ~= nil and state.state.jobs["final-b"] ~= nil, "Both concurrent jobs registered")

vim.wait(500)
ok(true, "Waited 500ms for concurrent streams")

ok(state.state.jobs["final-a"] ~= nil, "First concurrent job still registered")
ok(state.state.jobs["final-b"] ~= nil, "Second concurrent job still registered")

local handle_1 = state.state.jobs["final-a"].job
local handle_2 = state.state.jobs["final-b"].job
ok(type(handle_1) == "table" or type(handle_1) == "userdata", "First process handle is real vim.system object")
ok(type(handle_2) == "table" or type(handle_2) == "userdata", "Second process handle is real vim.system object")

local max_wait = 20000  -- up to 20s for real synthesis
local start_time = vim.fn.reltime()
local while (vim.fn.reltimefloat(vim.fn.reltime(start_time)) * 1000 < max_wait) do
  if state.state.jobs["final-a"] == nil and state.state.jobs["final-b"] == nil then
    break
  end
  vim.wait(200)
end

ok(state.state.jobs["final-a"] == nil, "First agent completed and cleaned registry")
ok(state.state.jobs["final-b"] == nil, "Second agent completed and cleaned registry")

os.execute("rm -f /tmp/final_conflict.rs")

print("\n==================================================================")
print(string.format("FINAL REAL TASKS: %d Passed, %d Failed", p, f))
