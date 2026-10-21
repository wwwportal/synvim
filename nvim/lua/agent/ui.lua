local M = {}
local state_mod = require("agent.state")

--- Resolve suggested target path cleanly without doubling base_dir
function M.resolve_suggested_path(base_dir, sugg)
  if not sugg or sugg == "" then return base_dir or "" end
  sugg = sugg:gsub("^%./", "")
  base_dir = (base_dir or ""):gsub("^%./", ""):gsub("/+$", "")

  if sugg:match("^/") then return sugg end
  if base_dir == "" or base_dir == "." then return sugg end

  if sugg == base_dir or sugg:find("^" .. vim.pesc(base_dir) .. "/") then
    return sugg
  end

  return base_dir .. "/" .. sugg
end

--- Resolve current working directory of a terminal buffer via /proc/<pid>/cwd or term:// URI
function M.get_terminal_cwd(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return nil end
  if vim.bo[buf].buftype ~= "terminal" then return nil end

  local chan = vim.bo[buf].channel
  if not chan or chan <= 0 then
    chan = vim.b[buf].terminal_job_id
  end
  if chan and chan > 0 then
    local ok, pid = pcall(vim.fn.jobpid, chan)
    if ok and pid and pid > 0 then
      local cwd = vim.uv.fs_realpath("/proc/" .. pid .. "/cwd")
      if cwd and cwd ~= "" and vim.fn.isdirectory(cwd) == 1 then
        return cwd
      end
    end
  end

  local name = vim.api.nvim_buf_get_name(buf)
  local term_path = name:match("^term://(.-)//")
  if term_path and term_path ~= "" then
    local expanded = vim.fn.expand(term_path)
    if vim.fn.isdirectory(expanded) == 1 then
      return vim.uv.fs_realpath(expanded) or expanded
    end
  end
  return nil
end

--- Get root directory of current project, prioritizing active or latest-navigated terminal split
function M.get_root_dir()
  local state = state_mod.state
  local cur_win = vim.api.nvim_get_current_win()
  local cur_buf = vim.api.nvim_win_get_buf(cur_win)
  local candidate = nil

  -- 1. If currently in a terminal split, its live CWD is primary
  if vim.bo[cur_buf].buftype == "terminal" then
    candidate = M.get_terminal_cwd(cur_buf)
  end

  -- 2. If currently in an editor buffer with a valid saved file on disk
  if not candidate and vim.bo[cur_buf].buftype == "" then
    local name = vim.api.nvim_buf_get_name(cur_buf)
    if name ~= "" and not name:match("^%a+://") and vim.fn.filereadable(name) == 1 then
      local root = vim.fs.root(name, { ".git", "Cargo.toml", "Makefile", "pyproject.toml", "package.json" })
      if root and root ~= vim.fn.expand("~") and root ~= "/" then
        candidate = root
      else
        candidate = vim.fn.fnamemodify(name, ":p:h")
      end
    end
  end

  -- 3. If latest focused split was a terminal, check live CWD of that terminal buffer
  if not candidate and state.last_terminal_buf and vim.api.nvim_buf_is_valid(state.last_terminal_buf) then
    candidate = M.get_terminal_cwd(state.last_terminal_buf)
  end

  -- 4. Check active terminal buffers in open windows
  if not candidate then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(win)
      if vim.bo[b].buftype == "terminal" then
        local tc = M.get_terminal_cwd(b)
        if tc and tc ~= vim.fn.expand("~") and tc ~= "/" then
          candidate = tc
          break
        end
      end
    end
  end

  -- 5. Fallback to tracked last_terminal_cwd or latest_focus_cwd
  if not candidate and state.last_terminal_cwd and vim.fn.isdirectory(state.last_terminal_cwd) == 1 then
    candidate = state.last_terminal_cwd
  end
  if not candidate and state.latest_focus_cwd and vim.fn.isdirectory(state.latest_focus_cwd) == 1 then
    candidate = state.latest_focus_cwd
  end

  -- 6. Fallback to git root of Neovim cwd if not in home
  if not candidate then
    local git_root = vim.fn.system("git rev-parse --show-toplevel 2>/dev/null"):gsub("[\r\n]+", "")
    if vim.v.shell_error == 0 and git_root ~= "" and git_root ~= vim.fn.expand("~") and git_root ~= "/" then
      candidate = git_root
    end
  end

  if not candidate or candidate == "" then
    candidate = vim.fn.getcwd()
  end

  -- If candidate is home directory or root, scan open buffers to find active project directory
  if candidate == vim.fn.expand("~") or candidate == "/" then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local bname = vim.api.nvim_buf_get_name(buf)
      if bname ~= "" and not bname:match("^%a+://") and vim.fn.filereadable(bname) == 1 then
        local r = vim.fs.root(bname, { ".git", "Cargo.toml", "Makefile", "pyproject.toml", "package.json" })
        if r and r ~= vim.fn.expand("~") and r ~= "/" then
          candidate = r
          break
        end
      end
    end
  end

  -- Resolve to project/repo root if inside a subdirectory
  local repo_root = vim.fs.root(candidate, { ".git", "Cargo.toml", "Makefile", "pyproject.toml", "package.json" })
  if repo_root and repo_root ~= vim.fn.expand("~") and repo_root ~= "/" then
    return repo_root
  end

  return candidate
end

--- Get primary editor split window (never creating splits)
function M.get_primary_editor_win()
  local cur = vim.api.nvim_get_current_win()
  local cur_cfg = vim.api.nvim_win_get_config(cur)
  local cur_buf = vim.api.nvim_win_get_buf(cur)
  if cur_cfg.relative == "" and vim.bo[cur_buf].buftype ~= "quickfix" then
    return cur
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local c = vim.api.nvim_win_get_config(win)
    if c.relative == "" then
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].buftype == "" then
        return win
      end
    end
  end
  return cur
end

--- Find existing tab displaying filepath, or open in a clean tab without disturbing splits
function M.find_or_open_tab(filepath)
  local fullpath = vim.fn.fnamemodify(filepath, ":p")

  -- 1. Check if fullpath is already open in any window across any tab
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local b = vim.api.nvim_win_get_buf(win)
      local bname = vim.api.nvim_buf_get_name(b)
      if bname ~= "" and vim.fn.fnamemodify(bname, ":p") == fullpath then
        vim.api.nvim_set_current_tabpage(tab)
        vim.api.nvim_set_current_win(win)
        return win
      end
    end
  end

  -- 2. If current window in current tab is an empty unnamed buffer, reuse it
  local cur_win = vim.api.nvim_get_current_win()
  local cur_buf = vim.api.nvim_win_get_buf(cur_win)
  if vim.bo[cur_buf].buftype == "" and vim.api.nvim_buf_get_name(cur_buf) == "" and not vim.bo[cur_buf].modified then
    vim.cmd("edit " .. vim.fn.fnameescape(fullpath))
    return cur_win
  end

  -- 3. If current window is terminal or quickfix, open in a full-screen tab so terminal context is preserved
  if vim.bo[cur_buf].buftype == "terminal" or vim.bo[cur_buf].buftype == "quickfix" then
    vim.cmd("tabedit " .. vim.fn.fnameescape(fullpath))
    return vim.api.nvim_get_current_win()
  end

  -- 4. Otherwise switch buffer in current editor window
  local ok = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(fullpath))
  if not ok then
    pcall(vim.cmd, "tabedit " .. vim.fn.fnameescape(fullpath))
  end
  return vim.api.nvim_get_current_win()
end

--- Format directory entries in multi-column terminal ls layout
function M.format_ls_columns(entries, suggested, max_width)
  if #entries == 0 then return { "  (empty directory)" } end
  local formatted_entries = {}
  local max_len = 0
  for _, entry in ipairs(entries) do
    local is_sugg = (entry == suggested)
    local label = is_sugg and string.format("[%s]*", entry) or entry
    table.insert(formatted_entries, { label = label, is_sugg = is_sugg })
    if #label > max_len then max_len = #label end
  end

  local col_width = math.max(16, max_len + 3)
  local num_cols = math.max(1, math.floor(max_width / col_width))
  local num_rows = math.ceil(#formatted_entries / num_cols)

  local rows = {}
  for r = 1, num_rows do
    local row_str = " "
    for c = 1, num_cols do
      local idx = (c - 1) * num_rows + r
      if idx <= #formatted_entries then
        local item = formatted_entries[idx]
        local pad = string.rep(" ", col_width - #item.label)
        row_str = row_str .. item.label .. pad
      end
    end
    table.insert(rows, row_str)
  end
  return rows
end

--- Close ephemeral dir preview modal if open
function M.close_dir_preview()
  local state = state_mod.state
  if state.dir_preview_win and vim.api.nvim_win_is_valid(state.dir_preview_win) then
    pcall(vim.api.nvim_win_close, state.dir_preview_win, true)
  end
  state.dir_preview_win = nil
  state.dir_preview_buf = nil
  state.on_path_accept = nil
end

--- Deprecated dir preview modal (seamlessly routed into bottom task pane)
function M.show_dir_preview(base_dir, entries, suggested, on_accept)
  local state = state_mod.state
  local sugg_entry = suggested or (entries and entries[1]) or "new_file"
  local target_path = M.resolve_suggested_path(base_dir, sugg_entry)
  local origin_win = state.origin_win or M.get_primary_editor_win()
  if on_accept then
    on_accept(origin_win, target_path)
  elseif state.pending_target then
    local target = state.pending_target
    state.pending_target = nil
    target.path = target_path
    state.last_target = target
    local tasks_mod = require("agent.tasks")
    if tasks_mod.jump_to_target then
      tasks_mod.jump_to_target(target, origin_win)
    end
  end
end

--- Display a centered, minimalist floating window showing all synvim commands and keybindings
function M.show_help()
  local lines = {
    "synvim - commands & usage",
    "─────────────────────────────────────────────────────────────────────────────",
    "",
    "Unified Tasks Workflow",
    "  :Tasks                 Toggle repository task agenda (:Tasks or <leader>q)",
    "  :Tasks list            List in-tree tasks in Quickfix",
    "  :Tasks add <desc>      Insert formatted task contract at cursor",
    "  :Tasks start [id]      Implement task (closest visible, or by ID/index)",
    "  :Tasks revise [id]     Mark task as REVISE; critique directly via in-line comments",
    "  :Tasks review          List pending reviews and changes with IDs",
    "  :Tasks accept <id>     Accept and approve specific review by ID",
    "  :Tasks reject <id>     Reject and revert specific review by ID",
    "  :Tasks stop            Stop active agent synthesis job and clear diffs",
    "",
    "Search & Inspection",
    "  :Find <concept>        Semantic LLM search; jumps directly to relevant code",
    "  :Ask <question>        Navigate to code and insert an in-line explanation diff",
    "",
    "In-Line Diff Shortcuts (when diff is active)",
    "  <M-a>                  Accept active review diff (:Tasks accept)",
    "  <M-r>                  Reject active review diff (:Tasks reject)",
    "  <M-w>                  Mark task for revision (:Tasks revise)",
    "",
    "Voice Dictation",
    "  :Listen                Voice-to-text dictation into active buffer (<leader>v)",
    "",
    "Window & Split Keybindings",
    "  Alt + Arrows           Navigate focus across splits in any mode",
    "  Alt + h/j/k/l          Swap active split with adjacent neighbor",
    "  Alt + z                Toggle maximize / zoom active split",
    "  Alt + q / Alt + w      Close active split (:SmartQuit)",
    "  Alt + + / Alt + _      Split right / split down with a new terminal",
    "  Alt + 1..9 / Alt + t   Jump to tab 1..9 / open new tab",
    "  Alt + ] / Alt + [      Next / previous tab",
    "  Ctrl + d / Ctrl + u    Scroll fixed 10 lines",
    "  Esc                    Return to Normal mode when at a shell prompt",
    "",
    "─────────────────────────────────────────────────────────────────────────────",
    "Press 'q' or <Esc> to close this window",
  }

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "synvim-help"

  local width = 80
  local height = #lines
  local ui = vim.api.nvim_list_uis()[1]
  local total_w = ui and ui.width or vim.o.columns
  local total_h = ui and ui.height or vim.o.lines
  local row = math.max(1, math.floor((total_h - height) / 2))
  local col = math.max(1, math.floor((total_w - width) / 2))

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
  })

  local close_fn = function()
    pcall(vim.api.nvim_win_close, win, true)
  end

  vim.keymap.set("n", "q", close_fn, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "<Esc>", close_fn, { buffer = buf, silent = true, nowait = true })
end

return M
