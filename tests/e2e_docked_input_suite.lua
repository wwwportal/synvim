-- ==============================================================================
-- e2e_docked_input_suite.lua: Verification for Docked Bottom Split Multi-line Input
-- ==============================================================================

local script_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local repo_root = vim.fn.fnamemodify(script_dir, ":h")
vim.opt.rtp:prepend(repo_root .. "/nvim")
package.path = repo_root .. "/nvim/lua/?.lua;" .. repo_root .. "/nvim/lua/?/init.lua;" .. package.path

local ui = require("agent.ui")
local agent = require("agent")

local passed = 0
local failed = 0

local function assert_true(cond, msg)
  if cond then
    passed = passed + 1
    print(string.format("  PASS: %s", msg))
  else
    failed = failed + 1
    error(string.format("Assertion failed: %s", msg))
  end
end

local function assert_eq(actual, expected, msg)
  if actual == expected then
    passed = passed + 1
    print(string.format("  PASS: %s", msg))
  else
    failed = failed + 1
    error(string.format("Assertion failed: %s (Expected '%s', got '%s')", msg, tostring(expected), tostring(actual)))
  end
end

print("==================================================================")
print("  Running synvim Docked Bottom Split Input Test Suite             ")
print("==================================================================")

-- -----------------------------------------------------------------------------
-- SCENARIO 1: Docked Split Properties (No Floating Clutter)
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 1] Docked Split Properties (No Floating Clutter)")
do
  local origin_win = vim.api.nvim_get_current_win()
  local submitted_text = nil

  local win, buf = ui.open_docked_input("Ask: Test Question", "", function(text)
    submitted_text = text
  end)

  assert_true(win ~= nil and vim.api.nvim_win_is_valid(win), "Docked split window opened successfully")
  assert_true(buf ~= nil and vim.api.nvim_buf_is_valid(buf), "Docked buffer created successfully")

  -- Verify it is a true docked split, NOT a floating window
  local cfg = vim.api.nvim_win_get_config(win)
  assert_eq(cfg.relative, "", "Window is a docked split (relative is empty), NOT a floating window over code")

  -- Verify buffer options
  assert_eq(vim.bo[buf].buftype, "nofile", "Buffer type is 'nofile'")
  assert_eq(vim.bo[buf].filetype, "markdown", "Buffer filetype is 'markdown'")
  assert_eq(vim.wo[win].winfixheight, true, "Window has winfixheight = true")

  -- Clean up
  pcall(vim.api.nvim_win_close, win, true)
  assert_true(vim.api.nvim_win_is_valid(origin_win), "Origin window preserved")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 2: Multi-line Entry and Submission via <C-s> / Normal <CR>
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 2] Multi-line Entry and Submission")
do
  local origin_win = vim.api.nvim_get_current_win()
  local result = nil

  local win, buf = ui.open_docked_input("Ask: Multi-line Questions", "", function(text)
    result = text
  end)

  -- Simulate typing 2 discrete lines in the buffer
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "1. Where is the audio volume handler?",
    "2. How does the transcription pipeline hook into it?",
  })

  -- Simulate triggering submission
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-s>", true, false, true), "tx", false)

  assert_true(result ~= nil, "Submission callback executed")
  assert_true(result:find("1%. Where is the audio volume handler%?") ~= nil, "Captured line 1")
  assert_true(result:find("2%. How does the transcription pipeline hook into it%?") ~= nil, "Captured line 2")
  assert_true(not vim.api.nvim_win_is_valid(win), "Docked split window automatically closed after submit")
  assert_eq(vim.api.nvim_get_current_win(), origin_win, "Focus smoothly restored to origin window")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 3: Cancellation via <Esc> or q
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 3] Cancellation via <Esc> or q")
do
  local origin_win = vim.api.nvim_get_current_win()
  local result = nil

  local win, buf = ui.open_docked_input("Ask: Multi-line Cancel Test", "", function(text)
    result = text
  end)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Unwanted question" })

  -- Cancel via <Esc> in Normal mode
  vim.cmd("stopinsert")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "tx", false)

  assert_eq(result, nil, "Callback was NOT executed on cancel")
  assert_true(not vim.api.nvim_win_is_valid(win), "Docked split closed on cancel")
  assert_eq(vim.api.nvim_get_current_win(), origin_win, "Focus restored to origin window")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 4: Integration with Empty :Ask Command
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 4] Integration with Empty :Ask Command")
do
  agent.setup()
  local origin_win = vim.api.nvim_get_current_win()

  -- Run :Ask with no arguments
  vim.cmd("Ask")

  local active_win = vim.api.nvim_get_current_win()
  local active_buf = vim.api.nvim_win_get_buf(active_win)

  assert_true(active_win ~= origin_win, "Empty :Ask opened input split")
  assert_eq(vim.bo[active_buf].buftype, "nofile", "Input split has buftype 'nofile'")

  -- Cancel to clean up
  vim.cmd("stopinsert")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "tx", false)
  assert_eq(vim.api.nvim_get_current_win(), origin_win, "Focus restored after cancelling :Ask")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 5: Integration with Empty :Tasks add Command
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 5] Integration with Empty :Tasks add Command")
do
  local origin_win = vim.api.nvim_get_current_win()

  -- Run :Tasks add with no arguments
  vim.cmd("Tasks add")

  local active_win = vim.api.nvim_get_current_win()
  local active_buf = vim.api.nvim_win_get_buf(active_win)

  assert_true(active_win ~= origin_win, "Empty :Tasks add opened input split")
  assert_eq(vim.bo[active_buf].buftype, "nofile", "Input split has buftype 'nofile'")

  -- Cancel to clean up
  vim.cmd("stopinsert")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "tx", false)
  assert_eq(vim.api.nvim_get_current_win(), origin_win, "Focus restored after cancelling :Tasks add")
end

print("\n==================================================================")
print(string.format("  DOCKED INPUT TEST RUN COMPLETE: %d Passed, %d Failed", passed, failed))
print("==================================================================")
