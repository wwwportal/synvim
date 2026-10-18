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
}

local py_bin = vim.fn.expand("~/myenv/bin/python")
local transcribe_script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h") .. "/bin/agent_transcribe.py"
if vim.fn.filereadable(transcribe_script) ~= 1 then
  transcribe_script = vim.fn.expand("/home/yassine/code/syn-nvim/bin/agent_transcribe.py")
end

local function setup_highlights()
  vim.api.nvim_set_hl(0, "AgentDiffAdd", { fg = "#107c10", bg = "#e6f4ea", bold = true, default = false })
  vim.api.nvim_set_hl(0, "AgentDiffDelete", { fg = "#d93025", bg = "#fce8e6", strikethrough = true, default = false })
  vim.api.nvim_set_hl(0, "AgentDiffHeader", { fg = "#ffffff", bg = "#2d3748", bold = true, default = false })
  vim.api.nvim_set_hl(0, "AgentDiffMenu", { fg = "#000000", bg = "#f0f0f0", bold = true, default = false })
end

--- Get root directory of current project
local function get_root_dir()
  local buf_name = vim.api.nvim_buf_get_name(0)
  if buf_name ~= "" then
    local root = vim.fs.root(buf_name, { ".git", "Cargo.toml", "Makefile" })
    if root then return root end
  end
  local git_root = vim.fn.system("git rev-parse --show-toplevel 2>/dev/null"):gsub("[\r\n]+", "")
  if vim.v.shell_error == 0 and git_root ~= "" then
    return git_root
  end
  return vim.fn.getcwd()
end

--- Get primary non-floating editor split window
local function get_primary_editor_win()
  local cur = vim.api.nvim_get_current_win()
  local config = vim.api.nvim_win_get_config(cur)
  if config.relative == "" then
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

--- Collect repository context summary (git files and active buffer context)
local function collect_context()
  local root = get_root_dir()
  local files_out = vim.fn.system({ "git", "-C", root, "ls-files" })
  local file_list = {}
  if vim.v.shell_error == 0 and files_out ~= "" then
    for line in files_out:gmatch("[^\r\n]+") do
      if #file_list < 150 then
        table.insert(file_list, line)
      end
    end
  end

  local cur_win = get_primary_editor_win()
  local cur_buf = vim.api.nvim_win_get_buf(cur_win)
  local cur_file = vim.api.nvim_buf_get_name(cur_buf)
  local rel_cur_file = ""
  if cur_file ~= "" then
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

--- Clear pending in-line diff and floating action toolbar
function M.clear_diff()
  if M.state.pending_diff then
    local p = M.state.pending_diff
    if p.bufnr and vim.api.nvim_buf_is_valid(p.bufnr) and p.mark_id then
      pcall(vim.api.nvim_buf_del_extmark, p.bufnr, ns_diff, p.mark_id)
    end
    if p.toolbar_win and vim.api.nvim_win_is_valid(p.toolbar_win) then
      pcall(vim.api.nvim_win_close, p.toolbar_win, true)
    end
    M.state.pending_diff = nil
  end
end

--- Accept and permanently apply the pending in-line diff
function M.accept_diff()
  if not M.state.pending_diff then
    vim.notify("Agent: No pending diff to accept", vim.log.levels.INFO)
    return
  end
  local p = M.state.pending_diff
  local bufnr = p.bufnr
  local target_line = p.target_line
  local new_lines = p.new_lines
  local old_count = p.old_count or 0

  M.clear_diff()

  if vim.api.nvim_buf_is_valid(bufnr) then
    local total = vim.api.nvim_buf_line_count(bufnr)
    local s_line = math.max(0, target_line - 1)
    local e_line = math.min(total, s_line + old_count)
    local was_mod = vim.bo[bufnr].modifiable
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, s_line, e_line, false, new_lines)
    vim.bo[bufnr].modifiable = was_mod
    vim.notify("✓ Agent: Implementation accepted and applied to buffer", vim.log.levels.INFO)
  end
end

--- Show suggested code in-line with green-red diff colors and action toolbar
function M.show_inline_diff(bufnr, target_line, new_content, old_lines_count)
  M.clear_diff()
  setup_highlights()

  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  target_line = math.max(1, target_line or 1)
  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  if target_line > total_lines then target_line = total_lines end

  local new_lines = vim.split(new_content or "", "\n")
  old_lines_count = old_lines_count or 0

  -- Extract existing lines if replacing
  local deleted_lines = {}
  if old_lines_count > 0 then
    local s_idx = target_line - 1
    local e_idx = math.min(total_lines, s_idx + old_lines_count)
    deleted_lines = vim.api.nvim_buf_get_lines(bufnr, s_idx, e_idx, false)
  end

  local virt_lines = {}
  table.insert(virt_lines, { { "┌── Suggested Implementation (In-Line Diff) ────────────────────────┐", "AgentDiffHeader" } })

  -- Red deleted lines
  for _, line in ipairs(deleted_lines) do
    table.insert(virt_lines, { { "- " .. line, "AgentDiffDelete" } })
  end

  -- Green added lines
  for _, line in ipairs(new_lines) do
    table.insert(virt_lines, { { "+ " .. line, "AgentDiffAdd" } })
  end

  table.insert(virt_lines, { { "└── [a] Accept  |  [r] Reject  |  [w] Write in Natural Language ────┘", "AgentDiffHeader" } })

  local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns_diff, math.max(0, target_line - 1), 0, {
    virt_lines = virt_lines,
    virt_lines_above = (total_lines == 0 or (target_line == 1 and old_lines_count == 0)),
  })

  -- Floating mini toolbar near cursor
  local t_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[t_buf].buftype = "nofile"
  vim.bo[t_buf].bufhidden = "wipe"
  local t_text = " [a] Accept   [r] Reject   [w] Write / Revise   [<Esc>] Dismiss "
  vim.api.nvim_buf_set_lines(t_buf, 0, -1, false, { t_text })

  local t_win = vim.api.nvim_open_win(t_buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = #t_text,
    height = 1,
    style = "minimal",
    border = "rounded",
    title = " Diff Action ",
    title_pos = "center",
  })

  M.state.pending_diff = {
    bufnr = bufnr,
    target_line = target_line,
    new_lines = new_lines,
    old_count = old_lines_count,
    mark_id = mark_id,
    toolbar_win = t_win,
    toolbar_buf = t_buf,
  }

  local function bind_keys(target_b)
    vim.keymap.set("n", "a", function()
      M.accept_diff()
    end, { buffer = target_b, silent = true, nowait = true })

    vim.keymap.set("n", "r", function()
      M.clear_diff()
      M.reject("")
    end, { buffer = target_b, silent = true, nowait = true })

    vim.keymap.set("n", "w", function()
      M.clear_diff()
      local input = vim.fn.input({ prompt = "● [Agent] Revise instruction (type or 'listen'): ", cancelreturn = "__CANCEL__" })
      if input ~= "__CANCEL__" and vim.trim(input) ~= "" then
        if vim.trim(input) == "listen" then
          M.record_voice(function(prompt) M.run(prompt, true) end)
        else
          M.run(input, true)
        end
      end
    end, { buffer = target_b, silent = true, nowait = true })

    vim.keymap.set("n", "<Esc>", function()
      M.clear_diff()
      vim.notify("Agent: Dismissed in-line diff preview", vim.log.levels.INFO)
    end, { buffer = target_b, silent = true, nowait = true })

    vim.keymap.set("n", "q", function()
      M.clear_diff()
    end, { buffer = target_b, silent = true, nowait = true })
  end

  bind_keys(t_buf)
  bind_keys(bufnr)

  vim.cmd("redraw")
end

--- Show terminal ls-style directory preview in an ephemeral floating window.
--- ONLY paths and directories are suggested in this floating window.
function M.show_dir_preview(base_dir, entries, suggested, on_accept)
  M.close_dir_preview()
  local origin_win = get_primary_editor_win()

  local width = math.min(78, math.max(50, vim.o.columns - 6))
  local header = string.format(" Directory: %s", base_dir ~= "" and base_dir or "./")
  local sep = string.rep("─", width - 2)
  local ls_rows = format_ls_columns(entries, suggested, width - 4)

  local lines = {
    header,
    " " .. sep,
  }
  for _, r in ipairs(ls_rows) do
    table.insert(lines, r)
  end
  table.insert(lines, " " .. sep)
  table.insert(lines, " [*] Suggested | <CR>: Select Path | q / <Esc>: Dismiss | :Agent reject: Re-route")

  local height = #lines
  local row = math.max(1, math.floor((vim.o.lines - height) / 2) - 2)
  local col = math.max(1, math.floor((vim.o.columns - width) / 2))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Agent Path Suggestion ",
    title_pos = "center",
  })

  M.state.dir_preview_win = win
  M.state.dir_preview_buf = buf

  local close_fn = function()
    M.close_dir_preview()
    if vim.api.nvim_win_is_valid(origin_win) then
      vim.api.nvim_set_current_win(origin_win)
    end
  end

  local accept_fn = function()
    M.close_dir_preview()
    -- Restore focus to primary editor window before opening file!
    if vim.api.nvim_win_is_valid(origin_win) then
      vim.api.nvim_set_current_win(origin_win)
    end
    if on_accept then on_accept(origin_win) end
  end

  M.state.on_path_accept = accept_fn

  vim.keymap.set("n", "<CR>", accept_fn, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "<Esc>", close_fn, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "q", close_fn, { buffer = buf, silent = true, nowait = true })
end

--- Jump to a target location in the primary editor split
local function jump_to_target(target, win)
  if not target or not target.path or target.path == "" then return end
  local root = get_root_dir()
  local path = target.path
  if not path:match("^/") then
    path = root .. "/" .. path
  end

  local origin_win = win or get_primary_editor_win()
  if vim.api.nvim_win_is_valid(origin_win) then
    vim.api.nvim_set_current_win(origin_win)
  end

  -- If target file does not exist, create it if requested
  local file_exists = (vim.fn.filereadable(path) == 1)
  if not file_exists then
    local parent = vim.fn.fnamemodify(path, ":h")
    if vim.fn.isdirectory(parent) ~= 1 then
      vim.fn.mkdir(parent, "p")
    end
    vim.fn.writefile({ "" }, path)
  end

  -- Switch buffer in primary editor split
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()

  local line = target.line or 1
  local col = math.max(0, (target.col or 1) - 1)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line > line_count then line = line_count end
  if line < 1 then line = 1 end

  pcall(vim.api.nvim_win_set_cursor, origin_win, { line, col })
  vim.cmd("normal! zz")

  -- If code implementation was suggested, display in-line green-red diff!
  if target.content and target.content ~= "" then
    local old_count = (target.action == "replace") and 1 or 0
    M.show_inline_diff(bufnr, line, target.content, old_count)
  end
end

--- Populate the Neovim Quickfix queue unified with :Tasks
local function update_queue_display(show_window)
  local qf = {}
  local root = get_root_dir()
  for idx, item in ipairs(M.state.queue) do
    local fullpath = item.path:match("^/") and item.path or (root .. "/" .. item.path)
    local prefix = (idx == M.state.queue_index) and "▶ [ACTIVE] " or (idx < M.state.queue_index and "✓ [DONE] " or "  [PENDING] ")
    table.insert(qf, {
      filename = fullpath,
      lnum = item.line or 1,
      col = item.col or 1,
      text = string.format("%s[%d/%d] %s", prefix, idx, #M.state.queue, item.description or item.path),
      type = (idx == M.state.queue_index) and "E" or "I",
    })
  end

  vim.fn.setqflist(qf, "r")
  vim.fn.setqflist({}, "a", { title = string.format("Agent Task Queue [%d/%d]", M.state.queue_index, #M.state.queue) })

  if show_window then
    vim.cmd("botright copen 6")
    vim.cmd("wincmd p")
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
  M.state.last_prompt = prompt
  M.state.is_busy = true

  local ctx = collect_context()
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

  local system_prompt = [[
You are an autonomous Neovim code navigation agent.
CRITICAL RULE: NEVER reply with conversational chat, apologies, or natural language prose.
You communicate EXCLUSIVELY by emitting a single STRICT JSON object.

Repository context:
Current file: ]] .. ctx.current_file .. [[ (line ]] .. ctx.current_line .. [[)
Available repository files:
]] .. file_list_str .. [[

Snippet around cursor:
]] .. ctx.snippet .. rejection_context .. [[

User Instruction:
]] .. prompt .. [[

Output STRICT JSON matching this schema:
{
  "action": "navigate" | "create_and_jump" | "propose_dir",
  "active_target": {
    "path": "relative/path/to/file",
    "line": 1,
    "col": 1,
    "content": "optional code snippet or implementation to suggest in-line"
  },
  "queue": [
    {"path": "file1", "line": 10, "col": 1, "description": "Step 1"},
    {"path": "file2", "line": 40, "col": 1, "description": "Step 2"}
  ],
  "dir_preview": {
    "base_dir": "path/to/directory",
    "entries": ["file1", "file2", "file3"],
    "suggested": "file3"
  }
}
Emit ONLY raw JSON. No markdown code blocks, no text before or after.
]]

  local agy_bin = vim.fn.exepath("agy")
  local cmd = {}
  if agy_bin ~= "" then
    cmd = { agy_bin, "-p", system_prompt, "--model", "gemini-3.8-flash-low", "--dangerously-skip-permissions", "--disable-slash-commands", "--effort", "low", "--output-format", "stream-json" }
  else
    local opencode_bin = vim.fn.exepath("opencode")
    if opencode_bin ~= "" then
      cmd = { opencode_bin, "run", "--auto", system_prompt }
    else
      M.state.is_busy = false
      vim.notify("Agent: Neither 'agy' nor 'opencode' found in PATH", vim.log.levels.ERROR)
      if on_done then on_done(nil) end
      return
    end
  end

  vim.api.nvim_echo({ { "● [Agent] Analyzing codebase...", "ModeMsg" } }, false, {})
  vim.cmd("redraw")

  local stdout_chunks = {}
  vim.system(cmd, {
    text = true,
    stdout = function(_, data)
      if data then table.insert(stdout_chunks, data) end
    end,
  }, vim.schedule_wrap(function(res)
    local raw = table.concat(stdout_chunks, "")
    local data = nil

    -- 1. Try finding stream-json result event
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

    -- 2. Fallback: search for balanced JSON in full raw output
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

    if not data then
      M.state.is_busy = false
      vim.notify("Agent: Received invalid response from model", vim.log.levels.ERROR)
      if on_done then on_done(nil) end
      return
    end

    -- Process Directory Preview Modal (STRICTLY for paths/directories)
    if data.action == "propose_dir" or (data.dir_preview and not data.active_target) then
      local base_dir = ""
      local entries = {}
      local sugg = nil
      if type(data.dir_preview) == "table" then
        if data.dir_preview.entries then
          base_dir = data.dir_preview.base_dir or ""
          entries = data.dir_preview.entries
          sugg = data.dir_preview.suggested or entries[1]
        elseif #data.dir_preview > 0 then
          entries = data.dir_preview
          sugg = entries[1]
        end
      end

      if #entries > 0 then
        local pending_path = (base_dir ~= "" and not base_dir:match("/$") and (base_dir .. "/") or base_dir) .. (sugg or "")
        M.state.pending_target = {
          path = pending_path,
          line = 1,
          col = 1,
          content = data.active_target and data.active_target.content or nil,
        }
        M.show_dir_preview(base_dir, entries, sugg, function(origin_win)
          M.accept()
        end)
      end
    end

    -- Process Multi-Target Queue
    if data.queue and #data.queue > 0 then
      M.state.queue = data.queue
      M.state.queue_index = 1
      update_queue_display(true)
    end

    -- Process Active Target Jump and in-line diff
    if data.active_target and data.active_target.path then
      M.state.last_target = data.active_target
      jump_to_target(data.active_target)
    end

    M.state.is_busy = false
    vim.cmd("redraw")
    if on_done then on_done(data) end
  end))
end

--- Reject current location and re-route
function M.reject(arg)
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

--- Run native logical compiler / code graph analysis (:Agent lgcc [args])
function M.lgcc(parts)
  local ok, lgcc = pcall(require, "lgcc")
  if not ok then
    vim.notify("Agent: lgcc module not available", vim.log.levels.ERROR)
    return
  end

  local fargs = vim.list_slice(parts, 2)
  local speak = false
  local bundle = true
  local user_budget = nil
  local spec_path = nil
  local open_qf = false
  local engine = "agy"
  local model_override = nil
  local target_file = nil
  local i = 1

  while i <= #fargs do
    local arg = fargs[i]
    if arg == "clear" or arg == "cancel" or arg == "stop" or arg == "kill" then
      lgcc.clear()
      return
    elseif arg == "-s" or arg == "--speak" or arg == "speak" then
      speak = true
    elseif arg == "-b" or arg == "--bundle" or arg == "bundle" then
      bundle = true
    elseif arg == "--no-bundle" or arg == "no-bundle" then
      bundle = false
    elseif arg == "--qf" or arg == "qf" then
      open_qf = true
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
    elseif arg == "--opencode" or arg == "opencode" then
      engine = "opencode"
    elseif arg == "--agy" or arg == "agy" then
      engine = "agy"
    elseif arg == "-l" or arg == "--local" or arg == "local" then
      engine = "local"
    elseif arg == "--spec" or arg == "spec" then
      i = i + 1
      spec_path = fargs[i]
    elseif not target_file and arg ~= "" and not arg:match("^-") then
      target_file = arg
    end
    i = i + 1
  end

  lgcc.lint({
    file = target_file,
    spec = spec_path,
    engine = engine,
    model = model_override,
    speak = speak,
    bundle = bundle,
    budget = user_budget,
    qf = open_qf,
  })
end

function M.setup()
  setup_highlights()

  vim.api.nvim_create_user_command("Agent", function(ctx)
    local raw_args = vim.trim(ctx.args or "")
    local parts = vim.split(raw_args, "%s+", { trimempty = true })
    local sub = (parts[1] or ""):lower()

    if sub == "listen" then
      M.record_voice(function(prompt)
        M.run(prompt, false)
      end)
    elseif sub == "lgcc" then
      M.lgcc(parts)
    elseif sub == "reject" then
      local rest = table.concat(vim.list_slice(parts, 2), " ")
      M.reject(rest)
    elseif sub == "next" then
      M.next()
    elseif sub == "prev" then
      M.prev()
    elseif sub == "queue" or sub == "tasks" or sub == "list" then
      M.toggle_queue()
    elseif sub == "accept" then
      M.accept()
    elseif sub == "diff" then
      local action = (parts[2] or ""):lower()
      if action == "accept" or action == "apply" then
        M.accept_diff()
      elseif action == "reject" or action == "cancel" or action == "clear" then
        M.clear_diff()
      else
        vim.notify("Usage: :Agent diff [accept|reject|clear]", vim.log.levels.INFO)
      end
    elseif sub == "clear" then
      M.state.queue = {}
      M.state.queue_index = 0
      M.close_dir_preview()
      M.clear_diff()
      vim.cmd("cclose")
      vim.notify("Agent: Cleared queue, diffs, and previews", vim.log.levels.INFO)
    elseif raw_args ~= "" then
      M.run(raw_args, false)
    else
      vim.notify("Usage: :Agent [<prompt> | listen | lgcc [opts] | reject [msg|listen] | next | prev | queue | accept | clear]", vim.log.levels.INFO)
    end
  end, {
    nargs = "*",
    complete = function(arglead, cmdline)
      local parts = vim.split(vim.trim(cmdline), "%s+")
      if #parts <= 2 and not cmdline:match("%s+$") then
        local subcmds = { "listen", "lgcc", "reject", "next", "prev", "queue", "accept", "diff", "clear" }
        return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, subcmds)
      elseif parts[2] == "lgcc" then
        local lgcc_flags = { "clear", "cancel", "stop", "--flash", "--sonnet", "--opencode", "--agy", "--argon", "-s", "--speak", "-b", "--bundle", "--no-bundle", "--budget", "--spec", "-l", "--local" }
        return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, lgcc_flags)
      elseif parts[2] == "diff" then
        local diff_sub = { "accept", "reject", "clear" }
        return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, diff_sub)
      end
      return {}
    end,
    desc = "Autonomous Silent Code Agent (:Agent [listen|lgcc|reject|next|prev|queue|accept])",
  })
end

return M
