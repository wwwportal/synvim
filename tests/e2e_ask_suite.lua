-- =============================================================================
-- End-to-End Test Suite: :Ask Code Navigation and Relevance Verification
-- Verifies that :Ask navigates to relevant files and NEVER blindly comments on
-- an unrelated currently opened buffer.
-- =============================================================================

local script_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local repo_root = vim.fn.fnamemodify(script_dir, ":h")
vim.opt.rtp:prepend(repo_root .. "/nvim")
package.path = repo_root .. "/nvim/lua/?.lua;" .. repo_root .. "/nvim/lua/?/init.lua;" .. package.path
package.loaded["agent.init"] = nil
package.loaded["agent.search"] = nil
package.loaded["agent.cmdline"] = nil
package.loaded["agent.tasks"] = nil
package.loaded["agent.reviews"] = nil
package.loaded["agent.diff"] = nil
package.loaded["agent.llm"] = nil
package.loaded["agent.state"] = nil
package.loaded["agent.ui"] = nil

local search_mod = require("agent.search")
local tasks_mod = require("agent.tasks")
local state_mod = require("agent.state")
local diff_mod = require("agent.diff")
local ui = require("agent.ui")
local mock_llm = require("agent.llm")

local passed = 0
local failed = 0

local function assert_true(cond, msg)
  if cond then
    print("  PASS: " .. msg)
    passed = passed + 1
  else
    print("  FAIL: " .. msg)
    failed = failed + 1
    error("Assertion failed: " .. msg)
  end
end

local function assert_eq(actual, expected, msg)
  if actual == expected then
    print("  PASS: " .. msg)
    passed = passed + 1
  else
    print(string.format("  FAIL: %s (Expected '%s', got '%s')", msg, tostring(expected), tostring(actual)))
    failed = failed + 1
    error(string.format("Assertion failed: %s (Expected '%s', got '%s')", msg, tostring(expected), tostring(actual)))
  end
end

print("==================================================================")
print("  Running synvim :Ask Navigation & Relevance Verification Suite   ")
print("==================================================================")

local tmp_dir = vim.fn.tempname()
vim.fn.mkdir(tmp_dir, "p")
vim.fn.chdir(tmp_dir)

-- Setup a mock repository scenario with an unrelated file and a relevant implementation file
local unrelated_file = tmp_dir .. "/unrelated_notes.py"
local relevant_file = tmp_dir .. "/audio_engine.lua"

local unrelated_code = {
  "# Project meeting notes",
  "def some_random_notes():",
  "    return 'nothing to do with audio'",
}

local relevant_code = {
  "local M = {}",
  "",
  "--- Control headphone mic volume and capture input",
  "function M.set_microphone_volume(vol)",
  "  local level = math.max(0, math.min(100, vol))",
  "  return level",
  "end",
  "",
  "return M",
}

vim.fn.writefile(unrelated_code, unrelated_file)
vim.fn.writefile(relevant_code, relevant_file)

-- -----------------------------------------------------------------------------
-- SCENARIO 1: :Ask navigates to relevant file when unrelated file is open
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 1] Unrelated File Open -> Navigates to Relevant Target (LLM)")
do
  -- 1. Open the unrelated file in the active window
  local u_buf = vim.fn.bufadd(unrelated_file)
  vim.fn.bufload(u_buf)
  local cur_win = ui.get_primary_editor_win()
  vim.api.nvim_win_set_buf(cur_win, u_buf)

  local cur_buf_before = vim.api.nvim_win_get_buf(cur_win)
  assert_eq(vim.api.nvim_buf_get_name(cur_buf_before), unrelated_file, "Unrelated file is initially active in editor")

  -- 2. Mock LLM returning relevant file
  local original_run = mock_llm.run
  mock_llm.run = function(prompt, is_rejection, on_done)
    on_done({
      action = "navigate",
      active_target = {
        path = relevant_file,
        line = 4,
        description = "set_microphone_volume definition",
        content = "-- NOTE: Controls microphone volume level",
      },
    })
  end

  local query = "where is set_microphone_volume implemented"
  local done = false
  search_mod.ask(query, tmp_dir, function(target)
    done = true
  end)

  mock_llm.run = original_run

  -- 3. Verify editor switched window buffer to relevant_file
  local cur_buf_after = vim.api.nvim_win_get_buf(cur_win)
  local active_name = vim.api.nvim_buf_get_name(cur_buf_after)
  assert_true(active_name:find("audio_engine.lua", 1, true) ~= nil, "Active window switched to relevant file (audio_engine.lua)")

  -- 4. Verify cursor jumped to target
  local cursor = vim.api.nvim_win_get_cursor(cur_win)
  assert_true(cursor[1] == 4 or cursor[1] == 5, "Cursor positioned at target definition / inserted note")

  -- 5. Verify unrelated file was NOT modified and has NO comments/diffs
  local u_lines_after = vim.fn.readfile(unrelated_file)
  assert_eq(#u_lines_after, #unrelated_code, "Unrelated file line count unchanged")
  assert_eq(u_lines_after[1], "# Project meeting notes", "Unrelated file line 1 preserved intact")
  assert_eq(u_lines_after[2], "def some_random_notes():", "Unrelated file line 2 preserved intact")
  local u_marks = vim.api.nvim_buf_get_extmarks(u_buf, state_mod.ns_diff, 0, -1, {})
  assert_eq(#u_marks, 0, "No diff extmarks placed on unrelated file")
  diff_mod.clear_diff(true)
end

-- -----------------------------------------------------------------------------
-- SCENARIO 2: Local Search Fallback Navigates Directly to Relevant Target
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 2] Local Search Fallback -> Navigates to Relevant Target")
do
  local u_buf = vim.fn.bufadd(unrelated_file)
  local cur_win = ui.get_primary_editor_win()
  vim.api.nvim_win_set_buf(cur_win, u_buf)

  -- Simulate LLM offline (returns nil)
  local original_run = mock_llm.run
  mock_llm.run = function(prompt, is_rejection, on_done)
    on_done(nil)
  end

  local query = "set_microphone_volume"
  local candidates = search_mod.search_and_rank(query, tmp_dir)
  assert_true(#candidates > 0, "search_and_rank located candidate")
  assert_true(candidates[1].path:find("audio_engine.lua", 1, true) ~= nil, "Top candidate is audio_engine.lua")

  search_mod.ask(query, tmp_dir, function(target) end)
  mock_llm.run = original_run

  local cur_buf_after = vim.api.nvim_win_get_buf(cur_win)
  local active_name = vim.api.nvim_buf_get_name(cur_buf_after)
  assert_true(active_name:find("audio_engine.lua", 1, true) ~= nil, "Fallback switched window to audio_engine.lua")
  local u_lines = vim.fn.readfile(unrelated_file)
  assert_eq(#u_lines, #unrelated_code, "Unrelated file line count completely untouched")
  diff_mod.clear_diff(true)
end

-- -----------------------------------------------------------------------------
-- SCENARIO 3: Anti-Blind-Comment Guard overrides hallucinated open buffer
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 3] Hallucinated Open Buffer Target is Overridden to Relevant Code")
do
  -- Re-open unrelated file
  local u_buf = vim.fn.bufadd(unrelated_file)
  local cur_win = ui.get_primary_editor_win()
  vim.api.nvim_win_set_buf(cur_win, u_buf)

  -- Simulate LLM mistakenly returning active_target as the opened unrelated file
  local original_run = mock_llm.run
  mock_llm.run = function(prompt, is_rejection, on_done)
    -- LLM erroneously claims the answer is in the open file
    on_done({
      action = "navigate",
      active_target = {
        path = vim.fn.fnamemodify(unrelated_file, ":."),
        line = 2,
        content = "# NOTE: Headphone mic volume is handled here",
      },
    })
  end

  local query = "set_microphone_volume volume level"
  search_mod.ask(query, tmp_dir, function(target) end)
  mock_llm.run = original_run

  -- Verify guard redirected away from unrelated file to audio_engine.lua
  local cur_buf_after = vim.api.nvim_win_get_buf(cur_win)
  local active_name = vim.api.nvim_buf_get_name(cur_buf_after)
  assert_true(active_name:find("audio_engine.lua", 1, true) ~= nil, "Guard redirected target to relevant audio_engine.lua")

  -- Verify unrelated file lines are completely untouched
  local u_lines = vim.fn.readfile(unrelated_file)
  assert_eq(#u_lines, #unrelated_code, "Unrelated file was NOT modified by blind comment")
  assert_eq(u_lines[1], "# Project meeting notes", "Unrelated file line 1 clean")
  assert_eq(u_lines[2], "def some_random_notes():", "Unrelated file line 2 clean")

  -- Verify audio_engine.lua received comment adapted with Lua comment leader '--'
  local pending = state_mod.state.pending_diff
  if pending then
    assert_true(pending.new_lines[1]:find("%-%- NOTE:") ~= nil, "Comment adapted to target language native leader (-- NOTE:)")
    diff_mod.clear_diff(true)
  end
end

-- -----------------------------------------------------------------------------
-- SCENARIO 4: :Ask when currently open file IS genuinely relevant
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 4] Relevant File is Already Open -> Stays in File and Jumps to Line")
do
  -- Open the relevant file directly
  local r_buf = vim.fn.bufadd(relevant_file)
  vim.fn.bufload(r_buf)
  local cur_win = ui.get_primary_editor_win()
  vim.api.nvim_win_set_buf(cur_win, r_buf)
  vim.api.nvim_win_set_cursor(cur_win, { 1, 0 })

  local original_run = mock_llm.run
  mock_llm.run = function(prompt, is_rejection, on_done)
    on_done(nil)
  end

  search_mod.ask("set_microphone_volume", tmp_dir, function() end)
  mock_llm.run = original_run

  local cur_buf_after = vim.api.nvim_win_get_buf(cur_win)
  local active_name = vim.api.nvim_buf_get_name(cur_buf_after)
  assert_true(active_name:find("audio_engine.lua", 1, true) ~= nil, "Editor remained in relevant file (audio_engine.lua)")
  local cursor = vim.api.nvim_win_get_cursor(cur_win)
  assert_true(cursor[1] >= 4 and cursor[1] <= 6, "Cursor jumped to definition line")
  diff_mod.clear_diff(true)
end

-- -----------------------------------------------------------------------------
-- SCENARIO 5: Non-existent concept -> No modification to open buffer
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 5] Non-existent Concept -> No Corruption of Open Buffer")
do
  local u_buf = vim.fn.bufadd(unrelated_file)
  local cur_win = ui.get_primary_editor_win()
  vim.api.nvim_win_set_buf(cur_win, u_buf)

  local original_run = mock_llm.run
  mock_llm.run = function(prompt, is_rejection, on_done)
    on_done(nil)
  end

  search_mod.ask("quantum_antigravity_flux_hyperdrive_matrix_zero", tmp_dir, function() end)
  mock_llm.run = original_run

  local cur_buf_after = vim.api.nvim_win_get_buf(cur_win)
  assert_eq(cur_buf_after, u_buf, "Editor stayed in open buffer without crash")
  local lines = vim.fn.readfile(unrelated_file)
  assert_eq(#lines, #unrelated_code, "File lines completely untouched")
  local u_marks = vim.api.nvim_buf_get_extmarks(u_buf, state_mod.ns_diff, 0, -1, {})
  assert_eq(#u_marks, 0, "No diff extmarks applied")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 6: Multi-Question Splitting Parser
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 6] Multi-Question Splitting Parser")
do
  -- 1. Numbered questions
  local q_num = "1. Where is audio volume set? 2. Where is speech transcription handled?"
  local parts_num = search_mod.split_questions(q_num)
  assert_eq(#parts_num, 2, "Numbered questions split into 2 parts")
  assert_true(parts_num[1]:find("audio volume", 1, true) ~= nil, "Part 1 contains audio question")
  assert_true(parts_num[2]:find("speech transcription", 1, true) ~= nil, "Part 2 contains speech question")

  -- 2. Multiple question marks
  local q_qm = "Where is the jwt token generated? And where is the user session stored?"
  local parts_qm = search_mod.split_questions(q_qm)
  assert_eq(#parts_qm, 2, "Double question-mark query split into 2 parts")

  -- 3. Conjunction split
  local q_conj = "Where is the router configured, and where are endpoints registered?"
  local parts_conj = search_mod.split_questions(q_conj)
  assert_eq(#parts_conj, 2, "Conjunction 'and where' query split into 2 parts")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 7: Multi-Question End-to-End Navigation & Queue Population
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 7] Multi-Question End-to-End Navigation & Queue Population")
do
  local speech_file = tmp_dir .. "/speech_transcriber.rs"
  local speech_code = {
    "pub struct SpeechTranscriber;",
    "",
    "impl SpeechTranscriber {",
    "    pub fn process_whisper_audio() {",
    "        println!(\"transcribing\");",
    "    }",
    "}",
  }
  vim.fn.writefile(speech_code, speech_file)

  local u_buf = vim.fn.bufadd(unrelated_file)
  local cur_win = ui.get_primary_editor_win()
  vim.api.nvim_win_set_buf(cur_win, u_buf)

  local multi_query = "1. Where is set_microphone_volume defined? 2. Where is process_whisper_audio implemented?"

  local original_run = mock_llm.run
  mock_llm.run = function(prompt, is_rejection, on_done)
    -- LLM answers both questions in structured format
    on_done({
      action = "navigate",
      active_target = {
        path = relevant_file,
        line = 4,
        description = "[Q1] set_microphone_volume definition",
        content = "-- NOTE: Volume control implementation",
      },
      queue = {
        {
          path = speech_file,
          line = 4,
          description = "[Q2] process_whisper_audio implementation",
          content = "// NOTE: Speech transcription processor",
        }
      }
    })
  end

  local returned_target = nil
  local returned_queue = nil
  search_mod.ask(multi_query, tmp_dir, function(tgt, q)
    returned_target = tgt
    returned_queue = q
  end)

  mock_llm.run = original_run

  assert_true(returned_queue ~= nil and #returned_queue >= 2, "Task queue populated with answers for both questions")

  -- 1. Active window starts at Question 1 (audio_engine.lua)
  local b1 = vim.api.nvim_win_get_buf(cur_win)
  assert_true(vim.api.nvim_buf_get_name(b1):find("audio_engine.lua", 1, true) ~= nil, "Active window navigated to Q1 target (audio_engine.lua)")

  -- 2. Advance to Question 2 using tasks_mod.next()
  tasks_mod.next()

  local b2 = vim.api.nvim_win_get_buf(cur_win)
  assert_true(vim.api.nvim_buf_get_name(b2):find("speech_transcriber.rs", 1, true) ~= nil, "Advancing queue navigates to Q2 target (speech_transcriber.rs)")
  local c2 = vim.api.nvim_win_get_cursor(cur_win)
  assert_true(c2[1] >= 4 and c2[1] <= 6, "Cursor positioned at Q2 definition line")

  -- 3. Verify unrelated file remains 100% clean
  local u_lines = vim.fn.readfile(unrelated_file)
  assert_eq(#u_lines, #unrelated_code, "Unrelated open file was NOT modified by either question")
  diff_mod.clear_diff(true)
end

-- -----------------------------------------------------------------------------
-- SCENARIO 8: Multi-line Sub-Questions (Lines Spanning Multiple Lines)
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 8] Multi-line Sub-Questions Spanning Multiple Lines")
do
  local multiline_numbered = [[
1. Where is the audio volume set
   specifically for headphone microphone input?
2. Where is speech transcription handled
   for local whisper audio recording?
]]
  local parts = search_mod.split_questions(multiline_numbered)
  assert_eq(#parts, 2, "Multi-line numbered questions cleanly split into 2 questions")
  assert_true(parts[1]:find("audio volume set specifically for headphone microphone input", 1, true) ~= nil, "Question 1 collapsed multi-line body into unified sentence")
  assert_true(parts[2]:find("speech transcription handled for local whisper audio recording", 1, true) ~= nil, "Question 2 collapsed multi-line body into unified sentence")
end

-- -----------------------------------------------------------------------------
-- SCENARIO 9: Command-line Literal \n Unescaping
-- -----------------------------------------------------------------------------
print("\n[SCENARIO 9] Command-line Literal \\n Unescaping")
do
  local cli_input = "1. Where is audio volume set?\\n2. Where is speech transcription handled?"
  local parts = search_mod.split_questions(cli_input)
  assert_eq(#parts, 2, "Literal \\n unescaped to real newlines and split into 2 questions")
  assert_true(parts[1]:find("audio volume set", 1, true) ~= nil, "Part 1 has audio question")
  assert_true(parts[2]:find("speech transcription handled", 1, true) ~= nil, "Part 2 has speech question")
end

-- Clean up
pcall(vim.fn.delete, tmp_dir, "rf")

-- -----------------------------------------------------------------------------
-- SUMMARY
-- -----------------------------------------------------------------------------
print("\n==================================================================")
print(string.format("  ASK TEST RUN COMPLETE: %d Passed, %d Failed", passed, failed))
print("==================================================================")

if failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qall")
end
