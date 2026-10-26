local script_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local repo_root = vim.fn.fnamemodify(script_dir, ":h")
vim.opt.rtp:prepend(repo_root .. "/nvim")
package.path = repo_root .. "/nvim/lua/?.lua;" .. repo_root .. "/nvim/lua/?/init.lua;" .. package.path

local history = require("agent.history")
local tasks = require("agent.tasks")
local reviews = require("agent.reviews")

local passed = 0
local failed = 0

local function assert_eq(a, b, desc)
  if a == b then
    passed = passed + 1
    print(string.format("  PASS: %s", desc))
  else
    failed = failed + 1
    print(string.format("  FAIL: %s (expected '%s', got '%s')", desc, tostring(b), tostring(a)))
  end
end

local function assert_true(cond, desc)
  if cond then
    passed = passed + 1
    print(string.format("  PASS: %s", desc))
  else
    failed = failed + 1
    print(string.format("  FAIL: %s", desc))
  end
end

print("==================================================================")
print("  Running synvim :History & Tasks YES/NO/MAYBE Test Suite         ")
print("==================================================================")

-- [SCENARIO 1] Tracking file visits and deduplication
print("\n[SCENARIO 1] File Visit Tracking & Deduplication (No Duplicates)")
history.clear()

local f1 = vim.fn.fnamemodify("nvim/init.lua", ":p")
local f2 = vim.fn.fnamemodify("nvim/lua/agent/init.lua", ":p")
local f3 = vim.fn.fnamemodify("nvim/lua/agent/tasks.lua", ":p")

history.record_visit(f1, 50, 0)
history.record_visit(f2, 100, 5)
history.record_visit(f3, 200, 10)

local h = history.get_history()
assert_eq(#h, 3, "Recorded 3 distinct files")
assert_eq(h[1].path, f3, "Most recent file is f3")
assert_eq(h[1].line, 200, "f3 recorded at line 200")
assert_eq(h[2].path, f2, "Second most recent file is f2")
assert_eq(h[3].path, f1, "Third file is f1")

-- Re-visit f1 at line 545
history.record_visit(f1, 545, 2)
h = history.get_history()
assert_eq(#h, 3, "No duplicate files: still exactly 3 distinct files")
assert_eq(h[1].path, f1, "f1 promoted to top of history (most recent)")
assert_eq(h[1].line, 545, "f1 updated to line 545")
assert_eq(h[2].path, f3, "f3 shifted to second position")
assert_eq(h[3].path, f2, "f2 shifted to third position")

-- [SCENARIO 2] Navigation Graph Transitions
print("\n[SCENARIO 2] Directed Graph Transitions")
assert_true(history.state.transitions[f1] ~= nil, "f1 has transitions")
assert_true(history.state.transitions[f1][f2] == 1, "Transition f1 -> f2 recorded")
assert_true(history.state.transitions[f2][f3] == 1, "Transition f2 -> f3 recorded")
assert_true(history.state.transitions[f3][f1] == 1, "Transition f3 -> f1 recorded")
assert_true(history.state.incoming[f1][f3] == 1, "Incoming transition to f1 from f3 recorded")

-- [SCENARIO 3] Jump to Last Line
print("\n[SCENARIO 3] Jump to Recorded Last Line")
local test_win = vim.api.nvim_get_current_win()
history.jump_to(h[1], test_win) -- jump to f1 (nvim/init.lua)
local cur_buf = vim.api.nvim_get_current_buf()
local cur_cursor = vim.api.nvim_win_get_cursor(test_win)
assert_true(vim.api.nvim_buf_get_name(cur_buf):find("nvim/init.lua") ~= nil, "Jumped to nvim/init.lua")
assert_eq(cur_cursor[1], 545, "Jumped exactly to line 545")

-- [SCENARIO 4] History UI Modal Window
print("\n[SCENARIO 4] History UI Modal Rendering")
history.show_history()
assert_true(history.state.win ~= nil and vim.api.nvim_win_is_valid(history.state.win), "History modal window is open")
local modal_buf = history.state.buf
local modal_lines = vim.api.nvim_buf_get_lines(modal_buf, 0, -1, false)
assert_true(#modal_lines >= 3, "Modal contains rendered graph lines")

local found_init = false
local found_tasks = false
local found_loop = false
local found_loop_symbol = false
local found_unicode_icon = false
local banned_symbols = { "◈", "◉", "◆", "◬", "◐", "⬡", "◭", "◑", "◒", "⬢", "✦", "▲", "■", "★", "●", "○", "◀", "▶" }
for _, l in ipairs(modal_lines) do
  if l:find("init.lua") then found_init = true end
  if l:find("tasks.lua") then found_tasks = true end
  if l:find("loops back") then found_loop = true end
  if l:find("↺") then found_loop_symbol = true end
  for _, s in ipairs(banned_symbols) do
    if l:find(s, 1, true) then found_unicode_icon = true end
  end
end
assert_true(found_init, "Graph displays init.lua")
assert_true(found_tasks, "Graph displays tasks.lua")
assert_true(not found_loop, "No duplicate loop lines or 'loops back' generated")
assert_true(not found_loop_symbol, "No looping symbol '↺' in graph lines")
assert_true(not found_unicode_icon, "No unicode node icons present in graph lines")

-- Test closest task anchor resolution
local anchor = history.find_closest_anchor(f3, 1940)
assert_true(anchor ~= nil and anchor.line ~= nil, "Closest anchor resolved for tasks.lua")
assert_true(anchor.label ~= nil and #anchor.label > 0, "Anchor has descriptive label")

local win_cfg = vim.api.nvim_win_get_config(history.state.win)
assert_true(win_cfg.footer == nil or win_cfg.footer == "", "Modal has NO help text in footer")
assert_true(history.state.inspector_win ~= nil and vim.api.nvim_win_is_valid(history.state.inspector_win), "Docked inspector bar is open")

-- Test initial cursor position is directly on the node head (the number)
local init_cursor = vim.api.nvim_win_get_cursor(history.state.win)
local init_char = modal_lines[init_cursor[1]]:sub(init_cursor[2] + 1, init_cursor[2] + 1)
assert_true(init_char:match("%d") ~= nil, string.format("Initial cursor is on number digit '%s'", init_char))

-- Test j snaps directly to next node line and onto the number digit
local p1 = vim.api.nvim_win_get_cursor(history.state.win)[1]
vim.cmd("normal j")
local p2_cursor = vim.api.nvim_win_get_cursor(history.state.win)
local p2 = p2_cursor[1]
assert_true(p2 > p1 or p2 == 1, "Cursor snapped to next option line")
local p2_char = modal_lines[p2]:sub(p2_cursor[2] + 1, p2_cursor[2] + 1)
assert_true(p2_char:match("%d") ~= nil, string.format("Cursor after j is directly on number digit '%s'", p2_char))

-- Test k snaps directly to previous node line and onto the number digit
vim.cmd("normal k")
local p3_cursor = vim.api.nvim_win_get_cursor(history.state.win)
local p3 = p3_cursor[1]
assert_eq(p3, p1, "Cursor snapped back to previous option line")
local p3_char = modal_lines[p3]:sub(p3_cursor[2] + 1, p3_cursor[2] + 1)
assert_true(p3_char:match("%d") ~= nil, string.format("Cursor after k is directly on number digit '%s'", p3_char))

-- Close modal
pcall(vim.api.nvim_win_close, history.state.win, true)
assert_true(history.state.inspector_win == nil or not vim.api.nvim_win_is_valid(history.state.inspector_win), "Inspector bar closed with graph")

-- [SCENARIO 5] Quickfix Export (:History qf)
print("\n[SCENARIO 5] Quickfix History Export")
history.show_quickfix()
local qf_list = vim.fn.getqflist()
assert_eq(#qf_list, 3, "Quickfix list populated with 3 unique files")
vim.cmd("cclose")

-- [SCENARIO 6] Tasks YES, NO, MAYBE subcommands
print("\n[SCENARIO 6] Tasks YES, NO, MAYBE subcommands")
-- Test autocompletion
local comp = tasks.tasks_complete("", "Tasks ")
local has_yes = false
local has_no = false
local has_maybe = false
for _, s in ipairs(comp) do
  if s == "YES" then has_yes = true end
  if s == "NO" then has_no = true end
  if s == "MAYBE" then has_maybe = true end
end
assert_true(has_yes, "Autocomplete includes YES")
assert_true(has_no, "Autocomplete includes NO")
assert_true(has_maybe, "Autocomplete includes MAYBE")

-- Test command dispatch without crashing
local ok_yes = pcall(tasks.tasks_command, "YES non_existent_id")
local ok_no = pcall(tasks.tasks_command, "NO non_existent_id")
local ok_maybe = pcall(tasks.tasks_command, "MAYBE")
assert_true(ok_yes, ":Tasks YES executes cleanly")
assert_true(ok_no, ":Tasks NO executes cleanly")
assert_true(ok_maybe, ":Tasks MAYBE executes cleanly")

-- [SCENARIO 7] Active Time & Character Edit Tracking
print("\n[SCENARIO 7] Active Time & Character Edit Tracking")
local test_file = vim.fn.tempname() .. ".lua"
vim.fn.writefile({ "local x = 1" }, test_file)
local b_test = vim.fn.bufadd(test_file)
vim.fn.bufload(b_test)
history.record_visit(test_file, 1, 0, b_test)
history.ensure_buffer_tracked(b_test)

-- Simulate typing / edits in buffer
vim.api.nvim_buf_set_lines(b_test, 0, -1, false, { "local x = 1", "local y = 2 -- added line" })
local file_info = history.state.files[history.find_closest_anchor(test_file, 1) and test_file] or history.state.files[vim.fs.normalize(test_file)]
assert_true(file_info ~= nil, "Test file recorded in history")
assert_true(file_info.chars_added > 0, string.format("Tracked characters added: %d", file_info.chars_added))

local t_spent = history.get_file_time(file_info)
assert_true(t_spent >= 0, string.format("Time spent computed: %d seconds", t_spent))

-- [SCENARIO 8] :Synvim help Window
print("\n[SCENARIO 8] :Synvim help Window")
local ui = require("agent.ui")
ui.show_help()
local help_win = nil
local help_buf = nil
for _, w in ipairs(vim.api.nvim_list_wins()) do
  local b = vim.api.nvim_win_get_buf(w)
  if vim.bo[b].filetype == "synvim-help" then
    help_win = w
    help_buf = b
    break
  end
end
assert_true(help_win ~= nil, ":Synvim help window opened")
local help_lines = vim.api.nvim_buf_get_lines(help_buf, 0, -1, false)
local has_history_sec = false
local has_tasks_sec = false
for _, l in ipairs(help_lines) do
  if l:find("Navigation & Visited Files Graph") then has_history_sec = true end
  if l:find("Unified Tasks Workflow") then has_tasks_sec = true end
end
assert_true(has_history_sec, "Help contains Visited Files & History section")
assert_true(has_tasks_sec, "Help contains Unified Tasks Workflow section")
pcall(vim.api.nvim_win_close, help_win, true)

-- Wipe temp test buffer to avoid E37 on exit
pcall(vim.api.nvim_buf_delete, b_test, { force = true })
pcall(vim.fn.delete, test_file)

print("\n==================================================================")
print(string.format("  HISTORY & YES/NO/MAYBE SUITE COMPLETE: %d Passed, %d Failed", passed, failed))
print("==================================================================")

if failed > 0 then
  vim.cmd("cquit 1")
end
