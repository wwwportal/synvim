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
    vim.api.nvim_set_hl(0, "AgentDiffAdd", { fg = "#85e89d", bg = "#144620", bold = true, ctermfg = "Green", default = false })
    vim.api.nvim_set_hl(0, "AgentDiffDelete", { fg = "#ff7b72", bg = "#490202", strikethrough = true, ctermfg = "Red", default = false })
    vim.api.nvim_set_hl(0, "AgentDiffHeader", { fg = "#c9d1d9", bg = "#21262d", bold = true, ctermfg = "White", ctermbg = "DarkGray", default = false })
    vim.api.nvim_set_hl(0, "AgentDiffMenuSel", { fg = "#ffffff", bg = "#238636", bold = true, ctermfg = "White", ctermbg = "DarkGreen", default = false })
    vim.api.nvim_set_hl(0, "AgentDiffMenuBtn", { fg = "#8b949e", bg = "#161b22", ctermfg = "LightGray", ctermbg = "Black", default = false })
  else
    vim.api.nvim_set_hl(0, "AgentDiffAdd", { fg = "#0e6b0e", bg = "#d4edda", bold = true, ctermfg = "DarkGreen", ctermbg = "LightGreen", default = false })
    vim.api.nvim_set_hl(0, "AgentDiffDelete", { fg = "#b31d28", bg = "#f8d7da", strikethrough = true, ctermfg = "DarkRed", ctermbg = "LightRed", default = false })
    vim.api.nvim_set_hl(0, "AgentDiffHeader", { fg = "#ffffff", bg = "#2d3748", bold = true, ctermfg = "White", ctermbg = "DarkGray", default = false })
    vim.api.nvim_set_hl(0, "AgentDiffMenuSel", { fg = "#ffffff", bg = "#0969da", bold = true, ctermfg = "White", ctermbg = "Blue", default = false })
    vim.api.nvim_set_hl(0, "AgentDiffMenuBtn", { fg = "#24292f", bg = "#eaeef2", ctermfg = "Black", ctermbg = "LightGray", default = false })
  end
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

--- Get primary non-floating editor split window (skipping quickfix/nofile)
local function get_primary_editor_win()
  local cur = vim.api.nvim_get_current_win()
  local cur_cfg = vim.api.nvim_win_get_config(cur)
  if cur_cfg.relative == "" and vim.bo[vim.api.nvim_win_get_buf(cur)].buftype == "" then
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
      if p.mark_id then
        pcall(vim.api.nvim_buf_del_extmark, p.bufnr, ns_diff, p.mark_id)
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
  if not M.state.pending_diff then
    vim.notify("Agent: No pending diff to accept", vim.log.levels.INFO)
    return
  end
  local p = M.state.pending_diff
  local bufnr = p.bufnr
  local origin_win = p.origin_win
  local target_line = p.target_line
  local new_lines = p.new_lines
  local old_count = p.old_count or 0
  local is_new_file = p.is_new_file

  M.clear_diff(true)

  if vim.api.nvim_buf_is_valid(bufnr) then
    local was_mod = vim.bo[bufnr].modifiable
    vim.bo[bufnr].modifiable = true
    if is_new_file then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("silent! write")
      end)
      vim.notify("✓ Agent: Created and saved " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":."), vim.log.levels.INFO)
    else
      local total = vim.api.nvim_buf_line_count(bufnr)
      local s_line = math.max(0, target_line - 1)
      local e_line = math.min(total, s_line + old_count)
      vim.api.nvim_buf_set_lines(bufnr, s_line, e_line, false, new_lines)
      vim.notify("✓ Agent: Implementation accepted and applied to buffer", vim.log.levels.INFO)
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

--- Show suggested code in-line with green-red diff colors.
--- Cursor stays in the editor split so the user can scroll normally through the document!
function M.show_inline_diff(bufnr, target_line, new_content, old_lines_count, is_new_file)
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

  -- Extract existing lines if replacing
  local deleted_lines = {}
  if old_lines_count > 0 then
    local s_idx = target_line - 1
    local e_idx = math.min(total_lines, s_idx + old_lines_count)
    deleted_lines = vim.api.nvim_buf_get_lines(bufnr, s_idx, e_idx, false)
  end

  local header_text = is_new_file
    and "┌── Suggested New File (In-Line Diff) ────────────────────────┐"
    or  "┌── Suggested Implementation (In-Line Diff) ──────────────────┐"

  local virt_lines = {}
  table.insert(virt_lines, { { header_text, "AgentDiffHeader" } })

  -- Red deleted lines
  for _, line in ipairs(deleted_lines) do
    table.insert(virt_lines, { { "- " .. line, "AgentDiffDelete" } })
  end

  -- Green added lines
  for _, line in ipairs(new_lines) do
    table.insert(virt_lines, { { "+ " .. line, "AgentDiffAdd" } })
  end

  table.insert(virt_lines, { { "└── Commands: :Accept  |  :Reject  |  :Revise  (or [a]/[r]/[w] in task pane) ──┘", "AgentDiffHeader" } })

  -- Attach virtual diff lines above target_line so it is immediately visible
  local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns_diff, math.max(0, target_line - 1), 0, {
    virt_lines = virt_lines,
    virt_lines_above = true,
  })

  -- Direct cursor to the exact start line of the diff and center on screen
  pcall(vim.api.nvim_win_set_cursor, origin_win, { target_line, 0 })
  vim.cmd("normal! zz")

  M.state.pending_diff = {
    bufnr = bufnr,
    origin_win = origin_win,
    target_line = target_line,
    new_lines = new_lines,
    old_count = old_lines_count,
    is_new_file = is_new_file or false,
    mark_id = mark_id,
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
    vim.notify("Agent: Dismissed in-line diff preview", vim.log.levels.INFO)
  end, "Dismiss diff")
  bind_buf_key("<Tab>", function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.bo[b].buftype == "quickfix" then
        vim.api.nvim_set_current_win(w)
        return
      end
    end
  end, "Focus task pane")

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

--- Jump to a target location in the primary editor split (never creates a new split)
jump_to_target = function(target, win)
  if not target or not target.path or target.path == "" then return end
  local root = get_root_dir()
  local path = target.path
  if not path:match("^/") then
    path = root .. "/" .. path
  end

  local origin_win = win or M.state.origin_win
  if not origin_win or not vim.api.nvim_win_is_valid(origin_win) then
    origin_win = get_primary_editor_win()
  else
    local b = vim.api.nvim_win_get_buf(origin_win)
    local cfg = vim.api.nvim_win_get_config(origin_win)
    if vim.bo[b].buftype ~= "" or cfg.relative ~= "" then
      origin_win = get_primary_editor_win()
    end
  end
  if vim.api.nvim_win_is_valid(origin_win) then
    vim.api.nvim_set_current_win(origin_win)
  end

  local file_exists = (vim.fn.filereadable(path) == 1)
  local is_new = not file_exists or target.is_new_file or (target.action == "create")

  if not file_exists then
    local parent = vim.fn.fnamemodify(path, ":h")
    if vim.fn.isdirectory(parent) ~= 1 then
      vim.fn.mkdir(parent, "p")
    end
    -- Note: unwritten buffer is created with :edit below, avoiding writing empty stubs to disk
  end

  -- Switch buffer in the calling split
  local ok = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  if not ok then
    pcall(vim.cmd, "edit! " .. vim.fn.fnameescape(path))
  end
  local bufnr = vim.api.nvim_get_current_buf()

  local line = tonumber(target.line) or 1
  local col = math.max(0, (tonumber(target.col) or 1) - 1)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line > line_count then line = math.max(1, line_count) end
  if line < 1 then line = 1 end

  pcall(vim.api.nvim_win_set_cursor, origin_win, { line, col })
  vim.cmd("normal! zz")

  -- If code implementation was suggested, display in-line green-red diff!
  if type(target.content) == "string" and vim.trim(target.content) ~= "" then
    local old_count = is_new and 0 or ((type(target.old_lines_count) == "number") and target.old_lines_count or ((target.action == "replace") and 1 or 0))
    M.show_inline_diff(bufnr, line, target.content, old_count, is_new)
  end

  if origin_win and vim.api.nvim_win_is_valid(origin_win) then
    vim.api.nvim_set_current_win(origin_win)
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
        vim.wo[w].statusline = "%#AgentDiffHeader# ● AGENT TASK PANE %#AgentDiffMenuSel# [a] :Accept %#AgentDiffHeader#  %#AgentDiffMenuBtn# [r] :Reject %#AgentDiffHeader#  %#AgentDiffMenuBtn# [w] :Revise %#AgentDiffHeader#  %#AgentDiffMenuBtn# [<CR>] Jump %#AgentDiffHeader#  %#Normal# [q] Close %="
      end)
    end
  end

  local function jump_in_origin(close_qf)
    local cur_win = vim.api.nvim_get_current_win()
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

    local target_win = origin_win
    if not target_win or not vim.api.nvim_win_is_valid(target_win) or target_win == cur_win then
      target_win = M.state.origin_win
    end
    if not target_win or not vim.api.nvim_win_is_valid(target_win) or target_win == cur_win then
      target_win = get_primary_editor_win()
    end

    if not target_win or not vim.api.nvim_win_is_valid(target_win) or target_win == cur_win then
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if w ~= cur_win then
          local cfg = vim.api.nvim_win_get_config(w)
          if cfg.relative == "" then
            local b = vim.api.nvim_win_get_buf(w)
            if vim.bo[b].buftype == "" then
              target_win = w
              break
            end
          end
        end
      end
    end

    if close_qf then
      vim.cmd("cclose")
    end

    if target_win and vim.api.nvim_win_is_valid(target_win) then
      vim.api.nvim_set_current_win(target_win)
      local ok = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(filepath))
      if not ok then
        pcall(vim.cmd, "edit! " .. vim.fn.fnameescape(filepath))
      end
      local lnum = math.max(1, item.lnum or 1)
      local col = math.max(0, (item.col or 1) - 1)
      pcall(vim.api.nvim_win_set_cursor, target_win, { lnum, col })
      vim.cmd("normal! zz")

      if M.state.queue and #M.state.queue >= idx then
        M.state.queue_index = idx
        local cur = M.state.queue[idx]
        if cur and type(cur.content) == "string" and vim.trim(cur.content) ~= "" then
          local b = vim.api.nvim_win_get_buf(target_win)
          local is_new = cur.is_new_file or (cur.action == "create")
          local old_cnt = is_new and 0 or (cur.old_lines_count or (cur.action == "replace" and 1 or 0))
          M.show_inline_diff(b, lnum, cur.content, old_cnt, is_new)
        end
        update_queue_display(false)
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
    local is_new = item.is_new_file or (item.action == "create")
    local tag = is_new and "[NEW FILE]" or "[DIFF]"
    local status = item.done and "✓ [DONE]" or ((idx == M.state.queue_index) and "▶ [ACTIVE]" or "  [PENDING]")
    local desc = item.description or (is_new and ("Create " .. item.path) or ("Modify " .. item.path))
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

  if show_window then
    local orig_win = M.state.origin_win or get_primary_editor_win()
    vim.cmd("botright copen 6")
    local qf_w = vim.api.nvim_get_current_win()
    local qf_b = vim.api.nvim_win_get_buf(qf_w)
    setup_agent_qf_keymaps(orig_win, qf_b)
    if orig_win and vim.api.nvim_win_is_valid(orig_win) then
      vim.api.nvim_set_current_win(orig_win)
    end
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
CRITICAL INSTRUCTION: Do NOT call any tools or commands (do NOT run bash, grep, find, view_file, or any tools). All context is provided directly in this prompt.
NEVER reply with conversational chat, apologies, or natural language prose.
Output your verdict IMMEDIATELY in this turn as a single STRICT JSON object.

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

  if M.state.active_job then
    pcall(function() M.state.active_job:kill(9) end)
    M.state.active_job = nil
  end

  local agy_bin = vim.fn.exepath("agy")
  local cmd = {}
  if agy_bin ~= "" then
    cmd = { agy_bin, "-p", system_prompt, "--model", "gemini-3.8-flash-low", "--print-timeout", "30s", "--dangerously-skip-permissions", "--disable-slash-commands", "--effort", "low", "--output-format", "stream-json" }
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
  if data.action == "propose_dir" or data.dir_preview then
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
    local is_new = not file_exists or (data.action == "create_and_jump" or data.action == "create" or at.action == "create")
    primary_target = {
      path = path,
      line = tonumber(at.line) or tonumber(data.line) or 1,
      col = tonumber(at.col) or tonumber(data.col) or 1,
      content = (type(at.content) == "string" and at.content) or (type(data.content) == "string" and data.content) or nil,
      action = is_new and "create" or (at.action or data.action or "replace"),
      old_lines_count = is_new and 0 or (tonumber(at.old_lines_count) or tonumber(data.old_lines_count) or (at.action == "replace" and 1 or 0)),
      is_new_file = is_new,
      description = at.description or data.description or (is_new and ("Create " .. path) or ("Modify " .. path)),
    }
  end

  -- 2. Build unified queue for bottom task pane
  local queue = {}
  if primary_target then
    table.insert(queue, primary_target)
  end
  if data.queue and #data.queue > 0 then
    for _, q_item in ipairs(data.queue) do
      local q_path = q_item.path
      local q_root = get_root_dir()
      local q_full = q_path:match("^/") and q_path or (q_root .. "/" .. q_path)
      local q_exists = (vim.fn.filereadable(q_full) == 1)
      local q_is_new = not q_exists or (q_item.action == "create")
      q_item.is_new_file = q_is_new
      if not primary_target or q_item.path ~= primary_target.path or q_item.line ~= primary_target.line then
        table.insert(queue, q_item)
      end
    end
  end

  if #queue > 0 then
    M.state.queue = queue
    M.state.queue_index = 1
    update_queue_display(true)
    local cur = queue[1]
    M.state.last_target = cur
    jump_to_target(cur, origin_win)
  end

  M.state.is_busy = false
  vim.cmd("redraw")
  if on_done then on_done(data) end
end
M.process_response = process_agent_response

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

function M.setup()
  setup_highlights()

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
      vim.notify("Usage: :Agent [<prompt> | listen | lgcc [opts] | reject [msg|listen] | next | prev | queue | accept | clear | stop]", vim.log.levels.INFO)
    end
  end, {
    nargs = "*",
    complete = function(arglead, cmdline)
      local parts = vim.split(vim.trim(cmdline), "%s+")
      if #parts <= 2 and not cmdline:match("%s+$") then
        local subcmds = { "listen", "lgcc", "reject", "accept", "revise", "write", "next", "prev", "queue", "diff", "clear", "stop", "cancel" }
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
    desc = "Autonomous Silent Code Agent (:Agent [listen|lgcc|reject|next|prev|queue|accept|revise])",
  })

  vim.api.nvim_create_user_command("Accept", function()
    M.accept()
  end, { desc = "Accept and apply current agent in-line diff or task" })

  vim.api.nvim_create_user_command("Reject", function(ctx)
    M.reject(ctx.args)
  end, { nargs = "*", desc = "Reject current agent diff or task" })

  vim.api.nvim_create_user_command("Revise", function(ctx)
    local arg = vim.trim(ctx.args or "")
    if arg ~= "" then
      M.clear_diff()
      M.run(arg, true)
    else
      M.write_revision()
    end
  end, { nargs = "*", desc = "Revise current agent instruction in natural language" })
end

return M
