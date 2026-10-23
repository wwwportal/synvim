local M = {}

local search = require("agent.search")

M.preview_buf = nil
M.preview_win = nil
M.ns_preview = vim.api.nvim_create_namespace("synvim_cmdline_preview")
M.enabled = false -- Disabled by default to prevent floating clutter over editor code

--- Safely close floating preview window and buffer
function M.close_preview()
  if M.preview_win and vim.api.nvim_win_is_valid(M.preview_win) then
    pcall(vim.api.nvim_win_close, M.preview_win, true)
  end
  M.preview_win = nil

  if M.preview_buf and vim.api.nvim_buf_is_valid(M.preview_buf) then
    pcall(vim.api.nvim_buf_delete, M.preview_buf, { force = true })
  end
  M.preview_buf = nil
end

--- Parse cmdline to check if it matches an agent command that supports multi-line visual preview
function M.parse_cmd(cmdline)
  if not cmdline or cmdline == "" then return nil, nil end
  -- Strip visual range prefixes like '<,'> or :'<,'> or leading colons
  local clean = cmdline:gsub("^%s*'<,'>%s*", ""):gsub("^%s*:'<,'>%s*", ""):gsub("^%s*:%s*", "")

  local ask_q = clean:match("^[Aa]sk%s*(.*)$")
  if ask_q ~= nil then return "ask", ask_q end

  local task_q = clean:match("^[Tt]asks%s+add%s*(.*)$")
  if task_q ~= nil then return "tasks", task_q end

  local find_q = clean:match("^[Ff]ind%s*(.*)$")
  if find_q ~= nil then return "find", find_q end

  return nil, nil
end

--- Parse query into discrete items (questions, tasks, or query lines)
function M.get_preview_items(cmd_type, raw_query)
  local norm = (raw_query or ""):gsub("\\r\\n", "\n"):gsub("\\n", "\n")
  local trimmed = vim.trim(norm)

  if trimmed == "" then
    return {}
  end

  if cmd_type == "ask" then
    local questions = search.split_questions(norm)
    if #questions > 1 then
      return questions
    end

    -- Check if string has explicit line breaks
    local raw_lines = {}
    for line in norm:gmatch("[^\r\n]+") do
      local t = vim.trim(line)
      if t ~= "" then table.insert(raw_lines, t) end
    end
    if #raw_lines > 1 then
      return raw_lines
    end

    return { trimmed }
  elseif cmd_type == "tasks" then
    -- Split numbered tasks or newlines
    local str = norm
    if str:match("^%s*[0-9]+[%.)]") or str:match("%s+[0-9]+[%.)]%s+") then
      str = ("\n" .. str):gsub("([%s\r\n]+[0-9]+[%.)]%s+)", "\n%1")
    end
    local tasks = {}
    for line in str:gmatch("[^\r\n]+") do
      local task_text = line:match("^%s*[0-9]+[%.)]%s*(.*)$") or line:match("^%s*[-*]%s*(.*)$")
      if task_text and vim.trim(task_text) ~= "" then
        table.insert(tasks, vim.trim(task_text))
      elseif vim.trim(line) ~= "" then
        table.insert(tasks, vim.trim(line))
      end
    end
    if #tasks > 0 then return tasks end

    local raw_lines = {}
    for line in norm:gmatch("[^\r\n]+") do
      local t = vim.trim(line)
      if t ~= "" then table.insert(raw_lines, t) end
    end
    if #raw_lines > 0 then return raw_lines end
    return { trimmed }
  else
    return { trimmed }
  end
end

--- Update or create floating preview window above the command entry line
function M.update_preview(cmdline)
  if not M.enabled then return end

  local cmd_type, raw_query = M.parse_cmd(cmdline)
  if not cmd_type then
    M.close_preview()
    return
  end

  local items = M.get_preview_items(cmd_type, raw_query)
  local display_lines = {}
  local highlights = {} -- list of { line = idx, col_start = 0, col_end = N, hl_group = "..." }
  local title = ""

  if #items == 0 then
    if cmd_type == "ask" then
      title = " Ask: Multi-line Query Preview "
      table.insert(display_lines, "Type your question(s).")
      table.insert(display_lines, "Tip: Press <C-j> or type \\n to break into multiple questions.")
    elseif cmd_type == "tasks" then
      title = " Tasks Add: Multi-line Preview "
      table.insert(display_lines, "Type task description or numbered list.")
      table.insert(display_lines, "Tip: Press <C-j> or type \\n to add multiple tasks.")
    else
      title = " Find: Search Preview "
      table.insert(display_lines, "Type keyword or concept to search.")
    end
    highlights[1] = { line = 1, col_start = 0, col_end = -1, hl_group = "Comment" }
  else
    if cmd_type == "ask" then
      if #items > 1 then
        title = string.format(" Ask: %d Questions Detected ", #items)
        for i, item in ipairs(items) do
          local prefix = string.format("[Q%d] ", i)
          table.insert(display_lines, prefix .. item)
          table.insert(highlights, { line = #display_lines - 1, col_start = 0, col_end = #prefix, hl_group = "DiagnosticInfo" })
        end
      else
        title = " Ask: Query Preview "
        local prefix = "[Q1] "
        table.insert(display_lines, prefix .. items[1])
        table.insert(highlights, { line = 0, col_start = 0, col_end = #prefix, hl_group = "DiagnosticInfo" })
        table.insert(display_lines, "")
        table.insert(display_lines, "Tip: Press <C-j> or type \\n to break into multiple questions.")
        table.insert(highlights, { line = #display_lines - 1, col_start = 0, col_end = -1, hl_group = "Comment" })
      end
    elseif cmd_type == "tasks" then
      if #items > 1 then
        title = string.format(" Tasks Add: %d Tasks Detected ", #items)
        for i, item in ipairs(items) do
          local prefix = string.format("[T%d] ", i)
          table.insert(display_lines, prefix .. item)
          table.insert(highlights, { line = #display_lines - 1, col_start = 0, col_end = #prefix, hl_group = "Title" })
        end
      else
        title = " Tasks Add: Task Preview "
        local prefix = "[T1] "
        table.insert(display_lines, prefix .. items[1])
        table.insert(highlights, { line = 0, col_start = 0, col_end = #prefix, hl_group = "Title" })
        table.insert(display_lines, "")
        table.insert(display_lines, "Tip: Press <C-j> or type \\n to add multiple tasks on discrete lines.")
        table.insert(highlights, { line = #display_lines - 1, col_start = 0, col_end = -1, hl_group = "Comment" })
      end
    else
      title = " Find: Search Preview "
      table.insert(display_lines, "Query: " .. items[1])
    end
  end

  -- Window geometry
  local total_cols = vim.o.columns
  local total_lines = vim.o.lines
  local width = math.min(100, math.max(48, total_cols - 4))
  local inner_width = math.max(10, width - 4)

  -- Calculate wrapped height
  local total_visual_lines = 0
  for _, line in ipairs(display_lines) do
    local l_len = #line
    total_visual_lines = total_visual_lines + math.max(1, math.ceil(l_len / inner_width))
  end

  local height = math.min(12, math.max(1, total_visual_lines))
  local cmdheight = vim.o.cmdheight or 1
  -- Position window flush directly above the bottom command entry line
  local row = math.max(0, total_lines - (height + 2) - cmdheight)
  local col = math.max(1, math.floor((total_cols - width) / 2))

  if not M.preview_buf or not vim.api.nvim_buf_is_valid(M.preview_buf) then
    M.preview_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[M.preview_buf].buftype = "nofile"
    vim.bo[M.preview_buf].bufhidden = "wipe"
  end

  vim.api.nvim_buf_set_lines(M.preview_buf, 0, -1, false, display_lines)
  vim.api.nvim_buf_clear_namespace(M.preview_buf, M.ns_preview, 0, -1)
  for _, hl in ipairs(highlights) do
    pcall(vim.api.nvim_buf_set_extmark, M.preview_buf, M.ns_preview, hl.line, hl.col_start, {
      end_col = hl.col_end >= 0 and hl.col_end or #display_lines[hl.line + 1],
      hl_group = hl.hl_group,
    })
  end

  local win_config = {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "left",
    footer = " [<C-j>: Newline | <CR>: Submit | <Esc>: Cancel] ",
    footer_pos = "right",
    focusable = false,
    noautocmd = true,
    zindex = 250,
  }

  if not M.preview_win or not vim.api.nvim_win_is_valid(M.preview_win) then
    local ok, win = pcall(vim.api.nvim_open_win, M.preview_buf, false, win_config)
    if ok then
      M.preview_win = win
      vim.wo[win].wrap = true
      vim.wo[win].linebreak = true
      vim.wo[win].breakindent = true
      vim.wo[win].breakindentopt = "shift:5"
    end
  else
    pcall(vim.api.nvim_win_set_config, M.preview_win, win_config)
  end
end

--- Setup autocmds and keymaps for cmdline visual preview
function M.setup()
  local grp = vim.api.nvim_create_augroup("SynvimCmdlinePreview", { clear = true })

  vim.api.nvim_create_autocmd("CmdlineChanged", {
    group = grp,
    callback = function()
      if vim.fn.getcmdtype() ~= ":" then
        M.close_preview()
        return
      end
      local cmdline = vim.fn.getcmdline()
      M.update_preview(cmdline)
    end,
    desc = "Live visual line-break rendering while typing queries in command entry line",
  })

  vim.api.nvim_create_autocmd("CmdlineLeave", {
    group = grp,
    callback = function()
      M.close_preview()
    end,
    desc = "Clean up cmdline floating preview on execute or cancel",
  })

  -- Keymap in cmdline: <C-j> and <S-CR> insert newline break
  local function insert_newline_break()
    local cmdtype = vim.fn.getcmdtype()
    if cmdtype == ":" then
      local line = vim.fn.getcmdline()
      local cmd_type = M.parse_cmd(line)
      if cmd_type then
        return "\\n "
      end
    end
    return vim.api.nvim_replace_termcodes("<CR>", true, false, true)
  end

  pcall(vim.keymap.set, "c", "<C-j>", insert_newline_break, { expr = true, desc = "Insert newline break in Ask / Tasks query" })
  pcall(vim.keymap.set, "c", "<S-CR>", insert_newline_break, { expr = true, desc = "Insert newline break in Ask / Tasks query" })
end

return M
