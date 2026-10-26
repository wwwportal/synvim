-- ==============================================================================
-- tests/test_image_viewer_suite.lua: Native LuaJIT FFI Kitty Image Viewer & Zoom/Pan Suite
-- ==============================================================================

local script_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local repo_root = vim.fn.fnamemodify(script_dir, ":h")
vim.opt.rtp:prepend(repo_root .. "/nvim")
package.path = repo_root .. "/nvim/lua/?.lua;" .. repo_root .. "/nvim/lua/?/init.lua;" .. package.path
package.loaded["agent.image"] = nil

local image = require("agent.image")
assert(image.is_available(), "Native Image engine (libsynvim_image.so) must be available via LuaJIT FFI")

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

print("\n=== [1/5] Testing Native LuaJIT FFI Image Engine Initialization ===")
assert_eq(image.version(), "1.0.0-image-ffi", "Native Image FFI version")

print("\n=== [2/5] Testing Viewport Crop Geometry & Clamping via FFI ===")
do
  local c1 = image.compute_crop_rect(800, 600, 1.0, 0.5, 0.5)
  assert_eq(c1.w, 800, "Full scale width")
  assert_eq(c1.h, 600, "Full scale height")
  assert_eq(c1.x, 0, "Full scale x offset")
  assert_eq(c1.y, 0, "Full scale y offset")

  local c2 = image.compute_crop_rect(800, 600, 2.0, 0.5, 0.5)
  assert_eq(c2.w, 400, "2x zoom width is halved")
  assert_eq(c2.h, 300, "2x zoom height is halved")
  assert_eq(c2.x, 200, "2x zoom centered x offset")
  assert_eq(c2.y, 150, "2x zoom centered y offset")

  local c_left = image.compute_crop_rect(800, 600, 2.0, -0.5, 0.5)
  assert_eq(c_left.x, 0, "Left pan clamped to 0")

  local c_right = image.compute_crop_rect(800, 600, 2.0, 1.5, 1.5)
  assert_eq(c_right.x, 400, "Right pan clamped to img_w - crop_w")
  assert_eq(c_right.y, 300, "Bottom pan clamped to img_h - crop_h")
end

print("\n=== [3/5] Testing Kitty Graphics Protocol Payload Builder via FFI (No Chafa) ===")
do
  local fake_png = string.rep("PNGDATA!", 700) -- 5600 bytes -> >4096 base64 chars (multi-chunk)
  local payload = image.build_kitty_payload(fake_png, {
    id = 42,
    row = 3,
    col = 5,
    cols = 80,
    rows = 24,
  })
  assert_true(payload:find("\27_Ga=T,f=100,i=42,c=80,r=24,C=1,q=2,m=1;", 1, true) ~= nil, "First chunk has Kitty header and m=1 continuation")
  assert_true(payload:find("m=0;", 1, true) ~= nil, "Final chunk has m=0 termination")
  assert_true(payload:find("chafa", 1, true) == nil, "No chafa invocation or fallback present")

  local del_seq = image.build_kitty_delete(42)
  assert_eq(del_seq, "\27_Ga=d,d=i,i=42,q=2\27\\", "Kitty delete placement escape sequence")
end

print("\n=== [4/5] Testing In-Memory libpng Decode, Sub-Rect Crop & Kitty Render ===")
do
  local sample_png = repo_root .. "/docs/architecture/synvim_architecture.png"
  assert_true(vim.fn.filereadable(sample_png) == 1, "Sample architecture PNG exists")

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  local state = image.open_image_buffer(bufnr, sample_png, vim.api.nvim_get_current_win())

  assert_true(state ~= nil, "Image viewer state initialized for buffer")
  assert_eq(state.scale, 1.0, "Initial zoom scale is 1.0")
  assert_eq(state.pan_x, 0.5, "Initial pan_x is centered (0.5)")
  assert_eq(state.pan_y, 0.5, "Initial pan_y is centered (0.5)")
  assert_true(state.img_w > 0 and state.img_h > 0, "Image dimensions decoded in-process via libpng FFI")
  assert_true(type(state.last_escape_payload) == "string" and #state.last_escape_payload > 0, "Kitty escape payload generated on open")

  -- Zoom in
  image.zoom(bufnr, 2.0)
  assert_eq(state.scale, 2.0, "Zoom in updated scale to 2.0")
  assert_eq(state.last_crop.w, math.floor(state.img_w / 2), "Crop width halved at 2x zoom")

  -- Pan right and down
  image.pan(bufnr, 0.25, 0.15)
  assert_true(state.pan_x > 0.5, "Pan right increased pan_x")
  assert_true(state.pan_y > 0.5, "Pan down increased pan_y")

  -- Refresh preserves zoom and pan
  image.refresh(bufnr)
  assert_eq(state.scale, 2.0, "Refresh preserved 2.0x zoom scale")
  assert_true(state.pan_x > 0.5, "Refresh preserved pan_x")

  -- Reset view
  image.reset(bufnr)
  assert_eq(state.scale, 1.0, "Reset restored scale to 1.0")
  assert_eq(state.pan_x, 0.5, "Reset restored pan_x to 0.5")
  assert_eq(state.pan_y, 0.5, "Reset restored pan_y to 0.5")
end

print("\n=== [5/5] Testing Buffer Keymaps (+, -, h, j, k, l, 0) ===")
do
  local sample_png = repo_root .. "/docs/architecture/task_lifecycle.png"
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  local state = image.open_image_buffer(bufnr, sample_png, vim.api.nvim_get_current_win())

  local maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
  local found_keys = {}
  for _, m in ipairs(maps) do
    found_keys[m.lhs] = true
  end
  assert_true(found_keys["+"] and found_keys["="], "Zoom in keymaps (+ and =) registered")
  assert_true(found_keys["-"], "Zoom out keymap (-) registered")
  assert_true(found_keys["h"] and found_keys["j"] and found_keys["k"] and found_keys["l"], "Pan keymaps (h/j/k/l) registered")
  assert_true(found_keys["0"], "Reset view keymap (0) registered")
  assert_true(state ~= nil, "State active on second image buffer")
end

if failed > 0 then
  error(string.format("%d test(s) failed in test_image_viewer_suite.lua", failed))
end
print(string.format("\n=== ALL %d IMAGE VIEWER FFI TESTS PASSED ===", passed))
