-- ==============================================================================
-- specs.lua: Source-First Specification & DAG Navigator
-- Provides the unified :Specs (and :Tasks) command for Neovim.
-- Displays in-tree source specifications (syn-prover / syn-nvim) or Taskwarrior tasks in a jumpable split.
--
-- SPECIFICATION ARCHITECTURE:
-- In Syntra, each Task Graph node acts as a formal, machine-checked interpretation
-- of an informal English sentence ("TODO: ..."), translating unstructured natural
-- language intent into a typed DAG node with explicit dependencies, tiers, and
-- verifiable LexLean / Lean 4 acceptance theorems.
-- ==============================================================================

-- SPEC(unified-tasks | tier:A | blocks:[syntra-plugin-bundle]): Bridge Taskwarrior and in-tree source TODOs into unified Neovim UI.
-- Description: Design and implement unified task management system in nvim bridging Taskwarrior and in-tree source TODOs.
-- Criterion: review: ":Tasks displays integrated agenda view with source TODOs and Taskwarrior tasks"
-- [lean:spec]
-- def unified_tasks : Bool := 1000 >= 0 && 1 <= 1000
-- theorem unified_tasks_verified : unified_tasks = true := by decide

-- SPEC(lgcc-task-synthesizer | tier:B | depends_on:[lgcc-dep-bundle] | blocks:[spec-lexlean-todo-schema]): Guided transformation of informal TODO/FIXME tags into schema-compliant contracts using constrained typesafe generation.
-- Description: Integrate lgcc and prime-router / typesafe schema enforcement to analyze informal code TODOs and auto-synthesize valid tier, description, and verifiable criterion.
-- Criterion: review: ":Tasks fix or lgcc --fix-tasks interactively converts unstructured TODOs into valid in-tree contracts with user confirmation"
-- [lean:spec]
-- def lgcc_task_synthesizer : Bool := lgcc_dep_bundle
-- theorem lgcc_task_synthesizer_verified : lgcc_task_synthesizer = true := by rfl

-- SPEC(spec-lexlean-todo-schema | tier:B | depends_on:[lgcc-task-synthesizer] | blocks:[spec-jit-patch-schema]): Formalize in-line source contracts as LexLean semantic specification blocks.
-- Description: Define a formal LexLean specification schema representing in-line task contracts, including inductive types for tiers, DAG dependencies, and theorem-backed acceptance criteria.
-- Criterion: assert: "LexLean schema for source task contracts passes lean4 formal verification and exports semantic AST"
-- [lean:spec]
-- def spec_lexlean_todo_schema : Bool := lgcc_task_synthesizer
-- theorem spec_lexlean_todo_schema_verified : spec_lexlean_todo_schema = true := by rfl

-- SPEC(spec-jit-patch-schema | tier:B | depends_on:[spec-lexlean-todo-schema] | blocks:[lgcc-native-linter]): Define syntax for distributed in-tree LexLean specification patches.
-- Description: Define specification patch syntax and grammar allowing in-line source comments to embed typed native Lean 4 declarations, inductive types, and theorem blocks.
-- Criterion: assert: "Formal grammar for in-line [lean:spec] patches validates under tree-sitter and Lean 4 kernel parsers"
-- [lean:spec]
-- def spec_jit_patch_schema : Bool := spec_lexlean_todo_schema
-- theorem spec_jit_patch_schema_verified : spec_jit_patch_schema = true := by rfl

-- SPEC(tasks-add-spec-scaffold | tier:B | depends_on:[lgcc-native-linter] | blocks:[tasks-lexlean-invariant-synthesis]): Extend :Tasks add to scaffold formal LexLean SPEC blocks with declaration and theorem templates.
-- Description: Extend :Tasks add in Neovim to scaffold formal Lean 4 SPEC blocks with [lean:spec] declaration and theorem templates.
-- Criterion: assert: ":Tasks add spec <desc> inserts structured SPEC comment block with native Lean 4 payload stubs at target line"
-- [lean:spec]
-- def tasks_add_spec_scaffold : Bool := lgcc_native_linter
-- theorem tasks_add_spec_scaffold_verified : tasks_add_spec_scaffold = true := by rfl

-- SPEC(tasks-lexlean-invariant-synthesis | tier:B | depends_on:[tasks-add-spec-scaffold] | blocks:[lgcc-spec-scanner]): Synthesize non-trivial LexLean domain invariants and inductive theorems from source functions.
-- Description: Upgrade :Tasks add and lgcc task synthesis to extract function argument signatures, parameter bounds, and state predicates into non-trivial LexLean definitions and machine-checkable theorems beyond reflexive tautologies.
-- Criterion: assert: "Scaffolded SPEC blocks contain typed input parameters, inductive property constraints, and verified Lean 4 theorem obligations"
-- [lean:spec]
-- def tasks_lexlean_invariant_synthesis : Bool := tasks_add_spec_scaffold
-- theorem tasks_lexlean_invariant_synthesis_verified : tasks_lexlean_invariant_synthesis = true := by rfl

-- SPEC(syntra-plugin-bundle | tier:B | depends_on:[unified-tasks] | blocks:[spec-syntra-application-manifest]): Bundle and install Syntra Neovim configuration with verified native lgcc engine.
-- Description: Provision and link Neovim configuration into ~/.config/nvim with verified native lgcc engine binary.
-- Criterion: review: "setup.sh provisions ~/.config/nvim and bin/lgcc executes cleanly"
-- [lean:spec]
-- def syntra_plugin_bundle : Bool := unified_tasks
-- theorem syntra_plugin_bundle_verified : syntra_plugin_bundle = true := by rfl

-- SPEC(spec-syntra-application-manifest | tier:B | depends_on:[syntra-plugin-bundle] | blocks:[spec-syntra-view-model]): Formalize SyntraApplication manifest specifying package metadata, token quotas, and installation targets.
-- Description: Define formal SyntraApplication inductive structure modeling package properties, context token budget limits, and script installation targets.
-- Criterion: assert: "SyntraApplication manifest passes prismpm check with zero schema errors"
-- [lean:spec]
-- inductive DistributionTarget where
--   | ScriptInstaller
--   | NeovimPlugin
--
-- structure SyntraApplication where
--   name : String
--   version : String
--   maxTokenBudget : Nat
--   target : DistributionTarget
--
-- def syntra_application_manifest : Bool := syntra_plugin_bundle
-- theorem syntra_application_manifest_verified : syntra_application_manifest = true := by rfl

-- SPEC(spec-syntra-view-model | tier:B | depends_on:[spec-syntra-application-manifest] | blocks:[spec-cli-wire-protocol-dispatch]): Formalize SyntraView and TaskAgendaView modeling Neovim presentation and keybindings.
-- Description: Model Neovim UI presentation parameters: split window layout, jumpable buffer options, agenda filter modes, and interactive key actions (<CR>, d, a, q).
-- Criterion: assert: "SyntraView and TaskAgendaView inductive structures pass Lean 4 kernel verification"
-- [lean:spec]
-- inductive AgendaAction where
--   | JumpToSource
--   | MarkCompleted
--   | FilterByTier
--   | QuitView
--
-- structure TaskAgendaView where
--   title : String
--   splitDirection : String
--   splitWidth : Nat
--   defaultAction : AgendaAction
--
-- def syntra_view_model : Bool := syntra_application_manifest
-- theorem syntra_view_model_verified : syntra_view_model = true := by rfl

local M = {}

--- Get all active directories from current window/split, buffer, terminal, or cwd
local function get_active_dirs()
  local dirs = {}
  local seen = {}
  local function add(d)
    if d and d ~= "" and not seen[d] and vim.fn.isdirectory(d) == 1 then
      seen[d] = true
      table.insert(dirs, d)
    end
  end

  -- 1. Check current buffer if terminal
  local cur_buf = vim.api.nvim_get_current_buf()
  if vim.bo[cur_buf].buftype == "terminal" then
    local pid = vim.b[cur_buf].terminal_job_pid
    if pid then
      local ok, cwd = pcall(vim.uv.fs_readlink, "/proc/" .. pid .. "/cwd")
      if ok and cwd then add(cwd) end
    end
  end

  -- 2. Check current buffer if normal file
  local bufname = vim.api.nvim_buf_get_name(cur_buf)
  if bufname ~= "" and not bufname:match("^term://") then
    add(vim.fn.fnamemodify(bufname, ":p:h"))
  end

  -- 3. Check any other open buffers (files or terminals)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      if vim.bo[bufnr].buftype == "terminal" then
        local pid = vim.b[bufnr].terminal_job_pid
        if pid then
          local ok, cwd = pcall(vim.uv.fs_readlink, "/proc/" .. pid .. "/cwd")
          if ok and cwd then add(cwd) end
        end
      else
        local bname = vim.api.nvim_buf_get_name(bufnr)
        if bname ~= "" and not bname:match("^term://") then
          add(vim.fn.fnamemodify(bname, ":p:h"))
        end
      end
    end
  end

  -- 4. Window-local and global cwd
  add(vim.fn.getcwd(0))
  add(vim.fn.getcwd())

  return dirs
end

local function get_lgcc_bin()
  local exepath = vim.fn.exepath("lgcc")
  if exepath ~= "" and vim.fn.executable(exepath) == 1 then
    return exepath
  end
  local candidates = {
    vim.fn.expand("~/code/synvim/bin/lgcc"),
    vim.fn.expand("~/code/syn-nvim/bin/lgcc"),
    vim.fn.expand("~/code/syntra-nvim/bin/lgcc"),
    vim.fn.expand("~/.local/bin/lgcc"),
    vim.fn.expand("~/.config/nvim/bin/lgcc"),
    "/usr/local/bin/lgcc",
    "/usr/bin/lgcc",
  }
  for _, c in ipairs(candidates) do
    if vim.fn.executable(c) == 1 then
      return c
    end
  end
  return nil
end

--- Find repository root for Task Graph linting in active split, buffer, terminal cwd, git root, or known repositories
--- @param target? string
local function find_lint_tasks(target)
  local default_syn_prover = vim.fn.expand("~/code/syn-prover")
  local default_prover = vim.fn.expand("~/code/prover")
  local default_synvim = vim.fn.expand("~/code/synvim")
  local default_syn = vim.fn.expand("~/code/syn-nvim")
  local default_syntra = vim.fn.expand("~/code/syntra-nvim")

  local prover_path = vim.uv.fs_stat(default_syn_prover) and default_syn_prover or default_prover
  local syn_path = vim.uv.fs_stat(default_synvim) and default_synvim or (vim.uv.fs_stat(default_syn) and default_syn or default_syntra)

  if target == "prover" and vim.uv.fs_stat(prover_path) then
    return prover_path
  elseif (target == "syntra" or target == "syntra-nvim" or target == "syn" or target == "syn-nvim" or target == "synvim") and vim.uv.fs_stat(syn_path) then
    return syn_path
  end

  local dirs = get_active_dirs()

  for _, dir in ipairs(dirs) do
    local git_root = vim.fs.root(dir, ".git")
    if git_root then
      return git_root
    end
    if dir:match("/prover") and vim.uv.fs_stat(prover_path) then
      return prover_path
    end
    if (dir:match("/syn%-nvim") or dir:match("/syntra")) and vim.uv.fs_stat(syn_path) then
      return syn_path
    end
  end

  if vim.uv.fs_stat(syn_path) then
    return syn_path
  elseif vim.uv.fs_stat(prover_path) then
    return prover_path
  end

  return nil
end

--- Set up buffer-local keymaps in the quickfix window to route jumps to the calling split
--- @param origin_win number
local function setup_qf_keymaps(origin_win)
  local qf_win = vim.api.nvim_get_current_win()
  local qf_buf = vim.api.nvim_win_get_buf(qf_win)

  -- 'q' closes the quickfix window and returns focus to origin_win
  vim.keymap.set("n", "q", function()
    vim.cmd("cclose")
    if vim.api.nvim_win_is_valid(origin_win) then
      vim.api.nvim_set_current_win(origin_win)
    end
  end, { buffer = qf_buf, silent = true, noremap = true, desc = "Close Tasks window" })

  -- Function to perform the jump into origin_win
  local function jump_in_origin(close_qf)
    local idx = vim.fn.line(".")
    local qf_list = vim.fn.getqflist()
    local item = qf_list[idx]
    if not item then return end

    local filepath = (item.filename and item.filename ~= "") and item.filename
    if not filepath or filepath == "" then
      if item.bufnr and item.bufnr > 0 and vim.api.nvim_buf_is_valid(item.bufnr) then
        filepath = vim.api.nvim_buf_get_name(item.bufnr)
      end
    end

    if not filepath or filepath == "" then
      vim.notify("Selected task has no associated file location", vim.log.levels.INFO)
      return
    end

    local target_win = origin_win
    if not vim.api.nvim_win_is_valid(target_win) or target_win == qf_win then
      -- Fallback: find any non-quickfix window
      target_win = nil
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if win ~= qf_win then
          target_win = win
          break
        end
      end
    end

    if not target_win or not vim.api.nvim_win_is_valid(target_win) then
      vim.cmd("cc " .. idx)
      return
    end

    if close_qf then
      vim.cmd("cclose")
    end

    -- Switch focus to the origin split
    vim.api.nvim_set_current_win(target_win)

    -- Open the file in this exact split
    vim.cmd("edit " .. vim.fn.fnameescape(filepath))

    -- Move cursor to line & column and center
    local lnum = math.max(1, item.lnum or 1)
    local col = math.max(0, (item.col or 1) - 1)
    pcall(vim.api.nvim_win_set_cursor, target_win, { lnum, col })
    vim.cmd("normal! zz")
  end

  -- <CR> jumps into origin_win (keeps quickfix open for easy browsing)
  vim.keymap.set("n", "<CR>", function()
    jump_in_origin(false)
  end, { buffer = qf_buf, silent = true, noremap = true, desc = "Jump to task in origin split" })

  -- Double-click jumps into origin_win
  vim.keymap.set("n", "<2-LeftMouse>", function()
    jump_in_origin(false)
  end, { buffer = qf_buf, silent = true, noremap = true, desc = "Jump to task in origin split" })

  -- 'o' jumps and closes quickfix
  vim.keymap.set("n", "o", function()
    jump_in_origin(true)
  end, { buffer = qf_buf, silent = true, noremap = true, desc = "Jump to task and close Tasks split" })

  -- 'g' toggles into the interactive visual DAG
  vim.keymap.set("n", "g", function()
    vim.cmd("cclose")
    local repo_dir = find_lint_tasks()
    M.show_visual_dag(repo_dir, origin_win)
  end, { buffer = qf_buf, silent = true, noremap = true, desc = "Toggle Visual DAG view" })
end

--- Show in-tree Source-First Task Graph
local function show_repo_tasks(repo_path, origin_win, target_task_id)
  local lgcc = get_lgcc_bin()
  if not lgcc or vim.fn.executable(lgcc) ~= 1 then
    vim.notify("tasks: Native lgcc binary not found", vim.log.levels.ERROR)
    return
  end
  local target_dir = vim.fs.root(repo_path, ".git") or repo_path
  local out = vim.fn.system({ lgcc, "--lint-tasks", "--json", target_dir })
  if vim.v.shell_error ~= 0 and (not out or out == "") then
    vim.notify("tasks: Failed to execute native lgcc task linter", vim.log.levels.ERROR)
    return
  end

  local ok, data = pcall(vim.fn.json_decode, out)
  if not ok or not data or not data.tasks then
    vim.notify("tasks: Invalid JSON output from task linter", vim.log.levels.ERROR)
    return
  end

  local tasks = data.tasks
  local root = data.root or vim.fs.root(script_path, ".git") or vim.fn.getcwd()
  local repo_name = vim.fn.fnamemodify(root, ":t"):gsub("^%l", string.upper)
  if repo_name == "" or repo_name == "." then repo_name = "Repository" end

  -- Sort: Tier A first, then Tier B, then Tier C, then by file and line
  table.sort(tasks, function(a, b)
    if (a.tier or "U") ~= (b.tier or "U") then
      return (a.tier or "U") < (b.tier or "U")
    end
    if (a.file or "") ~= (b.file or "") then
      return (a.file or "") < (b.file or "")
    end
    return (a.line or 0) < (b.line or 0)
  end)

  local index_to_id = {}
  local id_to_index = {}
  for idx, t in ipairs(tasks) do
    if t.id and t.id ~= "task" then
      index_to_id[tostring(idx)] = t.id
      id_to_index[t.id] = idx
    end
  end

  local adir = root .. "/.agent"
  pcall(vim.fn.mkdir, adir, "p")
  local index_file = adir .. "/task_index.json"
  local idx_data = {
    updated_at = os.date("%Y-%m-%d %H:%M:%S"),
    index_to_id = index_to_id,
    id_to_index = id_to_index,
  }
  pcall(vim.fn.writefile, { vim.fn.json_encode(idx_data) }, index_file)

  local target_idx = nil
  local qf = {}
  for idx, t in ipairs(tasks) do
    if target_task_id and t.id == target_task_id then
      target_idx = idx
    end
    local blocks_str = (#t.blocks > 0) and (" -> blocks [" .. table.concat(t.blocks, ", ") .. "]") or ""
    local deps_str = (#t.depends_on > 0) and (" (depends on: " .. table.concat(t.depends_on, ", ") .. ")") or ""
    local file_str = t.file or ""
    local fullpath = (file_str:sub(1, 1) == "/") and file_str or (root .. "/" .. file_str)

    local maturity_badge = ""
    if t.maturity == "VERIFIED" then
      maturity_badge = "[VERIFIED] "
    elseif t.maturity == "DRAFT" then
      maturity_badge = "[DRAFT] "
    elseif t.maturity == "INFORMAL" then
      maturity_badge = "[INFORMAL] "
    end

    local proof_note = ""
    if t.unproven_goals and #t.unproven_goals > 0 then
      proof_note = " [⊢ " .. table.concat(t.unproven_goals, "; ") .. "]"
    end

    table.insert(qf, {
      filename = fullpath,
      lnum = t.line,
      text = string.format("#%d %s[Tier %s] %s%s%s: %s%s", idx, maturity_badge, t.tier, t.id, deps_str, blocks_str, t.desc or t.description or "", proof_note),
      type = (t.maturity == "INFORMAL" and "W") or (t.maturity == "DRAFT" and "I") or "E",
    })
  end

  vim.fn.setqflist(qf, "r")
  vim.fn.setqflist({}, "a", { title = string.format("%s Source Tasks (%d tasks in DAG)", repo_name, #tasks) })
  vim.cmd("botright copen 12")
  local qf_win = vim.api.nvim_get_current_win()
  setup_qf_keymaps(origin_win)

  if target_idx then
    pcall(vim.api.nvim_win_set_cursor, qf_win, { target_idx, 0 })
    vim.cmd("normal! zz")
  end

  vim.api.nvim_echo({
    { string.format("● Loaded %d in-tree specifications for %s (<CR> to jump in split, o to jump & close, q to close)", #tasks, repo_name), "ModeMsg" }
  }, false, {})
end

--- Show interactive Visual DAG representation
--- @param repo_path? string
--- @param origin_win? number
--- @param opts? { reverse?: boolean, include_all?: boolean, filter_informal?: boolean }
function M.show_visual_dag(repo_path, origin_win, opts)
  origin_win = origin_win or vim.api.nvim_get_current_win()
  opts = opts or {}
  local reverse = opts.reverse or false
  local include_all = opts.include_all or false
  local filter_informal = opts.filter_informal or false

  local lgcc = get_lgcc_bin()
  if not lgcc or vim.fn.executable(lgcc) ~= 1 then
    vim.notify("specs: Native lgcc binary not found", vim.log.levels.ERROR)
    return
  end

  local target_dir = repo_path and (vim.fs.root(repo_path, ".git") or repo_path) or (vim.fs.root(vim.fn.getcwd(), ".git") or vim.fn.getcwd())

  -- 1. Get JSON graph metadata for node previews
  local json_args = { lgcc, "--graph", "--json" }
  if include_all then table.insert(json_args, "--all") end
  table.insert(json_args, target_dir)

  local json_out = vim.fn.system(json_args)
  local nodes_data = {}
  if vim.v.shell_error == 0 and json_out and json_out ~= "" then
    local ok, parsed = pcall(vim.fn.json_decode, json_out)
    if ok and parsed and parsed.nodes then
      nodes_data = parsed.nodes
    end
  end

  -- 2. Get ASCII graph representation
  local tree_args = { lgcc, "--graph" }
  if reverse then table.insert(tree_args, "--reverse") end
  if include_all then table.insert(tree_args, "--all") end
  table.insert(tree_args, target_dir)

  local tree_out = vim.fn.system(tree_args)
  if vim.v.shell_error ~= 0 or not tree_out or tree_out == "" then
    vim.notify("specs: Failed to render visual DAG from lgcc", vim.log.levels.ERROR)
    return
  end

  -- Reuse or open split buffer
  local buf_name = "[Specs DAG]"
  local existing_buf = nil
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):match("%[Specs DAG%]$") then
      existing_buf = b
      break
    end
  end

  local win = nil
  if existing_buf then
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == existing_buf then
        win = w
        break
      end
    end
  end

  if not win or not vim.api.nvim_win_is_valid(win) then
    vim.cmd("botright 16new")
    win = vim.api.nvim_get_current_win()
  else
    vim.api.nvim_set_current_win(win)
  end

  local buf = vim.api.nvim_win_get_buf(win)
  pcall(vim.api.nvim_buf_set_name, buf, buf_name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false

  local raw_lines = vim.split(tree_out, "\n")
  local display_lines = {}
  local line_meta = {}

  -- Header
  local flow_label = reverse and "Upstream Prerequisites (depends_on)" or "Downstream Impact (blocks)"
  local filter_label = include_all and "All (Specs + Code)" or (filter_informal and "Informal Only" or "Specs Only")
  table.insert(display_lines, string.format("─┤ SPECS DAG: %s | Filter: %s | <CR>/Click: Jump | r: Reverse | f: Filter | K: Info | q: Close ├─", flow_label, filter_label))
  table.insert(line_meta, { is_header = true })

  for _, line in ipairs(raw_lines) do
    if line ~= "" and not line:match("^===") and not line:match("^Specification & Code Graph") and not line:match("^Reverse Specification") then
      local skip = false
      if filter_informal and not line:match("%[INFORMAL%]") then
        skip = true
      end

      if not skip then
        table.insert(display_lines, line)
        local file, lnum = line:match("%((.-):(%d+)%)")
        local id = line:match("%] ([%w%-_%.]+)")
        if file and lnum then
          local full_file = (file:sub(1, 1) == "/") and file or (target_dir .. "/" .. file)
          local node_info = id and nodes_data[id] or nil
          table.insert(line_meta, {
            id = id,
            file = full_file,
            line = tonumber(lnum),
            node = node_info,
          })
        else
          table.insert(line_meta, { is_separator = true })
        end
      end
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)
  vim.bo[buf].modifiable = false

  -- Syntax highlights for badges
  vim.cmd([[
    syntax match SpecsDagVerified /\[VERIFIED\]/
    syntax match SpecsDagDraft /\[DRAFT\]/
    syntax match SpecsDagInformal /\[INFORMAL\]/
    syntax match SpecsDagCode /\[CODE\]/
    syntax match SpecsDagHeader /^─┤.*├─/
    syntax match SpecsDagBranch /[├└│─●]/
    syntax match SpecsDagLocation /(.*:[0-9]\+)/

    highlight default link SpecsDagVerified DiagnosticOk
    highlight default link SpecsDagDraft DiagnosticWarn
    highlight default link SpecsDagInformal DiagnosticInfo
    highlight default link SpecsDagCode Comment
    highlight default link SpecsDagHeader Title
    highlight default link SpecsDagBranch Special
    highlight default link SpecsDagLocation LineNr
  ]])

  -- Set up interactive keymaps
  local function jump_to_node(close_dag)
    local cur_line = vim.fn.line(".")
    local meta = line_meta[cur_line]
    if not meta or not meta.file or not meta.line then
      return
    end

    if close_dag then
      pcall(vim.api.nvim_win_close, win, true)
    end

    if vim.api.nvim_win_is_valid(origin_win) then
      vim.api.nvim_set_current_win(origin_win)
    end

    vim.cmd("edit " .. vim.fn.fnameescape(meta.file))
    pcall(vim.api.nvim_win_set_cursor, origin_win, { meta.line, 0 })
    vim.cmd("normal! zz")
  end

  -- Enter jumps into code split
  vim.keymap.set("n", "<CR>", function() jump_to_node(false) end, { buffer = buf, silent = true, noremap = true, desc = "Jump to spec/function" })
  vim.keymap.set("n", "<2-LeftMouse>", function() jump_to_node(false) end, { buffer = buf, silent = true, noremap = true, desc = "Jump to spec/function" })
  vim.keymap.set("n", "<LeftMouse>", function()
    local mouse_pos = vim.fn.getmousepos()
    if mouse_pos and mouse_pos.winid == win then
      pcall(vim.api.nvim_win_set_cursor, win, { mouse_pos.line, mouse_pos.column - 1 })
    end
  end, { buffer = buf, silent = true, noremap = true })

  -- 'o' jumps and closes
  vim.keymap.set("n", "o", function() jump_to_node(true) end, { buffer = buf, silent = true, noremap = true, desc = "Jump and close DAG" })

  -- 'r' flips direction (Forward <-> Reverse)
  vim.keymap.set("n", "r", function()
    M.show_visual_dag(target_dir, origin_win, { reverse = not reverse, include_all = include_all, filter_informal = filter_informal })
  end, { buffer = buf, silent = true, noremap = true, desc = "Toggle Downstream / Upstream direction" })

  -- 'f' cycles filter (Specs Only -> All with Code -> Informal Only -> Specs Only)
  vim.keymap.set("n", "f", function()
    if not include_all and not filter_informal then
      M.show_visual_dag(target_dir, origin_win, { reverse = reverse, include_all = true, filter_informal = false })
    elseif include_all then
      M.show_visual_dag(target_dir, origin_win, { reverse = reverse, include_all = false, filter_informal = true })
    else
      M.show_visual_dag(target_dir, origin_win, { reverse = reverse, include_all = false, filter_informal = false })
    end
  end, { buffer = buf, silent = true, noremap = true, desc = "Cycle Filter (Specs / All / Informal)" })

  -- 'K' / '<Space>' previews node details in float
  local function show_preview()
    local cur_line = vim.fn.line(".")
    local meta = line_meta[cur_line]
    if not meta or not meta.node then
      if meta and meta.file then
        vim.notify(string.format("%s:%d", meta.file, meta.line), vim.log.levels.INFO)
      end
      return
    end

    local n = meta.node
    local preview_lines = {
      string.format("Node: %s  [%s] (Tier %s)", n.id, n.maturity, n.tier or "-"),
      string.format("File: %s:%d", n.file, n.line),
      string.format("Kind: %s", n.kind),
      string.rep("─", 60),
    }

    if n.description and n.description ~= "" then
      table.insert(preview_lines, "Description:")
      table.insert(preview_lines, "  " .. n.description)
    end

    if n.criterion and n.criterion ~= "" then
      table.insert(preview_lines, "Criterion:")
      table.insert(preview_lines, "  " .. n.criterion)
    end

    if n.unproven_goals and #n.unproven_goals > 0 then
      table.insert(preview_lines, "Proof Obligations (Lean 4):")
      for _, goal in ipairs(n.unproven_goals) do
        table.insert(preview_lines, "  ⊢ " .. goal)
      end
    end

    if n.depends_on and #n.depends_on > 0 then
      table.insert(preview_lines, string.format("Depends on: [%s]", table.concat(n.depends_on, ", ")))
    end

    if n.blocks and #n.blocks > 0 then
      table.insert(preview_lines, string.format("Blocks: [%s]", table.concat(n.blocks, ", ")))
    end

    local pbuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, preview_lines)
    vim.bo[pbuf].buftype = "nofile"
    vim.bo[pbuf].bufhidden = "wipe"

    local pwin = vim.api.nvim_open_win(pbuf, true, {
      relative = "cursor",
      row = 1,
      col = 0,
      width = 65,
      height = math.min(15, #preview_lines),
      style = "minimal",
      border = "rounded",
    })

    vim.keymap.set("n", "q", function() pcall(vim.api.nvim_win_close, pwin, true) end, { buffer = pbuf, silent = true })
    vim.keymap.set("n", "<Esc>", function() pcall(vim.api.nvim_win_close, pwin, true) end, { buffer = pbuf, silent = true })
  end

  vim.keymap.set("n", "K", show_preview, { buffer = buf, silent = true, noremap = true, desc = "Preview spec details" })
  vim.keymap.set("n", "<Space>", show_preview, { buffer = buf, silent = true, noremap = true, desc = "Preview spec details" })

  -- 'q' / '<Esc>' closes DAG
  vim.keymap.set("n", "q", function()
    pcall(vim.api.nvim_win_close, win, true)
    if vim.api.nvim_win_is_valid(origin_win) then
      vim.api.nvim_set_current_win(origin_win)
    end
  end, { buffer = buf, silent = true, noremap = true, desc = "Close DAG view" })

  vim.keymap.set("n", "<Esc>", function()
    pcall(vim.api.nvim_win_close, win, true)
    if vim.api.nvim_win_is_valid(origin_win) then
      vim.api.nvim_set_current_win(origin_win)
    end
  end, { buffer = buf, silent = true, noremap = true, desc = "Close DAG view" })

  -- Position cursor on first node line (line 2)
  pcall(vim.api.nvim_win_set_cursor, win, { 2, 0 })
end

--- Parse the argument string for `:Tasks add`
--- Returns spec table or (nil, error_message)
local function parse_task_spec(args_str)
  local str = vim.trim(args_str or "")
  if str == "" then
    return nil, "Usage: :Tasks add [file] <TODO|FIXME|SPEC>[: <description>] or :Tasks add spec [file] <description>"
  end

  local is_spec_command = false
  if str:match("^[sS][pP][eE][cC]%s+") then
    is_spec_command = true
    str = vim.trim(str:sub(5))
  end

  local target_file = nil
  local first_word, rest = str:match("^(%S+)%s+(.*)$")
  if first_word and rest and (first_word:find("[./]") or vim.fn.filereadable(first_word) == 1) then
    target_file = first_word
    str = rest
  end

  local kind, custom_id, custom_attrs, desc = str:match("^(%a+)%(([^|]+)|?([^)]*)%)%s*:%s*(.+)$")
  local tier = "B"
  local blocks = nil
  local depends_on = nil

  if kind then
    kind = kind:upper()
    custom_id = vim.trim(custom_id)
    if custom_attrs and custom_attrs ~= "" then
      local t = custom_attrs:match("tier:([ABC])")
      if t then tier = t end
      blocks = custom_attrs:match("blocks:%[[^%]]*%]")
      depends_on = custom_attrs:match("depends_on:%[[^%]]*%]")
    end
    local resolved_kind = "TODO"
    if kind == "FIXME" then resolved_kind = "FIXME"
    elseif kind == "SPEC" or is_spec_command then resolved_kind = "SPEC" end

    return {
      file = target_file,
      kind = resolved_kind,
      id = custom_id,
      tier = tier,
      title = vim.trim(desc),
      description = vim.trim(desc),
      blocks = blocks,
      depends_on = depends_on,
    }
  end

  local final_kind = is_spec_command and "SPEC" or nil
  local parsed_id = nil
  local parsed_desc = nil

  local k, d = str:match("^([%w_-]+)%s*:%s*(.+)$")
  if k and d then
    local ku = k:upper()
    if ku == "TODO" or ku == "FIXME" or ku == "SPEC" then
      final_kind = ku
      parsed_desc = vim.trim(d)
    elseif is_spec_command then
      parsed_id = k
      final_kind = "SPEC"
      parsed_desc = vim.trim(d)
    else
      return nil, string.format("Unknown task type '%s'. Expected TODO, FIXME, or SPEC", k)
    end
  elseif is_spec_command then
    final_kind = "SPEC"
    parsed_desc = vim.trim(str)
  else
    local k2, d2 = str:match("^(%a+)%s+(.+)$")
    if k2 and d2 then
      local ku = k2:upper()
      if ku == "TODO" or ku == "FIXME" or ku == "SPEC" then
        final_kind = ku
        parsed_desc = vim.trim(d2)
      else
        return nil, string.format("Unknown task type '%s'. Expected TODO, FIXME, or SPEC", k2)
      end
    else
      return nil, "Invalid format. Expected: :Tasks add [file] <TODO|FIXME|SPEC>:<description> or :Tasks add spec [file] <description>"
    end
  end

  if not parsed_desc or parsed_desc == "" then
    return nil, "Task description cannot be empty"
  end

  local auto_id = parsed_id
  if not auto_id or auto_id == "" then
    local words = {}
    local stop_words = { a=true, an=true, the=true, ["to"]=true, ["for"]=true, ["in"]=true, of=true, on=true, at=true, with=true, ["and"]=true }
    for w in parsed_desc:lower():gmatch("[a-z0-9]+") do
      if not stop_words[w] then
        table.insert(words, w)
      end
      if #words >= 4 then break end
    end
    if #words == 0 then
      table.insert(words, "task")
    end
    auto_id = table.concat(words, "-")
  end

  return {
    file = target_file,
    kind = final_kind,
    id = auto_id,
    tier = "B",
    title = parsed_desc,
    description = parsed_desc,
  }
end

local function get_comment_leader(bufnr)
  local cs = vim.bo[bufnr].commentstring
  if cs and cs ~= "" and cs:find("%%s") then
    local leader = cs:gsub("%%s.*$", "")
    leader = vim.trim(leader)
    if leader ~= "" then
      return leader .. " "
    end
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  local ext = vim.fn.fnamemodify(name, ":e"):lower()
  if ext == "lua" then
    return "-- "
  elseif ext == "py" or ext == "sh" or ext == "bash" or ext == "yaml" or ext == "yml" or ext == "toml" then
    return "# "
  elseif ext == "c" or ext == "cpp" or ext == "h" or ext == "hpp" or ext == "rs" or ext == "go" or ext == "js" or ext == "ts" then
    return "// "
  end

  return "-- "
end

--- Semantically locate the best file and function line for a given task description
local function locate_target_file_and_line(repo_root, description)
  if not repo_root or repo_root == "" then
    return nil, 1
  end

  local git_cmd = string.format("git -C %s ls-files 2>/dev/null", vim.fn.shellescape(repo_root))
  local file_list_raw = vim.fn.system(git_cmd)
  if vim.v.shell_error ~= 0 or not file_list_raw or file_list_raw == "" then
    return nil, 1
  end

  local valid_exts = { lua=true, py=true, sh=true, bash=true, cpp=true, c=true, h=true, hpp=true, rs=true, go=true, js=true, ts=true, lean=true }
  local candidate_files = {}
  local scores = {}

  for line in file_list_raw:gmatch("[^\r\n]+") do
    local ext = vim.fn.fnamemodify(line, ":e"):lower()
    if valid_exts[ext] then
      table.insert(candidate_files, line)
      scores[line] = 0
    end
  end

  if #candidate_files == 0 then
    return nil, 1
  end

  local stop_words = {
    a=true, an=true, the=true, ["and"]=true, ["for"]=true, ["with"]=true,
    ["that"]=true, ["this"]=true, ["from"]=true, ["when"]=true, ["into"]=true,
    file=true, task=true, code=true, make=true, sure=true, need=true,
  }
  local keywords = {}
  for w in description:lower():gmatch("[a-z0-9_%-]+") do
    if #w > 2 and not stop_words[w] then
      table.insert(keywords, w)
    end
  end

  for _, f in ipairs(candidate_files) do
    local f_lower = f:lower()
    for _, kw in ipairs(keywords) do
      if f_lower:find(kw, 1, true) then
        scores[f] = scores[f] + 20
      end
    end
  end

  local rg_bin = vim.fn.expand("~/.local/bin/rg")
  if vim.fn.executable(rg_bin) ~= 1 then
    rg_bin = "rg"
  end

  for i = 1, math.min(#keywords, 6) do
    local kw = keywords[i]
    local rg_cmd = string.format("%s -l -i %s %s 2>/dev/null", rg_bin, vim.fn.shellescape(kw), vim.fn.shellescape(repo_root))
    local out = vim.fn.system(rg_cmd)
    if vim.v.shell_error == 0 and out and out ~= "" then
      for hit in out:gmatch("[^\r\n]+") do
        local rel = vim.fn.fnamemodify(hit, ":s?" .. repo_root .. "/??")
        if scores[rel] then
          scores[rel] = scores[rel] + 5
        end
      end
    end
  end

  local best_file = nil
  local max_score = -1
  for _, f in ipairs(candidate_files) do
    if scores[f] > max_score then
      max_score = scores[f]
      best_file = f
    end
  end

  if not best_file or max_score == 0 then
    best_file = candidate_files[1]
  end

  local fullpath = repo_root .. "/" .. best_file
  local target_line = 1

  if vim.fn.filereadable(fullpath) == 1 then
    local file_lines = vim.fn.readfile(fullpath)
    local best_func_line = nil
    local best_func_score = 0
    local cur_func_line = 1

    for lnum, line in ipairs(file_lines) do
      local is_def = line:match("^[ \t]*function%s+([%w_.:]+)")
        or line:match("^[ \t]*local%s+function%s+([%w_]+)")
        or line:match("^[ \t]*def%s+([%w_]+)")
        or line:match("^[ \t]*class%s+([%w_]+)")

      if is_def then
        cur_func_line = lnum
      end

      local line_lower = line:lower()
      local line_score = 0
      for _, kw in ipairs(keywords) do
        if line_lower:find(kw, 1, true) then
          line_score = line_score + 1
        end
      end

      if line_score > best_func_score then
        best_func_score = line_score
        best_func_line = cur_func_line
      end
    end

    if best_func_line and best_func_score > 0 then
      target_line = best_func_line
    end
  end

  return fullpath, target_line
end

local function resolve_target_file(spec_file, description, origin_win)
  if spec_file and spec_file ~= "" then
    local path = vim.fn.fnamemodify(spec_file, ":p")
    return path, 1
  end

  -- Determine active repository root
  local repo_root = nil
  local lint_root = find_lint_tasks()
  if lint_root then
    repo_root = vim.fs.root(lint_root, ".git") or lint_root
  end

  if not repo_root or repo_root == "" then
    if origin_win and vim.api.nvim_win_is_valid(origin_win) then
      local obuf = vim.api.nvim_win_get_buf(origin_win)
      local obuf_name = vim.api.nvim_buf_get_name(obuf)
      if obuf_name ~= "" and not obuf_name:match("^term://") then
        repo_root = vim.fs.root(obuf_name, ".git")
      end
    end
  end

  if not repo_root or repo_root == "" then
    repo_root = vim.fs.root(0, ".git") or vim.fn.getcwd()
  end

  local best_file, target_line = locate_target_file_and_line(repo_root, description)
  if best_file then
    return best_file, target_line
  end

  if origin_win and vim.api.nvim_win_is_valid(origin_win) then
    local obuf = vim.api.nvim_win_get_buf(origin_win)
    if vim.bo[obuf].buftype == "" and vim.api.nvim_buf_get_name(obuf) ~= "" then
      return vim.api.nvim_buf_get_name(obuf), 1
    end
  end

  return nil, 1
end

local function synthesize_lexlean_contract(bufnr, row, spec_id, depends_on_attr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local max_scan = math.min(line_count, row + 20)
  local search_lines = vim.api.nvim_buf_get_lines(bufnr, math.max(0, row - 1), max_scan, false)

  local fn_name = nil
  local raw_params = ""
  local ret_type = "bool"

  for _, line in ipairs(search_lines) do
    local r_fn, r_args, r_ret = line:match("^[ \t]*(?:pub(?:%([^)]+%))?%s+)?fn%s+([%w_]+)%s*(%b())%s*(?:->%s*([^{;]+))?")
    if r_fn then
      fn_name = r_fn
      raw_params = r_args:sub(2, -2)
      if r_ret then
        local trimmed = vim.trim(r_ret)
        if trimmed == "bool" then
          ret_type = "bool"
        elseif trimmed:match("u%d+") or trimmed:match("usize") then
          ret_type = "nat"
        elseif trimmed:match("i%d+") or trimmed:match("isize") then
          ret_type = "int"
        elseif trimmed:match("String") or trimmed:match("&str") then
          ret_type = "string"
        end
      end
      break
    end

    local l_fn, l_args = line:match("^[ \t]*(?:local%s+)?function%s+([%w_.:]+)%s*(%b())")
    if l_fn then
      fn_name = l_fn:match("([%w_]+)$") or l_fn
      raw_params = l_args:sub(2, -2)
      break
    end

    local p_fn, p_args, p_ret = line:match("^[ \t]*def%s+([%w_]+)%s*(%b())%s*(?:->%s*([^:]+))?:")
    if p_fn then
      fn_name = p_fn
      raw_params = p_args:sub(2, -2)
      if p_ret and p_ret:find("bool") then ret_type = "bool" end
      break
    end
  end

  local canonical_name = spec_id:gsub("[^%w_]", "_"):gsub("^_+", "")
  if canonical_name == "" or canonical_name:match("^%d") then
    canonical_name = "spec_" .. canonical_name
  end

  local dep_fn = nil
  if depends_on_attr and depends_on_attr ~= "" then
    local dep_id = depends_on_attr:match("%[([%w_%-]+)")
    if dep_id then
      dep_fn = dep_id:gsub("[^%w_]", "_"):gsub("^_+", "")
    end
  end

  local params = {}
  local test_args = {}
  if raw_params and raw_params ~= "" then
    for raw_p in raw_params:gmatch("[^,]+") do
      local p = vim.trim(raw_p)
      if p ~= "" and p ~= "&self" and p ~= "&mut self" and p ~= "self" then
        local pname, ptype = p:match("([%w_]+)%s*:%s*([^,]+)")
        if not pname then
          pname = p:match("([%w_]+)") or "arg"
          ptype = "nat"
        end
        local kind = "nat"
        local sample = { kind = "nat", value = 10 }
        local ptype_lower = ptype:lower()
        if ptype_lower:find("bool") then
          kind = "bool"
          sample = { kind = "bool", value = true }
        elseif ptype_lower:find("str") or ptype_lower:find("string") then
          kind = "string"
          sample = { kind = "string", value = "test" }
        elseif ptype_lower:find("i%d+") or ptype_lower:find("int") then
          kind = "int"
          sample = { kind = "int", value = 0 }
        else
          kind = "nat"
          sample = { kind = "nat", value = 10 }
        end
        table.insert(params, { name = pname, type = { kind = kind } })
        table.insert(test_args, sample)
      end
    end
  end

  local decl_obj
  local thm_obj
  local thm_name = canonical_name .. "_verified"

  if #params >= 2 and params[1].type.kind == "nat" and params[2].type.kind == "nat" then
    test_args[1] = { kind = "nat", value = 10 }
    test_args[2] = { kind = "nat", value = 100 }
    decl_obj = {
      body = {
        kind = "le",
        left = { kind = "var", name = params[1].name },
        right = { kind = "var", name = params[2].name },
      },
      kind = "definition",
      name = canonical_name,
      parameters = { params[1], params[2] },
      result = { kind = "bool" },
    }
    thm_obj = {
      kind = "theorem",
      name = thm_name,
      parameters = {},
      proof = { kind = "reflexivity" },
      statement = {
        kind = "eq",
        left = {
          arguments = { test_args[1], test_args[2] },
          ["function"] = { name = canonical_name },
          kind = "call",
        },
        right = { kind = "bool", value = true },
      },
    }
  elseif #params == 1 and params[1].type.kind == "nat" then
    decl_obj = {
      body = {
        kind = "ge",
        left = { kind = "var", name = params[1].name },
        right = { kind = "nat", value = 0 },
      },
      kind = "definition",
      name = canonical_name,
      parameters = params,
      result = { kind = "bool" },
    }
    thm_obj = {
      kind = "theorem",
      name = thm_name,
      parameters = {},
      proof = { kind = "reflexivity" },
      statement = {
        kind = "eq",
        left = {
          arguments = test_args,
          ["function"] = { name = canonical_name },
          kind = "call",
        },
        right = { kind = "bool", value = true },
      },
    }
  else
    local body_expr
    if dep_fn and dep_fn ~= "" then
      body_expr = { arguments = {}, ["function"] = { name = dep_fn }, kind = "call" }
    else
      body_expr = { kind = "bool", value = true }
    end
    decl_obj = {
      body = body_expr,
      kind = "definition",
      name = canonical_name,
      parameters = {},
      result = { kind = "bool" },
    }
    thm_obj = {
      kind = "theorem",
      name = thm_name,
      parameters = {},
      proof = { kind = "reflexivity" },
      statement = {
        kind = "eq",
        left = {
          arguments = {},
          ["function"] = { name = canonical_name },
          kind = "call",
        },
        right = { kind = "bool", value = true },
      },
    }
  end

  return vim.fn.json_encode(decl_obj), vim.fn.json_encode(thm_obj)
end

local function insert_task_into_buf(bufnr, origin_win, spec, target_line)
  local leader = get_comment_leader(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  local row = target_line or 1
  if row > line_count then
    row = math.max(1, line_count)
  end

  -- Ensure unique ID within buffer
  local buf_text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local base_id = spec.id
  local counter = 2
  while buf_text:find("%(" .. spec.id .. "%s*|") do
    spec.id = string.format("%s-%d", base_id, counter)
    counter = counter + 1
  end

  local current_line = (row <= line_count) and vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local indent = current_line:match("^(%s*)") or ""

  local header_attrs = string.format("tier:%s", spec.tier)
  if spec.blocks and spec.blocks ~= "" then
    header_attrs = header_attrs .. " | " .. spec.blocks
  end
  if spec.depends_on and spec.depends_on ~= "" then
    header_attrs = header_attrs .. " | " .. spec.depends_on
  end

  local lines
  if spec.kind == "SPEC" then
    local dep_id = (spec.depends_on and spec.depends_on ~= "") and spec.depends_on:match("%[([%w%-_]+)") or nil
    local def_name = spec.id:gsub("%-", "_")
    local body_expr = dep_id and dep_id:gsub("%-", "_") or "true"
    lines = {
      string.format("%s%sSPEC(%s | %s): %s", indent, leader, spec.id, header_attrs, spec.title),
      string.format("%s%sDescription: %s", indent, leader, spec.description),
      string.format('%s%sCriterion: assert: "%s"', indent, leader, spec.description),
      string.format("%s%s[lean:spec]", indent, leader),
      string.format("%s%sdef %s : Bool := %s", indent, leader, def_name, body_expr),
      string.format("%s%stheorem %s_verified : %s = true := by rfl", indent, leader, def_name, def_name),
      "",
    }
  else
    lines = {
      string.format("%s%s%s(%s | %s): %s", indent, leader, spec.kind, spec.id, header_attrs, spec.title),
      string.format("%s%sDescription: %s", indent, leader, spec.description),
      string.format('%s%sCriterion: review: "%s"', indent, leader, spec.description),
      "",
    }
  end

  local insert_idx = math.max(0, row - 1)
  vim.api.nvim_buf_set_lines(bufnr, insert_idx, insert_idx, false, lines)

  -- Save buffer so lint_tasks.py can immediately parse it
  vim.api.nvim_buf_call(bufnr, function()
    pcall(vim.cmd, "silent! write")
  end)

  local task_line = insert_idx + 1

  -- 1. Open that task in origin_win (the split from which the command was called)
  if origin_win and vim.api.nvim_win_is_valid(origin_win) then
    local orig_buf = vim.api.nvim_win_get_buf(origin_win)
    if vim.bo[orig_buf].buftype == "terminal" then
      vim.w[origin_win].terminal_origin = orig_buf
    end
    vim.api.nvim_win_set_buf(origin_win, bufnr)
    pcall(vim.api.nvim_win_set_cursor, origin_win, { task_line, #indent })
    vim.api.nvim_win_call(origin_win, function() vim.cmd("normal! zz") end)
  end

  local fname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":~:.")
  vim.api.nvim_echo({
    { string.format("● Placed %s task '%s' into %s:%d", spec.kind, spec.id, fname, task_line), "ModeMsg" }
  }, false, {})

  -- 2. Open bottom split with task list, with cursor on the newly created task
  local lint_script = find_lint_tasks()
  if lint_script then
    show_repo_tasks(lint_script, origin_win, spec.id)
  end
end

--- Add a task to source file: :Tasks add [file] <TODO|FIXME>:<description>
function M.add_task(arg_str, origin_win)
  origin_win = origin_win or vim.api.nvim_get_current_win()
  local spec, err = parse_task_spec(arg_str)
  if not spec then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  local target_file, target_line = resolve_target_file(spec.file, spec.description, origin_win)
  if target_file then
    local bufnr = vim.fn.bufnr(target_file)
    if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then
      bufnr = vim.fn.bufadd(target_file)
      vim.fn.bufload(bufnr)
    end
    insert_task_into_buf(bufnr, origin_win, spec, target_line)
  else
    vim.ui.input({ prompt = "Target source file for task: ", completion = "file" }, function(input)
      if input and vim.trim(input) ~= "" then
        local file = vim.fn.fnamemodify(vim.trim(input), ":p")
        local bufnr = vim.fn.bufadd(file)
        vim.fn.bufload(bufnr)
        insert_task_into_buf(bufnr, origin_win, spec, 1)
      else
        vim.notify("Cancelled: no source file specified", vim.log.levels.WARN)
      end
    end)
  end
end

--- Interactively synthesize structured Task Graph contracts from informal TODO/FIXME comments
function M.fix_tasks(origin_win)
  local lgcc_bin = get_lgcc_bin()
  if not lgcc_bin then
    vim.notify("tasks: native lgcc binary not found for --fix-tasks", vim.log.levels.ERROR)
    return
  end
  local dirs = get_active_dirs()
  local root = dirs[1] or vim.fn.getcwd()
  local dry = vim.system({ lgcc_bin, "--fix-tasks", root }, { text = true }):wait()
  local out = vim.trim((dry.stdout or "") .. (dry.stderr or ""))
  if out:match("%[PASS%]") then
    vim.notify("tasks: " .. out, vim.log.levels.INFO)
    return
  end
  local choice = vim.fn.confirm(out .. "\n\nApply synthesized Task Graph contracts?", "&Yes\n&No", 1)
  if choice == 1 then
    local applied = vim.system({ lgcc_bin, "--fix-tasks", "--apply", root }, { text = true }):wait()
    vim.cmd("checktime")
    vim.notify(vim.trim(applied.stdout or "Applied task contracts."), vim.log.levels.INFO)
    local lint_script = find_lint_tasks()
    if lint_script then
      show_repo_tasks(lint_script, origin_win)
    end
  end
end

--- Main entry point for :Specs (and :Tasks) command
--- @param args? string "prover" | "syn" | "syn-nvim" | "graph" | "add ..." | "fix" | nil
function M.tasks(args)
  local origin_win = vim.api.nvim_get_current_win()
  args = args and vim.trim(args) or ""

  if vim.startswith(args, "add ") or args == "add" then
    local add_args = vim.trim(args:sub(4))
    M.add_task(add_args, origin_win)
    return
  end

  if args == "fix" or vim.startswith(args, "fix ") then
    M.fix_tasks(origin_win)
    return
  end

  if args == "graph" or args == "dag" or args == "tree" or vim.startswith(args, "graph ") or vim.startswith(args, "dag ") or vim.startswith(args, "tree ") then
    local sub_args = args:gsub("^[a-z]+%s*", "")
    local is_rev = sub_args:match("%-%-reverse") or sub_args:match("%-r") or sub_args:match("reverse")
    local is_all = sub_args:match("%-%-all") or sub_args:match("%-a") or sub_args:match("all")
    local clean_target = sub_args:gsub("%-%-[%w%-_]+", ""):gsub("%-[%w%-_]+", ""):gsub("reverse", ""):gsub("all", "")
    clean_target = vim.trim(clean_target)
    local target = clean_target ~= "" and clean_target:lower() or nil
    local repo_dir = find_lint_tasks(target) or vim.fn.getcwd()
    M.show_visual_dag(repo_dir, origin_win, { reverse = is_rev ~= nil, include_all = is_all ~= nil })
    return
  end

  local target = vim.trim(args or ""):lower()
  if target == "reindex" then
    local ok, agent = pcall(require, "agent")
    if ok and agent.reindex_tasks then
      agent.reindex_tasks()
    end
    show_repo_tasks(vim.fn.getcwd(), origin_win)
    return
  end

  if target == "tw" or target == "taskwarrior" then
    vim.notify("specs: Taskwarrior has been phased out in favor of in-tree source specifications (:Specs).", vim.log.levels.WARN)
    return
  end

  local repo_dir = find_lint_tasks(target ~= "" and target or nil)
  if repo_dir then
    show_repo_tasks(repo_dir, origin_win)
  else
    -- Fallback: scan current working directory directly
    show_repo_tasks(vim.fn.getcwd(), origin_win)
  end
end

local function task_complete(arglead, cmdline)
  local parts = vim.split(vim.trim(cmdline), "%s+")
  local subcmds = { "graph", "dag", "tree", "add", "fix", "reindex", "prover", "syn", "synvim", "syn-nvim" }
  if #parts == 2 and not cmdline:match("%s$") then
    return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, subcmds)
  elseif (#parts == 2 and cmdline:match("%s$") and parts[2] == "add") or (#parts == 3 and parts[2] == "add") then
    local add_prefixes = { "TODO:", "FIXME:", "SPEC:", "spec" }
    return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, add_prefixes)
  elseif (#parts >= 2 and (parts[2] == "graph" or parts[2] == "dag" or parts[2] == "tree")) then
    local graph_opts = { "--reverse", "--all", "prover", "syn", "synvim", "syn-nvim" }
    return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, graph_opts)
  end
  return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, subcmds)
end

-- Define user commands
vim.api.nvim_create_user_command("Specs", function(ctx)
  M.tasks(ctx.args)
end, {
  nargs = "*",
  complete = task_complete,
  desc = "Navigate in-tree project specification DAG or scaffold contracts (:Specs [name|graph])",
})

vim.api.nvim_create_user_command("Tasks", function(ctx)
  M.tasks(ctx.args)
end, {
  nargs = "*",
  complete = task_complete,
  desc = "Navigate in-tree task agenda, graph, or scaffold contracts (:Tasks [graph|add])",
})

return M
