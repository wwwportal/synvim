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

local py_bin = vim.fn.expand("~/myenv/bin/python")
local transcribe_script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h") .. "/bin/agent_transcribe.py"
if vim.fn.filereadable(transcribe_script) ~= 1 then
  transcribe_script = vim.fn.expand("/home/yassine/code/syn-nvim/bin/agent_transcribe.py")
end

local process_agent_response = nil
local update_queue_display = nil
local jump_to_target = nil
local setup_agent_qf_keymaps = nil

local function setup_highlights()
  local is_dark = (vim.o.background == "dark")
  if is_dark then
    vim.api.nvim_set_hl(0, "AgentDiffAdd", { bg = "#163b22", default = false })
    vim.api.nvim_set_hl(0, "AgentDiffAddSign", { fg = "#85e89d", bold = true, default = false })
    vim.api.nvim_set_hl(0, "AgentDiffDelete", { fg = "#ff7b72", bg = "#490202", strikethrough = true, ctermfg = "Red", default = false })
    vim.api.nvim_set_hl(0, "AgentDiffHeader", { fg = "#c9d1d9", bg = "#21262d", bold = true, ctermfg = "White", ctermbg = "DarkGray", default = false })
    vim.api.nvim_set_hl(0, "AgentDiffFooter", { fg = "#8b949e", bg = "#161b22", bold = true, ctermfg = "Gray", default = false })
    vim.api.nvim_set_hl(0, "AgentDiffMenuSel", { fg = "#ffffff", bg = "#238636", bold = true, ctermfg = "White", ctermbg = "DarkGreen", default = false })
    vim.api.nvim_set_hl(0, "AgentDiffMenuBtn", { fg = "#8b949e", bg = "#161b22", ctermfg = "LightGray", ctermbg = "Black", default = false })
  else
    vim.api.nvim_set_hl(0, "AgentDiffAdd", { bg = "#d4edda", default = false })
    vim.api.nvim_set_hl(0, "AgentDiffAddSign", { fg = "#0e6b0e", bold = true, default = false })
    vim.api.nvim_set_hl(0, "AgentDiffDelete", { fg = "#b31d28", bg = "#f8d7da", strikethrough = true, ctermfg = "DarkRed", ctermbg = "LightRed", default = false })
    vim.api.nvim_set_hl(0, "AgentDiffHeader", { fg = "#ffffff", bg = "#2d3748", bold = true, ctermfg = "White", ctermbg = "DarkGray", default = false })
    vim.api.nvim_set_hl(0, "AgentDiffFooter", { fg = "#57606a", bg = "#f6f8fa", bold = true, default = false })
    vim.api.nvim_set_hl(0, "AgentDiffMenuSel", { fg = "#ffffff", bg = "#0969da", bold = true, ctermfg = "White", ctermbg = "Blue", default = false })
    vim.api.nvim_set_hl(0, "AgentDiffMenuBtn", { fg = "#24292f", bg = "#eaeef2", ctermfg = "Black", ctermbg = "LightGray", default = false })
  end
  pcall(vim.api.nvim_set_hl, 0, "GitReviewAdd", { link = "AgentDiffAdd", default = true })
  pcall(vim.api.nvim_set_hl, 0, "GitReviewDelete", { link = "AgentDiffDelete", default = true })
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

--- Locate native lgcc Rust binary
local function find_lgcc_bin()
  local exepath = vim.fn.exepath("lgcc")
  if exepath ~= "" and vim.fn.executable(exepath) == 1 then
    return exepath
  end
  local candidates = {
    vim.fn.expand("~/code/syn-nvim/bin/lgcc"),
    vim.fn.expand("~/.local/bin/lgcc"),
    vim.fn.expand("~/.config/nvim/bin/lgcc"),
    "/usr/local/bin/lgcc",
  }
  for _, p in ipairs(candidates) do
    if vim.fn.executable(p) == 1 then return p end
  end
  return nil
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
        vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! write") end)
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

--- Revise instruction in natural language
function M.write_revision()
  M.clear_diff()
  local input = vim.fn.input({
    prompt = "● [Agent] Revise instruction (type or 'listen'): ",
    cancelreturn = "__CANCEL__",
  })
  if input ~= "__CANCEL__" and vim.trim(input) ~= "" then
    if vim.trim(input) == "listen" then
      M.record_voice(function(prompt) M.run(prompt, true) end)
    else
      M.run(input, true)
    end
  end
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
--- No duplicate floating lines!
function M.show_inline_diff(bufnr, target_line, new_content, old_lines_count, is_new_file, old_lines, review_meta)
  M.clear_diff()
  setup_highlights()

  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if type(new_content) ~= "string" or vim.trim(new_content) == "" then return end

  local origin_win = get_primary_editor_win()
  if vim.api.nvim_win_is_valid(origin_win) then
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

  -- If not already applied to buffer, apply new_lines in-place so additions are truly in-line
  if not already_applied then
    local e_idx = math.min(total_lines, s_idx + old_lines_count)
    revert_lines = vim.api.nvim_buf_get_lines(bufnr, s_idx, e_idx, false)
    local was_mod = vim.bo[bufnr].modifiable
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, s_idx, e_idx, false, new_lines)
    vim.bo[bufnr].modifiable = was_mod
  end

  local win_w = (origin_win and vim.api.nvim_win_is_valid(origin_win)) and vim.api.nvim_win_get_width(origin_win) or 80
  local max_w = math.max(35, win_w - 6)

  local task_name = (review_meta and (review_meta.task_id or review_meta.id))
    or (is_new_file and "New File" or "Task")
  local header_label = string.format(" Git Review: %s ", task_name)
  local bar_len = math.max(4, max_w - #header_label - 4)
  local header_text = "┌──" .. header_label .. string.rep("─", bar_len) .. "┐"
  if #header_text > max_w then
    header_text = header_text:sub(1, max_w - 1) .. "┐"
  end

  local footer_text = "└── :GitReview accept (<Leader>a) | reject (<Leader>r) " .. string.rep("─", math.max(2, max_w - 55)) .. "┘"
  if #footer_text > max_w then
    footer_text = footer_text:sub(1, max_w - 1) .. "┘"
  end

  -- 1. Top virtual lines: Header + Red deleted lines (with word-wrapping)
  local virt_lines_top = {}
  table.insert(virt_lines_top, { { header_text, "AgentDiffHeader" } })

  for _, line in ipairs(deleted_lines) do
    local chunks = wrap_diff_line("- ", line, "AgentDiffDelete", max_w)
    for _, chunk in ipairs(chunks) do
      table.insert(virt_lines_top, chunk)
    end
  end

  local top_mark = vim.api.nvim_buf_set_extmark(bufnr, ns_diff, s_idx, 0, {
    virt_lines = virt_lines_top,
    virt_lines_above = true,
  })

  -- 2. Highlight additions IN-LINE directly on buffer lines in green, with '+' in sign column!
  -- NO DUPLICATE VIRTUAL LINES ABOVE!
  local num_added = math.max(1, #new_lines)
  for i = 0, num_added - 1 do
    local l_idx = s_idx + i
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_diff, l_idx, 0, {
      line_hl_group = "AgentDiffAdd",
      sign_text = "+",
      sign_hl_group = "AgentDiffAddSign",
    })
  end

  -- 3. Bottom virtual line: Footer attached below the last added line
  local last_idx = s_idx + num_added - 1
  local bot_mark = vim.api.nvim_buf_set_extmark(bufnr, ns_diff, last_idx, 0, {
    virt_lines = { { { footer_text, "AgentDiffFooter" } } },
    virt_lines_above = false,
  })

  -- Direct cursor to the exact start line of the diff and center on screen
  pcall(vim.api.nvim_win_set_cursor, origin_win, { target_line, 0 })
  pcall(function() vim.cmd("normal! zz") end)

  M.state.pending_diff = {
    bufnr = bufnr,
    origin_win = origin_win,
    target_line = target_line,
    new_lines = new_lines,
    old_count = old_lines_count,
    revert_lines = revert_lines,
    is_new_file = is_new_file or false,
    top_mark = top_mark,
    bot_mark = bot_mark,
    bound_keys = {},
  }

  -- Buffer-local shortcuts that allow normal scrolling and review:
  local function bind_buf_key(lhs, rhs, desc)
    pcall(vim.keymap.set, "n", lhs, rhs, { buffer = bufnr, silent = true, nowait = true, desc = desc })
    table.insert(M.state.pending_diff.bound_keys, lhs)
  end

  bind_buf_key("<Leader>a", function() M.accept_diff() end, "Accept diff")
  bind_buf_key("<Leader>r", function() M.reject("") end, "Reject diff")
  bind_buf_key("<Leader>w", function() M.write_revision() end, "Revise diff")
  bind_buf_key("<M-a>", function() M.accept_diff() end, "Accept diff")
  bind_buf_key("<M-r>", function() M.reject("") end, "Reject diff")
  bind_buf_key("<M-w>", function() M.write_revision() end, "Revise diff")
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
        vim.wo[w].statusline = "%#AgentDiffHeader# ● RESULTS %#AgentDiffMenuSel# [<CR>] Jump (Stays Open) %#AgentDiffHeader#  %#AgentDiffMenuBtn# [<Tab>] Focus File %#AgentDiffHeader#  %#AgentDiffMenuBtn# [o] Jump & Close %#AgentDiffHeader#  %#Normal# [q] Close %="
      end)
    end
  end

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
    update_queue_display(false)

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
    M.accept_diff()
  end, { buffer = qf_buf, silent = true, noremap = true, desc = "Accept current diff" })

  vim.keymap.set("n", "r", function()
    M.reject("")
  end, { buffer = qf_buf, silent = true, noremap = true, desc = "Reject current diff" })

  vim.keymap.set("n", "w", function()
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

--- Toggle queue display
function M.toggle_queue()
  M.state.origin_win = get_primary_editor_win()
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
    if #M.state.queue > 0 then
      update_queue_display(true)
    else
      -- Fall back to repository :Tasks if agent queue is empty
      local ok, specs = pcall(require, "specs")
      if ok and specs.tasks then
        specs.tasks()
      else
        vim.cmd("botright copen 6")
      end
    end
  end
end

--- Accept currently pending target from dir preview or in-line diff
function M.accept()
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

  if M.state.pending_diff then
    M.accept_diff()
    return
  end

  if M.state.pending_target then
    local target = M.state.pending_target
    M.state.pending_target = nil
    M.state.last_target = target
    jump_to_target(target)
  end
end

--- Record voice from microphone using arecord, stopping when user presses <CR>
function M.record_voice(callback)
  local arecord_bin = vim.fn.exepath("arecord")
  if arecord_bin == "" then
    vim.notify("Agent: 'arecord' audio utility not found", vim.log.levels.ERROR)
    return
  end

  local wav_file = "/tmp/agent_audio.wav"
  pcall(vim.fn.delete, wav_file)

  -- Spawn background recording process
  local job = vim.fn.jobstart({ arecord_bin, "-q", "-r", "16000", "-c", "1", "-f", "S16_LE", "-t", "wav", wav_file })
  if job <= 0 then
    vim.notify("Agent: Failed to start audio recording", vim.log.levels.ERROR)
    return
  end

  -- Wait for user to press <CR>
  vim.cmd("redraw")
  local input = vim.fn.input({
    prompt = "● [Agent Recording] Speak your request, then press <Enter> to send: ",
    cancelreturn = "__CANCEL__",
  })

  -- Stop recording immediately
  pcall(vim.fn.jobstop, job)
  vim.wait(100, function() return false end)

  if input == "__CANCEL__" then
    pcall(vim.fn.delete, wav_file)
    vim.notify("Agent: Voice capture cancelled", vim.log.levels.INFO)
    return
  end

  if vim.fn.filereadable(wav_file) ~= 1 or vim.fn.getfsize(wav_file) <= 44 then
    vim.notify("Agent: No audio data captured", vim.log.levels.WARN)
    return
  end

  vim.api.nvim_echo({ { "● Transcribing voice with faster-whisper...", "ModeMsg" } }, false, {})
  vim.cmd("redraw")

  -- Run faster-whisper transcription
  local cmd = { py_bin, transcribe_script, wav_file }
  local out = vim.fn.system(cmd)
  local text = vim.trim(out or "")

  pcall(vim.fn.delete, wav_file)

  if text == "" then
    vim.notify("Agent: No speech detected", vim.log.levels.WARN)
    return
  end

  vim.api.nvim_echo({
    { "● [Voice Input] ", "Directory" },
    { '"' .. text .. '"', "Normal" },
  }, false, {})

  callback(text)
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
- For navigation questions ("where did we implement X", "where is X", "find X", "show X"):
  - Set "action": "navigate"
  - Pinpoint the exact implementation file and line as "active_target"
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

  local opencode_bin = vim.fn.exepath("opencode")
  local agy_bin = vim.fn.exepath("agy")
  local cmd = {}
  if opencode_bin ~= "" then
    cmd = { opencode_bin, "run", "--format", "json", "--auto", system_prompt }
  elseif agy_bin ~= "" then
    cmd = { agy_bin, "-p", system_prompt, "--model", "gemini-3.8-flash-low", "--print-timeout", "30s", "--dangerously-skip-permissions", "--disable-slash-commands", "--effort", "low", "--output-format", "json" }
  else
    M.state.is_busy = false
    vim.notify("Agent: Neither 'opencode' nor 'agy' found in PATH", vim.log.levels.ERROR)
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

--- Shared processor for agent and lgcc JSON output:
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

--- Reject current location and re-route
function M.reject(arg)
  if M.state.current_review then
    local rev_id = M.state.current_review.id
    M.revert_review(rev_id)
    return
  end
  M.clear_diff()
  arg = vim.trim(arg or "")
  if arg == "listen" then
    M.record_voice(function(text)
      M.state.last_rejection = text
      M.run(text, true)
    end)
    return
  end

  if arg == "" then
    local input = vim.fn.input({
      prompt = "● [Agent Rejection] Explain why to reject current location: ",
      cancelreturn = "__CANCEL__",
    })
    if input == "__CANCEL__" or vim.trim(input) == "" then
      vim.notify("Agent: Rejection cancelled", vim.log.levels.INFO)
      return
    end
    arg = vim.trim(input)
  end

  M.state.last_rejection = arg
  M.run(arg, true)
end

--- Run Code Graph logic analysis (:Agent lgcc [args]) with path finding and in-line diff suggestions
function M.lgcc(parts, on_done)
  M.state.origin_win = get_primary_editor_win()
  local fargs = vim.list_slice(parts, 2)
  local user_budget = nil
  local spec_path = nil
  local model_override = nil
  local target_file = nil
  local bundle = true
  local i = 1

  while i <= #fargs do
    local arg = fargs[i]
    if arg == "clear" or arg == "cancel" or arg == "stop" or arg == "kill" then
      M.clear_diff()
      M.close_dir_preview()
      M.state.queue = {}
      M.state.queue_index = 0
      vim.cmd("cclose")
      vim.notify("Agent lgcc: Cleared diagnostics, diffs, and queue", vim.log.levels.INFO)
      if on_done then on_done(nil) end
      return
    elseif arg == "--flash" or arg == "flash" then
      model_override = "gemini-3.8-flash-low"
    elseif arg == "--sonnet" or arg == "sonnet" then
      model_override = "claude-sonnet-5-5-low"
    elseif arg == "--argon" or arg == "argon" then
      model_override = "gemini-4-argon-medium"
    elseif arg == "--model" or arg == "model" then
      i = i + 1
      model_override = fargs[i]
    elseif arg == "--budget" or arg == "budget" then
      i = i + 1
      user_budget = tonumber(fargs[i])
    elseif arg == "--spec" or arg == "spec" then
      i = i + 1
      spec_path = fargs[i]
    elseif arg == "--no-bundle" or arg == "no-bundle" then
      bundle = false
    elseif not target_file and arg ~= "" and not arg:match("^-") then
      target_file = arg
    end
    i = i + 1
  end

  local cur_win = get_primary_editor_win()
  local cur_buf = vim.api.nvim_win_get_buf(cur_win)
  if not target_file or target_file == "" then
    target_file = vim.api.nvim_buf_get_name(cur_buf)
  else
    target_file = vim.fn.expand(target_file)
  end

  if target_file == "" or vim.uv.fs_stat(target_file) == nil then
    vim.notify("Agent lgcc: Target file not found or buffer not saved: " .. (target_file ~= "" and target_file or "[unnamed]"), vim.log.levels.WARN)
    if on_done then on_done(nil) end
    return
  end

  local budget = user_budget or 4000
  local code_section = ""
  if bundle then
    local lgcc_bin = find_lgcc_bin()
    local git_root = vim.fs.root(target_file, { ".git" })
    if lgcc_bin and git_root then
      local ok, res = pcall(function()
        return vim.system({ lgcc_bin, "--route", target_file, "--budget", tostring(budget), "--format", "ir" }, { text = true }):wait(3000)
      end)
      if ok and res and res.code == 0 and res.stdout and res.stdout ~= "" then
        code_section = res.stdout
      end
    end
  end

  if code_section == "" then
    local lines = vim.fn.readfile(target_file)
    local numbered = {}
    for idx, l in ipairs(lines) do
      table.insert(numbered, string.format("%d: %s", idx, l))
    end
    code_section = string.format("--- SOURCE CODE (prefixed with line numbers) ---\nFile: %s\n%s", target_file, table.concat(numbered, "\n"))
  end

  local spec_section = ""
  if spec_path and spec_path ~= "" then
    local s_path = vim.fn.expand(spec_path)
    if vim.fn.filereadable(s_path) == 1 then
      spec_section = string.format("\n--- SPECIFICATION CONTRACT ---\n%s\n", table.concat(vim.fn.readfile(s_path), "\n"))
    end
  end

  local system_prompt = [[
You are the Logical Compiler (lgcc) and autonomous code agent for Neovim.
CRITICAL INSTRUCTION: Do NOT call any tools or commands (do NOT run bash, grep, find, view_file, or any tools). All context is provided directly in this prompt.
CRITICAL RULE: NEVER reply with conversational chat, apologies, or natural language prose.
Output your verdict IMMEDIATELY in this turn as a single STRICT JSON object.

Analyze the provided source code, Code Graph IR, and specifications for logical bugs, invariant violations, missing module implementations, or semantic flaws.

If there are NO logical bugs or flaws, output STRICTLY:
{"action": "clean"}

If logical flaws, invariant violations, or missing implementations exist:
- Provide the exact corrected code implementation to fix the flaw!
- If a new file or directory is needed (e.g., missing module), use "action": "create_and_jump" or "propose_dir", with "dir_preview" proposing the path.
- If modifying existing code, set "active_target" with:
  "path": target file path,
  "line": starting line number where fix should be applied,
  "action": "replace" or "insert",
  "old_lines_count": number of lines being deleted/replaced (0 if pure insertion),
  "content": replacement/new code lines,
  "description": concise description of the logical flaw and fix
- If multiple flaws exist across files/locations, populate "queue" with all targets.

Target File: ]] .. target_file .. [[

]] .. spec_section .. [[

]] .. code_section .. [[

Output STRICT JSON matching schema:
{
  "action": "replace" | "insert" | "create_and_jump" | "propose_dir" | "clean",
  "active_target": {
    "path": "path/to/file",
    "line": 1,
    "col": 1,
    "action": "replace" | "insert",
    "old_lines_count": 1,
    "content": "replacement code",
    "description": "Fix logic bug"
  },
  "queue": [
    {"path": "file1", "line": 10, "col": 1, "description": "Fix flaw A"}
  ],
  "dir_preview": {
    "base_dir": "path/to/dir",
    "entries": ["f1", "f2"],
    "suggested": "f2"
  }
}
Emit ONLY raw JSON. No markdown code blocks, no text before or after.
]]

  if M.state.active_job then
    pcall(function() M.state.active_job:kill(9) end)
    M.state.active_job = nil
  end

  M.state.is_busy = true
  local file_basename = vim.fn.fnamemodify(target_file, ":t")
  vim.api.nvim_echo({ { "● [Agent lgcc] Analyzing Code Graph IR for " .. file_basename .. "...", "ModeMsg" } }, false, {})
  vim.cmd("redraw")

  local agy_bin = vim.fn.exepath("agy")
  local cmd = {}
  local model = model_override or "gemini-3.8-flash-low"
  if agy_bin ~= "" then
    cmd = { agy_bin, "-p", system_prompt, "--model", model, "--print-timeout", "30s", "--dangerously-skip-permissions", "--disable-slash-commands", "--effort", "low", "--output-format", "stream-json" }
  else
    local opencode_bin = vim.fn.exepath("opencode")
    if opencode_bin ~= "" then
      cmd = { opencode_bin, "run", "--auto", system_prompt }
    else
      M.state.is_busy = false
      vim.notify("Agent lgcc: Neither 'agy' nor 'opencode' found in PATH", vim.log.levels.ERROR)
      if on_done then on_done(nil) end
      return
    end
  end

  local job_timeout = vim.uv.new_timer()
  job_timeout:start(30000, 0, vim.schedule_wrap(function()
    if M.state.active_job then
      vim.notify("Agent lgcc: Request timed out after 30s. Cancelled.", vim.log.levels.WARN)
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

    for line in raw:gmatch("[^\r\n]+") do
      if line:find('"event"%s*:%s*"result"') then
        local ok, res_obj = pcall(vim.fn.json_decode, line)
        if ok and res_obj and res_obj.result and res_obj.result.response then
          local resp_str = res_obj.result.response
          local rok, rdata = pcall(vim.fn.json_decode, resp_str)
          if rok and type(rdata) == "table" then
            data = rdata
            break
          end
          local sub = resp_str:match("(%b{})")
          if sub then
            local sok, sdata = pcall(vim.fn.json_decode, sub)
            if sok and type(sdata) == "table" then
              data = sdata
              break
            end
          end
        end
      end
    end

    if not data then
      for candidate in raw:gmatch("(%b{})") do
        local ok, cand_obj = pcall(vim.fn.json_decode, candidate)
        if ok and type(cand_obj) == "table" then
          if cand_obj.action or cand_obj.active_target or cand_obj.queue or cand_obj.dir_preview then
            data = cand_obj
            break
          end
        end
      end
    end

    process_agent_response(data, on_done)
  end))
end

--- Stop any active background agent/lgcc job and clear all previews/diffs
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

  local grep_matches = {}
  local pattern = table.concat(keywords, "|")
  local git_cmd = { "git", "-C", root, "grep", "-n", "-I", "-i", "-E", pattern, "--",
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

  local candidates = {}
  for _, line in ipairs(grep_matches) do
    local fpath, lnum, txt = line:match("^([^:]+):(%d+):(.*)$")
    if fpath and lnum and txt then
      local lnum_num = tonumber(lnum) or 1
      local txt_low = txt:lower()
      local fpath_low = fpath:lower()
      local score = 10

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

      -- Keyword match in filename (+30)
      for _, kw in ipairs(keywords) do
        if fpath_low:find(vim.pesc(kw)) then
          score = score + 30
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
      if fpath_low:find("^src/") or fpath_low:find("^lib/") or fpath_low:find("^include/") then
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

  table.sort(candidates, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.path < b.path
  end)

  return candidates
end

--- Specialized Code Search & Implementation Finder (:Agent find <description|symbol>)
function M.find(query)
  query = vim.trim(query or "")
  if query == "" then
    vim.notify("Usage: :Agent find <description or symbol name>", vim.log.levels.INFO)
    return
  end

  local prompt = "where did we implement " .. query .. " (find definition, implementation, and references)"
  M.run(prompt, false, function(res)
    if res and res.active_target then
      vim.api.nvim_echo({
        { "● [Agent Find] ", "ModeMsg" },
        { string.format("%s:%d", res.active_target.path, res.active_target.line or 1), "Directory" },
        { res.active_target.description and (" — " .. res.active_target.description) or "", "Comment" },
      }, false, {})
    else
      -- Fallback to local search_and_rank if model was unavailable
      local root = get_root_dir()
      local candidates = search_and_rank(query, root)
      if #candidates > 0 then
        local best = candidates[1]
        M.state.queue = candidates
        M.state.queue_index = 1
        jump_to_target(best)
        update_queue_display(#candidates > 1)
        vim.api.nvim_echo({
          { "● [Agent Find (Local)] ", "ModeMsg" },
          { string.format("%s:%d", best.path, best.line), "Directory" },
          { string.format(" — %s (found %d matches)", best.description, #candidates), "Normal" },
        }, false, {})
      end
    end
  end)
end

--- Specialized Build & Logic Specification Navigator (:Agent compile [syntax|logic] [arg])
function M.compile(kind, target_arg)
  kind = (kind or ""):lower()
  target_arg = vim.trim(target_arg or "")
  local root = get_root_dir()

  if kind == "syntax" or kind == "build" then
    local candidates = {
      "Makefile", "makefile", "GNUmakefile",
      "Cargo.toml",
      "build.sh", "scripts/build.sh", "compile.sh",
      "CMakeLists.txt",
      "lakefile.lean", "specs/lakefile.lean", "lakefile.toml",
      "justfile",
      "pyproject.toml",
      "flake.nix",
      "package.json",
    }
    local found = {}
    for _, c in ipairs(candidates) do
      local p = root .. "/" .. c
      if vim.fn.filereadable(p) == 1 then
        table.insert(found, { path = c, fullpath = p })
      end
    end

    if #found == 0 then
      vim.notify("Agent compile syntax: No build file found in " .. vim.fn.fnamemodify(root, ":."), vim.log.levels.WARN)
      return
    end

    local primary = found[1]
    local target_line = 1

    if target_arg ~= "" then
      local lines = vim.fn.readfile(primary.fullpath)
      for lnum, line in ipairs(lines) do
        if line:find("^%s*" .. vim.pesc(target_arg) .. "%s*:")
          or line:find("%[" .. vim.pesc(target_arg) .. "%]")
          or line:lower():find(vim.pesc(target_arg:lower())) then
          target_line = lnum
          break
        end
      end
    end

    local queue = {}
    for i, item in ipairs(found) do
      table.insert(queue, {
        path = item.path,
        line = (i == 1 and target_line or 1),
        col = 1,
        action = "navigate",
        description = "Build configuration: " .. item.path,
      })
    end

    M.state.queue = queue
    M.state.queue_index = 1
    update_queue_display(false)
    jump_to_target(queue[1])

    vim.api.nvim_echo({
      { "● [Agent Compile Syntax] ", "ModeMsg" },
      { string.format("%s:%d", primary.path, target_line), "Directory" },
      { " (compilation entrypoint)", "Comment" },
    }, false, {})

  elseif kind == "logic" or kind == "spec" or kind == "specs" then
    local candidates = {
      "specs/SPEC.md", "SPEC.md",
      "specs/specs.json",
      "specs/src/ProverEngine.lean", "specs/ProverEngine.lean",
      "specs/contracts.lean",
      "specs/model.lean",
    }
    local found = {}
    for _, c in ipairs(candidates) do
      local p = root .. "/" .. c
      if vim.fn.filereadable(p) == 1 then
        table.insert(found, { path = c, fullpath = p })
      end
    end

    if #found == 0 then
      local glob_specs = vim.fn.globpath(root .. "/specs", "*.lean", false, true)
      for _, gp in ipairs(glob_specs) do
        local rel = vim.fn.fnamemodify(gp, ":.")
        table.insert(found, { path = rel, fullpath = gp })
      end
    end

    if #found == 0 then
      local new_spec_path = "specs/SPEC.md"
      jump_to_target({
        path = new_spec_path,
        line = 1,
        col = 1,
        action = "create",
        is_new_file = true,
        content = "# Specification & Logic Verification Contract\n\n## Target Files for LLM Logic Analysis\n- [ ] specify target files here\n",
        description = "Create new logic specification contract",
      })
      vim.notify("Agent compile logic: Created logic specification stub at specs/SPEC.md. Run :Agent lgcc to verify.", vim.log.levels.INFO)
      return
    end

    local primary = found[1]
    local target_line = 1
    if target_arg ~= "" then
      local lines = vim.fn.readfile(primary.fullpath)
      for lnum, line in ipairs(lines) do
        if line:lower():find(vim.pesc(target_arg:lower())) then
          target_line = lnum
          break
        end
      end
    end

    local queue = {}
    for i, item in ipairs(found) do
      table.insert(queue, {
        path = item.path,
        line = (i == 1 and target_line or 1),
        col = 1,
        action = "navigate",
        description = "Logic specification contract: " .. item.path,
      })
    end

    M.state.queue = queue
    M.state.queue_index = 1
    update_queue_display(#queue > 1)
    jump_to_target(queue[1])

    vim.api.nvim_echo({
      { "● [Agent Compile Logic] ", "ModeMsg" },
      { string.format("%s:%d", primary.path, target_line), "Directory" },
      { " (specify analysis targets here; run :Agent lgcc to verify)", "Comment" },
    }, false, {})
  else
    vim.notify("Usage: :Agent compile [syntax [target] | logic [spec_name]]", vim.log.levels.INFO)
  end
end

--- Specialized Task & Contract Search (:Agent search [TODO|DONE] [query])
function M.search(subcmd, query)
  local mode = (subcmd or ""):upper()
  if mode == "TODO" or mode == "DONE" then
    -- query is passed directly
  else
    query = vim.trim((subcmd or "") .. " " .. (query or ""))
    mode = "ALL"
  end
  query = vim.trim(query or "")
  local root = get_root_dir()

  local results = {}
  local is_todo = (mode == "TODO")
  local is_done = (mode == "DONE")

  if is_todo and query == "" and vim.fn.exists(":TodoQuickFix") == 2 then
    pcall(vim.cmd, "TodoQuickFix keywords=TODO,FIXME,SPEC")
    return
  end

  local pattern = ""
  if is_todo then
    pattern = "TODO|FIXME|XXX|BUG|\\[ \\]|SPEC\\([^)]*\\)"
  elseif is_done then
    pattern = "verified|done|\\[x\\]|\\[X\\]|theorem.*verified"
  else
    pattern = query ~= "" and vim.pesc(query) or "TODO|SPEC"
  end

  local grep_cmd = { "git", "-C", root, "grep", "-n", "-I", "-E", "-i", pattern, "--", ":!*.json*", ":!*.log", ":!*.ipynb", ":!*.olean", ":!specs/.lexlean/*", ":!logs/*" }
  local grep_out = vim.fn.system(grep_cmd)

  if vim.v.shell_error ~= 0 or grep_out == "" then
    local rg_bin = vim.fn.exepath("rg")
    if rg_bin ~= "" then
      grep_cmd = { rg_bin, "-n", "--no-heading", "-i", "-e", pattern, "-g", "!*.json*", "-g", "!*.log", "-g", "!*.ipynb", "-g", "!*.olean", "-g", "!specs/.lexlean/*", "-g", "!logs/*", root }
      grep_out = vim.fn.system(grep_cmd)
    end
  end

  if grep_out and grep_out ~= "" then
    for line in grep_out:gmatch("[^\r\n]+") do
      local rel = line:gsub("^" .. vim.pesc(root) .. "/", "")
      local fpath, lnum, txt = rel:match("^([^:]+):(%d+):(.*)$")
      if fpath and lnum then
        local match_ok = true
        if query ~= "" then
          local q_low = query:lower()
          local line_low = (fpath .. " " .. txt):lower()
          if not line_low:find(vim.pesc(q_low)) then
            match_ok = false
          end
        end
        if is_done and txt:find("TODO") then
          match_ok = false
        end

        if match_ok and #results < 50 then
          local tag = is_todo and "[TODO]" or (is_done and "[DONE]" or "[SEARCH]")
          table.insert(results, {
            path = fpath,
            line = tonumber(lnum) or 1,
            col = 1,
            action = "navigate",
            is_new_file = false,
            description = tag .. " " .. vim.trim(txt),
          })
        end
      end
    end
  end

  if #results == 0 then
    vim.notify(string.format("Agent search %s: No items found matching '%s'", mode, query), vim.log.levels.WARN)
    return
  end

  M.state.queue = results
  M.state.queue_index = 1
  update_queue_display(#results > 1)
  jump_to_target(results[1])

  vim.api.nvim_echo({
    { string.format("● [Agent Search %s] ", mode), "ModeMsg" },
    { string.format("Found %d matches (active: %s:%d)", #results, results[1].path, results[1].line), "Directory" },
  }, false, {})
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
  local rel_file = vim.fn.fnamemodify(file_path, ":.")

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
  local target_full = rev.target_file:match("^/") and rev.target_file or (root .. "/" .. rev.target_file)
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
      vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! write") end)
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
  vim.notify(string.format("✗ GitReview: Reverted %s on %s!", rev.id, vim.fn.fnamemodify(target_full, ":.")), vim.log.levels.INFO)

  -- Refresh review list
  local rem = M.get_reviews("unreviewed")
  if #rem > 0 then
    if vim.fn.exists(":DiffviewRefresh") == 2 then
      pcall(vim.cmd, "DiffviewRefresh")
    end
    M.review("list")
  else
    if vim.fn.exists(":DiffviewClose") == 2 then
      pcall(vim.cmd, "DiffviewClose")
    end
    vim.cmd("cclose")
    vim.notify("✓ GitReview: All implementations have been reviewed by a human!", vim.log.levels.INFO)
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
  rev.status = "accepted"
  rev.reviewed_at = os.date("%Y-%m-%d %H:%M:%S")
  local meta_path = root .. "/" .. (rev.patch_file:gsub("%.patch$", ".json"))
  if vim.fn.filereadable(meta_path) == 1 then
    vim.fn.writefile({ vim.fn.json_encode(rev) }, meta_path)
  end

  M.state.current_review = nil
  vim.notify(string.format("✓ GitReview: %s accepted and approved by human!", rev.id), vim.log.levels.INFO)

  -- Refresh review list
  local rem = M.get_reviews("unreviewed")
  if #rem > 0 then
    if vim.fn.exists(":DiffviewRefresh") == 2 then
      pcall(vim.cmd, "DiffviewRefresh")
    end
    M.review("list")
  else
    if vim.fn.exists(":DiffviewClose") == 2 then
      pcall(vim.cmd, "DiffviewClose")
    end
    vim.cmd("cclose")
    vim.notify("✓ GitReview: All implementations have been reviewed by a human!", vim.log.levels.INFO)
  end
  return true
end

--- Display a specific review in-line
function M.show_review(rev)
  if not rev then return end
  local root = get_root_dir()
  local target_full = rev.target_file:match("^/") and rev.target_file or (root .. "/" .. rev.target_file)
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
    { "] " .. (rev.description or "") .. " — :GitReview accept (<Leader>a) to approve, :GitReview reject (<Leader>r) to revert", "Normal" },
  }, false, {})
end

--- Human Review Command Dispatcher (:Review [list|accept|reject|next|prev])
function M.review(subcmd, arg)
  subcmd = (subcmd or ""):lower()
  local root = get_root_dir()

  if subcmd == "accept" or subcmd == "a" then
    local target_id = arg or (M.state.current_review and M.state.current_review.id)
    if target_id then
      M.accept_review(target_id)
    else
      vim.notify("Review: No active review to accept. Run :Review to select one.", vim.log.levels.WARN)
    end
    return
  elseif subcmd == "reject" or subcmd == "r" then
    local target_id = arg or (M.state.current_review and M.state.current_review.id)
    if target_id then
      M.revert_review(target_id)
    else
      vim.notify("Review: No active review to reject. Run :Review to select one.", vim.log.levels.WARN)
    end
    return
  elseif subcmd == "clear" or subcmd == "close" then
    M.clear_diff()
    M.state.current_review = nil
    vim.cmd("cclose")
    vim.notify("Review: Closed review queue", vim.log.levels.INFO)
    return
  end

  -- Default or "list": show all unreviewed implementations
  local unreviewed = M.get_reviews("unreviewed")
  if #unreviewed == 0 then
    vim.notify("✓ Review: All implementations have been reviewed by a human! (0 pending)", vim.log.levels.INFO)
    vim.cmd("cclose")
    return
  end

  local qf_list = {}
  for _, r in ipairs(unreviewed) do
    local full = r.target_file:match("^/") and r.target_file or (root .. "/" .. r.target_file)
    table.insert(qf_list, {
      filename = full,
      lnum = r.start_line or 1,
      col = 1,
      text = string.format("[UNREVIEWED: %s] %s (%s)", r.id, r.description or "", r.task_id or ""),
      type = "W",
    })
  end

  vim.fn.setqflist(qf_list, "r")
  vim.fn.setqflist({}, "a", { title = string.format("[Human Review Queue: %d unreviewed implementation%s]", #unreviewed, #unreviewed == 1 and "" or "s") })
  vim.cmd("botright copen 6")

  local origin_win = get_primary_editor_win()
  if origin_win and vim.api.nvim_win_is_valid(origin_win) then
    setup_agent_qf_keymaps(origin_win, vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win()))
  end

  -- Show first unreviewed item
  M.show_review(unreviewed[1])

  -- If diffview is available, open Diffview review tab alongside review queue
  if vim.fn.exists(":DiffviewOpen") == 2 then
    pcall(vim.cmd, "DiffviewOpen")
  end
end

--- Find and execute in-line TODO/FIXME task in the current buffer or repository
function M.run_todo(bufnr, target_line)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    vim.notify("Agent: Invalid buffer", vim.log.levels.WARN)
    return
  end

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" or vim.fn.filereadable(filepath) ~= 1 then
    M.search("TODO", "")
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
    chosen_line = target_line
  -- 2. Check if cursor line has TODO or FIXME
  elseif lines[cursor_line] and (lines[cursor_line]:find("TODO") or lines[cursor_line]:find("FIXME") or lines[cursor_line]:find("SPEC%(")) then
    chosen_line = cursor_line
  else
    -- 3. Search forward from cursor
    for i = cursor_line, #lines do
      if lines[i]:find("TODO") or lines[i]:find("FIXME") or lines[i]:find("SPEC%(") then
        chosen_line = i
        break
      end
    end
    -- 4. Search from top of file
    if not chosen_line then
      for i = 1, cursor_line - 1 do
        if lines[i]:find("TODO") or lines[i]:find("FIXME") or lines[i]:find("SPEC%(") then
          chosen_line = i
          break
        end
      end
    end
  end

  if not chosen_line then
    vim.notify("Agent: No in-line TODO/FIXME found in current file. Searching repository...", vim.log.levels.INFO)
    M.search("TODO", "")
    return
  end

  local raw_header = lines[chosen_line]
  chosen_desc = raw_header:gsub("^[ \t]*[#/%-]+%s*", "")

  -- Count multi-line task comments (Description, Criterion, etc.)
  local j = chosen_line + 1
  while j <= #lines do
    local l = vim.trim(lines[j])
    if l:find("^[#/%-]+%s*[Dd]escription:") or l:find("^[#/%-]+%s*[Cc]riterion:") or l:find("^[#/%-]+%s*[-*]") then
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
  for idx, l in ipairs(lines) do
    table.insert(numbered_lines, string.format("%d: %s", idx, l))
  end
  local code_section = table.concat(numbered_lines, "\n")

  local ir_section = ""
  local lgcc_bin = vim.fn.exepath("lgcc")
  if lgcc_bin == "" and vim.fn.executable(vim.fn.expand("~/.local/bin/lgcc")) == 1 then
    lgcc_bin = vim.fn.expand("~/.local/bin/lgcc")
  end
  if lgcc_bin ~= "" then
    local res = vim.system({ lgcc_bin, "--route", filepath, "--budget", "16000", "--format", "ir" }, { text = true }):wait()
    if res.code == 0 and res.stdout and res.stdout ~= "" then
      ir_section = "\nROUTED CODE GRAPH CONTEXT & SYMBOL CONTRACTS:\n" .. res.stdout .. "\n"
    end
  end

  local prompt = string.format([[CRITICAL INSTRUCTION: You are the Autonomous Source-First Code Agent.
Your task is to implement the following in-line task directly inside the target file.
Source code is the single source of truth.

TARGET FILE: %s
TASK: %s
DESCRIPTION: %s
TARGET LINE: %d (replaces lines %d to %d)

SURROUNDING SOURCE CODE (with 1-based line numbers):
%s
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
    code_section, ir_section, chosen_line, old_lines_count)

  local opencode_bin = vim.fn.exepath("opencode")
  local agy_bin = vim.fn.exepath("agy")
  local cmd = {}

  if opencode_bin ~= "" then
    cmd = { opencode_bin, "run", "--format", "json", "--auto", prompt }
  elseif agy_bin ~= "" then
    cmd = { agy_bin, "-p", prompt, "--model", "gemini-3.8-flash-low", "--dangerously-skip-permissions", "--disable-slash-commands", "--effort", "low", "--output-format", "json" }
  else
    vim.notify("Agent: Neither 'opencode' nor 'agy' found in PATH", vim.log.levels.ERROR)
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
    local solution = nil

    -- 1. Parse opencode JSON stream
    for line in raw:gmatch("[^\r\n]+") do
      local ok, obj = pcall(vim.fn.json_decode, line)
      if ok and type(obj) == "table" then
        if obj.type == "text" and obj.part and obj.part.text then
          local ptext = obj.part.text
          local sok, sdata = pcall(vim.fn.json_decode, ptext)
          if sok and type(sdata) == "table" and sdata.content then
            solution = sdata
            break
          end
          local sub = ptext:match("(%b{})")
          if sub then
            local took, tdata = pcall(vim.fn.json_decode, sub)
            if took and type(tdata) == "table" and tdata.content then
              solution = tdata
              break
            end
          end
        elseif obj.content then
          solution = obj
          break
        end
      end
    end

    -- 2. Direct JSON fallback
    if not solution then
      local ok, obj = pcall(vim.fn.json_decode, raw)
      if ok and type(obj) == "table" then
        if obj.response and type(obj.response) == "string" then
          local sok, sdata = pcall(vim.fn.json_decode, obj.response)
          if sok and type(sdata) == "table" and sdata.content then
            solution = sdata
          end
        elseif obj.content then
          solution = obj
        end
      end
    end

    -- 3. Balanced JSON scan
    if not solution then
      for candidate in raw:gmatch("(%b{})") do
        local ok, cobj = pcall(vim.fn.json_decode, candidate)
        if ok and type(cobj) == "table" and cobj.content then
          solution = cobj
          break
        end
      end
    end

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
      { "] Applied to " .. file_basename .. " — :GitReview accept (<Leader>a) to approve, :GitReview reject (<Leader>r) to revert", "Comment" },
    }, false, {})
  end))
end

--- Execute task from a specified file (code file with TODO or task description file)
function M.run_file(file_arg)
  file_arg = vim.trim(file_arg or "")
  if file_arg == "" then
    vim.notify("Usage: :Agent file <path/to/file>", vim.log.levels.INFO)
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

  vim.api.nvim_create_user_command("Agent", function(ctx)
    M.state.origin_win = get_primary_editor_win()
    local raw_args = vim.trim(ctx.args or "")
    local parts = vim.split(raw_args, "%s+", { trimempty = true })
    local sub = (parts[1] or ""):lower()

    if sub == "stop" or sub == "cancel" or sub == "kill" then
      M.stop()
    elseif sub == "review" then
      M.review(parts[2], parts[3])
    elseif sub == "todo" then
      local lnum = tonumber(parts[2])
      M.run_todo(nil, lnum)
    elseif sub == "file" then
      M.run_file(parts[2])
    elseif sub == "find" or sub == "where" or sub == "where's" or sub == "locate" or (sub == "show" and (parts[2] == "me" or parts[2] == "where")) then
      local query_str = (sub == "find") and table.concat(vim.list_slice(parts, 2), " ") or raw_args
      M.find(query_str)
    elseif sub == "compile" then
      M.compile(parts[2], table.concat(vim.list_slice(parts, 3), " "))
    elseif sub == "search" then
      M.search(parts[2], table.concat(vim.list_slice(parts, 3), " "))
    elseif sub == "listen" then
      M.record_voice(function(prompt)
        M.run(prompt, false)
      end)
    elseif sub == "lgcc" then
      M.lgcc(parts)
    elseif sub == "reject" or sub == "r" then
      local rest = table.concat(vim.list_slice(parts, 2), " ")
      M.reject(rest)
    elseif sub == "accept" or sub == "a" then
      M.accept()
    elseif sub == "write" or sub == "revise" or sub == "w" then
      local rest = table.concat(vim.list_slice(parts, 2), " ")
      if rest ~= "" then
        M.clear_diff()
        M.run(rest, true)
      else
        M.write_revision()
      end
    elseif sub == "next" or sub == "n" then
      M.next()
    elseif sub == "prev" or sub == "p" then
      M.prev()
    elseif sub == "queue" or sub == "tasks" or sub == "list" or sub == "q" then
      M.toggle_queue()
    elseif sub == "diff" then
      local action = (parts[2] or ""):lower()
      if action == "accept" or action == "apply" or action == "a" then
        M.accept_diff()
      elseif action == "reject" or action == "cancel" or action == "clear" or action == "r" then
        M.clear_diff()
      else
        vim.notify("Usage: :Agent diff [accept|reject|clear]", vim.log.levels.INFO)
      end
    elseif sub == "clear" then
      M.stop()
      M.state.queue = {}
      M.state.queue_index = 0
      vim.cmd("cclose")
      vim.notify("Agent: Cleared queue, diffs, and previews", vim.log.levels.INFO)
    elseif raw_args ~= "" then
      M.run(raw_args, false)
    else
      M.run_todo(nil, nil)
    end
  end, {
    nargs = "*",
    complete = function(arglead, cmdline)
      local parts = vim.split(vim.trim(cmdline), "%s+")
      if #parts <= 2 and not cmdline:match("%s+$") then
        local subcmds = { "review", "todo", "file", "find", "compile", "search", "listen", "lgcc", "reject", "accept", "revise", "write", "next", "prev", "queue", "tasks", "diff", "clear", "stop", "cancel" }
        return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, subcmds)
      elseif parts[2] == "compile" then
        local comp_sub = { "syntax", "logic", "build", "spec" }
        return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, comp_sub)
      elseif parts[2] == "search" then
        local search_sub = { "TODO", "DONE" }
        return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, search_sub)
      elseif parts[2] == "lgcc" then
        local lgcc_flags = { "clear", "cancel", "stop", "--flash", "--sonnet", "--opencode", "--agy", "--argon", "-s", "--speak", "-b", "--bundle", "--no-bundle", "--budget", "--spec", "-l", "--local" }
        return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, lgcc_flags)
      elseif parts[2] == "diff" then
        local diff_sub = { "accept", "reject", "clear" }
        return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, diff_sub)
      end
      return {}
    end,
    desc = "Autonomous Silent Code Agent (:Agent [find|compile|search|lgcc|listen|accept|reject|revise|next|prev|queue])",
  })

  vim.api.nvim_create_user_command("Find", function(ctx)
    M.state.origin_win = vim.api.nvim_get_current_win()
    M.find(ctx.args)
  end, { nargs = "*", desc = "Find implementation or definition across repository (:Find <query>)" })

  vim.api.nvim_create_user_command("Compile", function(ctx)
    M.state.origin_win = vim.api.nvim_get_current_win()
    local parts = vim.split(vim.trim(ctx.args or ""), "%s+", { trimempty = true })
    M.compile(parts[1], table.concat(vim.list_slice(parts, 2), " "))
  end, {
    nargs = "*",
    complete = function(arglead, cmdline)
      local parts = vim.split(vim.trim(cmdline), "%s+")
      if #parts <= 2 and not cmdline:match("%s+$") then
        return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, { "syntax", "logic", "build", "spec" })
      end
      return {}
    end,
    desc = "Navigate compilation entrypoints (:Compile syntax [target] | :Compile logic [spec])",
  })

  vim.api.nvim_create_user_command("Search", function(ctx)
    M.state.origin_win = vim.api.nvim_get_current_win()
    local parts = vim.split(vim.trim(ctx.args or ""), "%s+", { trimempty = true })
    M.search(parts[1], table.concat(vim.list_slice(parts, 2), " "))
  end, {
    nargs = "*",
    complete = function(arglead, cmdline)
      local parts = vim.split(vim.trim(cmdline), "%s+")
      if #parts <= 2 and not cmdline:match("%s+$") then
        return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, { "TODO", "DONE" })
      end
      return {}
    end,
    desc = "Search repository tasks and contracts (:Search TODO [query] | :Search DONE [query])",
  })

  local function review_dispatcher(ctx)
    local parts = vim.split(vim.trim(ctx.args or ""), "%s+", { trimempty = true })
    M.review(parts[1], parts[2])
  end

  local review_cmd_opts = {
    nargs = "*",
    complete = function(arglead, cmdline)
      local subcmds = { "list", "accept", "reject", "next", "prev", "clear", "open" }
      return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, subcmds)
    end,
    desc = "Git Review Queue: Inspect, accept, or revert unreviewed implementations (:GitReview [list|accept|reject])",
  }

  vim.api.nvim_create_user_command("GitReview", review_dispatcher, review_cmd_opts)
  vim.api.nvim_create_user_command("GReview", review_dispatcher, review_cmd_opts)
  vim.api.nvim_create_user_command("Review", review_dispatcher, review_cmd_opts)

  vim.api.nvim_create_user_command("GitReviewAccept", function()
    M.accept()
  end, { desc = "Accept current git review implementation" })

  vim.api.nvim_create_user_command("GitReviewReject", function(ctx)
    M.reject(ctx.args)
  end, { nargs = "*", desc = "Reject and revert current git review implementation" })

  -- If :Git command does not exist, provide :Git with review support
  if vim.fn.exists(":Git") ~= 2 then
    vim.api.nvim_create_user_command("Git", function(ctx)
      local parts = vim.split(vim.trim(ctx.args or ""), "%s+", { trimempty = true })
      if parts[1] == "review" then
        M.review(parts[2], parts[3])
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
        elseif parts[2] == "review" then
          local rsubs = { "list", "accept", "reject", "next", "prev", "clear" }
          return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, rsubs)
        end
        return {}
      end,
      desc = "Git command runner with review support (:Git review [list|accept|reject])",
    })
  end

  vim.api.nvim_create_user_command("Accept", function()
    M.accept()
  end, { desc = "Accept and apply current agent in-line diff or task (:GitReview accept)" })

  vim.api.nvim_create_user_command("Reject", function(ctx)
    M.reject(ctx.args)
  end, { nargs = "*", desc = "Reject current agent diff or task (:GitReview reject)" })

  vim.api.nvim_create_user_command("Revise", function(ctx)
    local arg = vim.trim(ctx.args or "")
    if arg ~= "" then
      M.clear_diff()
      M.run(arg, true)
    else
      M.write_revision()
    end
  end, { nargs = "*", desc = "Revise current agent instruction in natural language" })

  vim.api.nvim_create_user_command("Results", function()
    M.toggle_queue()
  end, { desc = "Toggle the bottom query results list (:Results)" })

  vim.api.nvim_create_user_command("Queue", function()
    M.toggle_queue()
  end, { desc = "Toggle the bottom query results list (:Queue)" })

  vim.api.nvim_create_user_command("Tasks", function()
    M.toggle_queue()
  end, { desc = "Toggle the bottom task queue (:Tasks)" })

  M.get_root_dir = get_root_dir
  M.collect_context = collect_context
  M.find = M.find
  M.compile = M.compile
  M.search = M.search
  M.review = M.review
  M.git_review = M.review
  M.review_command = M.review
end

M.get_root_dir = get_root_dir
M.collect_context = collect_context
M.find = M.find
M.compile = M.compile
M.search = M.search
M.review = M.review
M.git_review = M.review
M.review_command = M.review

return M
