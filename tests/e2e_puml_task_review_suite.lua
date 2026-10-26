-- ==============================================================================
-- tests/e2e_puml_task_review_suite.lua: Iterative PlantUML Architecture Review on Task Creation
-- ==============================================================================

local script_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local repo_root = vim.fn.fnamemodify(script_dir, ":h")
vim.opt.rtp:prepend(repo_root .. "/nvim")
package.path = repo_root .. "/nvim/lua/?.lua;" .. repo_root .. "/nvim/lua/?/init.lua;" .. package.path
package.loaded["agent.tasks"] = nil
package.loaded["agent.image"] = nil
package.loaded["agent.state"] = nil
package.loaded["agent.ui"] = nil

local tasks = require("agent.tasks")
local image = require("agent.image")
local state_mod = require("agent.state")

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

print("\n=== [1/4] Testing Architecture Review Split Opening (.puml + Rendered .png) ===")
local callback_invoked = false
local session = tasks.open_architecture_review(function()
  callback_invoked = true
end)

assert_true(session ~= nil and session.active == true, "Architecture review session is active")
assert_true(#session.puml_files >= 2, "Discovered repository .puml models in docs/architecture")
assert_true(vim.api.nvim_buf_is_valid(session.puml_buf), "PlantUML text buffer is valid")
assert_true(vim.api.nvim_buf_is_valid(session.img_buf), "Rendered diagram image buffer is valid")
assert_true(image.states[session.img_buf] ~= nil, "Image viewer FFI state attached to diagram preview buffer")

print("\n=== [2/4] Testing Iterative PlantUML Text Edit & Live Image Re-render ===")
do
  -- Zoom into the architectural diagram image first to verify re-render preserves zoom
  image.zoom(session.img_buf, 1.5)
  assert_eq(image.states[session.img_buf].scale, 1.5, "Zoomed diagram preview to 1.5x")

  local prev_renders = session.render_count or 0
  tasks.rerender_architecture_model({ sync = true })
  assert_eq(session.render_count, prev_renders + 1, "Re-render counter incremented after PlantUML iteration")
  assert_eq(image.states[session.img_buf].scale, 1.5, "Live re-render preserved 1.5x zoom state on diagram image")
end

print("\n=== [3/4] Testing Cycling Between Architectural Models (<Tab>) ===")
do
  local first_puml = session.current_puml
  tasks.cycle_architecture_model(1)
  assert_true(session.current_puml ~= first_puml, "Cycled to next .puml model in docs/architecture")
  assert_true(image.states[session.img_buf].filepath:find("%.png$") ~= nil, "Image buffer updated to matching .png diagram")
end

print("\n=== [4/4] Testing Satisfaction Confirmation Keybinding -> Transitions to Task Form/Placement ===")
do
  local maps = vim.api.nvim_buf_get_keymap(session.puml_buf, "n")
  local has_confirm = false
  local has_rerender = false
  for _, m in ipairs(maps) do
    if m.lhs == "<C-S>" or m.lhs == "<C-s>" or m.lhs == "<M-a>" or m.lhs == "<M-A>" then
      has_confirm = true
    end
    if m.lhs == "<C-R>" or m.lhs == "<C-r>" then
      has_rerender = true
    end
  end
  assert_true(has_confirm, "Satisfaction confirmation keymap (<C-s> / <M-a>) registered on .puml buffer")
  assert_true(has_rerender, "Live re-render keymap (<C-r>) registered on .puml buffer")

  tasks.confirm_architecture_review()
  assert_eq(callback_invoked, true, "Confirming architectural model invoked progression callback")
  assert_true(not (state_mod.state.arch_review and state_mod.state.arch_review.active), "Architecture review session closed cleanly")
end

if failed > 0 then
  error(string.format("%d test(s) failed in e2e_puml_task_review_suite.lua", failed))
end
print(string.format("\n=== ALL %d PUML ARCHITECTURE REVIEW TESTS PASSED ===", passed))
