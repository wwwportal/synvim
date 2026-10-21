local M = {}

local ns_diff = vim.api.nvim_create_namespace("agent_inline_diff")

M.state = {
  queue = {},
  queue_index = 0,
  last_prompt = "",
  last_target = nil,
  last_rejection = nil,
  dir_preview_win = nil,
  dir_preview_buf = nil,
  pending_target = nil,
  pending_diff = nil,
  active_job = nil,
  status_tail = "",
  is_busy = false,
  origin_win = nil,
  last_terminal_cwd = nil,
  last_terminal_buf = nil,
  last_terminal_win = nil,
  latest_focus_cwd = nil,
  latest_focus_type = nil,
}

local process_agent_response = nil
local update_queue_display = nil
local jump_to_target = nil
local setup_agent_qf_keymaps = nil
local scan_repository_tasks = nil
local extract_task_info = nil

local function setup_highlights()
  local is_dark = (vim.o.background == "dark")
  if is_dark then
    vim.api.nvim_set_hl(0, "AgentDiffAdd", { fg = "#a6f3a6", bg = "#144620", ctermfg = 10, ctermbg = 22, default = false })
    vim.api.nvim_set_hl(0, "AgentDiffAddSign", { fg = "#22c55e", bold = true, ctermfg = 10, default = false })
    vim.api.nvim_set_hl(0, "AgentDiffDelete", { fg = "#ff8585", bg = "#4a0e0e", strikethrough = true, ctermfg = 9, ctermbg = 52, default = false })
  else
    vim.api.nvim_set_hl(0, "AgentDiffAdd", { fg = "#14532d", bg = "#bbf7d0", ctermfg = 28, ctermbg = 194, default = false })
    vim.api.nvim_set_hl(0, "AgentDiffAddSign", { fg = "#16a34a", bold = true, ctermfg = 28, default = false })
    vim.api.nvim_set_hl(0, "AgentDiffDelete", { fg = "#991b1b", bg = "#fecaca", strikethrough = true, ctermfg = 160, ctermbg = 224, default = false })
  end
  pcall(vim.api.nvim_set_hl, 0, "GitReviewAdd", { link = "AgentDiffAdd", default = false })
  pcall(vim.api.nvim_set_hl, 0, "GitReviewDelete", { link = "AgentDiffDelete", default = false })
end

--- Resolve suggested target path cleanly without doubling base_dir
local function resolve_suggested_path(base_dir, sugg)
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
local function get_terminal_cwd(buf)
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
local function get_root_dir()
  local cur_win = vim.api.nvim_get_current_win()
  local cur_buf = vim.api.nvim_win_get_buf(cur_win)
  local candidate = nil

  -- 1. If currently in a terminal split, its live CWD is primary
  if vim.bo[cur_buf].buftype == "terminal" then
    candidate = get_terminal_cwd(cur_buf)
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
  if not candidate and M.state.last_terminal_buf and vim.api.nvim_buf_is_valid(M.state.last_terminal_buf) then
    candidate = get_terminal_cwd(M.state.last_terminal_buf)
  end

  -- 4. Check active terminal buffers in open windows
  if not candidate then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(win)
      if vim.bo[b].buftype == "terminal" then
        local tc = get_terminal_cwd(b)
        if tc and tc ~= vim.fn.expand("~") and tc ~= "/" then
          candidate = tc
          break
        end
      end
    end
  end

  -- 5. Fallback to tracked last_terminal_cwd or latest_focus_cwd
  if not candidate and M.state.last_terminal_cwd and vim.fn.isdirectory(M.state.last_terminal_cwd) == 1 then
    candidate = M.state.last_terminal_cwd
  end
  if not candidate and M.state.latest_focus_cwd and vim.fn.isdirectory(M.state.latest_focus_cwd) == 1 then
    candidate = M.state.latest_focus_cwd
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
local function get_primary_editor_win()
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


--- Collect repository context summary (git files, active buffer context, and query keyword search)
local function collect_context(prompt)
  local root = get_root_dir()
  local files_out = vim.fn.system({ "git", "-C", root, "ls-files" })
  local file_list = {}
  if vim.v.shell_error == 0 and files_out ~= "" then
    for line in files_out:gmatch("[^\r\n]+") do
      if not line:match("%.olean$") and not line:match("%.tex$") and not line:match("%.jsonl$") and not line:match("%.log$") then
        if #file_list < 80 then
          table.insert(file_list, line)
        end
      end
    end
  end

  -- Fallback to find if not a git repo or git ls-files is empty
  if #file_list == 0 then
    local find_out = vim.fn.system({ "find", root, "-maxdepth", "3", "-not", "-path", "*/.*", "-not", "-path", "*/target/*", "-not", "-path", "*/node_modules/*", "-type", "f" })
    if vim.v.shell_error == 0 and find_out ~= "" then
      for line in find_out:gmatch("[^\r\n]+") do
        local rel = line:gsub("^" .. vim.pesc(root) .. "/?", "")
        if rel ~= "" and not rel:match("%.olean$") and not rel:match("%.tex$") and not rel:match("%.jsonl$") and #file_list < 80 then
          table.insert(file_list, rel)
        end
      end
    end
  end

  -- Search matches in repository for query keywords
  local search_matches = {}
  if prompt and prompt ~= "" then
    local stop_words = {
      ["where"]=true, ["did"]=true, ["we"]=true, ["implement"]=true, ["the"]=true,
      ["a"]=true, ["an"]=true, ["in"]=true, ["is"]=true, ["of"]=true, ["to"]=true,
      ["and"]=true, ["or"]=true, ["for"]=true, ["with"]=true, ["find"]=true,
      ["show"]=true, ["me"]=true, ["how"]=true, ["what"]=true, ["which"]=true,
      ["can"]=true, ["you"]=true, ["go"]=true, ["at"]=true, ["on"]=true,
      ["file"]=true, ["line"]=true, ["code"]=true, ["function"]=true, ["class"]=true,
      ["this"]=true, ["that"]=true, ["there"]=true, ["are"]=true, ["was"]=true,
      ["were"]=true, ["our"]=true, ["us"]=true, ["it"]=true, ["its"]=true,
      ["my"]=true, ["i"]=true, ["do"]=true, ["does"]=true, ["done"]=true,
      ["have"]=true, ["has"]=true, ["had"]=true, ["be"]=true, ["been"]=true,
      ["get"]=true, ["got"]=true, ["put"]=true, ["set"]=true,
    }
    local keywords = {}
    for word in prompt:lower():gmatch("[%a%d_-]+") do
      if #word >= 3 and not stop_words[word] then
        table.insert(keywords, word)
      end
    end

    for _, kw in ipairs(keywords) do
      local grep_out = vim.fn.system({ "git", "-C", root, "grep", "-n", "-I", "-i", kw, "--", ":!*.jsonl", ":!*.log", ":!*.json", ":!*.ipynb", ":!*.olean", ":!*.tex", ":!specs/.lexlean/*", ":!logs/*" })
      if vim.v.shell_error ~= 0 or grep_out == "" then
        local rg_bin = vim.fn.exepath("rg")
        if rg_bin ~= "" then
          grep_out = vim.fn.system({ rg_bin, "-n", "--no-heading", "-i", "-g", "!*.jsonl", "-g", "!*.log", "-g", "!*.json", "-g", "!*.ipynb", "-g", "!*.olean", "-g", "!*.tex", "-g", "!specs/.lexlean/*", "-g", "!logs/*", kw, root })
        else
          grep_out = vim.fn.system({ "grep", "-rn", "-I", "-i", "--exclude-dir=.git", "--exclude-dir=target", "--exclude-dir=logs", "--exclude-dir=.lexlean", "--exclude=*.jsonl", "--exclude=*.log", "--exclude=*.json", "--exclude=*.ipynb", "--exclude=*.olean", "--exclude=*.tex", kw, root })
        end
      end
      if grep_out and grep_out ~= "" then
        for gline in grep_out:gmatch("[^\r\n]+") do
          local rel = gline:gsub("^" .. vim.pesc(root) .. "/", "")
          local filepart = rel:match("^([^:]+)") or rel
          if not filepart:match("%.json")
            and not filepart:match("%.log")
            and not filepart:match("%.ipynb")
            and not filepart:match("%.olean")
            and not filepart:match("%.tex")
            and not filepart:match("/%.")
            and not filepart:match("^%.")
            and not filepart:match("^logs/")
            and #rel < 300 then
            if #search_matches < 35 then
              table.insert(search_matches, rel:sub(1, 200))
            else
              break
            end
          end
        end
      end
      if #search_matches >= 35 then break end
    end
  end

  local cur_win = get_primary_editor_win()
  local cur_buf = vim.api.nvim_win_get_buf(cur_win)
  local cur_file = vim.api.nvim_buf_get_name(cur_buf)
  local rel_cur_file = ""
  if cur_file ~= "" and not cur_file:match("^%a+://") then
    rel_cur_file = vim.fn.fnamemodify(cur_file, ":.")
  end

  local cursor = vim.api.nvim_win_get_cursor(cur_win)
  local cur_line = cursor[1]
  local cur_col = cursor[2] + 1

  -- Snippet around cursor
  local snippet = ""
  if vim.api.nvim_buf_is_valid(cur_buf) and vim.bo[cur_buf].buftype == "" then
    local total_lines = vim.api.nvim_buf_line_count(cur_buf)
    local s_line = math.max(0, cur_line - 25)
    local e_line = math.min(total_lines, cur_line + 25)
    local lines = vim.api.nvim_buf_get_lines(cur_buf, s_line, e_line, false)
    snippet = table.concat(lines, "\n")
  end

  return {
    root = root,
    current_file = rel_cur_file,
    current_line = cur_line,
    current_col = cur_col,
    snippet = snippet,
    files = file_list,
    search_matches = search_matches,
  }
end

--- Format directory entries in multi-column terminal ls layout
local function format_ls_columns(entries, suggested, max_width)
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
  if M.state.dir_preview_win and vim.api.nvim_win_is_valid(M.state.dir_preview_win) then
    pcall(vim.api.nvim_win_close, M.state.dir_preview_win, true)
  end
  M.state.dir_preview_win = nil
  M.state.dir_preview_buf = nil
  M.state.on_path_accept = nil
end

--- Clear pending in-line diff
function M.clear_diff(keep_buffer)
  if M.state.pending_diff then
    local p = M.state.pending_diff
    if p.bufnr and vim.api.nvim_buf_is_valid(p.bufnr) then
      if p.bound_keys then
        for _, k in ipairs(p.bound_keys) do
          pcall(vim.keymap.del, "n", k, { buffer = p.bufnr })
        end
      end
      -- Clear all diff extmarks in ns_diff namespace (red virtual lines, green line highlights, signs, and footer)
      pcall(vim.api.nvim_buf_clear_namespace, p.bufnr, ns_diff, 0, -1)

      -- If diff was ephemeral and not accepted, revert buffer lines back to original
      if not keep_buffer and p.revert_lines then
        local s_idx = math.max(0, p.target_line - 1)
        local new_cnt = (p.new_lines and #p.new_lines) or 0
        vim.bo[p.bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(p.bufnr, s_idx, s_idx + new_cnt, false, p.revert_lines)
      end

      -- If it was an unsaved new file, wipe the buffer so no empty file is left on disk
      if not keep_buffer and p.is_new_file and not vim.bo[p.bufnr].modified then
        local name = vim.api.nvim_buf_get_name(p.bufnr)
        if vim.fn.filereadable(name) ~= 1 then
          pcall(vim.api.nvim_buf_delete, p.bufnr, { force = true })
        end
      end
    end
    if p.toolbar_win and vim.api.nvim_win_is_valid(p.toolbar_win) then
      pcall(vim.api.nvim_win_close, p.toolbar_win, true)
    end
    M.state.pending_diff = nil
  end
end

local function promote_contract_to_approved(filepath, task_id)
  if not filepath or filepath == "" then return end
  local root = get_root_dir()
  local full_path = filepath:match("^/") and filepath or (root .. "/" .. filepath)
  if vim.fn.filereadable(full_path) ~= 1 then return end

  local lines = vim.fn.readfile(full_path)
  local changed = false
  for i, line in ipairs(lines) do
    if line:find("SPEC%(") or line:find("TODO%(") or line:find("FIXME%(") then
      if not task_id or line:find(task_id, 1, true) then
        if line:find("status:DONE") then
          lines[i] = line:gsub("status:DONE", "status:APPROVED")
          changed = true
        elseif line:find("status:TODO") then
          lines[i] = line:gsub("status:TODO", "status:APPROVED")
          changed = true
        elseif not line:find("status:") then
          lines[i] = line:gsub("%):", " | status:APPROVED):")
          changed = true
        end
      end
    elseif line:match("^[ \t]*[#/%-]+%s*status:%s*(TODO|DONE)") then
      lines[i] = line:gsub("status:%s*(TODO|DONE)", "status: APPROVED")
      changed = true
    end
  end

  if changed then
    vim.fn.writefile(lines, full_path)
    local b = vim.fn.bufnr(full_path)
    if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then
      vim.api.nvim_buf_call(b, function() vim.cmd("checktime") end)
    end
  end
end

local function ensure_contract_preserved_as_done(orig_slice, new_lines)
  if not orig_slice or #orig_slice == 0 then return new_lines end
  local first = orig_slice[1]
  if not (first:find("SPEC%(") or first:find("TODO%(") or first:find("FIXME%(")) then
    return new_lines
  end

  -- Check if new_lines already has the contract header
  local new_first = new_lines[1] or ""
  if new_first:find("SPEC%(") or new_first:find("TODO%(") or new_first:find("FIXME%(") then
    for idx, nl in ipairs(new_lines) do
      if nl:find("status:TODO") then
        new_lines[idx] = nl:gsub("status:TODO", "status:DONE")
      elseif nl:find("status:REVISE") then
        new_lines[idx] = nl:gsub("status:REVISE", "status:DONE")
      end
    end
    return new_lines
  end

  -- Extract contract comment lines from orig_slice
  local contract_lines = {}
  for _, l in ipairs(orig_slice) do
    local trimmed = vim.trim(l)
    if trimmed:find("^[#/%-]+%s*[a-zA-Z0-9_%-]+%s*%(.*%):")
      or trimmed:find("^[#/%-]+%s*action:")
      or trimmed:find("^[#/%-]+%s*requires:")
      or trimmed:find("^[#/%-]+%s*ensures:")
      or trimmed:find("^[#/%-]+%s*invariant:")
      or trimmed:find("^[#/%-]+%s*modifies:")
      or trimmed:find("^[#/%-]+%s*status:")
      or trimmed:find("^[#/%-]+%s*%[lean:spec%]")
      or trimmed:find("^[#/%-]+%s*def%s+")
      or trimmed:find("^[#/%-]+%s*theorem%s+")
      or trimmed:find("^[#/%-]+%s*inductive%s+")
      or trimmed:find("^[#/%-]+%s*structure%s+")
      or trimmed:find("^[#/%-]+%s*|%s+")
      or trimmed:find("^[#/%-]+%s*Description:")
      or trimmed:find("^[#/%-]+%s*Criterion:")
    then
      local updated_l = l
      if updated_l:find("status:TODO") then
        updated_l = updated_l:gsub("status:TODO", "status:DONE")
      elseif updated_l:find("status:REVISE") then
        updated_l = updated_l:gsub("status:REVISE", "status:DONE")
      elseif updated_l:find("SPEC%(") or updated_l:find("TODO%(") or updated_l:find("FIXME%(") then
        if not updated_l:find("status:") then
          updated_l = updated_l:gsub("%):", " | status:DONE):")
        end
      end
      table.insert(contract_lines, updated_l)
    else
      break
    end
  end

  if #contract_lines > 0 then
    local combined = {}
    for _, cl in ipairs(contract_lines) do
      table.insert(combined, cl)
    end
    for _, nl in ipairs(new_lines) do
      table.insert(combined, nl)
    end
    return combined
  end

  return new_lines
end

--- Accept and permanently apply the pending in-line diff
function M.accept_diff()
  if M.state.current_review then
    local rev_id = M.state.current_review.id
    M.accept_review(rev_id)
    return
  end
  if not M.state.pending_diff then
    vim.notify("GitReview: No pending diff to accept", vim.log.levels.INFO)
    return
  end
  local p = M.state.pending_diff
  local bufnr = p.bufnr
  local origin_win = p.origin_win
  local target_line = p.target_line
  local new_lines = p.new_lines
  local old_count = p.old_count or 0
  local is_new_file = p.is_new_file
  local filepath = vim.api.nvim_buf_get_name(bufnr)

  promote_contract_to_approved(filepath, p.review and p.review.task_id)

  -- Mark diff as accepted so clear_diff will not revert buffer lines
  p.revert_lines = nil
  M.clear_diff(true)

  if vim.api.nvim_buf_is_valid(bufnr) then
    local was_mod = vim.bo[bufnr].modifiable
    vim.bo[bufnr].modifiable = true
    if is_new_file then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("silent! write")
      end)
      vim.notify("✓ GitReview: Created and saved " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":."), vim.log.levels.INFO)
    else
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and vim.bo[bufnr].buftype == "" then
        vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! write!") end)
      end
      vim.notify("✓ GitReview: Implementation accepted and saved to " .. (name ~= "" and vim.fn.fnamemodify(name, ":.") or "buffer"), vim.log.levels.INFO)
    end
    vim.bo[bufnr].modifiable = was_mod
    if origin_win and vim.api.nvim_win_is_valid(origin_win) then
      pcall(vim.api.nvim_set_current_win, origin_win)
    end
  end

  -- Mark current task in queue as done
  if M.state.queue and M.state.queue_index and M.state.queue[M.state.queue_index] then
    M.state.queue[M.state.queue_index].done = true
    update_queue_display(false)
  end

  -- Auto-advance to next queued task if present
  if M.state.queue and M.state.queue_index and M.state.queue_index < #M.state.queue then
    M.next()
  end
end

--- Mark task as REVISE and allow user to write in-line critique comments directly in the code
function M.revise_task(task_arg)
  task_arg = vim.trim(task_arg or "")
  local cur_buf = vim.api.nvim_get_current_buf()
  local root = get_root_dir()

  -- If viewing a pending diff, dismiss the diff visualization and keep buffer modifiable
  M.clear_diff(true)

  local target_buf = cur_buf
  local target_line = nil
  local target_task_id = nil

  if task_arg ~= "" then
    local all_tasks = scan_repository_tasks()
    local matched = nil
    local num = tonumber(task_arg)
    if num and all_tasks[num] then
      matched = all_tasks[num]
    else
      for _, t in ipairs(all_tasks) do
        if t.task_id and t.task_id:lower() == task_arg:lower() then
          matched = t
          break
        end
      end
    end

    if matched then
      local full_path = (matched.file:sub(1, 1) == "/") and matched.file or (root .. "/" .. matched.file)
      target_buf = vim.fn.bufadd(full_path)
      vim.fn.bufload(target_buf)
      target_line = matched.line
      target_task_id = matched.task_id
    else
      vim.notify("Tasks: Task '" .. task_arg .. "' not found", vim.log.levels.WARN)
      return
    end
  else
    -- Use cursor line or closest task in current buffer
    local cur_win = get_primary_editor_win()
    if cur_win and vim.api.nvim_win_is_valid(cur_win) then
      local lnum = vim.api.nvim_win_get_cursor(cur_win)[1]
      local lines = vim.api.nvim_buf_get_lines(cur_buf, 0, -1, false)
      for i = lnum, 1, -1 do
        if is_todo_comment(lines[i]) then
          target_line = i
          break
        end
      end
      if not target_line then
        for i = lnum, #lines do
          if is_todo_comment(lines[i]) then
            target_line = i
            break
          end
        end
      end
    end
  end

  if not target_line then
    vim.notify("Tasks: Place cursor on/near a task to revise, or specify :Tasks revise <id>", vim.log.levels.INFO)
    return
  end

  -- Update contract header to status:REVISE
  local lines = vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)
  local header = lines[target_line]
  if header then
    local new_header = header
    if new_header:find("status:%s*[%w_%-]+") then
      new_header = new_header:gsub("status:%s*[%w_%-]+", "status:REVISE")
    elseif new_header:find("%):") then
      new_header = new_header:gsub("%):", " | status:REVISE):")
    elseif new_header:find("%)") then
      new_header = new_header:gsub("%)", " | status:REVISE)")
    end

    if new_header ~= header then
      vim.bo[target_buf].modifiable = true
      vim.api.nvim_buf_set_lines(target_buf, target_line - 1, target_line, false, { new_header })
      vim.api.nvim_buf_call(target_buf, function() vim.cmd("silent! write") end)
    end

    local t_info = extract_task_info(header)
    target_task_id = (t_info and t_info.id) or target_task_id or "task"
  end

  local origin_win = get_primary_editor_win()
  if origin_win and vim.api.nvim_win_is_valid(origin_win) then
    vim.api.nvim_set_current_win(origin_win)
    vim.api.nvim_win_set_buf(origin_win, target_buf)
    pcall(vim.api.nvim_win_set_cursor, origin_win, { math.min(#lines, target_line + 1), 0 })
    pcall(function() vim.cmd("normal! zz") end)
  end

  vim.notify(string.format("● [Tasks] Task '%s' marked as REVISE. Add in-line comments (e.g. '# REVISE: ...') and run ':Tasks start' when ready.", target_task_id or "task"), vim.log.levels.INFO)
end

function M.write_revision()
  M.revise_task()
end

--- Wrap virtual diff line into visual chunks not exceeding max_w
local function wrap_diff_line(prefix, text, hl_group, max_w)
  max_w = math.max(30, max_w or 80)
  local full = prefix .. text
  if #full <= max_w then
    return { { { full, hl_group } } }
  end

  local lines = {}
  local cont_prefix = string.rep(" ", #prefix)
  local current = prefix

  local words = vim.split(text, " ", { plain = true })
  for _, word in ipairs(words) do
    local sep = (current == prefix or current == cont_prefix) and "" or " "
    if #(current .. sep .. word) <= max_w then
      current = current .. sep .. word
    else
      if current ~= prefix and current ~= cont_prefix then
        table.insert(lines, { { current, hl_group } })
        current = cont_prefix
      end

      local avail = max_w - #current
      local rem = word
      while #rem > avail and avail > 4 do
        local chunk = string.sub(rem, 1, avail)
        table.insert(lines, { { current .. chunk, hl_group } })
        current = cont_prefix
        rem = string.sub(rem, avail + 1)
        avail = max_w - #current
      end
      current = current .. rem
    end
  end

  if current ~= "" and current ~= cont_prefix then
    table.insert(lines, { { current, hl_group } })
  end

  return (#lines > 0) and lines or { { { full, hl_group } } }
end

--- Show suggested code in-line with green-red diff colors.
--- Deleted lines are shown in RED as virtual lines above.
--- Added lines are highlighted IN-LINE directly on the buffer lines in GREEN.
function M.show_inline_diff(bufnr, target_line, new_content, old_lines_count, is_new_file, old_lines, review_meta)
  M.clear_diff()
  setup_highlights()

  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if type(new_content) ~= "string" or vim.trim(new_content) == "" then return end

  local origin_win = get_primary_editor_win()
  if origin_win and vim.api.nvim_win_is_valid(origin_win) then
    vim.api.nvim_set_current_win(origin_win)
  end

  target_line = math.max(1, (type(target_line) == "number" and target_line) or 1)
  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  if target_line > total_lines then target_line = math.max(1, total_lines) end

  local new_lines = vim.split(new_content, "\n")
  old_lines_count = (type(old_lines_count) == "number") and old_lines_count or 0

  local s_idx = math.max(0, target_line - 1)
  local cur_slice = vim.api.nvim_buf_get_lines(bufnr, s_idx, s_idx + #new_lines, false)
  local already_applied = (table.concat(cur_slice, "\n") == new_content)
  local revert_lines = nil

  -- Extract original deleted lines
  local deleted_lines = {}
  if type(old_lines) == "table" and #old_lines > 0 then
    deleted_lines = old_lines
  elseif already_applied and review_meta and review_meta.old_lines then
    deleted_lines = review_meta.old_lines
  elseif not already_applied and old_lines_count > 0 then
    local e_idx = math.min(total_lines, s_idx + old_lines_count)
    deleted_lines = vim.api.nvim_buf_get_lines(bufnr, s_idx, e_idx, false)
  end

  -- If not already applied to buffer, apply new_lines in-place so additions are visible
  if not already_applied then
    local e_idx = math.min(total_lines, s_idx + old_lines_count)
    revert_lines = vim.api.nvim_buf_get_lines(bufnr, s_idx, e_idx, false)
    local was_mod = vim.bo[bufnr].modifiable
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, s_idx, e_idx, false, new_lines)
    vim.bo[bufnr].modifiable = was_mod
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! write") end)
  end

  local win_w = (origin_win and vim.api.nvim_win_is_valid(origin_win)) and vim.api.nvim_win_get_width(origin_win) or 80
  local max_w = math.max(35, win_w - 6)

  -- Ensure editor window displays this buffer and sign column is enabled
  if origin_win and vim.api.nvim_win_is_valid(origin_win) then
    if vim.api.nvim_win_get_buf(origin_win) ~= bufnr then
      vim.api.nvim_win_set_buf(origin_win, bufnr)
    end
    pcall(function() vim.wo[origin_win].signcolumn = "yes" end)
  end

  -- 1. Red deleted lines displayed directly above as virtual lines
  local virt_lines_top = {}
  for _, line in ipairs(deleted_lines) do
    local chunks = wrap_diff_line("- ", line, "AgentDiffDelete", max_w)
    for _, chunk in ipairs(chunks) do
      table.insert(virt_lines_top, chunk)
    end
  end

  if #virt_lines_top > 0 then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_diff, s_idx, 0, {
      virt_lines = virt_lines_top,
      virt_lines_above = true,
      priority = 250,
    })
  end

  -- 2. Green added lines highlighted directly on buffer lines with '+' in sign column
  local num_added = math.max(1, #new_lines)
  for i = 0, num_added - 1 do
    local l_idx = s_idx + i
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_diff, l_idx, 0, {
      line_hl_group = "AgentDiffAdd",
      sign_text = "+",
      sign_hl_group = "AgentDiffAddSign",
      priority = 250,
    })
  end

  -- Direct cursor to the exact start line of the diff and center on screen
  if origin_win and vim.api.nvim_win_is_valid(origin_win) then
    pcall(vim.api.nvim_win_set_cursor, origin_win, { target_line, 0 })
    pcall(function() vim.cmd("normal! zz") end)
  end

  -- Refresh gitsigns in the background
  local ok_gs, gs = pcall(require, "gitsigns")
  if ok_gs and gs then
    pcall(gs.refresh)
  end

  M.state.pending_diff = {
    bufnr = bufnr,
    origin_win = origin_win,
    target_line = target_line,
    new_lines = new_lines,
    old_count = old_lines_count,
    revert_lines = revert_lines,
    is_new_file = is_new_file or false,
    review = review_meta,
    bound_keys = {},
  }

  -- Buffer-local shortcuts that allow normal scrolling and review:
  local function bind_buf_key(lhs, rhs, desc)
    pcall(vim.keymap.set, "n", lhs, rhs, { buffer = bufnr, silent = true, nowait = true, desc = desc })
    table.insert(M.state.pending_diff.bound_keys, lhs)
  end

  bind_buf_key("<M-a>", function() M.accept() end, "Accept diff (:Tasks accept)")
  bind_buf_key("<M-r>", function() M.reject() end, "Reject diff (:Tasks reject)")
  bind_buf_key("<M-w>", function() M.revise_task() end, "Revise diff (:Tasks revise)")
  bind_buf_key("<Esc>", function()
    M.clear_diff()
    vim.notify("GitReview: Dismissed in-line diff preview", vim.log.levels.INFO)
  end, "Dismiss diff")
  bind_buf_key("<Tab>", function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.bo[b].buftype == "quickfix" then
        vim.api.nvim_set_current_win(w)
        return
      end
    end
  end, "Focus review/task pane")

  vim.cmd("redraw")
end

--- Deprecated dir preview modal (seamlessly routed into bottom task pane)
function M.show_dir_preview(base_dir, entries, suggested, on_accept)
  local sugg_entry = suggested or (entries and entries[1]) or "new_file"
  local target_path = resolve_suggested_path(base_dir, sugg_entry)
  local origin_win = M.state.origin_win or get_primary_editor_win()
  if on_accept then
    on_accept(origin_win, target_path)
  elseif M.state.pending_target then
    local target = M.state.pending_target
    M.state.pending_target = nil
    target.path = target_path
    M.state.last_target = target
    jump_to_target(target, origin_win)
  end
end

--- Find existing tab displaying filepath, or open in a clean tab without disturbing splits
local function find_or_open_tab(filepath)
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

--- Jump to a target location in the editor, replacing what's in the current split in-place
jump_to_target = function(target, win)
  if not target or not target.path or target.path == "" then return end
  local root = get_root_dir()
  local path = target.path
  if not path:match("^/") then
    path = root .. "/" .. path
  end

  -- Never open a directory as an editable file (prevents Netrw file listings)
  if vim.fn.isdirectory(path) == 1 then
    vim.notify("Agent: Target is a directory, not a file: " .. vim.fn.fnamemodify(path, ":."), vim.log.levels.WARN)
    return
  end

  local file_exists = (vim.fn.filereadable(path) == 1)
  local is_new = not file_exists or target.is_new_file or (target.action == "create")

  if not file_exists then
    local parent = vim.fn.fnamemodify(path, ":h")
    if vim.fn.isdirectory(parent) ~= 1 then
      vim.fn.mkdir(parent, "p")
    end
  end

  -- Determine target split: calling window, origin_win, or current editor window
  local qf_win = nil
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.bo[b].buftype == "quickfix" then
      qf_win = w
      break
    end
  end

  local target_win = win
  if not target_win or not vim.api.nvim_win_is_valid(target_win) or target_win == qf_win then
    target_win = M.state.origin_win
  end
  if not target_win or not vim.api.nvim_win_is_valid(target_win) or target_win == qf_win then
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= qf_win then
        target_win = w
        break
      end
    end
  end
  if not target_win or not vim.api.nvim_win_is_valid(target_win) or target_win == qf_win then
    vim.cmd("aboveleft split")
    target_win = vim.api.nvim_get_current_win()
  end

  local cur_buf = vim.api.nvim_win_get_buf(target_win)
  vim.api.nvim_set_current_win(target_win)

  -- If current split is a terminal, record terminal_origin so SmartQuit (:q) seamlessly returns to terminal
  if vim.bo[cur_buf].buftype == "terminal" then
    vim.w[target_win].terminal_origin = cur_buf
  end

  -- Open file directly in current split, replacing the previous buffer in-place
  local fullpath = vim.fn.fnamemodify(path, ":p")
  local ok = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(fullpath))
  if not ok then
    pcall(vim.cmd, "edit! " .. vim.fn.fnameescape(fullpath))
  end

  local bufnr = vim.api.nvim_win_get_buf(target_win)
  local line = tonumber(target.line) or 1
  local col = math.max(0, (tonumber(target.col) or 1) - 1)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line > line_count then line = math.max(1, line_count) end
  if line < 1 then line = 1 end

  pcall(vim.api.nvim_win_set_cursor, target_win, { line, col })
  vim.cmd("normal! zz")

  -- Visual flash on target line so user's focus is immediately drawn to the matched line
  pcall(function()
    local ns = vim.api.nvim_create_namespace("agent_jump_flash")
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    vim.api.nvim_buf_add_highlight(bufnr, ns, "IncSearch", line - 1, 0, -1)
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      end
    end, 1000)
  end)

  -- If code implementation was suggested, display in-line green-red diff!
  if type(target.content) == "string" and vim.trim(target.content) ~= "" then
    local old_count = is_new and 0 or ((type(target.old_lines_count) == "number") and target.old_lines_count or ((target.action == "replace") and 1 or 0))
    M.show_inline_diff(bufnr, line, target.content, old_count, is_new)
  end
end

--- Route jumps from quickfix window directly into calling split without splitting
setup_agent_qf_keymaps = function(origin_win, qf_buf)
  if not qf_buf or not vim.api.nvim_buf_is_valid(qf_buf) then
    local qf_win = vim.api.nvim_get_current_win()
    qf_buf = vim.api.nvim_win_get_buf(qf_win)
  end

  -- Informative statusline on quickfix window
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == qf_buf then
      pcall(function()
        if M.state.is_tasks_list then
          vim.wo[w].statusline = "%#AgentDiffHeader# ● TASKS %#AgentDiffMenuSel# [<CR>] Jump %#AgentDiffHeader#  %#AgentDiffMenuBtn# [o] Jump & Close %#AgentDiffHeader#  %#AgentDiffMenuBtn# [<Tab>] Switch %#AgentDiffHeader#  %#Normal# [q] Close %="
        else
          vim.wo[w].statusline = "%#AgentDiffHeader# ● RESULTS %#AgentDiffMenuSel# [<CR>] Jump (Stays Open) %#AgentDiffHeader#  %#AgentDiffMenuBtn# [<Tab>] Focus File %#AgentDiffHeader#  %#AgentDiffMenuBtn# [o] Jump & Close %#AgentDiffHeader#  %#Normal# [q] Close %="
        end
      end)
    end
  end

  local function jump_in_origin(close_qf)
    local idx = vim.fn.line(".")
    local qf_list = vim.fn.getqflist()
    local item = qf_list[idx]
    if not item then return end

    -- Check if this quickfix item represents a review
    local rev_id = item.text and item.text:match("ID:%s*([%w_%-]+)")
    if rev_id then
      local all_reviews = M.get_reviews("all")
      for _, r in ipairs(all_reviews) do
        if r.id == rev_id then
          if close_qf then vim.cmd("cclose") end
          M.show_review(r)
          return
        end
      end
    end

    local filepath = (item.filename and item.filename ~= "") and item.filename
    if not filepath or filepath == "" then
      if item.bufnr and item.bufnr > 0 and vim.api.nvim_buf_is_valid(item.bufnr) then
        filepath = vim.api.nvim_buf_get_name(item.bufnr)
      end
    end

    if not filepath or filepath == "" then return end

    local cur_item = (M.state.queue and M.state.queue[idx]) or {
      path = filepath,
      line = item.lnum or 1,
      col = item.col or 1,
      action = "navigate",
    }
    M.state.queue_index = idx

    -- Target editor split in current tab
    local qf_w = vim.api.nvim_get_current_win()
    local editor_win = origin_win
    if not editor_win or not vim.api.nvim_win_is_valid(editor_win) or editor_win == qf_w or vim.bo[vim.api.nvim_win_get_buf(editor_win)].buftype == "quickfix" then
      editor_win = nil
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local b = vim.api.nvim_win_get_buf(w)
        if vim.bo[b].buftype ~= "quickfix" then
          editor_win = w
          break
        end
      end
    end

    if close_qf then
      vim.cmd("cclose")
    end

    jump_to_target(cur_item, editor_win)
    if not M.state.is_tasks_list then
      update_queue_display(false)
    end

    -- If NOT closing quickfix, LEAVE RESULTS OPEN and keep cursor in quickfix for continuous browsing!
    if not close_qf then
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local b = vim.api.nvim_win_get_buf(w)
        if vim.bo[b].buftype == "quickfix" then
          vim.api.nvim_set_current_win(w)
          pcall(vim.api.nvim_win_set_cursor, w, { idx, 0 })
          break
        end
      end
    end
  end

  vim.keymap.set("n", "<CR>", function()
    jump_in_origin(false)
  end, { buffer = qf_buf, silent = true, noremap = true, desc = "Jump to task in calling split" })

  vim.keymap.set("n", "<2-LeftMouse>", function()
    jump_in_origin(false)
  end, { buffer = qf_buf, silent = true, noremap = true, desc = "Jump to task in calling split" })

  vim.keymap.set("n", "o", function()
    jump_in_origin(true)
  end, { buffer = qf_buf, silent = true, noremap = true, desc = "Jump to task and close bottom pane" })

  vim.keymap.set("n", "a", function()
    if M.state.is_tasks_list then
      vim.notify("Tasks: To accept a review, run :Tasks accept <id>", vim.log.levels.INFO)
      return
    end
    M.accept_diff()
  end, { buffer = qf_buf, silent = true, noremap = true, desc = "Accept current diff" })

  vim.keymap.set("n", "r", function()
    if M.state.is_tasks_list then
      vim.notify("Tasks: To reject a review, run :Tasks reject <id>", vim.log.levels.INFO)
      return
    end
    M.reject("")
  end, { buffer = qf_buf, silent = true, noremap = true, desc = "Reject current diff" })

  vim.keymap.set("n", "w", function()
    if M.state.is_tasks_list then
      local idx = vim.fn.line(".")
      local qf_list = vim.fn.getqflist()
      local item = qf_list[idx]
      local t_id = item and item.text and item.text:match("%[[%w_%-]+%]%s*([%w_%-]+)")
      if t_id then
        M.revise_task(t_id)
      else
        M.revise_task(tostring(idx))
      end
      return
    end
    M.write_revision()
  end, { buffer = qf_buf, silent = true, noremap = true, desc = "Revise instruction in natural language" })

  vim.keymap.set("n", "<Tab>", function()
    local target_win = origin_win
    if not target_win or not vim.api.nvim_win_is_valid(target_win) then
      target_win = M.state.origin_win or get_primary_editor_win()
    end
    if target_win and vim.api.nvim_win_is_valid(target_win) then
      vim.api.nvim_set_current_win(target_win)
    end
  end, { buffer = qf_buf, silent = true, noremap = true, desc = "Switch to editor split" })

  vim.keymap.set("n", "q", function()
    vim.cmd("cclose")
    local cur_target = origin_win
    if not cur_target or not vim.api.nvim_win_is_valid(cur_target) then
      cur_target = M.state.origin_win or get_primary_editor_win()
    end
    if cur_target and vim.api.nvim_win_is_valid(cur_target) then
      vim.api.nvim_set_current_win(cur_target)
    end
  end, { buffer = qf_buf, silent = true, noremap = true, desc = "Close bottom pane" })
end

--- Populate the Neovim Quickfix queue unified with :Tasks
update_queue_display = function(show_window)
  M.state.is_tasks_list = false
  local qf = {}
  local root = get_root_dir()
  for idx, item in ipairs(M.state.queue) do
    local fullpath = item.path:match("^/") and item.path or (root .. "/" .. item.path)
    local is_nav = (item.action == "navigate")
    local is_new = not is_nav and (item.is_new_file or (item.action == "create"))
    local tag = is_nav and "[MATCH]" or (is_new and "[NEW FILE]" or "[DIFF]")
    local status = item.done and "✓ [DONE]" or ((idx == M.state.queue_index) and "▶ [ACTIVE]" or "  [PENDING]")
    local desc = item.description or (is_nav and item.path or (is_new and ("Create " .. item.path) or ("Modify " .. item.path)))
    table.insert(qf, {
      filename = fullpath,
      lnum = item.line or 1,
      col = item.col or 1,
      text = string.format("%s %s %s", status, tag, desc),
      type = item.done and "I" or ((idx == M.state.queue_index) and "E" or "W"),
    })
  end

  vim.fn.setqflist(qf, "r")
  vim.fn.setqflist({}, "a", { title = string.format("Agent Task Queue [%d/%d] | :Accept  :Reject  :Revise", M.state.queue_index, #M.state.queue) })

  -- If quickfix window is already open in the current tab, refresh it in place without splitting
  local qf_win = nil
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "quickfix" then
      qf_win = win
      break
    end
  end

  if show_window and not qf_win then
    local orig_win = M.state.origin_win or vim.api.nvim_get_current_win()
    vim.cmd("botright copen 6")
    local qf_w = vim.api.nvim_get_current_win()
    local qf_b = vim.api.nvim_win_get_buf(qf_w)
    setup_agent_qf_keymaps(orig_win, qf_b)
    if orig_win and vim.api.nvim_win_is_valid(orig_win) then
      vim.api.nvim_set_current_win(orig_win)
    end
  elseif qf_win then
    local orig_win = M.state.origin_win or vim.api.nvim_get_current_win()
    local qf_b = vim.api.nvim_win_get_buf(qf_win)
    setup_agent_qf_keymaps(orig_win, qf_b)
  end
end

--- Step to next queued location
function M.next()
  if #M.state.queue == 0 then
    vim.notify("Agent: Queue is empty", vim.log.levels.INFO)
    return
  end
  if M.state.queue_index >= #M.state.queue then
    vim.notify("Agent: All queued targets completed (end of queue)", vim.log.levels.INFO)
    return
  end

  M.state.queue_index = M.state.queue_index + 1
  local cur = M.state.queue[M.state.queue_index]
  jump_to_target(cur)
  update_queue_display(false)
  vim.api.nvim_echo({
    { string.format("● [Agent Queue %d/%d] ", M.state.queue_index, #M.state.queue), "ModeMsg" },
    { string.format("%s:%d", cur.path, cur.line or 1), "Directory" },
    { cur.description and (" — " .. cur.description) or "", "Comment" },
  }, false, {})
end

--- Step to previous queued location
function M.prev()
  if #M.state.queue == 0 then
    vim.notify("Agent: Queue is empty", vim.log.levels.INFO)
    return
  end
  if M.state.queue_index <= 1 then
    vim.notify("Agent: Already at the first queued target", vim.log.levels.INFO)
    return
  end

  M.state.queue_index = M.state.queue_index - 1
  local cur = M.state.queue[M.state.queue_index]
  jump_to_target(cur)
  update_queue_display(false)
  vim.api.nvim_echo({
    { string.format("● [Agent Queue %d/%d] ", M.state.queue_index, #M.state.queue), "ModeMsg" },
    { string.format("%s:%d", cur.path, cur.line or 1), "Directory" },
    { cur.description and (" — " .. cur.description) or "", "Comment" },
  }, false, {})
end

--- Format in-line task as a concise, minimal summary line for quickfix split
local function format_task_summary(t, idx)
  local label = (t.task_id and t.task_id ~= "task") and t.task_id or ""
  local status_str = string.format("[%s]", t.status or "TODO")
  if label ~= "" then
    return string.format("#%d %s %s", idx, status_str, label)
  end
  local raw = t.description or t.raw or ""
  local short_desc = raw:gsub("^[ \t]*[#/%-%*%\"]+%s*", ""):gsub("^[A-Z]+%(?[^%)]*%)?:?%s*", "")
  short_desc = vim.trim(short_desc:gsub("[\r\n]+.*$", ""))
  if #short_desc > 35 then
    short_desc = short_desc:sub(1, 32) .. "..."
  end
  if short_desc == "" then short_desc = "task" end
  return string.format("#%d %s %s", idx, status_str, short_desc)
end

--- Display repository in-tree tasks agenda in a bottom split
function M.show_tasks()
  local root = get_root_dir()
  local tasks = scan_repository_tasks and scan_repository_tasks() or {}
  if #tasks == 0 then
    vim.notify("Tasks: No in-tree TODO/FIXME tasks found in " .. vim.fn.fnamemodify(root, ":t"), vim.log.levels.INFO)
    return
  end

  table.sort(tasks, function(a, b)
    if (a.tier or "U") ~= (b.tier or "U") then
      return (a.tier or "U") < (b.tier or "U")
    end
    if (a.file or "") ~= (b.file or "") then
      return (a.file or "") < (b.file or "")
    end
    return (a.line or 0) < (b.line or 0)
  end)

  local qf_list = {}
  local task_queue = {}
  for idx, t in ipairs(tasks) do
    local text = format_task_summary(t, idx)
    local abs_path = (t.file:match("^/") and t.file) or (root .. "/" .. t.file)
    local rel_path = t.file:gsub("^" .. vim.pesc(root) .. "/", ""):gsub("^/+", "")
    local bufnr = vim.fn.bufadd(abs_path)
    table.insert(qf_list, {
      bufnr = bufnr,
      filename = rel_path,
      lnum = t.line,
      text = text,
    })
    table.insert(task_queue, {
      path = abs_path,
      line = t.line,
      action = "navigate",
      task_id = t.task_id,
      tier = t.tier,
      description = t.description,
    })
  end

  M.state.is_tasks_list = true
  M.state.queue = task_queue
  M.state.queue_index = 1
  M.state.origin_win = get_primary_editor_win()
  vim.fn.setqflist(qf_list, "r")
  vim.fn.setqflist({}, "a", { title = string.format("Tasks: %d items (%s)", #tasks, vim.fn.fnamemodify(root, ":t")) })
  vim.cmd("botright copen 10")
  if M.state.origin_win and vim.api.nvim_win_is_valid(M.state.origin_win) then
    setup_agent_qf_keymaps(M.state.origin_win, vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win()))
  end
end

--- Toggle repository in-tree tasks agenda in a bottom split
function M.toggle_tasks()
  local qf_open = false
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "quickfix" then
      qf_open = true
      break
    end
  end

  if qf_open then
    vim.cmd("cclose")
  else
    M.show_tasks()
  end
end
M.toggle_queue = M.toggle_tasks

--- Accept review by ID or active pending diff
function M.accept(arg)
  arg = vim.trim(arg or "")

  if arg:lower() == "all" then
    vim.notify("Tasks: Batch accept is disabled. Please accept changes individually by review ID: :Tasks accept <id>", vim.log.levels.WARN)
    return
  end

  local rev_id = nil
  if arg ~= "" then
    local num = tonumber(arg:match("^#?(%d+)$"))
    local reviews = M.get_reviews("all")
    if num and reviews[num] then
      rev_id = reviews[num].id
    else
      for _, r in ipairs(reviews) do
        if r.id == arg or (r.task_id and r.task_id:lower() == arg:lower()) or (r.id and tostring(r.id):sub(-6) == tostring(arg):sub(-6)) then
          rev_id = r.id
          break
        end
      end
    end
    if not rev_id then
      vim.notify("Tasks: Review ID '" .. arg .. "' not found. Run :Tasks review to see active reviews.", vim.log.levels.WARN)
      return
    end
    M.accept_review(rev_id)
    return
  end

  -- In-line diff active
  if M.state.pending_diff then
    local review = M.state.pending_diff.review
    M.accept_diff()
    if review and review.id then
      M.accept_review(review.id)
    end
    return
  end

  if M.state.current_review then
    M.accept_review(M.state.current_review.id)
    return
  end

  -- Dir preview:
  if M.state.dir_preview_win then
    local fn = M.state.on_path_accept
    M.state.on_path_accept = nil
    if fn then
      fn()
    else
      M.close_dir_preview()
      if M.state.pending_target then
        local target = M.state.pending_target
        M.state.pending_target = nil
        M.state.last_target = target
        jump_to_target(target)
      end
    end
    return
  end

  if M.state.pending_target then
    local target = M.state.pending_target
    M.state.pending_target = nil
    M.state.last_target = target
    jump_to_target(target)
    return
  end

  local unrev = M.get_reviews("unreviewed")
  if #unrev == 1 then
    M.accept_review(unrev[1].id)
    return
  elseif #unrev > 1 then
    vim.notify(string.format("Tasks: Multiple pending reviews exist (%d). Specify review ID: :Tasks accept <id>. Run :Tasks review to list them.", #unrev), vim.log.levels.INFO)
    M.list_reviews_qf()
    return
  else
    vim.notify("Tasks: No pending review or diff to accept", vim.log.levels.INFO)
    return
  end
end

--- Record voice from microphone and transcribe using faster-whisper
function M.record_voice(callback)
  require("voice").record_once(callback)
end

--- Execute prompt against LLM and process silent structured response
function M.run(prompt, is_rejection, on_done)
  if not prompt or prompt == "" then
    if on_done then on_done(nil) end
    return
  end
  M.state.origin_win = get_primary_editor_win()
  M.state.last_prompt = prompt
  M.state.is_busy = true

  local root = get_root_dir()
  pcall(vim.fn.chdir, root)

  local ctx = collect_context(prompt)
  local file_list_str = table.concat(ctx.files, "\n")

  local rejection_context = ""
  if is_rejection and M.state.last_target then
    rejection_context = string.format(
      "\nREJECTION FEEDBACK: The user rejected previous target file '%s' at line %d. Reason: '%s'. Propose an alternative suitable location or file.",
      M.state.last_target.path or "",
      M.state.last_target.line or 1,
      M.state.last_rejection or prompt
    )
  end

  local search_section = ""
  if ctx.search_matches and #ctx.search_matches > 0 then
    search_section = "\nSearch matches in repository for query terms:\n" .. table.concat(ctx.search_matches, "\n") .. "\n"
  end

  local system_prompt = [[
You are an autonomous Neovim code navigation agent.
CRITICAL INSTRUCTION: Do NOT call any tools or commands (do NOT run bash, grep, find, view_file, or any tools). All context is provided directly in this prompt.
NEVER reply with conversational chat, apologies, or natural language prose.
Output your verdict IMMEDIATELY in this turn as a single STRICT JSON object.

Repository context:
Project Root: ]] .. root .. [[

Current file: ]] .. ctx.current_file .. [[ (line ]] .. ctx.current_line .. [[)
Available repository files:
]] .. file_list_str .. [[
]] .. search_section .. [[

Snippet around cursor:
]] .. ctx.snippet .. rejection_context .. [[

User Instruction:
]] .. prompt .. [[

Navigation rules:
- For navigation and general code questions ("where did we implement X", "where is X", "find X", "show X", "how does X work", "why is Y done"):
  - Set "action": "navigate"
  - Pinpoint the exact implementation file and line as "active_target"
  - In "active_target.content", if the code benefits from clarification, provide a crisp, professional in-line comment (using the language's native comment syntax: // or -- or #) to be inserted directly above the target line that indirectly answers the question by making the code self-documenting.
  - NEVER output conversational text or answers in chat. The code and in-line comment ARE the answer.
  - Populate "queue" with ALL other relevant matching files and lines from the search matches or file list
  - active_target.path MUST point to an actual file (NEVER a directory, NEVER ".")
- For new file requests: set "action": "create_and_jump" or "propose_dir"
- NEVER suggest a directory as active_target.path. Always choose a specific file.

Output STRICT JSON matching this schema:
{
  "action": "navigate" | "create_and_jump" | "propose_dir",
  "active_target": {
    "path": "relative/path/to/file",
    "line": 1,
    "col": 1,
    "description": "Brief description of this match",
    "content": "optional code snippet or implementation to suggest in-line"
  },
  "queue": [
    {"path": "file1", "line": 10, "col": 1, "description": "Match 1"},
    {"path": "file2", "line": 40, "col": 1, "description": "Match 2"}
  ],
  "dir_preview": {
    "base_dir": "path/to/directory",
    "entries": ["file1", "file2", "file3"],
    "suggested": "file3"
  }
}
Emit ONLY raw JSON. No markdown code blocks, no text before or after.
]]

  if M.state.active_job then
    pcall(function() M.state.active_job:kill(9) end)
    M.state.active_job = nil
  end

  local agy_bin = vim.fn.exepath("agy")
  local opencode_bin = vim.fn.exepath("opencode")
  local cmd = {}
  if agy_bin ~= "" then
    cmd = { agy_bin, "-p", system_prompt, "--model", "Gemini 3.8 Flash (Low)", "--print-timeout", "30s", "--dangerously-skip-permissions", "--disable-slash-commands" }
  elseif opencode_bin ~= "" then
    cmd = { opencode_bin, "run", "--format", "json", system_prompt }
  else
    M.state.is_busy = false
    vim.notify("Agent: Neither 'agy' nor 'opencode' found in PATH", vim.log.levels.ERROR)
    if on_done then on_done(nil) end
    return
  end

  vim.api.nvim_echo({ { "● [Agent] Analyzing codebase...", "ModeMsg" } }, false, {})
  vim.cmd("redraw")

  local job_timeout = vim.uv.new_timer()
  job_timeout:start(30000, 0, vim.schedule_wrap(function()
    if M.state.active_job then
      vim.notify("Agent: Request timed out after 30s. Cancelled.", vim.log.levels.WARN)
      pcall(function() M.state.active_job:kill(9) end)
      M.state.active_job = nil
      M.state.is_busy = false
      if on_done then on_done(nil) end
    end
    if job_timeout then
      pcall(function() job_timeout:stop(); job_timeout:close() end)
      job_timeout = nil
    end
  end))

  local stdout_chunks = {}
  M.state.active_job = vim.system(cmd, {
    text = true,
    stdout = function(_, data)
      if data then table.insert(stdout_chunks, data) end
    end,
  }, vim.schedule_wrap(function(res)
    M.state.active_job = nil
    if job_timeout then
      pcall(function() job_timeout:stop(); job_timeout:close() end)
      job_timeout = nil
    end
    local raw = table.concat(stdout_chunks, "")
    local data = nil

    -- 1. Direct parse of json output ({ "status": "SUCCESS", "response": "..." })
    local ok, res_obj = pcall(vim.fn.json_decode, raw)
    if ok and type(res_obj) == "table" then
      if res_obj.response and type(res_obj.response) == "string" then
        local rok, rdata = pcall(vim.fn.json_decode, res_obj.response)
        if rok and type(rdata) == "table" then
          data = rdata
        else
          local sub = res_obj.response:match("(%b{})")
          if sub then
            local sok, sdata = pcall(vim.fn.json_decode, sub)
            if sok and type(sdata) == "table" then
              data = sdata
            end
          end
        end
      elseif res_obj.action or res_obj.active_target or res_obj.queue or res_obj.dir_preview then
        data = res_obj
      end
    end

    -- 2. OpenCode format json stream (lines with type == "text" and part.text)
    if not data then
      for line in raw:gmatch("[^\r\n]+") do
        local lok, lobj = pcall(vim.fn.json_decode, line)
        if lok and type(lobj) == "table" and lobj.type == "text" and lobj.part and lobj.part.text then
          local ptext = lobj.part.text
          local pok, pdata = pcall(vim.fn.json_decode, ptext)
          if pok and type(pdata) == "table" and (pdata.action or pdata.active_target or pdata.content) then
            data = pdata
            break
          end
          local sub = ptext:match("(%b{})")
          if sub then
            local sok, sdata = pcall(vim.fn.json_decode, sub)
            if sok and type(sdata) == "table" and (sdata.action or sdata.active_target or sdata.content) then
              data = sdata
              break
            end
          end
        end
      end
    end

    -- 2. Try finding stream-json result event if stream format was used
    if not data then
      for line in raw:gmatch("[^\r\n]+") do
        if line:find('"event"%s*:%s*"result"') then
          local rok, robj = pcall(vim.fn.json_decode, line)
          if rok and robj and robj.result and robj.result.response then
            local resp_str = robj.result.response
            local sok, sdata = pcall(vim.fn.json_decode, resp_str)
            if sok and type(sdata) == "table" then
              data = sdata
              break
            end
            local sub = resp_str:match("(%b{})")
            if sub then
              local tok, tdata = pcall(vim.fn.json_decode, sub)
              if tok and type(tdata) == "table" then
                data = tdata
                break
              end
            end
          end
        end
      end
    end

    -- 3. Fallback: search for balanced JSON in full raw output
    if not data then
      for candidate in raw:gmatch("(%b{})") do
        local cok, cand_obj = pcall(vim.fn.json_decode, candidate)
        if cok and type(cand_obj) == "table" then
          if cand_obj.action or cand_obj.active_target or cand_obj.queue or cand_obj.dir_preview then
            data = cand_obj
            break
          end
        end
      end
    end

    if not data then
      print("RAW_DEBUG=" .. raw)
    end

    process_agent_response(data, on_done)
  end))
end

--- Shared processor for agent JSON output:
--- - propose_dir / dir_preview: path-only floating preview modal
--- - active_target: jump to file & line in primary editor split
--- - content: in-line green-red diff (showing deleted lines in red, added in green)
--- - queue: multi-location step queue
--- - clean: notify clean logic check
process_agent_response = function(data, on_done)
  if not data or type(data) ~= "table" then
    vim.notify("Agent: Received invalid response from model", vim.log.levels.ERROR)
    if on_done then on_done(nil) end
    return
  end

  if data.action == "clean" then
    M.state.is_busy = false
    vim.notify("✓ Agent: Code logic check clean. No logical errors found.", vim.log.levels.INFO)
    if on_done then on_done(data) end
    return
  end

  local origin_win = M.state.origin_win or get_primary_editor_win()

  -- 1. Determine primary target (file edit, new file, or proposed dir)
  local primary_target = nil
  if (data.action == "propose_dir" and not data.active_target) or (data.dir_preview and not data.active_target and not data.path) then
    local base_dir = ""
    local sugg = nil
    if type(data.dir_preview) == "table" then
      base_dir = data.dir_preview.base_dir or ""
      sugg = data.dir_preview.suggested or (data.dir_preview.entries and data.dir_preview.entries[1])
    elseif type(data.dir_preview) == "string" then
      sugg = data.dir_preview
    end
    local at = data.active_target or {}
    local raw_target = at.path or sugg or "new_file"
    local target_path = resolve_suggested_path(base_dir, raw_target)
    local target_content = (type(at.content) == "string" and at.content) or (type(data.content) == "string" and data.content) or nil
    primary_target = {
      path = target_path,
      line = 1,
      col = 1,
      content = target_content,
      action = "create",
      is_new_file = true,
      description = at.description or data.description or ("Create new file " .. target_path),
    }
  elseif data.active_target or data.path then
    local at = data.active_target or {}
    local path = at.path or data.path
    local root = get_root_dir()
    local fullpath = path:match("^/") and path or (root .. "/" .. path)
    local file_exists = (vim.fn.filereadable(fullpath) == 1)
    local is_nav = (data.action == "navigate" or at.action == "navigate")
    local is_new = not is_nav and (not file_exists or (data.action == "create_and_jump" or data.action == "create" or at.action == "create"))
    local final_action = is_nav and "navigate" or (is_new and "create" or (at.action or data.action or "replace"))
    primary_target = {
      path = path,
      line = tonumber(at.line) or tonumber(data.line) or 1,
      col = tonumber(at.col) or tonumber(data.col) or 1,
      content = (type(at.content) == "string" and at.content) or (type(data.content) == "string" and data.content) or nil,
      action = final_action,
      old_lines_count = (is_new or is_nav) and 0 or (tonumber(at.old_lines_count) or tonumber(data.old_lines_count) or (at.action == "replace" and 1 or 0)),
      is_new_file = is_new,
      description = at.description or data.description or (is_nav and ("Jump to " .. path) or (is_new and ("Create " .. path) or ("Modify " .. path))),
    }
  end

  -- 2. Build unified queue for bottom task pane, filtering out directory paths
  local root = get_root_dir()
  local function is_dir(p)
    if not p or p == "" or p == "." or p == "./" then return true end
    local full = p:match("^/") and p or (root .. "/" .. p)
    return vim.fn.isdirectory(full) == 1
  end

  local queue = {}
  if primary_target and not is_dir(primary_target.path) then
    table.insert(queue, primary_target)
  end
  if data.queue and #data.queue > 0 then
    for _, q_item in ipairs(data.queue) do
      if not is_dir(q_item.path) then
        local q_path = q_item.path
        local q_full = q_path:match("^/") and q_path or (root .. "/" .. q_path)
        local q_exists = (vim.fn.filereadable(q_full) == 1)
        local q_is_nav = (data.action == "navigate" or q_item.action == "navigate")
        local q_is_new = not q_is_nav and (not q_exists or (q_item.action == "create"))
        q_item.is_new_file = q_is_new
        if q_is_nav then q_item.action = "navigate" end
        if not primary_target or q_item.path ~= primary_target.path or q_item.line ~= primary_target.line then
          table.insert(queue, q_item)
        end
      end
    end
  end

  if #queue > 0 then
    M.state.queue = queue
    M.state.queue_index = 1
    local cur = queue[1]
    M.state.last_target = cur
    jump_to_target(cur, origin_win)
    if #queue > 1 then
      update_queue_display(true)
    else
      update_queue_display(false)
    end
  else
    vim.notify("Agent: Found no specific file matches to open", vim.log.levels.WARN)
  end

  M.state.is_busy = false
  vim.cmd("redraw")
  if on_done then on_done(data) end
end
M.process_response = process_agent_response

--- Reject and revert review by ID or active pending diff
function M.reject(arg)
  arg = vim.trim(arg or "")

  if arg:lower() == "all" then
    vim.notify("Tasks: Batch reject is disabled. Please reject changes individually by review ID: :Tasks reject <id>", vim.log.levels.WARN)
    return
  end

  local rev_id = nil
  if arg ~= "" then
    local num = tonumber(arg:match("^#?(%d+)$"))
    local reviews = M.get_reviews("all")
    if num and reviews[num] then
      rev_id = reviews[num].id
    else
      for _, r in ipairs(reviews) do
        if r.id == arg or (r.task_id and r.task_id:lower() == arg:lower()) or (r.id and tostring(r.id):sub(-6) == tostring(arg):sub(-6)) then
          rev_id = r.id
          break
        end
      end
    end
    if not rev_id then
      vim.notify("Tasks: Review ID '" .. arg .. "' not found. Run :Tasks review to see active reviews.", vim.log.levels.WARN)
      return
    end
    M.revert_review(rev_id)
    return
  end

  -- In-line diff active
  if M.state.pending_diff then
    local review = M.state.pending_diff.review
    if review and review.id then
      M.revert_review(review.id)
    else
      M.clear_diff()
      vim.notify("Tasks: In-line diff reverted", vim.log.levels.INFO)
    end
    return
  end

  if M.state.current_review then
    M.revert_review(M.state.current_review.id)
    return
  end

  local unrev = M.get_reviews("unreviewed")
  if #unrev == 1 then
    M.revert_review(unrev[1].id)
    return
  elseif #unrev > 1 then
    vim.notify(string.format("Tasks: Multiple pending reviews exist (%d). Specify review ID: :Tasks reject <id>. Run :Tasks review to list them.", #unrev), vim.log.levels.INFO)
    M.list_reviews_qf()
    return
  else
    vim.notify("Tasks: No pending review to reject", vim.log.levels.INFO)
    return
  end
end

--- Stop any active background agent job and clear all previews/diffs
function M.stop()
  if M.state.active_job then
    pcall(function() M.state.active_job:kill(9) end)
    M.state.active_job = nil
  end
  M.state.is_busy = false
  M.clear_diff()
  M.close_dir_preview()
  vim.notify("Agent: Stopped active job and cleared state", vim.log.levels.INFO)
end

--- Extract core search keywords from natural language or symbol queries
local function extract_search_keywords(query)
  local stop_words = {
    ["where"]=true, ["did"]=true, ["we"]=true, ["implement"]=true, ["implementation"]=true,
    ["the"]=true, ["a"]=true, ["an"]=true, ["in"]=true, ["is"]=true, ["of"]=true, ["to"]=true,
    ["and"]=true, ["or"]=true, ["for"]=true, ["with"]=true, ["find"]=true, ["show"]=true,
    ["me"]=true, ["how"]=true, ["what"]=true, ["which"]=true, ["can"]=true, ["you"]=true,
    ["at"]=true, ["on"]=true, ["file"]=true, ["line"]=true, ["code"]=true, ["function"]=true,
    ["class"]=true, ["this"]=true, ["that"]=true, ["there"]=true, ["are"]=true, ["was"]=true,
    ["our"]=true, ["us"]=true, ["it"]=true, ["its"]=true, ["my"]=true, ["i"]=true,
    ["definition"]=true, ["defined"]=true, ["locate"]=true, ["look"]=true, ["up"]=true,
  }
  local keywords = {}
  for word in query:lower():gmatch("[%a%d_-]+") do
    if #word >= 3 and not stop_words[word] then
      table.insert(keywords, word)
    end
  end
  if #keywords == 0 then
    for word in query:gmatch("%S+") do
      table.insert(keywords, word:lower())
    end
  end
  return keywords
end

--- Search codebase and rank matches by definition confidence
local function search_and_rank(query, root)
  local keywords = extract_search_keywords(query)
  if #keywords == 0 then return {} end

  local candidates = {}
  local seen_locs = {}

  -- 1. Check for filename matches across repository
  local find_cmd = { "git", "-C", root, "ls-files", "*" .. (keywords[1] or query) .. "*" }
  local find_out = vim.fn.system(find_cmd)
  if vim.v.shell_error == 0 and find_out ~= "" then
    for line in find_out:gmatch("[^\r\n]+") do
      if not line:match("%.olean$") and not line:match("%.jsonl$") and not line:match("%.log$") and not line:match("%.ipynb$") then
        local loc_key = line .. ":1"
        if not seen_locs[loc_key] then
          seen_locs[loc_key] = true
          table.insert(candidates, {
            path = line,
            line = 1,
            col = 1,
            action = "navigate",
            description = "[FILE] " .. line,
            score = 150,
          })
        end
      end
    end
  end

  local grep_matches = {}
  local pattern = table.concat(keywords, "|")
  local git_cmd = { "git", "-C", root, "grep", "--untracked", "-n", "-I", "-i", "-E", pattern, "--",
    ":!*.jsonl", ":!*.log", ":!*.json", ":!*.ipynb", ":!*.olean", ":!specs/.lexlean/*", ":!logs/*", ":!target/*" }
  local git_out = vim.fn.system(git_cmd)

  if vim.v.shell_error == 0 and git_out ~= "" then
    for line in git_out:gmatch("[^\r\n]+") do
      table.insert(grep_matches, line)
    end
  else
    local rg_bin = vim.fn.exepath("rg")
    if rg_bin ~= "" then
      local rg_cmd = { rg_bin, "-n", "--no-heading", "-i", "-e", pattern,
        "-g", "!*.jsonl", "-g", "!*.log", "-g", "!*.json", "-g", "!*.ipynb", "-g", "!*.olean", "-g", "!specs/.lexlean/*", "-g", "!logs/*", "-g", "!target/*", root }
      local rg_out = vim.fn.system(rg_cmd)
      if rg_out and rg_out ~= "" then
        for line in rg_out:gmatch("[^\r\n]+") do
          local rel = line:gsub("^" .. vim.pesc(root) .. "/", "")
          table.insert(grep_matches, rel)
        end
      end
    end
  end

  for _, line in ipairs(grep_matches) do
    local fpath, lnum, txt = line:match("^([^:]+):(%d+):(.*)$")
    if fpath and lnum and txt then
      local lnum_num = tonumber(lnum) or 1
      local loc_key = fpath .. ":" .. lnum_num
      if not seen_locs[loc_key] then
        seen_locs[loc_key] = true
        local txt_low = txt:lower()
        local fpath_low = fpath:lower()
        local query_low = query:lower()
        local score = 10

        -- Exact verbatim query match (+140)
        if txt:find(query, 1, true) then
          score = score + 140
        elseif txt_low:find(query_low, 1, true) then
          score = score + 90
        end

        -- Direct symbol definition match (+120)
        for _, kw in ipairs(keywords) do
          local pat1 = "fn%s+" .. kw
          local pat2 = "def%s+" .. kw
          local pat3 = "function%s+" .. kw
          local pat4 = "function%s+[%a0-9_]*[:%.]" .. kw
          local pat5 = "struct%s+" .. kw
          local pat6 = "class%s+" .. kw
          local pat7 = "theorem%s+" .. kw
          local pat8 = "type%s+" .. kw
          local pat9 = "let%s+" .. kw
          local pat10 = kw .. "%s*="
          if txt_low:find(pat1) or txt_low:find(pat2) or txt_low:find(pat3) or txt_low:find(pat4)
            or txt_low:find(pat5) or txt_low:find(pat6) or txt_low:find(pat7) or txt_low:find(pat8)
            or txt_low:find(pat9) or txt_low:find(pat10) then
            score = score + 120
            break
          end
        end

        -- Boost actual function/method implementation bodies (+60)
        if txt_low:find("=%s*function") or txt_low:find("function%s*[%a0-9_]*%s*%(") or txt_low:find("fn%s+[%a0-9_]+%s*%(") or txt_low:find("def%s+[%a0-9_]+%s*%(") then
          score = score + 60
        end

        -- Penalize forward stubs / nil initializations (-50)
        if txt_low:find("=%s*nil%s*$") or txt_low:find("=%s*none%s*$") or txt_low:find("=%s*null%s*$") then
          score = score - 50
        end

        -- Definition keywords (+50)
        if txt_low:find("%f[%a]struct%f[%A]")
          or txt_low:find("%f[%a]class%f[%A]")
          or txt_low:find("%f[%a]def%f[%A]")
          or txt_low:find("%f[%a]fn%f[%A]")
          or txt_low:find("%f[%a]theorem%f[%A]")
          or txt_low:find("%f[%a]lemma%f[%A]")
          or txt_low:find("%f[%a]axiom%f[%A]")
          or txt_low:find("%f[%a]type%f[%A]")
          or txt_low:find("%f[%a]typedef%f[%A]")
          or txt_low:find("%f[%a]enum%f[%A]")
          or txt_low:find("%f[%a]interface%f[%A]") then
          score = score + 50
        end

        -- Explanatory comment (+35)
        if txt_low:find("^%s*//") or txt_low:find("^%s*/%*") or txt_low:find("^%s*#") or txt_low:find("^%s*%-%-") then
          score = score + 35
        end

        -- Keyword match in filename (+40)
        for _, kw in ipairs(keywords) do
          if fpath_low:find(vim.pesc(kw)) then
            score = score + 40
            break
          end
        end

        -- Penalize generated tex / documentation files or huge lines (-50)
        if fpath_low:match("%.tex$") or fpath_low:match("%.md$") or fpath_low:match("%.txt$") or fpath_low:match("%.rst$") or #txt > 500 then
          score = score - 50
        end

        -- Boost code implementation files (+40)
        if fpath_low:match("%.hpp$") or fpath_low:match("%.cpp$") or fpath_low:match("%.rs$") or fpath_low:match("%.c$") or fpath_low:match("%.h$") or fpath_low:match("%.lean$") or fpath_low:match("%.py$") or fpath_low:match("%.lua$") or fpath_low:match("%.go$") then
          score = score + 40
        end

        -- Core source directories (+30)
        if fpath_low:find("^src/") or fpath_low:find("^lib/") or fpath_low:find("^include/") or fpath_low:find("^crates/") or fpath_low:find("^nvim/lua/") then
          score = score + 30
        end

        -- Penalize includes/imports (-25)
        if txt_low:find("^%s*#include") or txt_low:find("^%s*import%s") or txt_low:find("^%s*from%s.*import") then
          score = score - 25
        end

        -- Penalize tests if query is not asking for tests (-20)
        if (fpath_low:find("test") or fpath_low:find("tests/")) and not query:lower():find("test") then
          score = score - 20
        end

        table.insert(candidates, {
          path = fpath,
          line = lnum_num,
          col = 1,
          action = "navigate",
          description = vim.trim(txt),
          score = score,
        })
      end
    end
  end

  table.sort(candidates, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.path < b.path
  end)

  return candidates
end

--- Semantic Code Search (:Find <concept|description>)
-- Uses LLM to locate the exact code implementation corresponding to the concept.
function M.find(query)
  query = vim.trim(query or "")
  if query == "" then
    vim.notify("Usage: :Find <concept or description of code>", vim.log.levels.INFO)
    return
  end

  local root = get_root_dir()

  vim.api.nvim_echo({ { "● [Finding Code] ", "ModeMsg" }, { "Locating code with LLM...", "Comment" } }, false, {})
  local prompt = "where did we implement " .. query .. " (locate the exact source file and line implementing this logic)"
  M.run(prompt, false, function(res)
    if res and res.active_target and res.active_target.path then
      local target = res.active_target
      jump_to_target(target)
      update_queue_display(M.state.queue and #M.state.queue > 1)
      vim.api.nvim_echo({
        { "● [Found] ", "ModeMsg" },
        { string.format("%s:%d", target.path, target.line or 1), "Directory" },
        { target.description and (" — " .. target.description) or "", "Normal" },
      }, false, {})
    else
      -- Fallback to local grep if model offline or returned nothing
      local candidates = search_and_rank(query, root)
      if #candidates > 0 then
        local best = candidates[1]
        M.state.queue = candidates
        M.state.queue_index = 1
        jump_to_target(best)
        update_queue_display(#candidates > 1)
        vim.api.nvim_echo({
          { "● [Found (Local Fallback)] ", "ModeMsg" },
          { string.format("%s:%d", best.path, best.line), "Directory" },
          { string.format(" — %s (%d match%s)", best.description, #candidates, #candidates > 1 and "es" or ""), "Normal" },
        }, false, {})
      else
        vim.notify("No code found matching '" .. query .. "'", vim.log.levels.WARN)
      end
    end
  end)
end

--- Ask a question about the code: navigates to the exact lines that answer it,
-- proposing an in-line clarifying comment diff right above that code to make it self-documenting.
-- Never answers in conversational chat or prose.
function M.ask(question)
  question = vim.trim(question or "")
  if question == "" then
    vim.notify("Usage: :Ask <question about the code>", vim.log.levels.INFO)
    return
  end

  local root = get_root_dir()
  local candidates = search_and_rank(question, root)

  local prompt = string.format(
    "Code question: '%s'. Locate the exact source file and line answering this. In active_target.content, produce a concise, professional in-line comment (e.g. // NOTE: ... or -- NOTE: ...) right above the target line that makes the code self-documenting and directly clarifies the answer in code. Do NOT output conversational text.",
    question
  )

  vim.api.nvim_echo({ { "● [Navigating to Code] ", "ModeMsg" }, { "Locating line & preparing in-line clarification...", "Comment" } }, false, {})

  M.run(prompt, false, function(res)
    if res and res.active_target and res.active_target.path then
      local target = res.active_target
      M.state.queue = res.queue or candidates
      M.state.queue_index = 1
      jump_to_target(target)
      update_queue_display(#(M.state.queue) > 1)
      vim.api.nvim_echo({
        { "● [Code Located] ", "ModeMsg" },
        { string.format("%s:%d", target.path, target.line or 1), "Directory" },
        { target.description and (" — " .. target.description) or " (clarification previewed in-line)", "Normal" },
      }, false, {})
    elseif #candidates > 0 then
      local best = candidates[1]
      M.state.queue = candidates
      M.state.queue_index = 1
      jump_to_target(best)
      update_queue_display(#candidates > 1)
      vim.api.nvim_echo({
        { "● [Code Located (Local)] ", "ModeMsg" },
        { string.format("%s:%d", best.path, best.line), "Directory" },
        { string.format(" — %s", best.description), "Normal" },
      }, false, {})
    else
      vim.notify("Could not locate code answering: '" .. question .. "'", vim.log.levels.WARN)
    end
  end)
end

--- Get reviews directory in root and ensure .agent/ is ignored
local function get_reviews_dir(root)
  root = root or get_root_dir()
  local rdir = root .. "/.agent/reviews"
  vim.fn.mkdir(rdir, "p")
  local gi = root .. "/.gitignore"
  if vim.fn.filereadable(gi) == 1 then
    local lines = vim.fn.readfile(gi)
    local has_agent = false
    for _, l in ipairs(lines) do
      if l:find("%.agent") then has_agent = true; break end
    end
    if not has_agent then
      table.insert(lines, ".agent/")
      vim.fn.writefile(lines, gi)
    end
  end
  return rdir
end

--- Load reviews from .agent/reviews/*.json
function M.get_reviews(status_filter)
  status_filter = status_filter or "unreviewed"
  local root = get_root_dir()
  local rdir = root .. "/.agent/reviews"
  if vim.fn.isdirectory(rdir) ~= 1 then return {} end

  local files = vim.fn.globpath(rdir, "*.json", false, true)
  local reviews = {}
  for _, f in ipairs(files) do
    local ok, content = pcall(vim.fn.readfile, f)
    if ok and content then
      local j_ok, obj = pcall(vim.fn.json_decode, table.concat(content, "\n"))
      if j_ok and type(obj) == "table" and obj.id then
        if status_filter == "all" or obj.status == status_filter then
          table.insert(reviews, obj)
        end
      end
    end
  end

  table.sort(reviews, function(a, b)
    return (a.created_at or "") > (b.created_at or "")
  end)
  return reviews
end

--- Create a review record and patch on disk
function M.create_review(file_path, start_line, old_count, old_lines, new_lines, task_id, desc, status)
  status = status or "unreviewed"
  local root = get_root_dir()
  local rdir = get_reviews_dir(root)
  local ts = os.time()
  local rev_id = string.format("rev-%d-%04d", ts, math.random(1000, 9999))
  local rel_file = file_path
  if file_path:sub(1, #root) == root then
    rel_file = file_path:sub(#root + 2)
  else
    rel_file = vim.fn.fnamemodify(file_path, ":.")
  end

  -- Read current lines to build complete patch
  local all_lines = vim.fn.filereadable(file_path) == 1 and vim.fn.readfile(file_path) or {}
  local s_idx = math.max(0, start_line - 1)
  local e_idx = math.min(#all_lines, s_idx + old_count)

  -- Build unified patch
  local patch_lines = {
    "--- a/" .. rel_file,
    "+++ b/" .. rel_file,
    string.format("@@ -%d,%d +%d,%d @@", start_line, math.max(1, old_count), start_line, math.max(1, #new_lines)),
  }
  for _, l in ipairs(old_lines) do
    table.insert(patch_lines, "-" .. l)
  end
  for _, l in ipairs(new_lines) do
    table.insert(patch_lines, "+" .. l)
  end

  local patch_file = rdir .. "/" .. rev_id .. ".patch"
  vim.fn.writefile(patch_lines, patch_file)

  local meta = {
    id = rev_id,
    task_id = task_id or "task",
    target_file = rel_file,
    abs_file = vim.fn.fnamemodify(file_path, ":p"),
    start_line = start_line,
    old_lines_count = old_count,
    new_lines_count = #new_lines,
    old_lines = old_lines,
    new_lines = new_lines,
    description = desc or "",
    created_at = os.date("%Y-%m-%d %H:%M:%S"),
    status = status,
    patch_file = ".agent/reviews/" .. rev_id .. ".patch",
  }

  local meta_file = rdir .. "/" .. rev_id .. ".json"
  vim.fn.writefile({ vim.fn.json_encode(meta) }, meta_file)
  return meta
end

--- Revert review cleanly using git apply -R or line replacement
function M.revert_review(rev_id)
  local root = get_root_dir()
  local reviews = M.get_reviews("all")

  if not rev_id or rev_id == "" then
    if M.state.current_review and M.state.current_review.id then
      rev_id = M.state.current_review.id
    else
      local unrev = M.get_reviews("unreviewed")
      if #unrev > 0 then
        rev_id = unrev[1].id
      end
    end
  end

  if not rev_id then
    vim.notify("GitReview: No review to reject", vim.log.levels.WARN)
    return false
  end

  local rev = nil
  for _, r in ipairs(reviews) do
    if r.id == rev_id or (r.id and rev_id and tostring(r.id):sub(-6) == tostring(rev_id):sub(-6)) then
      rev = r
      break
    end
  end

  if not rev then
    vim.notify("GitReview: Review ID not found: " .. tostring(rev_id), vim.log.levels.WARN)
    return false
  end

  M.clear_diff(true)
  local target_full = rev.abs_file or (rev.target_file:match("^/") and rev.target_file or (root .. "/" .. rev.target_file))
  local reverted = false

  -- 1. Try git apply -R
  local patch_path = root .. "/" .. (rev.patch_file or "")
  if vim.fn.filereadable(patch_path) == 1 then
    local res = vim.system({ "git", "-C", root, "apply", "-R", patch_path }, { text = true }):wait()
    if res.code == 0 then
      reverted = true
    end
  end

  -- 2. Line-replacement fallback or reload active buffer
  local bufnr = vim.fn.bufnr(target_full)
  if bufnr and bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
    if reverted then
      vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! edit!") end)
    elseif rev.old_lines then
      local s_line = math.max(0, (rev.start_line or 1) - 1)
      local new_cnt = rev.new_lines_count or (rev.new_lines and #rev.new_lines) or 1
      local total = vim.api.nvim_buf_line_count(bufnr)
      local e_line = math.min(total, s_line + new_cnt)
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, s_line, e_line, false, rev.old_lines)
      vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! write!") end)
      reverted = true
    end
  elseif not reverted and vim.fn.filereadable(target_full) == 1 and rev.old_lines then
    local cur = vim.fn.readfile(target_full)
    local s_line = math.max(0, (rev.start_line or 1) - 1)
    local new_cnt = rev.new_lines_count or (rev.new_lines and #rev.new_lines) or 1
    local e_line = math.min(#cur, s_line + new_cnt)
    local restored = {}
    for i = 1, s_line do table.insert(restored, cur[i]) end
    for _, l in ipairs(rev.old_lines) do table.insert(restored, l) end
    for i = e_line + 1, #cur do table.insert(restored, cur[i]) end
    vim.fn.writefile(restored, target_full)
    reverted = true
  end

  -- Update review JSON
  rev.status = "rejected"
  rev.reviewed_at = os.date("%Y-%m-%d %H:%M:%S")
  local meta_path = root .. "/" .. (rev.patch_file:gsub("%.patch$", ".json"))
  if vim.fn.filereadable(meta_path) == 1 then
    vim.fn.writefile({ vim.fn.json_encode(rev) }, meta_path)
  end

  M.state.current_review = nil
  vim.notify(string.format("✗ Tasks: Reverted %s on %s!", rev.id, vim.fn.fnamemodify(target_full, ":.")), vim.log.levels.INFO)

  -- Refresh review list
  local rem = M.get_reviews("unreviewed")
  if #rem > 0 then
    M.review("list")
  else
    vim.cmd("cclose")
    vim.notify("✓ Tasks: All implementations have been reviewed by a human!", vim.log.levels.INFO)
  end
  return true
end

--- Accept review: mark as human-approved
function M.accept_review(rev_id)
  local root = get_root_dir()
  local reviews = M.get_reviews("all")

  if not rev_id or rev_id == "" then
    if M.state.current_review and M.state.current_review.id then
      rev_id = M.state.current_review.id
    else
      local unrev = M.get_reviews("unreviewed")
      if #unrev > 0 then
        rev_id = unrev[1].id
      end
    end
  end

  if not rev_id then
    vim.notify("GitReview: No review to accept", vim.log.levels.WARN)
    return false
  end

  local rev = nil
  for _, r in ipairs(reviews) do
    if r.id == rev_id or (r.id and rev_id and tostring(r.id):sub(-6) == tostring(rev_id):sub(-6)) then
      rev = r
      break
    end
  end

  if not rev then
    vim.notify("GitReview: Review ID not found: " .. tostring(rev_id), vim.log.levels.WARN)
    return false
  end

  M.clear_diff(true)
  promote_contract_to_approved(rev.filepath or rev.file, rev.task_id)
  rev.status = "accepted"
  rev.reviewed_at = os.date("%Y-%m-%d %H:%M:%S")
  local meta_path = root .. "/" .. (rev.patch_file:gsub("%.patch$", ".json"))
  if vim.fn.filereadable(meta_path) == 1 then
    vim.fn.writefile({ vim.fn.json_encode(rev) }, meta_path)
  end

  M.state.current_review = nil
  vim.notify(string.format("✓ Tasks: %s accepted and approved!", rev.id), vim.log.levels.INFO)

  -- Check and notify if this task unblocks downstream tasks
  local accepted_id = rev.task_id
  if accepted_id and accepted_id ~= "" and accepted_id ~= "task" then
    local all_tasks = scan_repository_tasks()
    for _, t in ipairs(all_tasks) do
      if t.status ~= "DONE" and t.status ~= "APPROVED" then
        local was_blocked = false
        for _, dep in ipairs(t.depends_on or {}) do
          if dep:lower() == accepted_id:lower() then
            was_blocked = true
            break
          end
        end
        if was_blocked then
          local all_met = true
          for _, dep in ipairs(t.depends_on or {}) do
            if dep:lower() ~= accepted_id:lower() then
              local dep_met = false
              for _, other in ipairs(all_tasks) do
                if other.task_id and other.task_id:lower() == dep:lower() then
                  if other.status == "DONE" or other.status == "APPROVED" then
                    dep_met = true
                  end
                  break
                end
              end
              if not dep_met then
                all_met = false
                break
              end
            end
          end
          if all_met then
            vim.notify(string.format("● [Tasks] '%s' is now UNBLOCKED and ready to start (:Tasks start %s)", t.task_id, t.task_id), vim.log.levels.INFO)
          end
        end
      end
    end
  end

  -- Refresh review list
  local rem = M.get_reviews("unreviewed")
  if #rem > 0 then
    M.review("list")
  else
    vim.cmd("cclose")
    vim.notify("✓ Tasks: All implementations have been reviewed and approved!", vim.log.levels.INFO)
  end
  return true
end

--- List all reviews in quickfix (:Tasks review)
function M.list_reviews_qf()
  local root = get_root_dir()
  local all_reviews = M.get_reviews("all")
  local unreviewed = M.get_reviews("unreviewed")

  if #all_reviews == 0 then
    local git_status = vim.trim(vim.fn.system({ "git", "-C", root, "status", "--porcelain" }))
    if git_status ~= "" then
      vim.notify("Tasks: No review records, but uncommitted Git changes exist.", vim.log.levels.INFO)
    else
      vim.notify("Tasks: No review changes recorded. Run :Tasks start to generate implementations.", vim.log.levels.INFO)
    end
    vim.cmd("cclose")
    return
  end

  local qf_list = {}
  for idx, r in ipairs(all_reviews) do
    local f = r.target_file or r.file or r.filepath or ""
    local full = (f:match("^/") and f) or (root .. "/" .. f)
    local rel_f = f:gsub("^" .. vim.pesc(root) .. "/", ""):gsub("^/+", "")
    local status_label = (r.status == "accepted") and "[APPROVED]" or ((r.status == "rejected") and "[REJECTED]" or "[PENDING]")
    local item_type = (r.status == "accepted") and "I" or ((r.status == "rejected") and "E" or "W")
    local d = vim.trim(r.description or "")
    if #d > 35 then d = d:sub(1, 32) .. "..." end
    local text = string.format("#%d %s ID: %s (%s)", idx, status_label, r.id or "unknown", r.task_id or "task")
    if d ~= "" and d ~= r.task_id then
      text = text .. " — " .. d
    end
    local bufnr = vim.fn.bufadd(full)
    table.insert(qf_list, {
      bufnr = bufnr,
      filename = rel_f,
      lnum = r.start_line or 1,
      text = text,
      type = item_type,
    })
  end

  vim.fn.setqflist(qf_list, "r")
  vim.fn.setqflist({}, "a", { title = string.format("[Tasks Review: %d pending, %d total]", #unreviewed, #all_reviews) })
  vim.cmd("botright copen 6")
  local qf_win = vim.api.nvim_get_current_win()
  local cur_w = get_primary_editor_win()
  if cur_w and vim.api.nvim_win_is_valid(cur_w) then
    setup_agent_qf_keymaps(cur_w, vim.api.nvim_win_get_buf(qf_win))
    pcall(vim.api.nvim_set_current_win, cur_w)
  end
  vim.notify(string.format("Tasks: %d pending review%s (:Tasks accept <id> | :Tasks reject <id>)", #unreviewed, #unreviewed == 1 and "" or "s"), vim.log.levels.INFO)
end

--- Display a specific review in-line
function M.show_review(rev)
  if not rev then return end
  local root = get_root_dir()
  local target_full = rev.abs_file or (rev.target_file:match("^/") and rev.target_file or (root .. "/" .. rev.target_file))
  if vim.fn.filereadable(target_full) ~= 1 then
    vim.notify("GitReview: Target file not found: " .. target_full, vim.log.levels.WARN)
    return
  end

  local bufnr = vim.fn.bufadd(target_full)
  vim.fn.bufload(bufnr)
  local origin_win = get_primary_editor_win()
  vim.api.nvim_win_set_buf(origin_win, bufnr)

  local lnum = rev.start_line or 1
  pcall(vim.api.nvim_win_set_cursor, origin_win, { lnum, 0 })
  pcall(function() vim.cmd("normal! zz") end)

  M.state.current_review = rev
  local new_content = table.concat(rev.new_lines or {}, "\n")
  local old_cnt = rev.old_lines_count or (rev.old_lines and #rev.old_lines) or 1

  M.show_inline_diff(bufnr, lnum, new_content, old_cnt, false, rev.old_lines, rev)

  vim.api.nvim_echo({
    { "● [Git Review: ", "ModeMsg" },
    { rev.id, "Directory" },
    { "] " .. (rev.description or "") .. " — :accept to approve, :reject to revert", "Normal" },
  }, false, {})
end

--- Human Review Command Dispatcher (:Tasks review [id])
function M.review(subcmd, arg)
  subcmd = (subcmd or ""):lower()
  local root = get_root_dir()

  if subcmd == "accept" or subcmd == "a" then
    local target_id = arg or (M.state.current_review and M.state.current_review.id)
    if target_id then
      M.accept_review(target_id)
    else
      vim.notify("Review: No active review to accept. Run :Tasks review to select one.", vim.log.levels.WARN)
    end
    return
  elseif subcmd == "reject" or subcmd == "r" then
    local target_id = arg or (M.state.current_review and M.state.current_review.id)
    if target_id then
      M.revert_review(target_id)
    else
      vim.notify("Review: No active review to reject. Run :Tasks review to select one.", vim.log.levels.WARN)
    end
    return
  elseif subcmd == "clear" or subcmd == "close" then
    M.clear_diff()
    M.state.current_review = nil
    vim.cmd("cclose")
    vim.notify("Review: Closed review queue", vim.log.levels.INFO)
    return
  end

  local all_reviews = M.get_reviews("all")
  local unreviewed = M.get_reviews("unreviewed")

  if #all_reviews == 0 then
    vim.notify("Tasks: No reviews recorded. Run :Tasks start to generate implementations.", vim.log.levels.INFO)
    vim.cmd("cclose")
    return
  end

  -- If user passed a specific review id or index: :Tasks review <id|index>
  if subcmd ~= "" and subcmd ~= "list" then
    local target_id = subcmd
    local num = tonumber(target_id:match("^#?(%d+)$"))
    local matched = nil
    if num and all_reviews[num] then
      matched = all_reviews[num]
    else
      for _, r in ipairs(all_reviews) do
        if r.id == target_id or (r.task_id and r.task_id:lower() == target_id:lower()) or (r.id and tostring(r.id):sub(-6) == tostring(target_id):sub(-6)) then
          matched = r
          break
        end
      end
    end
    if matched then
      M.show_review(matched)
      return
    else
      vim.notify("Tasks: Review '" .. target_id .. "' not found.", vim.log.levels.WARN)
    end
  end

  -- If exactly 1 unreviewed review exists, show it directly in the active split
  if #unreviewed == 1 then
    M.show_review(unreviewed[1])
    return
  end

  -- Otherwise list in Quickfix and show the first unreviewed review in the split
  M.list_reviews_qf()
  if #unreviewed > 0 then
    M.show_review(unreviewed[1])
  elseif #all_reviews > 0 then
    M.show_review(all_reviews[#all_reviews])
  end
end

local function is_todo_comment(line)
  if not line or type(line) ~= "string" then return false end
  return line:match("^[ \t]*[#/%-%*%\"]+%s*TODO") ~= nil or
         line:match("^[ \t]*[#/%-%*%\"]+%s*FIXME") ~= nil or
         line:match("^[ \t]*[#/%-%*%\"]+%s*SPEC%(") ~= nil or
         line:match("^[ \t]*[-*]%s*%[%s*%]") ~= nil
end

extract_task_info = function(line)
  if not line then return nil end
  local kind, inside, desc = line:match("^[ \t]*[#/%-%*%\"]+%s*(%a+)%(([^)]+)%)%s*:%s*(.*)$")
  if kind and inside then
    local parts = vim.split(inside, "%s*|%s*")
    local clean_id = vim.trim(parts[1] or "task")
    local tier = "U"
    local status = "TODO"
    local depends_on = {}
    local blocks = {}

    for _, p in ipairs(parts) do
      local t = p:match("tier:([ABCU])")
      if t then tier = t end
      local s = p:match("status:([%w_%-]+)")
      if s then status = s:upper() end
      local dep_str = p:match("depends_on:%[([^%]]+)%]")
      if dep_str then
        for d in dep_str:gmatch("[^,%s%[%]]+") do
          table.insert(depends_on, vim.trim(d))
        end
      end
      local blk_str = p:match("blocks:%[([^%]]+)%]")
      if blk_str then
        for b in blk_str:gmatch("[^,%s%[%]]+") do
          table.insert(blocks, vim.trim(b))
        end
      end
    end

    return {
      kind = kind,
      id = clean_id,
      tier = tier,
      status = status,
      depends_on = depends_on,
      blocks = blocks,
      desc = desc,
    }
  end

  local kind3, desc3 = line:match("^[ \t]*[#/%-%*%\"]+%s*(%a+)%s*:%s*(.*)$")
  if kind3 and (kind3 == "TODO" or kind3 == "FIXME" or kind3 == "SPEC") then
    return { kind = kind3, id = "task", tier = "U", status = "TODO", depends_on = {}, blocks = {}, desc = desc3 }
  end
  local kind4, desc4 = line:match("^[ \t]*[#/%-%*%\"]+%s*(%a+)%s+(.*)$")
  if kind4 and (kind4 == "TODO" or kind4 == "FIXME" or kind4 == "SPEC") then
    return { kind = kind4, id = "task", tier = "U", status = "TODO", depends_on = {}, blocks = {}, desc = desc4 }
  end
  return nil
end

scan_repository_tasks = function()
  local root = get_root_dir()
  local pattern = "(#|//|--|/\\*).*\\b(TODO|FIXME|SPEC)\\b"
  local grep_cmd = { "git", "-C", root, "grep", "-n", "-I", "-E", pattern, "--", ":!*.json*", ":!*.log", ":!*.ipynb", ":!*.olean", ":!specs/.lexlean/*", ":!logs/*" }
  local out = vim.fn.system(grep_cmd)
  if vim.v.shell_error ~= 0 or out == "" then
    local rg_bin = vim.fn.exepath("rg")
    if rg_bin ~= "" then
      local rg_cmd = { rg_bin, "-n", "--no-heading", "-e", pattern, "-g", "!*.json*", "-g", "!*.log", "-g", "!*.ipynb", "-g", "!*.olean", "-g", "!specs/.lexlean/*", "-g", "!logs/*", root }
      out = vim.fn.system(rg_cmd)
    end
  end

  local tasks = {}
  if out and out ~= "" then
    for line in out:gmatch("[^\r\n]+") do
      local rel = line:gsub("^" .. vim.pesc(root) .. "/", "")
      local fpath, lnum, txt = rel:match("^([^:]+):(%d+):(.*)$")
      if fpath and lnum and txt then
        local t_info = extract_task_info(txt)
        if t_info then
          local desc = t_info.desc
          if not desc or vim.trim(desc) == "" then
            local abs_f = (fpath:match("^/") and fpath) or (root .. "/" .. fpath)
            local l_idx = tonumber(lnum) or 1
            local ok_f, next_lines = pcall(vim.fn.readfile, abs_f, "", l_idx + 1)
            if ok_f and next_lines and #next_lines >= l_idx + 1 then
              local nxt = next_lines[l_idx + 1]
              local d = nxt:match("^[ \t]*[#/%-%*%\"]+%s*[Dd]escription:%s*(.*)$") or
                        nxt:match("^[ \t]*[#/%-%*%\"]+%s*[Dd]esc:%s*(.*)$")
              if d and vim.trim(d) ~= "" then
                desc = vim.trim(d)
              end
            end
          end
          if not desc or vim.trim(desc) == "" then
            desc = (t_info.id and t_info.id ~= "task") and t_info.id or vim.trim(txt)
          end

          table.insert(tasks, {
            file = fpath,
            line = tonumber(lnum) or 1,
            task_id = t_info.id,
            tier = t_info.tier or "U",
            status = t_info.status or "TODO",
            depends_on = t_info.depends_on or {},
            blocks = t_info.blocks or {},
            kind = t_info.kind or "TODO",
            description = desc,
            raw = txt,
          })
        end
      end
    end
  end
  return tasks
end

local function resolve_task_identifier(arg)
  arg = vim.trim(arg or "")
  if arg == "" then return nil end

  local all_tasks = scan_repository_tasks()
  table.sort(all_tasks, function(a, b)
    if (a.tier or "U") ~= (b.tier or "U") then
      return (a.tier or "U") < (b.tier or "U")
    end
    if (a.file or "") ~= (b.file or "") then
      return (a.file or "") < (b.file or "")
    end
    return (a.line or 0) < (b.line or 0)
  end)

  local num = tonumber(arg:match("^#?(%d+)$"))
  if num and all_tasks[num] then
    return all_tasks[num].task_id or all_tasks[num]
  end

  for _, t in ipairs(all_tasks) do
    if t.task_id and t.task_id:lower() == arg:lower() then
      return t.task_id
    end
  end

  return arg
end

function M.scaffold_and_run_task(instruction)
  local cur_buf = vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(cur_buf)
  local root = get_root_dir()

  if filepath == "" or vim.bo[cur_buf].buftype ~= "" then
    local spec_path = root .. "/specs/SPEC.md"
    if vim.fn.filereadable(spec_path) == 1 then
      filepath = spec_path
      cur_buf = vim.fn.bufadd(filepath)
      vim.fn.bufload(cur_buf)
      local origin_win = get_primary_editor_win()
      if origin_win and vim.api.nvim_win_is_valid(origin_win) then
        vim.api.nvim_set_current_win(origin_win)
        vim.api.nvim_win_set_buf(origin_win, cur_buf)
      end
    else
      vim.notify("Agent: Cannot scaffold task in an unnamed buffer. Please open a file first.", vim.log.levels.WARN)
      return
    end
  end

  -- Generate clean slug
  local clean = instruction:gsub("[^%w%s%-_]", "")
  local words = vim.split(vim.trim(clean), "%s+", { trimempty = true })
  local slug_parts = {}
  for i = 1, math.min(#words, 5) do
    table.insert(slug_parts, words[i]:lower())
  end
  local slug = table.concat(slug_parts, "-")
  if slug == "" then slug = "task-" .. tostring(os.time() % 10000) end

  -- Ensure unique slug
  local all_tasks = scan_repository_tasks()
  local existing = {}
  for _, t in ipairs(all_tasks) do
    if t.task_id then existing[t.task_id] = true end
  end
  local candidate = slug
  local counter = 2
  while existing[candidate] do
    candidate = slug .. "-" .. counter
    counter = counter + 1
  end
  slug = candidate

  -- Format comment line
  local ext = vim.fn.fnamemodify(filepath, ":e")
  local leader = "//"
  if ext == "lua" then
    leader = "--"
  elseif ext == "sh" or ext == "bash" or ext == "py" or ext == "yaml" or ext == "yml" or ext == "toml" then
    leader = "#"
  end

  local rel_path = vim.fn.fnamemodify(filepath, ":.")
  local stub_lines = {
    string.format("%s SPEC(%s | tier:A | status:TODO):", leader, slug),
    string.format("%s   action:    %s", leader, instruction),
    string.format("%s   requires:  []", leader),
    string.format('%s   ensures:   review "%s"', leader, instruction),
    string.format('%s   invariant: "Module interfaces and type signatures preserved"', leader),
    string.format("%s   modifies:  [%s]", leader, rel_path),
  }

  local cur_win = get_primary_editor_win()
  local cursor_line = 1
  if cur_win and vim.api.nvim_win_is_valid(cur_win) then
    cursor_line = vim.api.nvim_win_get_cursor(cur_win)[1]
  end

  local total_lines = vim.api.nvim_buf_line_count(cur_buf)
  local insert_idx = math.min(cursor_line, total_lines)
  vim.api.nvim_buf_set_lines(cur_buf, insert_idx, insert_idx, false, stub_lines)
  local target_line = insert_idx + 1

  pcall(function()
    vim.api.nvim_buf_call(cur_buf, function()
      vim.cmd("silent! write")
    end)
  end)

  if cur_win and vim.api.nvim_win_is_valid(cur_win) then
    pcall(vim.api.nvim_win_set_cursor, cur_win, { target_line, 0 })
  end

  M.reindex_tasks()

  vim.notify(string.format("Scaffolded Task [%s] at %s:%d. Executing...", slug, vim.fn.fnamemodify(filepath, ":t"), target_line), vim.log.levels.INFO)
  M.run_todo(cur_buf, target_line)
end

local function rank_tasks_by_query(tasks, query)
  local q_words = vim.split(query:lower(), "%s+", { trimempty = true })
  local scored = {}
  for _, t in ipairs(tasks) do
    local score = 0
    local tid_low = (t.task_id or ""):lower()
    local desc_low = (t.description or ""):lower()
    local file_low = (t.file or ""):lower()

    if tid_low == query:lower() then
      score = score + 100
    elseif tid_low:find(vim.pesc(query:lower())) then
      score = score + 50
    end

    if desc_low:find(vim.pesc(query:lower())) then
      score = score + 60
    end

    for _, w in ipairs(q_words) do
      if #w >= 2 then
        if tid_low:find(vim.pesc(w)) then
          score = score + 30
        elseif desc_low:find(vim.pesc(w)) then
          score = score + 20
        elseif file_low:find(vim.pesc(w)) then
          score = score + 10
        end
      end
    end

    if score > 0 then
      if t.tier == "A" then score = score + 5
      elseif t.tier == "B" then score = score + 3
      end
      table.insert(scored, { task = t, score = score })
    end
  end

  table.sort(scored, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.task.line < b.task.line
  end)

  local res = {}
  for _, item in ipairs(scored) do
    table.insert(res, item.task)
  end
  return res
end

local function parse_solution_from_raw(raw)
  if not raw or type(raw) ~= "string" or vim.trim(raw) == "" then
    return nil
  end

  -- 1. Reassemble text parts from opencode / agy streaming JSON Lines
  local full_text = ""
  for line in raw:gmatch("[^\r\n]+") do
    local ok, obj = pcall(vim.fn.json_decode, line)
    if ok and type(obj) == "table" then
      if obj.type == "text" and obj.part and obj.part.text then
        full_text = full_text .. obj.part.text
      elseif obj.response and type(obj.response) == "string" then
        full_text = full_text .. obj.response
      elseif obj.content then
        return obj
      end
    end
  end

  if full_text == "" then
    full_text = raw
  end

  -- 2. Direct JSON decode of full_text
  local ok, data = pcall(vim.fn.json_decode, vim.trim(full_text))
  if ok and type(data) == "table" and (data.content or data.code) then
    if not data.content and data.code then data.content = data.code end
    return data
  end

  -- 3. Check for ```json ... ``` code fence
  local json_block = full_text:match("```[jJ][sS][oO][nN]%s*\n(.-)\n%s*```")
  if json_block then
    local jok, jdata = pcall(vim.fn.json_decode, vim.trim(json_block))
    if jok and type(jdata) == "table" and (jdata.content or jdata.code) then
      if not jdata.content and jdata.code then jdata.content = jdata.code end
      return jdata
    end
  end

  -- 4. Delimiter-depth JSON object parser (string-literal aware)
  local s_idx = 1
  while s_idx <= #full_text do
    local b_start = full_text:find("{", s_idx, true)
    if not b_start then break end

    local depth = 0
    local in_str = false
    local escape = false
    local b_end = nil

    for i = b_start, #full_text do
      local c = full_text:sub(i, i)
      if escape then
        escape = false
      elseif c == "\\" then
        escape = true
      elseif c == '"' then
        in_str = not in_str
      elseif not in_str then
        if c == "{" then
          depth = depth + 1
        elseif c == "}" then
          depth = depth - 1
          if depth == 0 then
            b_end = i
            break
          end
        end
      end
    end

    if b_end then
      local candidate = full_text:sub(b_start, b_end)
      local cok, cdata = pcall(vim.fn.json_decode, candidate)
      if cok and type(cdata) == "table" and (cdata.content or cdata.code) then
        if not cdata.content and cdata.code then cdata.content = cdata.code end
        return cdata
      end
      s_idx = b_start + 1
    else
      break
    end
  end

  -- 5. Fallback: extract generic markdown code fence ```...``` if model wrote code directly
  local code_block = full_text:match("```[%w%-_]*%s*\n(.-)\n%s*```")
  if code_block and vim.trim(code_block) ~= "" then
    return {
      content = code_block,
      description = "Implementation from agent",
    }
  end

  return nil
end

M.parse_solution_from_raw = parse_solution_from_raw

--- Find and execute in-line TODO/FIXME task in the current buffer or repository
function M.run_todo(bufnr, target_arg)
  -- 1. If target_arg is a string query (e.g. :Tasks start normalize audio | :Tasks list)
  if type(target_arg) == "string" and vim.trim(target_arg) ~= "" and not tonumber(target_arg) then
    local query = vim.trim(target_arg)
    local all_tasks = scan_repository_tasks()
    if #all_tasks == 0 then
      vim.notify("Todo: No in-line TODO/FIXME tasks found in repository", vim.log.levels.WARN)
      return
    end

    if query:lower() == "list" or query:lower() == "all" then
      local qf = {}
      local root = get_root_dir()
      for idx, t in ipairs(all_tasks) do
        local abs_path = (t.file:match("^/") and t.file) or (root .. "/" .. t.file)
        local rel_path = t.file:gsub("^" .. vim.pesc(root) .. "/", ""):gsub("^/+", "")
        local bufnr = vim.fn.bufadd(abs_path)
        table.insert(qf, {
          bufnr = bufnr,
          filename = rel_path,
          lnum = t.line,
          text = format_task_summary(t, idx),
        })
      end
      M.state.is_tasks_list = true
      vim.fn.setqflist(qf, "r")
      vim.fn.setqflist({}, "a", { title = string.format("Tasks: %d items (%s)", #all_tasks, vim.fn.fnamemodify(root, ":t")) })
      vim.cmd("botright copen 10")
      local cur_w = get_primary_editor_win()
      local qf_win = vim.api.nvim_get_current_win()
      if cur_w and vim.api.nvim_win_is_valid(cur_w) then
        setup_agent_qf_keymaps(cur_w, vim.api.nvim_win_get_buf(qf_win))
        pcall(vim.api.nvim_set_current_win, cur_w)
      end
      vim.notify(string.format("Listed %d in-line tasks across repository.", #all_tasks), vim.log.levels.INFO)
      return
    end

    -- Exact task_id match takes absolute priority
    for _, t in ipairs(all_tasks) do
      if t.task_id and t.task_id ~= "task" and t.task_id:lower() == query:lower() then
        local root = get_root_dir()
        local full_path = root .. "/" .. t.file
        local target_buf = vim.fn.bufadd(full_path)
        vim.fn.bufload(target_buf)
        local origin_win = get_primary_editor_win()
        if origin_win and vim.api.nvim_win_is_valid(origin_win) then
          vim.api.nvim_set_current_win(origin_win)
          vim.api.nvim_win_set_buf(origin_win, target_buf)
          pcall(vim.api.nvim_win_set_cursor, origin_win, { t.line, 0 })
          pcall(function() vim.cmd("normal! zz") end)
        end

        vim.api.nvim_echo({
          { "● [Executing Task Contract: ", "ModeMsg" },
          { string.format("%s (Tier %s)", t.task_id, t.tier), "Directory" },
          { string.format("] %s in %s:%d", t.description, t.file, t.line), "Normal" },
        }, false, {})

        M.run_todo(target_buf, t.line)
        return
      end
    end

    local matches = rank_tasks_by_query(all_tasks, query)
    if #matches == 0 then
      vim.notify(string.format("Todo: No in-line TODO found matching '%s' (%d total tasks in repo)", query, #all_tasks), vim.log.levels.WARN)
      local qf = {}
      local root = get_root_dir()
      for idx, t in ipairs(all_tasks) do
        local abs_path = (t.file:match("^/") and t.file) or (root .. "/" .. t.file)
        local rel_path = t.file:gsub("^" .. vim.pesc(root) .. "/", ""):gsub("^/+", "")
        local bufnr = vim.fn.bufadd(abs_path)
        table.insert(qf, {
          bufnr = bufnr,
          filename = rel_path,
          lnum = t.line,
          text = format_task_summary(t, idx),
        })
      end
      M.state.is_tasks_list = true
      vim.fn.setqflist(qf, "r")
      vim.fn.setqflist({}, "a", { title = string.format("Tasks: %d items (none matched '%s')", #all_tasks, query) })
      vim.cmd("botright copen 10")
      local cur_w = get_primary_editor_win()
      local qf_win = vim.api.nvim_get_current_win()
      if cur_w and vim.api.nvim_win_is_valid(cur_w) then
        setup_agent_qf_keymaps(cur_w, vim.api.nvim_win_get_buf(qf_win))
        pcall(vim.api.nvim_set_current_win, cur_w)
      end
      return
    end

    local best = matches[1]
    local root = get_root_dir()
    local full_path = root .. "/" .. best.file
    local qf = {}
    for idx, t in ipairs(matches) do
      local abs_path = (t.file:match("^/") and t.file) or (root .. "/" .. t.file)
      local rel_path = t.file:gsub("^" .. vim.pesc(root) .. "/", ""):gsub("^/+", "")
      local bufnr = vim.fn.bufadd(abs_path)
      table.insert(qf, {
        bufnr = bufnr,
        filename = rel_path,
        lnum = t.line,
        text = format_task_summary(t, idx),
      })
    end
    M.state.is_tasks_list = true
    vim.fn.setqflist(qf, "r")
    vim.fn.setqflist({}, "a", { title = string.format("Tasks: %d matches for '%s'", #matches, query) })
    vim.cmd("botright copen 10")

    local target_buf = vim.fn.bufadd(full_path)
    vim.fn.bufload(target_buf)
    local origin_win = get_primary_editor_win()
    if origin_win and vim.api.nvim_win_is_valid(origin_win) then
      vim.api.nvim_set_current_win(origin_win)
      vim.api.nvim_win_set_buf(origin_win, target_buf)
      pcall(vim.api.nvim_win_set_cursor, origin_win, { best.line, 0 })
      pcall(function() vim.cmd("normal! zz") end)
    end

    vim.api.nvim_echo({
      { "● [Agent Task Contract: ", "ModeMsg" },
      { string.format("%s (Tier %s)", best.task_id, best.tier), "Directory" },
      { string.format("] %s in %s:%d", best.description, best.file, best.line), "Normal" },
    }, false, {})

    -- Execute the task at that line
    M.run_todo(target_buf, best.line)
    return
  end

  local target_line = (type(target_arg) == "number" and target_arg) or tonumber(target_arg)

  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    vim.notify("Agent: Invalid buffer", vim.log.levels.WARN)
    return
  end

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" or vim.fn.filereadable(filepath) ~= 1 then
    vim.notify("Agent: Current buffer is not a saved file on disk.", vim.log.levels.WARN)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines == 0 then
    vim.notify("Agent: Current file is empty", vim.log.levels.INFO)
    return
  end

  local cur_win = get_primary_editor_win()
  local cursor_line = 1
  if cur_win and vim.api.nvim_win_is_valid(cur_win) then
    cursor_line = vim.api.nvim_win_get_cursor(cur_win)[1]
  end

  local chosen_line = nil
  local chosen_desc = nil
  local old_lines_count = 1

  -- 1. Check if user specified target_line
  if target_line and target_line > 0 and target_line <= #lines then
    if is_todo_comment(lines[target_line]) then
      chosen_line = target_line
    else
      local preview = vim.trim(lines[target_line] or "")
      vim.notify(string.format("Agent: Line %d in %s is not a TODO comment: '%s'", target_line, vim.fn.fnamemodify(filepath, ":t"), preview:sub(1, 40)), vim.log.levels.WARN)
      return
    end
  -- 2. Check if cursor line is a TODO comment
  elseif lines[cursor_line] and is_todo_comment(lines[cursor_line]) then
    chosen_line = cursor_line
  else
    -- 3. Search forward from cursor
    for i = cursor_line, #lines do
      if is_todo_comment(lines[i]) then
        chosen_line = i
        break
      end
    end
    -- 4. Search from top of file
    if not chosen_line then
      for i = 1, cursor_line - 1 do
        if is_todo_comment(lines[i]) then
          chosen_line = i
          break
        end
      end
    end
  end

  -- If NO TODO comment was found in current file:
  -- DO NOT randomly jump to another file!
  if not chosen_line then
    local file_basename = vim.fn.fnamemodify(filepath, ":t")
    vim.notify(string.format("Agent: No in-line TODO/FIXME comments found in '%s'.", file_basename), vim.log.levels.INFO)

    local all_tasks = scan_repository_tasks()
    if #all_tasks > 0 then
      local root = get_root_dir()
      local qf = {}
      for idx, t in ipairs(all_tasks) do
        local abs_path = (t.file:match("^/") and t.file) or (root .. "/" .. t.file)
        local rel_path = t.file:gsub("^" .. vim.pesc(root) .. "/", ""):gsub("^/+", "")
        local bufnr = vim.fn.bufadd(abs_path)
        table.insert(qf, {
          bufnr = bufnr,
          filename = rel_path,
          lnum = t.line,
          text = format_task_summary(t, idx),
        })
      end
      M.state.is_tasks_list = true
      vim.fn.setqflist(qf, "r")
      vim.fn.setqflist({}, "a", { title = string.format("Tasks: %d items (%s)", #all_tasks, vim.fn.fnamemodify(root, ":t")) })
      vim.cmd("botright copen 10")
      local qf_win = vim.api.nvim_get_current_win()
      if cur_win and vim.api.nvim_win_is_valid(cur_win) then
        setup_agent_qf_keymaps(cur_win, vim.api.nvim_win_get_buf(qf_win))
        pcall(vim.api.nvim_set_current_win, cur_win)
      end
      vim.notify(string.format("Opened task list (%d tasks pending in repository). Select one or use ':Tasks start <id>'.", #all_tasks), vim.log.levels.INFO)
    else
      vim.notify("No in-line TODO/FIXME contracts found in repository.", vim.log.levels.INFO)
    end
    return
  end

  local raw_header = lines[chosen_line]
  chosen_desc = raw_header:gsub("^[ \t]*[#/%-]+%s*", "")

  -- Count multi-line task comments (Description, Criterion, action, requires, etc.)
  local j = chosen_line + 1
  while j <= #lines do
    local l = vim.trim(lines[j])
    if l:find("^[#/%-]+%s*[Dd]escription:")
      or l:find("^[#/%-]+%s*[Cc]riterion:")
      or l:find("^[#/%-]+%s*action:")
      or l:find("^[#/%-]+%s*requires:")
      or l:find("^[#/%-]+%s*ensures:")
      or l:find("^[#/%-]+%s*invariant:")
      or l:find("^[#/%-]+%s*modifies:")
      or l:find("^[#/%-]+%s*status:")
      or l:find("^[#/%-]+%s*%[lean:spec%]")
      or l:find("^[#/%-]+%s*def%s+")
      or l:find("^[#/%-]+%s*theorem%s+")
      or l:find("^[#/%-]+%s*inductive%s+")
      or l:find("^[#/%-]+%s*structure%s+")
      or l:find("^[#/%-]+%s*|%s+")
      or l:find("^[#/%-]+%s*[-*]")
    then
      old_lines_count = old_lines_count + 1
      chosen_desc = chosen_desc .. " " .. l:gsub("^[#/%-]+%s*", "")
      j = j + 1
    else
      break
    end
  end

  if cur_win and vim.api.nvim_win_is_valid(cur_win) then
    pcall(vim.api.nvim_win_set_cursor, cur_win, { chosen_line, 0 })
    vim.cmd("normal! zz")
  end

  local file_basename = vim.fn.fnamemodify(filepath, ":t")
  vim.api.nvim_echo({
    { "● [Agent] ", "ModeMsg" },
    { string.format("%s:%d", file_basename, chosen_line), "Directory" },
    { string.format(" Implementing in-line task (%s)...", chosen_desc:sub(1, 40)), "Comment" },
  }, false, {})
  vim.cmd("redraw")

  local rel_path = vim.fn.fnamemodify(filepath, ":.")
  local numbered_lines = {}
  local total_lines = #lines
  local context_start = 1
  local context_end = total_lines
  if total_lines > 120 then
    context_start = math.max(1, chosen_line - 40)
    context_end = math.min(total_lines, chosen_line + 60)
  end
  for idx = context_start, context_end do
    table.insert(numbered_lines, string.format("%d: %s", idx, lines[idx]))
  end
  local code_section = table.concat(numbered_lines, "\n")

  -- Scan for in-line revision critique comments within the target function/block
  local critiques = {}
  if raw_header:find("status:REVISE") or raw_header:find("REVISE") then
    -- Task was marked as revise
  end

  local scan_end = math.min(#lines, chosen_line + 40)
  for k = chosen_line + 1, scan_end do
    local l = vim.trim(lines[k])
    if l:match("^[#/%-]+%s*[A-Z]+%(") then
      break
    end
    local c_text = l:match("^[#/%-]+%s*[Rr][Ee][Vv][Ii][Ss][Ee]:%s*(.*)$")
      or l:match("^[#/%-]+%s*[Cc][Rr][Ii][Tt][Ii][Qq][Uu][Ee]:%s*(.*)$")
      or l:match("^[#/%-]+%s*[Ff][Ii][Xx]:%s*(.*)$")
      or l:match("^[#/%-]+%s*[Nn][Oo][Tt][Ee]:%s*(.*)$")
    if c_text and vim.trim(c_text) ~= "" then
      table.insert(critiques, vim.trim(c_text))
    end
  end

  local critique_section = ""
  if #critiques > 0 then
    local crit_lines = {}
    for _, c in ipairs(critiques) do
      table.insert(crit_lines, "• " .. c)
    end
    critique_section = string.format([[

USER IN-LINE REVISION CRITIQUES (MUST BE ADDRESSED):
%s

CRITICAL REVISION INSTRUCTION:
The user reviewed the previous implementation and left the in-line critique notes above.
You MUST update the implementation to satisfy all of these critiques.
Do NOT retain the temporary critique comments (e.g. # REVISE:, # CRITIQUE:) in your replacement output.
]], table.concat(crit_lines, "\n"))
  end

  local prompt = string.format([[You are a direct code generator assistant. Do NOT call any tools, do NOT run bash commands or tests, and do NOT read other files.
Generate the replacement code for the following in-line task directly and return strict JSON immediately.

TARGET FILE: %s
TASK: %s
DESCRIPTION: %s
TARGET LINE: %d (replaces lines %d to %d)%s

SURROUNDING SOURCE CODE (with 1-based line numbers):
%s

RULES:
1. Provide the complete, working, production-quality implementation to replace the TODO comment.
2. Maintain existing indentation, variable names, type signatures, and import patterns.
3. Do NOT include placeholder comments or ellipsis; write fully verified implementation.
4. Output STRICT JSON ONLY matching this schema:
{
  "start_line": %d,
  "old_lines_count": %d,
  "content": "<exact replacement code lines without line number prefixes>",
  "description": "<one-line summary of what was implemented>"
}
Emit ONLY raw JSON. No markdown code blocks, no prose before or after.
]], rel_path, raw_header, chosen_desc, chosen_line, chosen_line, chosen_line + old_lines_count - 1,
    critique_section, code_section, chosen_line, old_lines_count)

  local agy_bin = vim.fn.exepath("agy")
  local opencode_bin = vim.fn.exepath("opencode")
  local cmd = {}

  if agy_bin ~= "" then
    cmd = { agy_bin, "-p", prompt, "--model", "Gemini 3.8 Flash (Low)", "--dangerously-skip-permissions", "--disable-slash-commands" }
  elseif opencode_bin ~= "" then
    cmd = { opencode_bin, "run", "--format", "json", prompt }
  else
    vim.notify("Agent: Neither 'agy' nor 'opencode' found in PATH", vim.log.levels.ERROR)
    return
  end

  M.state.is_busy = true
  if M.state.active_job then
    pcall(function() M.state.active_job:kill(9) end)
    M.state.active_job = nil
  end

  local stdout_chunks = {}
  local job_timeout = vim.uv.new_timer()
  job_timeout:start(45000, 0, vim.schedule_wrap(function()
    if M.state.active_job then
      vim.notify("Agent: Task execution timed out after 45s. Cancelled.", vim.log.levels.WARN)
      pcall(function() M.state.active_job:kill(9) end)
      M.state.active_job = nil
      M.state.is_busy = false
    end
    if job_timeout then
      pcall(function() job_timeout:stop(); job_timeout:close() end)
      job_timeout = nil
    end
  end))

  M.state.active_job = vim.system(cmd, { text = true, stdout = function(_, data)
    if data then table.insert(stdout_chunks, data) end
  end }, vim.schedule_wrap(function(res)
    M.state.active_job = nil
    M.state.is_busy = false
    if job_timeout then
      pcall(function() job_timeout:stop(); job_timeout:close() end)
      job_timeout = nil
    end

    local raw = table.concat(stdout_chunks, "")
    local solution = parse_solution_from_raw(raw)

    if not solution or not solution.content then
      vim.notify("Agent: Could not parse implementation for task", vim.log.levels.WARN)
      return
    end

    local start_lnum = tonumber(solution.start_line) or chosen_line
    local old_cnt = tonumber(solution.old_lines_count) or old_lines_count
    local new_content = solution.content
    local new_lines = vim.split(new_content, "\n")

    -- Extract original lines before modification
    local total = vim.api.nvim_buf_line_count(bufnr)
    local s_idx = math.max(0, start_lnum - 1)
    local e_idx = math.min(total, s_idx + old_cnt)
    local orig_slice = vim.api.nvim_buf_get_lines(bufnr, s_idx, e_idx, false)

    new_lines = ensure_contract_preserved_as_done(orig_slice, new_lines)
    new_content = table.concat(new_lines, "\n")

    -- Apply changes to buffer and save to file so code runs/inspects immediately
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, s_idx, e_idx, false, new_lines)
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! write") end)

    -- Create review record and patch on disk marked UNREVIEWED
    local rev = M.create_review(filepath, start_lnum, old_cnt, orig_slice, new_lines, raw_header, solution.description or chosen_desc, "unreviewed")
    M.state.current_review = rev

    M.show_inline_diff(bufnr, start_lnum, new_content, old_cnt, false, orig_slice, rev)
    vim.api.nvim_echo({
      { "● [Git Review Pending: ", "ModeMsg" },
      { rev.id, "Directory" },
      { "] Applied to " .. file_basename .. " — :accept to approve, :reject to revert", "Comment" },
    }, false, {})
  end))
end

--- Execute task from a specified file (code file with TODO or task description file)
function M.run_file(file_arg)
  file_arg = vim.trim(file_arg or "")
  if file_arg == "" then
    vim.notify("Usage: :Tasks start <path/to/file>", vim.log.levels.INFO)
    return
  end
  local root = get_root_dir()
  local full = file_arg:match("^/") and file_arg or (root .. "/" .. file_arg)
  if vim.fn.filereadable(full) ~= 1 then
    vim.notify("Agent file: File not found: " .. file_arg, vim.log.levels.WARN)
    return
  end
  local bufnr = vim.fn.bufadd(full)
  vim.fn.bufload(bufnr)
  local origin_win = get_primary_editor_win()
  vim.api.nvim_win_set_buf(origin_win, bufnr)
  M.run_todo(bufnr, 1)
end

--- Display a centered, minimalist floating window showing all synvim commands and keybindings
local function show_help()
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
    "  <Esc>                  Dismiss diff view",
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

function M.setup()
  setup_highlights()

  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "TermEnter", "TermOpen" }, {
    callback = function(args)
      local buf = args.buf
      if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
      local bt = vim.bo[buf].buftype
      if bt == "terminal" then
        local cwd = get_terminal_cwd(buf)
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
        end
      end
    end,
    desc = "Track active directory across terminal and editor splits",
  })

  vim.api.nvim_create_autocmd("FileType", {
    pattern = "qf",
    callback = function(args)
      local origin = M.state.origin_win or get_primary_editor_win()
      setup_agent_qf_keymaps(origin, args.buf)
    end,
    desc = "Route quickfix jumps directly into calling split without splitting",
  })

  local function task_id_complete(arglead, cmdline)
    local all_tasks = scan_repository_tasks()
    local completions = {}
    local seen = {}
    local idx_data = load_task_index()
    if idx_data and idx_data.index_to_id then
      for i = 1, #all_tasks do
        local istr = tostring(i)
        if idx_data.index_to_id[istr] then
          table.insert(completions, istr)
        end
      end
    end
    for _, t in ipairs(all_tasks) do
      if t.task_id and t.task_id ~= "task" and not seen[t.task_id] then
        seen[t.task_id] = true
        table.insert(completions, t.task_id)
      end
    end
    return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, completions)
  end

  --- Get comment leader for a given file extension
  local function get_comment_leader(filepath)
    local ext = vim.fn.fnamemodify(filepath, ":e"):lower()
    if ext == "py" or ext == "sh" or ext == "bash" or ext == "yaml" or ext == "yml" or ext == "toml" or ext == "rb" then
      return "#"
    elseif ext == "lua" or ext == "lean" or ext == "hs" or ext == "sql" then
      return "--"
    else
      return "//"
    end
  end

  --- Add an in-line task at the cursor position in active buffer or specified target file
  function M.add_task(arg_str, win)
    win = win or get_primary_editor_win()
    arg_str = vim.trim(arg_str or "")
    if arg_str == "" then
      vim.ui.input({ prompt = "Task description: " }, function(input)
        if input and vim.trim(input) ~= "" then
          M.add_task(input, win)
        end
      end)
      return
    end

    local bufnr = vim.api.nvim_win_get_buf(win)
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    local cur_line = vim.api.nvim_win_get_cursor(win)[1]

    -- Check if user specified a file:line in arg (e.g. :Task add src/main.rs:10 description)
    local file_arg, line_arg, desc_arg = arg_str:match("^([^%s:]+):(%d+)%s+(.*)$")
    if file_arg and line_arg and desc_arg then
      local root = get_root_dir()
      local full = file_arg:match("^/") and file_arg or (root .. "/" .. file_arg)
      local tbuf = vim.fn.bufadd(full)
      vim.fn.bufload(tbuf)
      bufnr = tbuf
      filepath = full
      cur_line = tonumber(line_arg) or 1
      arg_str = desc_arg
    else
      local f_arg, d_arg = arg_str:match("^([^%s]+%.[%w]+)%s+(.*)$")
      if f_arg and d_arg then
        local root = get_root_dir()
        local full = f_arg:match("^/") and f_arg or (root .. "/" .. f_arg)
        local tbuf = vim.fn.bufadd(full)
        vim.fn.bufload(tbuf)
        bufnr = tbuf
        filepath = full
        cur_line = 1
        arg_str = d_arg
      end
    end

    if not filepath or filepath == "" or vim.bo[bufnr].buftype ~= "" then
      vim.notify("Error: No active editable file. Specify a file path: :Add <file> <description>", vim.log.levels.ERROR)
      return
    end

    local leader = get_comment_leader(filepath)
    local indent = ""
    local total_lines = vim.api.nvim_buf_line_count(bufnr)
    if cur_line <= total_lines and cur_line > 0 then
      local line_content = vim.api.nvim_buf_get_lines(bufnr, cur_line - 1, cur_line, false)[1] or ""
      indent = line_content:match("^(%s*)") or ""
    end

    local slug = arg_str:lower():gsub("[^%a0-9%s_-]", ""):gsub("%s+", "-"):sub(1, 32):gsub("%-+$", "")
    if slug == "" then slug = "task" end

    local task_line_str = string.format("%s%s TODO(%s): %s", indent, leader, slug, arg_str)
    local insert_idx = math.max(0, cur_line - 1)
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, insert_idx, insert_idx, false, { task_line_str })
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! write") end)

    local new_line_num = insert_idx + 1
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_buf(win, bufnr)
      pcall(vim.api.nvim_win_set_cursor, win, { new_line_num, #indent })
      vim.api.nvim_win_call(win, function() vim.cmd("normal! zz") end)
      local ns = vim.api.nvim_create_namespace("agent_jump_flash")
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      vim.api.nvim_buf_add_highlight(bufnr, ns, "IncSearch", new_line_num - 1, 0, -1)
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
        end
      end, 1000)
    end

    local rel_path = vim.fn.fnamemodify(filepath, ":.")
    local root = get_root_dir()
    local dup_notice = ""
    local dup_candidates = search_and_rank(arg_str, root)
    if #dup_candidates > 0 and dup_candidates[1].score >= 260 then
      dup_notice = string.format(" [Note: '%s' exists in %s:%d]", dup_candidates[1].description, dup_candidates[1].path, dup_candidates[1].line)
    end

    vim.api.nvim_echo({
      { "● [Task Added] ", "ModeMsg" },
      { string.format("%s:%d", rel_path, new_line_num), "Directory" },
      { string.format(" — %s%s (Run :Tasks start to implement)", task_line_str:gsub("^%s*", ""), dup_notice), "Normal" },
    }, false, {})
  end

  function M.start_task(raw)
    M.state.origin_win = get_primary_editor_win()
    raw = vim.trim(raw or "")

    -- If called without arguments: execute closest in-line task visible in the current window
    if raw == "" then
      local win = get_primary_editor_win()
      local bufnr = vim.api.nvim_win_get_buf(win)
      if vim.bo[bufnr].buftype ~= "" then
        vim.notify("Tasks: Active split is not an editable file.", vim.log.levels.ERROR)
        return
      end

      local w0 = vim.fn.line("w0", win)
      local w_dollar = vim.fn.line("w$", win)
      local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
      local lines = vim.api.nvim_buf_get_lines(bufnr, w0 - 1, w_dollar, false)

      local best_line = nil
      local best_dist = 999999
      local best_text = nil

      for idx, l in ipairs(lines) do
        local actual_line = (w0 - 1) + idx
        local has_task = l:find("%f[%a]TODO%f[%A]") or l:find("%f[%a]FIXME%f[%A]") or l:find("%f[%a]SPEC%f[%A]")
        local is_comment = l:find("^%s*//") or l:find("^%s*#") or l:find("^%s*%-%-") or l:find("^%s*/%*")
        if has_task and is_comment then
          local dist = math.abs(actual_line - cursor_line)
          if dist < best_dist then
            best_dist = dist
            best_line = actual_line
            best_text = l
          end
        end
      end

      if not best_line then
        vim.notify(string.format("Tasks: No in-line task (TODO/FIXME/SPEC) visible in current window (lines %d–%d). Specify task: :Tasks start <id>", w0, w_dollar), vim.log.levels.ERROR)
        return
      end

      -- Check dependencies for closest visible task
      local t_info = extract_task_info(best_text)
      if t_info and t_info.depends_on and #t_info.depends_on > 0 then
        local all_tasks = scan_repository_tasks()
        for _, dep_id in ipairs(t_info.depends_on) do
          local dep_status = "NOT_FOUND"
          for _, ot in ipairs(all_tasks) do
            if ot.task_id and ot.task_id:lower() == dep_id:lower() then
              dep_status = ot.status or "TODO"
              break
            end
          end
          if dep_status ~= "DONE" and dep_status ~= "APPROVED" then
            vim.notify(string.format("⚠ [Tasks] Dependency warning: '%s' depends on '%s' (status: %s)", t_info.id or "task", dep_id, dep_status), vim.log.levels.WARN)
          end
        end
      end

      -- Jump to the visible task line, center, flash, and execute
      vim.api.nvim_win_set_cursor(win, { best_line, 0 })
      vim.cmd("normal! zz")
      local ns = vim.api.nvim_create_namespace("agent_jump_flash")
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      vim.api.nvim_buf_add_highlight(bufnr, ns, "IncSearch", best_line - 1, 0, -1)
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
        end
      end, 1000)

      vim.api.nvim_echo({
        { "● [Executing Closest Visible Task] ", "ModeMsg" },
        { string.format("Line %d: %s", best_line, vim.trim(best_text)), "Normal" },
      }, false, {})

      M.run_todo(bufnr, best_line)
      return
    end

    local resolved_id = resolve_task_identifier(raw)
    local all_tasks = scan_repository_tasks()
    local matched_task = nil
    for _, t in ipairs(all_tasks) do
      if t.task_id and t.task_id ~= "task" and t.task_id:lower() == resolved_id:lower() then
        matched_task = t
        break
      end
    end

    if matched_task then
      -- Check dependencies
      if matched_task.depends_on and #matched_task.depends_on > 0 then
        for _, dep_id in ipairs(matched_task.depends_on) do
          local dep_status = "NOT_FOUND"
          for _, ot in ipairs(all_tasks) do
            if ot.task_id and ot.task_id:lower() == dep_id:lower() then
              dep_status = ot.status or "TODO"
              break
            end
          end
          if dep_status ~= "DONE" and dep_status ~= "APPROVED" then
            vim.notify(string.format("⚠ [Tasks] Dependency warning: '%s' depends on '%s' (status: %s)", matched_task.task_id, dep_id, dep_status), vim.log.levels.WARN)
          end
        end
      end

      local root = get_root_dir()
      local full_path = (matched_task.file:sub(1, 1) == "/") and matched_task.file or (root .. "/" .. matched_task.file)
      local target_buf = vim.fn.bufadd(full_path)
      vim.fn.bufload(target_buf)
      local origin_win = get_primary_editor_win()
      if origin_win and vim.api.nvim_win_is_valid(origin_win) then
        vim.api.nvim_set_current_win(origin_win)
        vim.api.nvim_win_set_buf(origin_win, target_buf)
        pcall(vim.api.nvim_win_set_cursor, origin_win, { matched_task.line, 0 })
        pcall(function() vim.cmd("normal! zz") end)
      end
      vim.api.nvim_echo({
        { "● [Executing Task Contract: ", "ModeMsg" },
        { string.format("%s (Tier %s)", matched_task.task_id, matched_task.tier), "Directory" },
        { string.format("] %s in %s:%d", matched_task.description, matched_task.file, matched_task.line), "Normal" },
      }, false, {})
      M.run_todo(target_buf, matched_task.line)
      return
    end

    if raw:match("^#?%d+$") then
      vim.notify(string.format("Tasks: Task index '%s' not found. Run :Tasks to view available tasks.", raw), vim.log.levels.WARN)
      return
    end

    M.scaffold_and_run_task(raw)
  end

  local function tasks_complete(arglead, cmdline)
    local parts = vim.split(vim.trim(cmdline), "%s+")
    local has_trailing = cmdline:match("%s+$") ~= nil
    local subcmds = { "list", "add", "start", "stop", "review", "accept", "reject", "revise" }

    if #parts == 1 or (#parts == 2 and not has_trailing) then
      return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, subcmds)
    end

    local sub = (parts[2] or ""):lower()
    if sub == "start" or sub == "revise" then
      local ids = {}
      local all_tasks = scan_repository_tasks()
      for idx, t in ipairs(all_tasks) do
        if t.task_id and t.task_id ~= "task" then
          table.insert(ids, t.task_id)
        end
        table.insert(ids, tostring(idx))
      end
      return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, ids)
    elseif sub == "accept" or sub == "reject" then
      local ids = {}
      local reviews = M.get_reviews("all")
      for idx, r in ipairs(reviews) do
        if r.id then table.insert(ids, r.id) end
        if r.task_id and r.task_id ~= "task" then table.insert(ids, r.task_id) end
        table.insert(ids, tostring(idx))
      end
      return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, ids)
    end

    return {}
  end

  function M.tasks_command(args)
    args = vim.trim(args or "")
    local parts = vim.split(args, "%s+", { trimempty = true })
    local subcmd = (parts[1] or ""):lower()
    local rest = table.concat(vim.list_slice(parts, 2), " ")

    if subcmd == "" or subcmd == "list" then
      local qf_open = false
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].buftype == "quickfix" then
          qf_open = true
          break
        end
      end
      if qf_open and subcmd == "" then
        vim.cmd("cclose")
      else
        M.show_tasks()
      end
    elseif subcmd == "add" then
      M.add_task(rest, vim.api.nvim_get_current_win())
    elseif subcmd == "start" then
      M.start_task(rest)
    elseif subcmd == "stop" then
      M.stop()
      M.clear_diff()
      vim.notify("Tasks: Execution stopped and diff previews cleared.", vim.log.levels.INFO)
    elseif subcmd == "review" then
      M.review(rest)
    elseif subcmd == "accept" then
      M.accept(rest)
    elseif subcmd == "reject" then
      M.reject(rest)
    elseif subcmd == "revise" then
      M.revise_task(rest)
    else
      vim.notify(string.format("Tasks: Unknown subcommand '%s'. Available: list, add, start, stop, review, accept, reject, revise", subcmd), vim.log.levels.WARN)
    end
  end

  -- Unified :Tasks command
  vim.api.nvim_create_user_command("Tasks", function(ctx)
    M.tasks_command(ctx.args)
  end, {
    nargs = "*",
    complete = tasks_complete,
    desc = "Unified tasks manager (:Tasks [list|add|start|stop|review|accept|reject|revise])",
  })

  vim.api.nvim_create_user_command("Find", function(ctx)
    M.state.origin_win = vim.api.nvim_get_current_win()
    M.find(ctx.args)
  end, { nargs = "*", desc = "Semantic code search across repository with LLM (:Find <concept>)" })

  vim.api.nvim_create_user_command("Ask", function(ctx)
    M.state.origin_win = vim.api.nvim_get_current_win()
    M.ask(ctx.args)
  end, { nargs = "+", desc = "Ask a question about the code: navigates to exact line with clarifying in-line comment (:Ask <question>)" })

  -- If :Git command does not exist, provide basic :Git with review support
  if vim.fn.exists(":Git") ~= 2 then
    vim.api.nvim_create_user_command("Git", function(ctx)
      local parts = vim.split(vim.trim(ctx.args or ""), "%s+", { trimempty = true })
      if parts[1] == "review" then
        M.list_reviews_qf()
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
    local arg = vim.trim(ctx.args or ""):lower()
    if arg == "help" or arg == "" then
      show_help()
    else
      vim.notify("synvim: Unknown argument '" .. ctx.args .. "'. Run :Synvim help for usage.", vim.log.levels.WARN)
    end
  end, {
    nargs = "?",
    complete = function(arglead, cmdline)
      return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, { "help" })
    end,
    desc = "Show synvim commands and usage (:Synvim help)",
  })

  -- Enable native lowercase command abbreviations
  pcall(vim.cmd, [[
    cnoreabbrev <expr> tasks (getcmdtype() ==# ':' && getcmdline() ==# 'tasks') ? 'Tasks' : 'tasks'
    cnoreabbrev <expr> ask (getcmdtype() ==# ':' && getcmdline() ==# 'ask') ? 'Ask' : 'ask'
    cnoreabbrev <expr> find (getcmdtype() ==# ':' && getcmdline() ==# 'find') ? 'Find' : 'find'
    cnoreabbrev <expr> synvim (getcmdtype() ==# ':' && getcmdline() ==# 'synvim') ? 'Synvim' : 'synvim'
  ]])

  M.get_root_dir = get_root_dir
  M.collect_context = collect_context
  M.search_and_rank = search_and_rank
  M.find = M.find
  M.ask = M.ask
  M.add_task = M.add_task
  M.review = M.review
  M.git_review = M.review
  M.review_command = M.review
  M.reindex = M.reindex_tasks
  M.show_help = show_help
  M.help = show_help
  M.tasks = M.show_tasks
  M.show_tasks = M.show_tasks
  M.scan_repository_tasks = scan_repository_tasks
end

M.get_root_dir = get_root_dir
M.collect_context = collect_context
M.search_and_rank = search_and_rank
M.find = M.find
M.ask = M.ask
M.add_task = M.add_task
M.review = M.review
M.git_review = M.review
M.review_command = M.review
M.reindex = M.reindex_tasks
M.scaffold_and_run_task = M.scaffold_and_run_task
M.show_help = show_help
M.help = show_help
M.tasks = M.show_tasks
M.show_tasks = M.show_tasks
M.scan_repository_tasks = scan_repository_tasks

return M
