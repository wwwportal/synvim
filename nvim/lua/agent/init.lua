local M = {}

local state_mod = require("agent.state")
local ui = require("agent.ui")
local diff = require("agent.diff")
local reviews = require("agent.reviews")
local llm = require("agent.llm")
local search = require("agent.search")
local tasks = require("agent.tasks")
local cmdline = require("agent.cmdline")
local history = require("agent.history")
local dtl = require("agent.dtl")

M.dtl = dtl

M.state = state_mod.state
M.ns_diff = state_mod.ns_diff
M.ns_flash = state_mod.ns_flash

-- UI & Navigation
M.get_terminal_cwd = ui.get_terminal_cwd
M.get_root_dir = ui.get_root_dir
M.get_primary_editor_win = ui.get_primary_editor_win
M.find_or_open_file = ui.find_or_open_file
M.find_or_open_tab = ui.find_or_open_tab
M.format_ls_columns = ui.format_ls_columns
M.resolve_suggested_path = ui.resolve_suggested_path
M.show_help = ui.show_help
M.help = ui.show_help
M.close_dir_preview = ui.close_dir_preview
M.show_dir_preview = ui.show_dir_preview
M.open_docked_input = ui.open_docked_input
M.open_multiline_input = ui.open_docked_input

-- In-line Diffs
M.setup_highlights = diff.setup_highlights
M.wrap_diff_line = diff.wrap_diff_line
M.tokenize_line = diff.tokenize_line
M.compute_char_diff = diff.compute_char_diff
M.show_inline_diff = diff.show_inline_diff
M.clear_diff = diff.clear_diff
M.accept_diff = diff.accept_diff
M.attach_pending_diff = diff.attach_pending_diff
M.promote_contract_to_approved = diff.promote_contract_to_approved
M.ensure_contract_preserved_as_done = diff.ensure_contract_preserved_as_done

-- Reviews & Staging
M.get_reviews_dir = reviews.get_reviews_dir
M.review_matches_file = reviews.review_matches_file
M.get_reviews = reviews.get_reviews
M.create_review = reviews.create_review
M.revert_review = reviews.revert_review
M.accept_review = reviews.accept_review
M.list_reviews_qf = reviews.list_reviews_qf
M.show_review = reviews.show_review
M.review = reviews.review
M.git_review = reviews.review
M.review_command = reviews.review
M.accept = reviews.accept
M.reject = reviews.reject
M.YES = reviews.accept
M.NO = reviews.reject
M.MAYBE = tasks.revise_task

-- History & Navigation Graph
M.history = history

-- LLM Execution & Parsing
M.collect_context = llm.collect_context
M.parse_solution_from_raw = llm.parse_solution_from_raw
M.extract_json_object = llm.extract_json_object
M.process_response = llm.process_agent_response
M.run = llm.run
M.stop = llm.stop
M.record_voice = llm.record_voice

-- Search & Query
M.extract_search_keywords = search.extract_search_keywords
M.search_and_rank = search.search_and_rank
M.find = search.find
M.ask = search.ask

-- Tasks & Agenda
M.is_todo_comment = tasks.is_todo_comment
M.extract_task_info = tasks.extract_task_info
M.scan_repository_tasks = tasks.scan_repository_tasks
M.reindex_tasks = tasks.reindex_tasks
M.reindex = tasks.reindex_tasks
M.resolve_task_identifier = tasks.resolve_task_identifier
M.rank_tasks_by_query = tasks.rank_tasks_by_query
M.format_task_summary = tasks.format_task_summary
M.setup_agent_qf_keymaps = tasks.setup_agent_qf_keymaps
M.update_queue_display = tasks.update_queue_display
M.next = tasks.next
M.prev = tasks.prev
M.show_tasks = tasks.show_tasks
M.tasks = tasks.show_tasks
M.toggle_tasks = tasks.toggle_tasks
M.toggle_queue = tasks.toggle_tasks
M.jump_to_target = tasks.jump_to_target
M.scaffold_and_run_task = tasks.scaffold_and_run_task
M.run_todo = tasks.run_todo
M.run_file = tasks.run_file
M.insert_single_task_stub = tasks.insert_single_task_stub
M.decompose_and_add_tasks = tasks.decompose_and_add_tasks
M.add_task = tasks.add_task
M.start_task = tasks.start_task
M.revise_task = tasks.revise_task
M.write_revision = tasks.write_revision
M.tasks_complete = tasks.tasks_complete
M.tasks_command = tasks.tasks_command

function M.setup()
  diff.setup_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    callback = diff.setup_highlights,
  })

  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "TermEnter", "TermOpen" }, {
    callback = function(args)
      local buf = args.buf
      if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
      local bt = vim.bo[buf].buftype
      if bt == "terminal" then
        local cwd = ui.get_terminal_cwd(buf)
        if cwd then
          M.state.last_terminal_cwd = cwd
          M.state.last_terminal_buf = buf
          M.state.last_terminal_win = vim.api.nvim_get_current_win()
          M.state.latest_focus_cwd = cwd
          M.state.latest_focus_type = "terminal"
        end
      elseif bt == "" then
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= "" and not name:match("^%a+://") and vim.fn.filereadable(name) == 1 then
          local dir = vim.fs.root(name, { ".git", "Cargo.toml", "Makefile", "pyproject.toml" }) or vim.fn.fnamemodify(name, ":p:h")
          if dir and dir ~= vim.fn.expand("~") and dir ~= "/" then
            M.state.latest_focus_cwd = dir
            M.state.latest_focus_type = "editor"
          end
          -- Keep pending diffs visible across buffer switches.
          if not M.state._attaching then
            M.state._attaching = true
            pcall(function()
              diff.attach_pending_diff(buf)
            end)
            M.state._attaching = false
          end
        end
      end
    end,
    desc = "Track active directory across terminal and editor splits",
  })

  vim.api.nvim_create_autocmd("FileType", {
    pattern = "qf",
    callback = function(args)
      local origin = M.state.origin_win or ui.get_primary_editor_win()
      tasks.setup_agent_qf_keymaps(origin, args.buf)
    end,
    desc = "Route quickfix jumps directly into calling split without splitting",
  })

  -- Unified :Tasks command
  vim.api.nvim_create_user_command("Tasks", function(ctx)
    tasks.tasks_command(ctx.args)
  end, {
    nargs = "*",
    complete = tasks.tasks_complete,
    desc = "Unified tasks manager (:Tasks [list|add|start|stop|review|YES|MAYBE|NO])",
  })

  -- Visited Files Navigation Graph (:History)
  vim.api.nvim_create_user_command("History", function(ctx)
    local arg = vim.trim(ctx.args or ""):lower()
    if arg == "clear" then
      history.clear()
    elseif arg == "qf" or arg == "list" then
      history.show_quickfix()
    else
      history.show_history()
    end
  end, {
    nargs = "?",
    complete = function(arglead, cmdline)
      return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, { "graph", "qf", "list", "clear" })
    end,
    desc = "Visited files navigation graph & last cursor line (:History [graph|qf|clear])",
  })

  vim.api.nvim_create_user_command("Find", function(ctx)
    M.state.origin_win = vim.api.nvim_get_current_win()
    search.find(ctx.args)
  end, { nargs = "*", desc = "Semantic code search across repository with LLM (:Find <concept>)" })

  vim.api.nvim_create_user_command("Ask", function(ctx)
    M.state.origin_win = vim.api.nvim_get_current_win()
    local query = vim.trim(ctx.args or "")
    if ctx.range == 2 and ctx.line1 and ctx.line2 then
      local lines = vim.api.nvim_buf_get_lines(0, ctx.line1 - 1, ctx.line2, false)
      local selected = vim.trim(table.concat(lines, "\n"))
      if query ~= "" then
        query = query .. "\n" .. selected
      else
        query = selected
      end
    end
    if query == "" then
      ui.open_docked_input("Ask: Multi-line Question Entry", "", function(text)
        search.ask(text)
      end)
      return
    end
    search.ask(query)
  end, { range = true, nargs = "*", desc = "Ask code question (supports docked multi-line split, multi-question, and visual selection) (:Ask [question])" })

  -- If :Git command does not exist, provide basic :Git with review support
  if vim.fn.exists(":Git") ~= 2 then
    vim.api.nvim_create_user_command("Git", function(ctx)
      local parts = vim.split(vim.trim(ctx.args or ""), "%s+", { trimempty = true })
      if parts[1] == "review" then
        reviews.list_reviews_qf()
      else
        local cmd = "git " .. ctx.args
        vim.cmd("!" .. cmd)
      end
    end, {
      nargs = "*",
      complete = function(arglead, cmdline)
        local parts = vim.split(vim.trim(cmdline), "%s+")
        if #parts <= 2 and not cmdline:match("%s+$") then
          local git_subs = { "review", "status", "diff", "log", "commit", "push", "pull", "checkout", "branch" }
          return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, git_subs)
        end
        return {}
      end,
      desc = "Git command runner (:Git <command>)",
    })
  end

  vim.api.nvim_create_user_command("Synvim", function(ctx)
    ui.show_help()
  end, {
    nargs = "?",
    complete = function(arglead, cmdline)
      return vim.tbl_filter(function(s) return vim.startswith(s:lower(), arglead:lower()) end, { "help" })
    end,
    desc = "Show synvim commands and usage (:Synvim help)",
  })

  -- Enable native lowercase command abbreviations
  pcall(vim.cmd, [[
    cnoreabbrev <expr> tasks (getcmdtype() ==# ':' && getcmdline() ==# 'tasks') ? 'Tasks' : 'tasks'
    cnoreabbrev <expr> ask (getcmdtype() ==# ':' && getcmdline() ==# 'ask') ? 'Ask' : 'ask'
    cnoreabbrev <expr> find (getcmdtype() ==# ':' && getcmdline() ==# 'find') ? 'Find' : 'find'
    cnoreabbrev <expr> synvim (getcmdtype() ==# ':' && getcmdline() ==# 'synvim') ? 'Synvim' : 'synvim'
    cnoreabbrev <expr> history (getcmdtype() ==# ':' && getcmdline() ==# 'history') ? 'History' : 'history'
  ]])

  history.setup()
  cmdline.setup()
end

return M
