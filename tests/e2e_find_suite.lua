-- ==============================================================================
-- tests/e2e_find_suite.lua
-- Comprehensive E2E test suite for the Hybrid Deterministic :Find Search Engine
-- (Native C++20 LuaJIT FFI: FZF/Smith-Waterman + Okapi BM25 + 5-Line Proximity +
--  Multi-Language AST Symbol Detection + Typo Tolerance + Location Scoping)
-- ==============================================================================

package.path = "./nvim/lua/?.lua;./nvim/lua/?/init.lua;" .. package.path

local search = require("agent.search")
local state_mod = require("agent.state")
local llm_mod = require("agent.llm")
local agent = require("agent")

local pass_count = 0
local fail_count = 0
local scenario_count = 0

local function assert_true(cond, msg)
  if cond then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("  [FAIL] " .. (msg or "assertion failed"))
  end
end

local function assert_eq(actual, expected, msg)
  if actual == expected then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print(string.format("  [FAIL] %s (expected %s, got %s)", msg or "equality failed", vim.inspect(expected), vim.inspect(actual)))
  end
end

local function scenario(title, fn)
  scenario_count = scenario_count + 1
  print(string.format("==> Scenario %d: %s", scenario_count, title))
  local ok, err = pcall(fn)
  if not ok then
    fail_count = fail_count + 1
    print("  [ERROR] " .. tostring(err))
  end
end

agent.setup()
local repo_root = vim.fn.getcwd()

-- 1. Native C++20 FFI Engine Availability
scenario("Native C++20 FFI Search Engine (libsynvim_search.so) is loaded", function()
  assert_true(search.is_native_available(), "libsynvim_search.so should be loaded via LuaJIT FFI")
  assert_eq(search.version(), "0.2.0-hybrid-bm25-fzf-c++20", "Search engine version should match")
end)

-- 2. Exact & Fuzzy File Name / Path Alignment (Smith-Waterman / FZF)
scenario("Exact, suffix, and FZF subsequence filename search", function()
  -- Exact basename
  local r1 = search.search_and_rank("tasks.lua", repo_root)
  assert_true(#r1 > 0, "Should find tasks.lua")
  assert_eq(r1[1].path, "nvim/lua/agent/tasks.lua", "Top match for 'tasks.lua' must be nvim/lua/agent/tasks.lua")
  assert_eq(r1[1].match_type, "file", "Top match for 'tasks.lua' should be a file match")

  -- Path suffix match
  local r2 = search.search_and_rank("agent/diff.lua", repo_root)
  assert_true(#r2 > 0, "Should find agent/diff.lua")
  assert_eq(r2[1].path, "nvim/lua/agent/diff.lua", "Top match for 'agent/diff.lua' must be nvim/lua/agent/diff.lua")

  -- Fuzzy subsequence on filename ('dtl_eng' -> 'c_src/dtl_engine.cpp' or '.h')
  local r3 = search.search_and_rank("dtl_eng", repo_root)
  assert_true(#r3 > 0, "Should fuzzy-match 'dtl_eng'")
  assert_true(r3[1].path:find("c_src/dtl_engine", 1, true) ~= nil, "Top match for 'dtl_eng' should be dtl_engine.*")

  -- File:line syntax ('tasks.lua:45')
  local r4 = search.search_and_rank("tasks.lua:45", repo_root)
  assert_true(#r4 > 0, "Should resolve 'tasks.lua:45'")
  assert_eq(r4[1].path, "nvim/lua/agent/tasks.lua", "Path should be nvim/lua/agent/tasks.lua")
  assert_eq(r4[1].line, 45, "Line should be 45")
end)

-- 3. Multi-Language Structural Symbol Definition Ranking (Lua & C++)
scenario("Symbol definitions rank #1 above call sites and imports across repo", function()
  -- Lua function definition: open_task_form in nvim/lua/agent/tasks.lua
  local r_lua = search.search_and_rank("open_task_form", repo_root)
  assert_true(#r_lua > 0, "Should find open_task_form")
  assert_eq(r_lua[1].path, "nvim/lua/agent/tasks.lua", "open_task_form definition is in tasks.lua")
  assert_eq(r_lua[1].match_type, "symbol", "open_task_form top hit should be classified as symbol")
  assert_true(r_lua[1].description:find("function M.open_task_form", 1, true) ~= nil, "Top hit must be the function definition line")

  -- C++ FFI function definition: synvim_find_context_anchor in c_src/anchor_engine.cpp
  local r_cpp = search.search_and_rank("synvim_find_context_anchor", repo_root)
  assert_true(#r_cpp > 0, "Should find synvim_find_context_anchor")
  assert_true(
    r_cpp[1].path == "c_src/anchor_engine.cpp" or r_cpp[1].path == "c_src/anchor_engine.h",
    "Top hit for synvim_find_context_anchor should be in c_src/anchor_engine"
  )
end)

-- 4. CamelCase / snake_case Sub-Token Splitting & Typo Tolerance (Damerau-Levenshtein)
scenario("CamelCase/snake_case cross-matching and typo-tolerant identifier search", function()
  -- Query in camelCase ('openTaskForm') finds snake_case 'open_task_form'
  local r_camel = search.search_and_rank("openTaskForm", repo_root)
  assert_true(#r_camel > 0, "camelCase 'openTaskForm' should match snake_case 'open_task_form'")
  assert_eq(r_camel[1].path, "nvim/lua/agent/tasks.lua", "openTaskForm should resolve to tasks.lua")
  assert_true(r_camel[1].description:find("open_task_form", 1, true) ~= nil, "Should locate open_task_form line")

  -- Query with a typo ('synvim_find_task_blok_span' missing 'c' in 'block')
  local r_typo = search.search_and_rank("synvim_find_task_blok_span", repo_root)
  assert_true(#r_typo > 0, "Typo query 'synvim_find_task_blok_span' should still find matches")
  assert_true(
    r_typo[1].description:find("synvim_find_task_block_span", 1, true) ~= nil,
    "Typo query should resolve to synvim_find_task_block_span"
  )

  -- Single-token typo ('trajectry' missing 'o' -> 'trajectory')
  local r_typo_single = search.search_and_rank("trajectry", repo_root)
  assert_true(#r_typo_single > 0, "Single-word typo 'trajectry' should resolve via bounded edit distance")
  assert_true(
    r_typo_single[1].description:lower():find("trajectory", 1, true) ~= nil,
    "Top result for 'trajectry' should contain 'trajectory'"
  )
end)

-- 5. Natural Language & Multi-Term BM25 + 5-Line Sliding Window Proximity
scenario("Natural-language multi-term BM25 and 5-line sliding window proximity", function()
  local r_nl = search.search_and_rank("where do we start interactive placement mode and drop task at cursor", repo_root)
  assert_true(#r_nl > 0, "Natural language query should return ranked matches")
  assert_eq(r_nl[1].path, "nvim/lua/agent/tasks.lua", "Interactive placement mode is implemented in tasks.lua")
end)

-- 6. Location Argument Parser & Scoped Search (`in <loc>`, `@<loc>`, `path:<loc>`, globs, positional)
scenario("Location-scoped search restricts results to specified directories, files, or globs", function()
  -- Syntax 1: `<query> in <dir>`
  local q1, locs1 = search.parse_find_args("validate_patch in c_src", repo_root)
  assert_eq(q1, "validate_patch", "Clean query should be 'validate_patch'")
  assert_eq(#locs1, 1, "Should extract 1 location")
  assert_eq(locs1[1], "c_src", "Location should be 'c_src'")

  local res_csrc = search.search_and_rank("validate_patch in c_src", repo_root)
  assert_true(#res_csrc > 0, "Should find validate_patch in c_src")
  for _, item in ipairs(res_csrc) do
    assert_true(vim.startswith(item.path, "c_src/"), "Every result must be inside c_src/, got: " .. item.path)
  end

  -- Syntax 2: `@<file> <query>`
  local res_at = search.search_and_rank("@nvim/lua/agent/diff.lua apply", repo_root)
  assert_true(#res_at > 0, "Should find 'apply' scoped to @nvim/lua/agent/diff.lua")
  for _, item in ipairs(res_at) do
    assert_eq(item.path, "nvim/lua/agent/diff.lua", "Every result must be in nvim/lua/agent/diff.lua")
  end

  -- Syntax 3: `path:<glob> <query>`
  local res_glob = search.search_and_rank("path:*.h synvim_dtl", repo_root)
  assert_true(#res_glob > 0, "Should find 'synvim_dtl' in *.h files")
  for _, item in ipairs(res_glob) do
    assert_true(item.path:match("%.h$") ~= nil, "Every result must end with .h, got: " .. item.path)
  end

  -- Syntax 4: Positional leading directory (`c_src synvim_anchor_version`)
  local res_pos = search.search_and_rank("c_src synvim_anchor_version", repo_root)
  assert_true(#res_pos > 0, "Positional directory scope should find synvim_anchor_version in c_src")
  for _, item in ipairs(res_pos) do
    assert_true(vim.startswith(item.path, "c_src/"), "Positional scope must restrict to c_src/, got: " .. item.path)
  end

  -- Syntax 5: Multiple locations (`in c_src nvim/lua/agent/dtl.lua`)
  local res_multi = search.search_and_rank("synvim_dtl_validate_patch in c_src nvim/lua/agent/dtl.lua", repo_root)
  assert_true(#res_multi >= 2, "Should find matches across both specified locations")
  for _, item in ipairs(res_multi) do
    local ok_loc = vim.startswith(item.path, "c_src/") or item.path == "nvim/lua/agent/dtl.lua"
    assert_true(ok_loc, "Result must belong to c_src/ or nvim/lua/agent/dtl.lua, got: " .. item.path)
  end
end)

-- 7. End-to-End Floating `:Find` Menu (Search Bar on Top + Live Results Below in Same Box)
scenario(":Find opens floating menu with top search bar + results below, live-updates, previews, and jumps", function()
  local orig_llm_run = llm_mod.run
  local llm_called = false
  llm_mod.run = function(...)
    llm_called = true
    error("LLM must NEVER be called by :Find!")
  end

  local found_target = nil
  local found_queue = nil
  local win, buf = search.find("open_task_form in nvim/lua/agent", repo_root, function(best, queue)
    found_target = best
    found_queue = queue
  end)

  -- Verify floating window configuration (rounded box, centered, same buffer for search bar + results)
  assert_true(win ~= nil and vim.api.nvim_win_is_valid(win), "Floating :Find window must be open and valid")
  assert_true(buf ~= nil and vim.api.nvim_buf_is_valid(buf), "Floating :Find buffer must be valid")
  assert_eq(vim.bo[buf].filetype, "synvim-find", "Buffer filetype must be synvim-find")

  local win_cfg = vim.api.nvim_win_get_config(win)
  assert_eq(win_cfg.relative, "editor", "Find menu must be a floating editor window")

  -- Verify single-box layout: Line 1 = Search Bar, Line 2 = Divider, Lines 3+ = Ranked Results
  local box_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert_true(#box_lines >= 4, "Floating box must contain search bar (line 1), divider (line 2), and results (lines 3+)")
  assert_eq(box_lines[1], "open_task_form in nvim/lua/agent", "Line 1 must be the search bar text")
  assert_true(box_lines[2]:find("───", 1, true) ~= nil, "Line 2 must be the horizontal divider inside the box")
  assert_true(box_lines[3]:find("▶ [1]", 1, true) ~= nil, "Line 3 must be the selected top result row")
  assert_true(box_lines[3]:find("[SYMBOL]", 1, true) ~= nil, "Line 3 must display [SYMBOL] badge")
  assert_true(box_lines[3]:find("nvim/lua/agent/tasks.lua", 1, true) ~= nil, "Line 3 must show nvim/lua/agent/tasks.lua")

  -- Verify docked Code Context Inspector Bar below the floating :Find box
  local insp_win = search.state.inspector_win
  local insp_buf = search.state.inspector_buf
  assert_true(insp_win ~= nil and vim.api.nvim_win_is_valid(insp_win), "Docked Inspector window must be open and valid")
  assert_true(insp_buf ~= nil and vim.api.nvim_buf_is_valid(insp_buf), "Docked Inspector buffer must be valid")
  local insp_lines = vim.api.nvim_buf_get_lines(insp_buf, 0, -1, false)
  assert_true(#insp_lines >= 4, "Inspector bar must show header + surrounding code context lines")
  assert_true(insp_lines[1]:find("nvim/lua/agent/tasks.lua", 1, true) ~= nil, "Inspector header must show selected file path")
  local has_target_marker = false
  for _, il in ipairs(insp_lines) do
    if il:find("▶", 1, true) and il:find("function M.open_task_form", 1, true) then
      has_target_marker = true
      break
    end
  end
  assert_true(has_target_marker, "Inspector bar must display the actual source code line with ▶ marker")

  -- Verify navigating down/up in results list updates selection indicator inside the same box
  search.select_next(1)
  assert_eq(search.state.selected_idx, 2, "select_next should advance selected_idx to 2")
  local box_lines_after_next = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert_eq(box_lines_after_next[1], "open_task_form in nvim/lua/agent", "Line 1 search bar stays pinned")
  assert_true(box_lines_after_next[4]:find("▶ [2]", 1, true) ~= nil, "Line 4 must now have the selection marker ▶ [2]")

  search.select_prev(1)
  assert_eq(search.state.selected_idx, 1, "select_prev should return selected_idx to 1")

  -- Verify live search bar editing updates results below in the same box
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "synvim_find_context_anchor in c_src" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
  local live_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert_eq(live_lines[1], "synvim_find_context_anchor in c_src", "Line 1 updated to new query")
  assert_true(live_lines[3]:find("c_src/anchor_engine", 1, true) ~= nil, "Lines 3+ updated live to c_src/anchor_engine matches")

  -- Switch back to open_task_form and confirm selection (<CR>)
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "open_task_form in nvim/lua/agent" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
  search.activate_selected_result(true)

  llm_mod.run = orig_llm_run

  assert_eq(llm_called, false, ":Find must not invoke llm_mod.run")
  assert_true(not vim.api.nvim_win_is_valid(win), "Confirming selection (<CR>) must close the floating :Find window")
  assert_true(found_target ~= nil, ":Find should invoke callback with selected match")
  assert_eq(found_target.path, "nvim/lua/agent/tasks.lua", ":Find should jump to nvim/lua/agent/tasks.lua")
  assert_true(found_queue and #found_queue >= 1, ":Find should populate candidate queue")
  assert_eq(state_mod.state.queue_index, 1, "state.queue_index should be initialized to 1")

  local cur_buf_name = vim.api.nvim_buf_get_name(0)
  assert_true(cur_buf_name:find("nvim/lua/agent/tasks.lua", 1, true) ~= nil, "Active buffer must be tasks.lua")
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  assert_eq(cursor_line, found_target.line, "Cursor line must match target definition line")
end)

-- 8. Large Prover Repository Stress & Latency Benchmark (100,000+ lines + .lake/packages trap)
scenario("Large prover repo stress benchmark (100k+ dense lines + .lake dir) never freezes (< 30ms)", function()
  local tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_root .. "/src/prover", "p")
  vim.fn.mkdir(tmp_root .. "/.lake/packages/mathlib", "p")

  -- Populate .lake/packages/mathlib with giant trap files that MUST be ignored
  local trap_lines = {}
  for i = 1, 5000 do
    trap_lines[i] = string.format("theorem mathlib_trap_theorem_%d (x : Nat) : x = x := rfl", i)
  end
  for f = 1, 10 do
    vim.fn.writefile(trap_lines, string.format("%s/.lake/packages/mathlib/Trap%d.lean", tmp_root, f))
  end

  -- Populate src/prover with 50 dense Lean/Rust files (100,000 lines total) where EVERY line has 'theorem'/'def'
  local dense_lines = {}
  for i = 1, 2000 do
    dense_lines[i] = string.format("theorem r4_dense_step_%d (h : Prop) : h -> h := fun x => x", i)
  end
  for f = 1, 50 do
    if f == 25 then
      dense_lines[1000] = "theorem r4_soundness_main_goal (st : ProverState) : Valid st := by exact rfl"
    end
    vim.fn.writefile(dense_lines, string.format("%s/src/prover/Module%d.lean", tmp_root, f))
    if f == 25 then
      dense_lines[1000] = "theorem r4_dense_step_1000 (h : Prop) : h -> h := fun x => x"
    end
  end

  -- 1) First query (cold cache load of 100,000 lines + ignoring 50,000 .lake lines)
  local t0 = vim.uv.hrtime()
  local r_ubiquitous = search.search_and_rank("theorem", tmp_root)
  local cold_ms = (vim.uv.hrtime() - t0) / 1e6
  assert_true(#r_ubiquitous > 0, "Ubiquitous query 'theorem' across 100k lines must return results")
  assert_true(cold_ms < 250, string.format("Cold 100k-line scan should be fast (<250ms), took %.2f ms", cold_ms))
  for _, item in ipairs(r_ubiquitous) do
    assert_true(item.path:find("^%.lake/") == nil, ".lake directory must be completely ignored")
  end

  -- 2) Subsequent keystrokes (warm in-memory corpus cache: 't', 'th', 'theorem r4_soundness_main_goal')
  local t1 = vim.uv.hrtime()
  local r_1char = search.search_and_rank("m", tmp_root)
  local r_2char = search.search_and_rank("th", tmp_root)
  local r_target = search.search_and_rank("r4_soundness_main_goal", tmp_root)
  local warm_ms = (vim.uv.hrtime() - t1) / 1e6

  assert_true(#r_1char > 0, "1-char query 'm' should return file matches immediately")
  assert_true(#r_2char > 0, "2-char query 'th' should return bounded matches immediately")
  assert_true(#r_target > 0, "Specific theorem query must locate r4_soundness_main_goal")
  assert_eq(r_target[1].path, "src/prover/Module25.lean", "Must pinpoint Module25.lean")
  assert_eq(r_target[1].line, 1000, "Must pinpoint line 1000 in Module25.lean")
  assert_eq(r_target[1].match_type, "symbol", "Lean 'theorem' definition must be recognized as symbol")
  assert_true(warm_ms < 40, string.format("3 warm keystrokes across 100k lines must complete in <40ms total, took %.2f ms", warm_ms))
  print(string.format("  [BENCHMARK] 100k-line prover repo: Cold = %.2f ms | 3 Warm Keystrokes = %.2f ms (%.2f ms/query)", cold_ms, warm_ms, warm_ms / 3))

  vim.fn.delete(tmp_root, "rf")
end)

-- 9. Full End-to-End Workflow (:Tasks add -> :Find in Placement Mode -> <M-p> Drop -> :Tasks start -> :Tasks YES)
scenario("Full workflow: :Tasks add -> :Find target -> <M-p> drop from :Find -> :Tasks start -> :Tasks YES", function()
  local tasks_mod = require("agent.tasks")
  local reviews_mod = require("agent.reviews")
  local diff_mod = require("agent.diff")

  local e2e_dir = repo_root .. "/tests/tmp_e2e_workflow"
  vim.fn.mkdir(e2e_dir, "p")
  local target_file = e2e_dir .. "/math_ops.lua"
  local rel_target_file = "tests/tmp_e2e_workflow/math_ops.lua"
  vim.fn.writefile({
    "local M = {}",
    "",
    "function M.compute_ clamp_value(x, lo, hi)",
    "  return x",
    "end",
    "",
    "return M",
  }, target_file)
  -- Fix typo in function name so :Find locates `compute_clamp_value` as a symbol
  vim.fn.writefile({
    "local M = {}",
    "",
    "function M.compute_clamp_value(x, lo, hi)",
    "  return x",
    "end",
    "",
    "return M",
  }, target_file)

  -- Step 1: Submit a Two-Layer Contract task via :Tasks add form processor
  local form_text = table.concat({
    "CON" .. "TRACT(clamp-bounds-check):",
    "  [HOARE CODE CONTRACT]",
    "  requires:  []",
    "  action:    Clamp x between lo and hi in compute_clamp_value",
    '  ensures:   review: "Returns math.max(lo, math.min(hi, x))"',
    "",
    "  [DTL AGENT POLICY]",
    "  allow:     [" .. rel_target_file .. "]",
    "  forbid:    [.env*, *.pem, *.key]",
    '  always:    review: "Module table M is preserved"',
    "  repair:    on_violation -> (auto_revert, mark:REVISE)",
  }, "\n")

  local specs = tasks_mod.process_task_form_submission(form_text, vim.api.nvim_get_current_win(), false)
  assert_eq(#specs, 1, "Form submission should produce 1 finalized task spec")
  local placed_id = specs[1].task_id
  assert_eq(state_mod.state.placement_active, true, "Task Placement Mode must be active after :Tasks add form submit")

  -- Step 2: Open :Find while in Placement Mode to locate `compute_clamp_value` in `tests/tmp_e2e_workflow`
  local fwin, fbuf = search.open_find_menu("compute_clamp_value in tests/tmp_e2e_workflow", repo_root)
  assert_true(vim.api.nvim_win_is_valid(fwin), ":Find window must open during Placement Mode")
  local insp_lines = vim.api.nvim_buf_get_lines(search.state.inspector_buf, 0, -1, false)
  assert_true(insp_lines[1]:find("Placement [1/1]: CONTRACT(" .. placed_id .. ")", 1, true) ~= nil,
    "Inspector header must display active Task Placement badge")

  -- Step 3: Press <M-p> (`drop_task_at_selected_result`) directly inside :Find to jump & drop the task!
  local stub_rev = search.drop_task_at_selected_result(1)
  assert_true(stub_rev ~= nil, "drop_task_at_selected_result must create the task stub review")
  assert_eq(state_mod.state.placement_active, false, "Placement Mode must complete after dropping the single queued task")
  assert_true(not vim.api.nvim_win_is_valid(fwin), ":Find window must close after <M-p> drop")

  -- Verify the Two-Layer CONTRACT stub was written right above `function M.compute_clamp_value`
  local lines_after_drop = vim.fn.readfile(target_file)
  local full_after_drop = table.concat(lines_after_drop, "\n")
  assert_true(full_after_drop:find("-- CONTRACT(" .. placed_id .. "):", 1, true) ~= nil, "CONTRACT header must be placed in file")
  assert_true(full_after_drop:find("--   [HOARE CODE CONTRACT]", 1, true) ~= nil, "HOARE block must be placed in file")
  assert_true(full_after_drop:find("--   [DTL AGENT POLICY]", 1, true) ~= nil, "DTL block must be placed in file")

  -- Approve the placed task stub (:Tasks YES <placed_id>)
  reviews_mod.accept(placed_id)

  -- Step 4: Execute :Tasks start (`run_todo`) with mocked agent subprocess & DTL/Hoare gate verification
  local orig_system = vim.system
  local orig_schedule_wrap = vim.schedule_wrap
  vim.schedule_wrap = function(fn) return fn end
  vim.system = function(cmd, opts, on_exit)
    local mock_json = vim.fn.json_encode({
      start_line = 14,
      old_lines_count = 3,
      description = "Implement " .. placed_id,
      content = table.concat({
        "function M.compute_clamp_value(x, lo, hi)",
        "  return math.max(lo, math.min(hi, x))",
        "end",
      }, "\n"),
    })
    if opts and opts.stdout then
      opts.stdout(nil, mock_json)
    end
    if on_exit then
      on_exit({ code = 0, stdout = mock_json, stderr = "" })
    end
    return { kill = function() end }
  end

  local t_buf = vim.fn.bufadd(target_file)
  vim.fn.bufload(t_buf)
  tasks_mod.run_todo(t_buf, 3)
  vim.system = orig_system
  vim.schedule_wrap = orig_schedule_wrap

  -- Step 5: Approve the synthesized implementation (:Tasks YES)
  assert_true(state_mod.state.current_review ~= nil, "run_todo must create an unreviewed implementation review after passing DTL validation")
  reviews_mod.accept(state_mod.state.current_review.id)
  local final_code = table.concat(vim.fn.readfile(target_file), "\n")
  assert_true(final_code:find("math.max(lo, math.min(hi, x))", 1, true) ~= nil,
    "Final approved code on disk must contain synthesized implementation")

  vim.fn.delete(e2e_dir, "rf")
end)

-- 10. Embedded Code Documentation & External Search Providers (@deps, @loogle, @docs, @code)
scenario("Embedded Code Documentation & External Search Providers (@deps, @loogle, @docs, @code)", function()
  -- A. Test @deps provider against a local `.lake/packages/mathlib` dependency tree
  local dep_root = repo_root .. "/tests/tmp_deps_test"
  local mathlib_dir = dep_root .. "/.lake/packages/mathlib/Mathlib/Algebra/Group"
  local src_dir = dep_root .. "/src"
  vim.fn.mkdir(mathlib_dir, "p")
  vim.fn.mkdir(src_dir, "p")

  vim.fn.writefile({
    "namespace Mathlib.Algebra",
    "theorem mul_inv_cancel_left (a b : G) : a * (a⁻¹ * b) = b := by simp",
    "end Mathlib.Algebra",
  }, mathlib_dir .. "/Defs.lean")

  vim.fn.writefile({
    "def project_main : IO Unit := pure ()",
  }, src_dir .. "/Main.lean")

  -- Normal repo search must NOT include `.lake/packages`
  local normal_res = search.search_and_rank("mul_inv_cancel_left", dep_root)
  local found_in_normal = false
  for _, r in ipairs(normal_res) do
    if r.path:find(".lake", 1, true) then found_in_normal = true end
  end
  assert_eq(found_in_normal, false, "Normal :Find must ignore .lake/packages by default")

  -- `@deps` search MUST search `.lake/packages` via C++20 FFI engine and rank `mul_inv_cancel_left` #1
  local cq_deps, locs_deps, prov_deps = search.parse_find_args("@deps mul_inv_cancel_left", dep_root)
  assert_eq(prov_deps, "deps", "@deps token must set provider = 'deps'")
  assert_eq(cq_deps, "mul_inv_cancel_left", "@deps token must be stripped from clean_query")
  assert_true(#locs_deps >= 1, "@deps must resolve local dependency directories")

  local deps_res = search.search_and_rank("@deps mul_inv_cancel_left", dep_root)
  assert_true(#deps_res >= 1, "@deps search must find theorem inside .lake/packages/mathlib")
  assert_eq(deps_res[1].match_type, "deps", "@deps results must have match_type = 'deps'")
  assert_true(deps_res[1].path:find("Defs.lean", 1, true) ~= nil, "@deps top match must be Defs.lean")

  -- Subsequent normal search on same root must STILL ignore `.lake/packages` (`is_explicit_only` guard)
  local normal_after = search.search_and_rank("mul_inv_cancel_left", dep_root)
  local leaked_after = false
  for _, r in ipairs(normal_after) do
    if r.path:find(".lake", 1, true) then leaked_after = true end
  end
  assert_eq(leaked_after, false, "Cached .lake/packages files must not leak into normal repo searches")

  -- B. Test @loogle provider (Lean 4 & Mathlib4 theorem/type search + floating menu + inspector)
  search.custom_http_get = function(url)
    if url:find("loogle.lean-lang.org", 1, true) then
      return vim.fn.json_encode({
        count = 2,
        hits = {
          {
            name = "List.map_append",
            type = "∀ {α β : Type _} (f : α → β) (l₁ l₂ : List α), List.map f (l₁ ++ l₂) = List.map f l₁ ++ List.map f l₂",
            module = "Mathlib.Data.List.Basic",
            doc = "Mapping a function over an appended list distributes over `++`.",
          },
          {
            name = "Mathlib.Algebra.mul_inv_cancel_left",
            type = "∀ (a b : G), a * (a⁻¹ * b) = b",
            module = "Mathlib.Algebra.Group.Defs",
            doc = "Left cancellation with inverse in a group.",
          },
        },
      })
    elseif url:find("cht.sh", 1, true) then
      return table.concat({
        "# Lua table concatenation & manipulation",
        "local t = {'a', 'b', 'c'}",
        "print(table.concat(t, ', '))",
        "",
        "# Insert and remove elements",
        "table.insert(t, 'd')",
      }, "\n")
    elseif url:find("devdocs.io", 1, true) then
      return vim.fn.json_encode({
        entries = {
          { name = "table.concat", path = "index#pdf-table.concat", type = "Standard Libraries" },
        },
      })
    elseif url:find("grep.app", 1, true) then
      return vim.fn.json_encode({
        hits = {
          hits = {
            {
              repo = { raw = "neovim/neovim" },
              path = { raw = "runtime/lua/vim/lsp/buf.lua" },
              content = {
                snippet = '<tr data-line="41"><td>local params = util.make_position_params()</td></tr>'
                  .. '<tr data-line="42"><td><mark>nvim_open_win</mark>(buf, true, win_opts)</td></tr>'
                  .. '<tr data-line="43"><td>return win_id</td></tr>',
              },
            },
          },
        },
      })
    end
    return nil
  end

  local fwin_l, fbuf_l = search.open_find_menu("@loogle List.map_append", dep_root)
  assert_true(vim.api.nvim_win_is_valid(fwin_l), ":Find @loogle floating window must open")
  assert_eq(search.state.provider, "loogle", ":Find @loogle must set state.provider = 'loogle'")
  assert_true(#search.state.candidates >= 2, ":Find @loogle must return Loogle theorem hits")
  assert_eq(search.state.candidates[1].match_type, "loogle", "Loogle candidate must have match_type = 'loogle'")
  local l_rows = vim.api.nvim_buf_get_lines(fbuf_l, 0, -1, false)
  assert_true(l_rows[3]:find("[LOOGLE]", 1, true) ~= nil, "Floating results list must display [LOOGLE] badge")
  local l_insp = vim.api.nvim_buf_get_lines(search.state.inspector_buf, 0, -1, false)
  assert_true(l_insp[2]:find("import Mathlib.Data.List.Basic", 1, true) ~= nil, "Inspector must show Lean `import` module line")
  assert_true(l_insp[3]:find("List.map_append", 1, true) ~= nil, "Inspector must highlight theorem type signature")
  -- Second hit resolves directly to local `.lake/packages/mathlib/Mathlib/Algebra/Group/Defs.lean` line 2!
  assert_eq(search.state.candidates[2].is_virtual, false, "Loogle hit present in local .lake/packages must resolve to real local file")
  assert_eq(search.state.candidates[2].line, 2, "Loogle hit present locally must resolve exact theorem line number")

  -- Activate virtual Loogle hit (#1) and verify it opens a Lean reference buffer
  search.activate_selected_result(true, 1)
  local cur_b = vim.api.nvim_get_current_buf()
  assert_eq(vim.bo[cur_b].filetype, "lean", "Activating virtual @loogle result must open a Lean syntax buffer")
  local v_text = table.concat(vim.api.nvim_buf_get_lines(cur_b, 0, -1, false), "\n")
  assert_true(v_text:find("import Mathlib.Data.List.Basic", 1, true) ~= nil, "Virtual Loogle buffer must include import statement")

  -- C. Test @docs provider (cht.sh + DevDocs + local docs)
  local fwin_d, fbuf_d = search.open_find_menu("@docs lua table.concat", repo_root)
  assert_true(vim.api.nvim_win_is_valid(fwin_d), ":Find @docs floating window must open")
  assert_eq(search.state.provider, "docs", ":Find @docs must set state.provider = 'docs'")
  assert_true(#search.state.candidates >= 2, ":Find @docs must return cht.sh + DevDocs documentation hits")
  local d_rows = vim.api.nvim_buf_get_lines(fbuf_d, 0, -1, false)
  assert_true(d_rows[3]:find("[DOCS]", 1, true) ~= nil, "Floating results list must display [DOCS] badge")
  local d_insp = vim.api.nvim_buf_get_lines(search.state.inspector_buf, 0, -1, false)
  assert_true(#d_insp == 5, "Inspector must display 5 lines for @docs preview")
  search.close_find_menu()

  -- D. Test @code provider (grep.app public open-source code search)
  local fwin_c, fbuf_c = search.open_find_menu("@code nvim_open_win", repo_root)
  assert_true(vim.api.nvim_win_is_valid(fwin_c), ":Find @code floating window must open")
  assert_eq(search.state.provider, "code", ":Find @code must set state.provider = 'code'")
  assert_true(#search.state.candidates >= 1, ":Find @code must return public code hits")
  assert_eq(search.state.candidates[1].path, "neovim/neovim:runtime/lua/vim/lsp/buf.lua", "@code hit must format repo:path")
  assert_eq(search.state.candidates[1].line, 42, "@code hit must extract exact data-line number (42) from snippet")
  local c_rows = vim.api.nvim_buf_get_lines(fbuf_c, 0, -1, false)
  assert_true(c_rows[3]:find("[CODE]", 1, true) ~= nil, "Floating results list must display [CODE] badge")
  local c_insp = vim.api.nvim_buf_get_lines(search.state.inspector_buf, 0, -1, false)
  assert_true(c_insp[3]:find("nvim_open_win(buf, true, win_opts)", 1, true) ~= nil, "Inspector must show HTML-stripped matched code line")
  search.close_find_menu()

  search.custom_http_get = nil
  vim.fn.delete(dep_root, "rf")
end)

print("==========================================================")
print(string.format("E2E :Find Suite Complete: %d passed, %d failed across %d scenarios", pass_count, fail_count, scenario_count))
print("==========================================================")

if fail_count > 0 then
  vim.cmd("cq! 1")
else
  vim.cmd("qall!")
end
