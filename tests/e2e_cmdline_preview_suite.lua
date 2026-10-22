-- ==============================================================================
-- e2e_cmdline_preview_suite.lua: Verification for Live Command-Line Visual Line Break Preview
-- ==============================================================================

local script_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local repo_root = vim.fn.fnamemodify(script_dir, ":h")
vim.opt.rtp:prepend(repo_root .. "/nvim")
package.path = repo_root .. "/nvim/lua/?.lua;" .. repo_root .. "/nvim/lua/?/init.lua;" .. package.path

local cmdline_mod = require("agent.cmdline")
local search_mod = require("agent.search")

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
print("  Running synvim Command-Line Visual Line Break Preview Suite    ")
print("==================================================================")

-- -----------------------------------------------------------------------------
-- SCENARIO 1: Command Prefix Parser
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 1] Command Prefix Parser")
do
  local t1, q1 = cmdline_mod.parse_cmd("Ask where is diff implemented?")
  assert_eq(t1, "ask", "Parses 'Ask' command")
  assert_eq(q1, "where is diff implemented?", "Extracts question query")

  local t2, q2 = cmdline_mod.parse_cmd("ask where is diff implemented?")
  assert_eq(t2, "ask", "Parses lowercase 'ask'")

  local t3, q3 = cmdline_mod.parse_cmd(":'<,'>Ask 1. first 2. second")
  assert_eq(t3, "ask", "Parses visual range prefix :'<,'>Ask")
  assert_eq(q3, "1. first 2. second", "Extracts range query")

  local t4, q4 = cmdline_mod.parse_cmd("Tasks add 1. add parser 2. test parser")
  assert_eq(t4, "tasks", "Parses 'Tasks add' command")
  assert_eq(q4, "1. add parser 2. test parser", "Extracts tasks query")

  local t5, q5 = cmdline_mod.parse_cmd("tasks add fix bug")
  assert_eq(t5, "tasks", "Parses lowercase 'tasks add'")

  local t6, q6 = cmdline_mod.parse_cmd("Find semantic search")
  assert_eq(t6, "find", "Parses 'Find' command")

  local t7, q7 = cmdline_mod.parse_cmd("w")
  assert_eq(t7, nil, "Ignores unrelated commands (:w)")

  local t8, q8 = cmdline_mod.parse_cmd("edit foo.lua")
  assert_eq(t8, nil, "Ignores unrelated commands (:edit)")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 2: Query Breakdown & Multi-Line Item Detection
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 2] Query Breakdown & Multi-Line Item Detection")
do
  -- Numbered questions
  local q_num = cmdline_mod.get_preview_items("ask", "1. where is diff defined? 2. how does tasks add work?")
  assert_eq(#q_num, 2, "Numbered list breaks into 2 discrete questions")
  assert_eq(q_num[1], "where is diff defined?", "Q1 extracted cleanly")
  assert_eq(q_num[2], "how does tasks add work?", "Q2 extracted cleanly")

  -- Literal \n breaks
  local q_nl = cmdline_mod.get_preview_items("ask", "where is diff defined?\\nhow does tasks add work?")
  assert_eq(#q_nl, 2, "Literal \\n breaks into 2 discrete questions")
  assert_eq(q_nl[1], "where is diff defined?", "Q1 extracted from \\n break")
  assert_eq(q_nl[2], "how does tasks add work?", "Q2 extracted from \\n break")

  -- Real newlines breaks
  local q_real = cmdline_mod.get_preview_items("ask", "where is diff defined?\nhow does tasks add work?")
  assert_eq(#q_real, 2, "Real newline breaks into 2 discrete questions")

  -- Multiple question marks
  local q_qm = cmdline_mod.get_preview_items("ask", "where is diff defined? how does tasks add work?")
  assert_eq(#q_qm, 2, "Multiple question marks break into 2 discrete questions")

  -- Tasks add newlines
  local t_nl = cmdline_mod.get_preview_items("tasks", "implement preview renderer\\nwrite e2e test suite")
  assert_eq(#t_nl, 2, "Tasks add with \\n breaks into 2 discrete tasks")
  assert_eq(t_nl[1], "implement preview renderer", "Task 1 extracted")
  assert_eq(t_nl[2], "write e2e test suite", "Task 2 extracted")

  -- Tasks add numbered
  local t_num = cmdline_mod.get_preview_items("tasks", "1. implement preview\\n2. add tests")
  assert_eq(#t_num, 2, "Tasks add with numbered list breaks into 2 discrete tasks")
  assert_eq(t_num[1], "implement preview", "Task 1 extracted")
  assert_eq(t_num[2], "add tests", "Task 2 extracted")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 3: Floating Preview Window Rendering Above Cmdline
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 3] Floating Preview Window Rendering Above Cmdline")
do
  cmdline_mod.close_preview()

  -- 1. Initial empty command rendering
  cmdline_mod.update_preview("Ask ")
  assert_true(cmdline_mod.preview_win ~= nil and vim.api.nvim_win_is_valid(cmdline_mod.preview_win), "Floating preview window opened for 'Ask '")
  assert_true(cmdline_mod.preview_buf ~= nil and vim.api.nvim_buf_is_valid(cmdline_mod.preview_buf), "Preview buffer created")

  local cfg = vim.api.nvim_win_get_config(cmdline_mod.preview_win)
  assert_true(cfg.focusable == false, "Window is strictly non-focusable (prevents stealing cursor from cmdline)")
  assert_true(cfg.zindex == 250, "Window has elevated z-index (250)")

  -- Verify positioning is directly above cmdline
  local expected_max_row = vim.o.lines - 3
  local actual_row = type(cfg.row) == "table" and cfg.row[false] or cfg.row
  assert_true(actual_row <= expected_max_row, "Window row positioned flush directly above cmdline")

  -- 2. Multi-line query rendering
  cmdline_mod.update_preview("Ask 1. Where is diff located? 2. How are tests run?")
  local lines = vim.api.nvim_buf_get_lines(cmdline_mod.preview_buf, 0, -1, false)
  assert_true(#lines >= 2, "Buffer updated with multiple rendered visual lines")
  assert_true(lines[1]:find("%[Q1%] Where is diff located%?") ~= nil, "Line 1 formatted with [Q1] badge")
  assert_true(lines[2]:find("%[Q2%] How are tests run%?") ~= nil, "Line 2 formatted with [Q2] badge")

  -- Verify extmarks (syntax highlights) applied
  local marks = vim.api.nvim_buf_get_extmarks(cmdline_mod.preview_buf, cmdline_mod.ns_preview, 0, -1, { details = true })
  assert_true(#marks >= 2, "Extmark badges applied for question visual indicators")

  -- 3. Switching to Tasks add dynamically
  cmdline_mod.update_preview("Tasks add 1. build feature 2. run suite")
  local t_lines = vim.api.nvim_buf_get_lines(cmdline_mod.preview_buf, 0, -1, false)
  assert_true(t_lines[1]:find("%[T1%] build feature") ~= nil, "Line 1 formatted with [T1] badge")
  assert_true(t_lines[2]:find("%[T2%] run suite") ~= nil, "Line 2 formatted with [T2] badge")

  -- 4. Switching to unrelated command closes window
  cmdline_mod.update_preview("edit file.txt")
  assert_true(cmdline_mod.preview_win == nil, "Preview window closed when typing unrelated command")
  assert_true(cmdline_mod.preview_buf == nil, "Preview buffer closed when typing unrelated command")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 4: Interactive Typing & Autocmd Integration
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 4] Interactive Typing & Autocmd Integration")
do
  cmdline_mod.close_preview()
  cmdline_mod.setup()

  local was_window_valid_during_typing = false
  local lines_during_typing = nil
  local leave_called = false

  local test_grp = vim.api.nvim_create_augroup("TestCmdlineSpy", { clear = true })
  vim.api.nvim_create_autocmd("CmdlineChanged", {
    group = test_grp,
    callback = function()
      if cmdline_mod.preview_win and vim.api.nvim_win_is_valid(cmdline_mod.preview_win) then
        was_window_valid_during_typing = true
        lines_during_typing = vim.api.nvim_buf_get_lines(cmdline_mod.preview_buf, 0, -1, false)
      end
    end,
  })
  vim.api.nvim_create_autocmd("CmdlineLeave", {
    group = test_grp,
    callback = function()
      leave_called = true
    end,
  })

  -- Simulate user typing :Ask query in commandline
  vim.api.nvim_feedkeys(":Ask hello\\nworld", "tx", false)

  assert_true(was_window_valid_during_typing, "CmdlineChanged automatically spawned preview window while typing")
  assert_true(lines_during_typing ~= nil and #lines_during_typing >= 2, "Rendered line breaks directly while user typed")
  assert_true(lines_during_typing[1]:find("%[Q1%] hello") ~= nil, "Captured Q1 from interactive typing")
  assert_true(lines_during_typing[2]:find("%[Q2%] world") ~= nil, "Captured Q2 from interactive typing")
  assert_true(leave_called, "CmdlineLeave was triggered on exiting cmdline")
  assert_true(cmdline_mod.preview_win == nil, "CmdlineLeave automatically closed preview window")

  -- Test <C-j> keymap in cmdline
  local cj_lines_during_typing = nil
  vim.api.nvim_create_autocmd("CmdlineChanged", {
    group = test_grp,
    callback = function()
      if cmdline_mod.preview_win and vim.api.nvim_win_is_valid(cmdline_mod.preview_win) then
        local l = vim.api.nvim_buf_get_lines(cmdline_mod.preview_buf, 0, -1, false)
        if #l >= 2 then
          cj_lines_during_typing = l
        end
      end
    end,
  })

  vim.api.nvim_feedkeys(":Ask first question\x0asecond question", "tx", false)
  assert_true(cj_lines_during_typing ~= nil, "<C-j> inserted newline break seamlessly rendered into discrete questions")
  assert_true(cj_lines_during_typing[1]:find("%[Q1%] first question") ~= nil, "Q1 rendered from <C-j>")
  assert_true(cj_lines_during_typing[2]:find("%[Q2%] second question") ~= nil, "Q2 rendered from <C-j>")
  assert_true(cmdline_mod.preview_win == nil, "Preview cleanly closed after second test")
end

print("\n==================================================================")
print(string.format("  CMDLINE PREVIEW TEST RUN COMPLETE: %d Passed, %d Failed", passed, failed))
print("==================================================================")
