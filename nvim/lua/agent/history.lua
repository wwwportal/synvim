local M = {}

local state_mod = require("agent.state")

M.state = {
  files = {},        -- map of path -> { path, rel_path, line, col, anchor, snippet, timestamp, count, time_spent_secs, chars_added, chars_deleted, last_enter }
  lru = {},          -- ordered list of unique file paths (most recently visited first)
  transitions = {},  -- map of source_path -> { [target_path] = count }
  incoming = {},     -- map of target_path -> { [source_path] = count }
  attached_bufs = {},-- map of bufnr -> true (for on_bytes edit tracking)
  prev_file = nil,
  win = nil,
  buf = nil,
  inspector_win = nil,
  inspector_buf = nil,
  ns = vim.api.nvim_create_namespace("synvim_file_history"),
  ns_inspector = vim.api.nvim_create_namespace("synvim_history_inspector"),
}

--- Format duration in seconds into human-readable compact time
local function format_duration(secs)
  secs = math.max(0, math.floor(secs or 0))
  if secs < 60 then
    return string.format("%ds", secs)
  elseif secs < 3600 then
    return string.format("%dm %02ds", math.floor(secs / 60), secs % 60)
  else
    return string.format("%dh %02dm", math.floor(secs / 3600), math.floor((secs % 3600) / 60))
  end
end

--- Format character edits into compact string
local function format_chars(added, deleted)
  return string.format("+%d/-%d chars", added or 0, deleted or 0)
end

--- Check if buffer represents a normal, persistent file
local function is_trackable_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return false end
  local bt = vim.bo[bufnr].buftype
  if bt ~= "" then return false end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name or name == "" then return false end
  if name:match("^%a+://") then return false end
  if name:match("^term:") then return false end

  -- Ignore synvim internal floating buffers
  local ft = vim.bo[bufnr].filetype
  if ft == "synvim-help" or ft == "synvim-history" or ft == "synvim-history-inspector" then return false end

  return true
end

--- Get repository root directory for clean relative path display
local function get_root_dir()
  local ok, ui = pcall(require, "agent.ui")
  if ok and ui.get_root_dir then
    return ui.get_root_dir()
  end
  return vim.fn.getcwd()
end

--- Normalize absolute file path
local function normalize_path(path)
  if not path or path == "" then return "" end
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

--- Extract line snippet from buffer or disk
local function get_line_snippet(bufnr, path, line_nr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
    local count = vim.api.nvim_buf_line_count(bufnr)
    if line_nr >= 1 and line_nr <= count then
      local lines = vim.api.nvim_buf_get_lines(bufnr, line_nr - 1, line_nr, false)
      if lines and lines[1] then
        local trimmed = vim.trim(lines[1])
        if trimmed ~= "" then return trimmed end
      end
    end
  end

  if path and vim.fn.filereadable(path) == 1 then
    local ok, file_lines = pcall(vim.fn.readfile, path, "", line_nr + 1)
    if ok and file_lines and file_lines[line_nr] then
      local trimmed = vim.trim(file_lines[line_nr])
      if trimmed ~= "" then return trimmed end
    end
  end

  return ""
end

--- Find the closest in-tree task (TODO/FIXME/SPEC/contract) or nearest symbol to cursor line
function M.find_closest_anchor(filepath, target_line)
  if not filepath or vim.fn.filereadable(filepath) ~= 1 then
    return { type = "line", line = target_line or 1, label = string.format("line %d", target_line or 1) }
  end

  local lines = nil
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_is_loaded(b) then
      if normalize_path(vim.api.nvim_buf_get_name(b)) == filepath then
        lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
        break
      end
    end
  end

  if not lines then
    local ok, fl = pcall(vim.fn.readfile, filepath)
    if ok and fl then lines = fl end
  end

  if not lines or #lines == 0 then
    return { type = "line", line = target_line or 1, label = string.format("line %d", target_line or 1) }
  end

  target_line = math.min(#lines, math.max(1, target_line or 1))

  -- 1. Scan for in-tree task contracts
  local tasks_mod = require("agent.tasks")
  local best_task = nil
  local min_task_dist = 999999

  for idx, l in ipairs(lines) do
    local is_comment = l:find("^%s*//") or l:find("^%s*#") or l:find("^%s*%-%-") or l:find("^%s*/%*") or l:find("^%s*%- %[ %]")
    if is_comment then
      local has_tag = l:find("%f[%a]TODO%f[%A]") or l:find("%f[%a]FIXME%f[%A]") or l:find("%f[%a]SPEC%f[%A]") or l:find("%f[%a]TASK%f[%A]")
      if has_tag or l:find("^%s*%- %[ %]") then
        local t_info = tasks_mod.extract_task_info(l)
        local slug = t_info and t_info.id
        local desc = t_info and t_info.desc
        if not desc or desc == "" then
          desc = l:gsub("^[ \t]*[#/%-%*%\"]+%s*", ""):gsub("^[A-Z]+%b():?%s*", ""):gsub("^[A-Z]+:%s*", "")
        end
        desc = vim.trim(desc or "")
        if #desc > 60 then desc = desc:sub(1, 57) .. "..." end

        local dist = math.abs(idx - target_line)
        if dist < min_task_dist then
          min_task_dist = dist
          local label = ""
          if slug and slug ~= "task" and slug ~= "" then
            label = string.format("[%s]", slug)
          elseif desc ~= "" then
            label = string.format("TODO: %s", desc)
          else
            label = "TODO: task"
          end
          best_task = {
            type = "task",
            id = slug,
            desc = desc,
            label = label,
            status = t_info and t_info.status or "TODO",
            line = idx,
            dist = dist,
          }
        end
      end
    end
  end

  if best_task and min_task_dist <= 120 then
    return best_task
  end

  -- 2. Fallback: find nearest enclosing function or symbol definition
  local best_sym = nil
  local min_sym_dist = 999999
  for idx, l in ipairs(lines) do
    local fn_name = l:match("^%s*function%s+([%w_.:]+)")
      or l:match("^%s*local%s+function%s+([%w_]+)")
      or l:match("^%s*def%s+([%w_]+)")
      or l:match("^%s*pub%s+fn%s+([%w_]+)")
      or l:match("^%s*fn%s+([%w_]+)")
      or l:match("^%s*class%s+([%w_]+)")
    if fn_name then
      local dist = math.abs(idx - target_line)
      if dist < min_sym_dist then
        min_sym_dist = dist
        best_sym = {
          type = "symbol",
          name = fn_name,
          line = idx,
          dist = dist,
          label = string.format("fn %s()", fn_name),
        }
      end
    end
  end

  if best_sym and min_sym_dist <= 80 then
    return best_sym
  end

  if best_task then
    return best_task
  end

  return {
    type = "line",
    line = target_line,
    label = string.format("line %d", target_line),
  }
end

--- Attach buffer for real-time character addition and deletion tracking
function M.ensure_buffer_tracked(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if not is_trackable_buffer(bufnr) then return end
  if M.state.attached_bufs[bufnr] then return end

  M.state.attached_bufs[bufnr] = true
  pcall(vim.api.nvim_buf_attach, bufnr, false, {
    on_bytes = function(_, buf, _, _, _, _, _, _, o_byte, _, _, n_byte)
      if not vim.api.nvim_buf_is_valid(buf) then return end
      local b_name = normalize_path(vim.api.nvim_buf_get_name(buf))
      if b_name ~= "" and M.state.files[b_name] then
        local f = M.state.files[b_name]
        f.chars_deleted = (f.chars_deleted or 0) + (o_byte or 0)
        f.chars_added = (f.chars_added or 0) + (n_byte or 0)
      end
    end,
    on_detach = function()
      M.state.attached_bufs[bufnr] = nil
    end,
  })
end

--- Get cumulative active time spent in a file (including currently active session)
function M.get_file_time(entry)
  if not entry then return 0 end
  local total = entry.time_spent_secs or 0
  if entry.last_enter then
    local delta = os.time() - entry.last_enter
    if delta > 0 then
      total = total + delta
    end
  end
  return total
end

--- Record visit to a file
function M.record_visit(path, line, col, bufnr)
  if not path or path == "" then return end
  local norm_path = normalize_path(path)
  if norm_path == "" or vim.fn.filereadable(norm_path) ~= 1 then return end

  line = math.max(1, line or 1)
  col = math.max(0, col or 0)

  local root = get_root_dir()
  local rel_path = norm_path
  if root and root ~= "" and norm_path:find(root, 1, true) == 1 then
    rel_path = norm_path:sub(#root + 2)
  else
    rel_path = vim.fn.fnamemodify(norm_path, ":.")
  end

  local snippet = get_line_snippet(bufnr, norm_path, line)
  local existing = M.state.files[norm_path]
  local anchor = M.find_closest_anchor(norm_path, line)

  M.state.files[norm_path] = {
    path = norm_path,
    rel_path = rel_path,
    line = line,
    col = col,
    anchor = anchor,
    snippet = snippet ~= "" and snippet or (existing and existing.snippet or ""),
    timestamp = os.time(),
    count = (existing and existing.count or 0) + 1,
    time_spent_secs = existing and existing.time_spent_secs or 0,
    chars_added = existing and existing.chars_added or 0,
    chars_deleted = existing and existing.chars_deleted or 0,
    last_enter = existing and existing.last_enter or os.time(),
  }

  if bufnr then
    M.ensure_buffer_tracked(bufnr)
  end

  -- Maintain unique LRU list (no duplicate files)
  for i = #M.state.lru, 1, -1 do
    if M.state.lru[i] == norm_path then
      table.remove(M.state.lru, i)
    end
  end
  table.insert(M.state.lru, 1, norm_path)

  -- Record graph transition edge from previous file
  if M.state.prev_file and M.state.prev_file ~= norm_path and M.state.files[M.state.prev_file] then
    local p = M.state.prev_file
    M.state.transitions[p] = M.state.transitions[p] or {}
    M.state.transitions[p][norm_path] = (M.state.transitions[p][norm_path] or 0) + 1

    M.state.incoming[norm_path] = M.state.incoming[norm_path] or {}
    M.state.incoming[norm_path][p] = (M.state.incoming[norm_path][p] or 0) + 1
  end

  M.state.prev_file = norm_path
end

--- Update cursor position for currently active buffer
function M.update_current_position()
  local cur_win = vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(cur_win) then return end
  local cur_buf = vim.api.nvim_win_get_buf(cur_win)

  if is_trackable_buffer(cur_buf) then
    local name = vim.api.nvim_buf_get_name(cur_buf)
    local cur = vim.api.nvim_win_get_cursor(cur_win)
    M.record_visit(name, cur[1], cur[2], cur_buf)
  end
end

--- Clear visit history
function M.clear()
  M.state.files = {}
  M.state.lru = {}
  M.state.transitions = {}
  M.state.incoming = {}
  M.state.attached_bufs = {}
  M.state.prev_file = nil
  vim.notify("Visited files history cleared.", vim.log.levels.INFO)
end

--- Get unique visited files ordered by recent visits
function M.get_history()
  local res = {}
  for _, path in ipairs(M.state.lru) do
    if M.state.files[path] then
      table.insert(res, M.state.files[path])
    end
  end
  return res
end

--- Jump to a file entry at its closest task or recorded line
function M.jump_to(entry, editor_win)
  if not entry or not entry.path then return end
  local path = entry.path
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("History: File not found on disk: " .. path, vim.log.levels.WARN)
    return
  end

  local win = editor_win
  local ui = require("agent.ui")
  if not win or not vim.api.nvim_win_is_valid(win) or vim.bo[vim.api.nvim_win_get_buf(win)].buftype ~= "" then
    win = ui.get_primary_editor_win()
  end

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end

  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local total_lines = vim.api.nvim_buf_line_count(0)
  -- Prioritize jumping directly to the closest in-tree task contract / anchor
  local target_line = (entry.anchor and entry.anchor.line) or entry.line or 1
  target_line = math.min(total_lines, math.max(1, target_line))
  local target_col = entry.col or 0
  pcall(vim.api.nvim_win_set_cursor, 0, { target_line, target_col })
  pcall(function() vim.cmd("normal! zz") end)

  -- Flash line
  pcall(function()
    local ns = state_mod.ns_flash
    vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(0, ns, target_line - 1, 0, {
      end_row = target_line,
      hl_group = "IncSearch",
      hl_eol = true,
    })
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(0) then
        pcall(vim.api.nvim_buf_clear_namespace, 0, ns, 0, -1)
      end
    end, 300)
  end)
end

--- Build Tree lines: EVERY file appears EXACTLY ONCE. No duplicate loop lines. No loopback symbols.
local function build_tree_lines(entries, current_file)
  local lines = {}
  local highlights = {}
  local line_to_entry = {}
  local node_lines = {}
  local path_to_line = {}
  local line_to_head_col = {}

  local path_to_idx = {}
  for idx, entry in ipairs(entries) do
    path_to_idx[entry.path] = idx
  end

  local rendered = {}
  local function render_node(entry, prefix, is_last, depth)
    if depth > 10 then return end
    local path = entry.path
    if rendered[path] then return end
    rendered[path] = true

    local idx = path_to_idx[path] or 0
    local is_cur = (path == current_file)
    local connector = depth == 0 and "" or (is_last and "└───> " or "├───> ")
    local idx_str = string.format("[%d]", idx)
    local file_part = entry.rel_path or vim.fn.fnamemodify(path, ":t")

    -- Extract closest task badge
    local task_badge = ""
    local anchor = entry.anchor or M.find_closest_anchor(path, entry.line)
    if anchor and anchor.type == "task" then
      if anchor.id and anchor.id ~= "task" and anchor.id ~= "" then
        task_badge = string.format("[@%s]", anchor.id)
      elseif anchor.desc and anchor.desc ~= "" then
        task_badge = string.format("[Task: %s]", anchor.desc:sub(1, 26))
      else
        task_badge = "[@task]"
      end
    elseif anchor and anchor.type == "symbol" then
      task_badge = string.format("[%s]", anchor.label)
    end

    local time_str = format_duration(M.get_file_time(entry))
    local edits_str = format_chars(entry.chars_added, entry.chars_deleted)
    local cur_badge = is_cur and "  [ACTIVE]" or ""

    local line_str = prefix .. connector .. idx_str .. " " .. file_part
    if task_badge ~= "" then
      line_str = line_str .. "  " .. task_badge
    end
    line_str = line_str .. "  " .. time_str .. "  " .. edits_str .. cur_badge

    local line_idx = #lines
    table.insert(lines, line_str)
    line_to_entry[line_idx + 1] = entry
    table.insert(node_lines, line_idx + 1)
    path_to_line[path] = line_idx + 1

    -- Exact 0-based column of the number head for snapping
    local s_b = line_str:find("%[(%d+)%]")
    line_to_head_col[line_idx + 1] = s_b

    -- Connector highlight
    if #connector > 0 then
      table.insert(highlights, {
        line = line_idx,
        col_start = #prefix,
        col_end = #prefix + #connector,
        hl_group = "Directory",
      })
    end

    -- Node index
    local idx_start = #prefix + #connector
    local idx_end = idx_start + #idx_str
    table.insert(highlights, {
      line = line_idx,
      col_start = idx_start,
      col_end = idx_end,
      hl_group = "Title",
    })

    -- Filename / relative path
    local f_start = idx_end + 1
    local f_end = f_start + #file_part
    table.insert(highlights, {
      line = line_idx,
      col_start = f_start,
      col_end = f_end,
      hl_group = "Function",
    })

    -- Task badge highlight
    if task_badge ~= "" then
      local t_start = f_end + 2
      local t_end = t_start + #task_badge
      table.insert(highlights, {
        line = line_idx,
        col_start = t_start,
        col_end = t_end,
        hl_group = "Special",
      })
    end

    -- Active file badge
    if is_cur then
      table.insert(highlights, {
        line = line_idx,
        col_start = #line_str - #cur_badge,
        col_end = #line_str,
        hl_group = "ModeMsg",
      })
    end

    -- Identify outgoing transitions: only unvisited children!
    -- NO DUPLICATES, NO LOOPS, NO REPEATING PREVIOUS NODES!
    local out_edges = M.state.transitions[path] or {}
    local children = {}
    for tgt, _ in pairs(out_edges) do
      if path_to_idx[tgt] and not rendered[tgt] then
        table.insert(children, M.state.files[tgt])
      end
    end

    table.sort(children, function(a, b) return (a.timestamp or 0) > (b.timestamp or 0) end)

    local child_prefix = prefix .. (depth == 0 and " " or (is_last and "      " or "│     "))
    for c_i, child in ipairs(children) do
      local is_child_last = (c_i == #children)
      render_node(child, child_prefix, is_child_last, depth + 1)
    end
  end

  -- First, render tree rooted at current_file if present
  if current_file and M.state.files[current_file] then
    render_node(M.state.files[current_file], " ", false, 0)
  end

  -- Then render any remaining unrendered nodes in LRU order
  for _, entry in ipairs(entries) do
    if not rendered[entry.path] then
      render_node(entry, " ", false, 0)
    end
  end

  return lines, highlights, line_to_entry, node_lines, path_to_line, line_to_head_col
end

--- Show interactive Visited Files Graph window
function M.show_history(opts)
  opts = opts or {}
  M.update_current_position()

  local entries = M.get_history()
  if #entries == 0 then
    vim.notify("History: No visited files recorded in this session.", vim.log.levels.INFO)
    return
  end

  local cur_buf = vim.api.nvim_get_current_buf()
  local current_file = normalize_path(vim.api.nvim_buf_get_name(cur_buf))
  local origin_win = vim.api.nvim_get_current_win()

  local lines, highlights, line_to_entry, node_lines, path_to_line, line_to_head_col = build_tree_lines(entries, current_file)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "synvim-history"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Apply extmarks
  vim.api.nvim_buf_clear_namespace(buf, M.state.ns, 0, -1)
  for _, hl in ipairs(highlights) do
    pcall(vim.api.nvim_buf_set_extmark, buf, M.state.ns, hl.line, hl.col_start, {
      end_col = hl.col_end >= 0 and hl.col_end or #lines[hl.line + 1],
      hl_group = hl.hl_group,
    })
  end

  -- Window dimensions
  local total_cols = vim.o.columns
  local total_lines = vim.o.lines
  local width = math.min(110, math.max(70, total_cols - 10))
  local inspector_h = 4
  local graph_h = math.min(math.max(5, total_lines - inspector_h - 10), #lines + 1)
  local total_block_h = graph_h + 2 + inspector_h + 2
  local start_row = math.max(1, math.floor((total_lines - total_block_h) / 2))
  local start_col = math.max(1, math.floor((total_cols - width) / 2))

  local win_config = {
    relative = "editor",
    row = start_row,
    col = start_col,
    width = width,
    height = graph_h,
    style = "minimal",
    border = "rounded",
    title = string.format(" Visited Files History (%d files) ", #entries),
    title_pos = "left",
    zindex = 150,
  }

  local win = vim.api.nvim_open_win(buf, true, win_config)
  M.state.win = win
  M.state.buf = buf

  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true

  -- Create docked bottom Inspector Bar
  local insp_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[insp_buf].buftype = "nofile"
  vim.bo[insp_buf].bufhidden = "wipe"
  vim.bo[insp_buf].filetype = "synvim-history-inspector"

  local insp_win_config = {
    relative = "editor",
    row = start_row + graph_h + 2,
    col = start_col,
    width = width,
    height = inspector_h,
    style = "minimal",
    border = "rounded",
    title = " File & Task Context ",
    title_pos = "left",
    focusable = false,
    zindex = 150,
  }

  local insp_win = vim.api.nvim_open_win(insp_buf, false, insp_win_config)
  M.state.inspector_win = insp_win
  M.state.inspector_buf = insp_buf
  vim.wo[insp_win].wrap = false

  local function close_win()
    if M.state.win and vim.api.nvim_win_is_valid(M.state.win) then
      pcall(vim.api.nvim_win_close, M.state.win, true)
    end
    if M.state.inspector_win and vim.api.nvim_win_is_valid(M.state.inspector_win) then
      pcall(vim.api.nvim_win_close, M.state.inspector_win, true)
    end
    M.state.win = nil
    M.state.buf = nil
    M.state.inspector_win = nil
    M.state.inspector_buf = nil
  end

  local function do_jump(close_after)
    local cur_line = vim.fn.line(".")
    local entry = line_to_entry[cur_line]
    if not entry then
      entry = line_to_entry[cur_line - 1] or line_to_entry[cur_line + 1]
    end
    if not entry then return end

    if close_after then
      close_win()
    end
    M.jump_to(entry, origin_win)
  end

  -- Dynamic inspector in the bottom bar: shows path, closest task, time spent, edits
  local function update_inspector()
    if not win or not vim.api.nvim_win_is_valid(win) then return end
    if not M.state.inspector_buf or not vim.api.nvim_buf_is_valid(M.state.inspector_buf) then return end

    local cur_l = vim.fn.line(".")
    local entry = line_to_entry[cur_l] or line_to_entry[cur_l - 1] or line_to_entry[cur_l + 1]
    if not entry then return end

    local entry_idx = 1
    for i, e in ipairs(entries) do
      if e.path == entry.path then entry_idx = i; break end
    end
    local anchor = entry.anchor or M.find_closest_anchor(entry.path, entry.line)
    local is_cur = (entry.path == current_file)

    local total_time = format_duration(M.get_file_time(entry))
    local edits = format_chars(entry.chars_added, entry.chars_deleted)

    local l1 = string.format(" [%d] %s:%d%s",
      entry_idx,
      entry.rel_path,
      anchor.line or entry.line,
      is_cur and "  [ACTIVE]" or ""
    )

    local l2 = ""
    if anchor.type == "task" then
      local desc_str = (anchor.desc and anchor.desc ~= "") and (' "' .. anchor.desc .. '"') or ""
      l2 = string.format(" Task:   @ %s%s  (status: %s)", anchor.label, desc_str, anchor.status or "TODO")
    elseif anchor.type == "symbol" then
      l2 = string.format(" Scope:  @ %s (nearest code definition)", anchor.label)
    else
      l2 = string.format(" Scope:  line %d", anchor.line or entry.line)
    end

    local l3 = string.format(" Stats:  Time spent: %s  |  Edits: %s  |  Visits: %dx",
      total_time,
      edits,
      entry.count or 1
    )

    local l4 = string.format(" File:   %s", entry.path)

    local insp_lines = { l1, l2, l3, l4 }
    vim.api.nvim_buf_set_lines(M.state.inspector_buf, 0, -1, false, insp_lines)

    -- Apply inspector highlights
    vim.api.nvim_buf_clear_namespace(M.state.inspector_buf, M.state.ns_inspector, 0, -1)
    pcall(vim.api.nvim_buf_set_extmark, M.state.inspector_buf, M.state.ns_inspector, 0, 0, {
      end_col = -1,
      hl_group = "Title",
    })
    pcall(vim.api.nvim_buf_set_extmark, M.state.inspector_buf, M.state.ns_inspector, 1, 0, {
      end_col = 7,
      hl_group = "Keyword",
    })
    pcall(vim.api.nvim_buf_set_extmark, M.state.inspector_buf, M.state.ns_inspector, 1, 7, {
      end_col = -1,
      hl_group = (anchor.type == "task") and "Special" or "Comment",
    })
    pcall(vim.api.nvim_buf_set_extmark, M.state.inspector_buf, M.state.ns_inspector, 2, 0, {
      end_col = 7,
      hl_group = "Keyword",
    })
    pcall(vim.api.nvim_buf_set_extmark, M.state.inspector_buf, M.state.ns_inspector, 2, 7, {
      end_col = -1,
      hl_group = "Number",
    })
    pcall(vim.api.nvim_buf_set_extmark, M.state.inspector_buf, M.state.ns_inspector, 3, 0, {
      end_col = 7,
      hl_group = "Keyword",
    })
    pcall(vim.api.nvim_buf_set_extmark, M.state.inspector_buf, M.state.ns_inspector, 3, 7, {
      end_col = -1,
      hl_group = "Directory",
    })
  end

  -- Autocmd to update dynamic inspector and enforce snapping directly to node heads
  local in_cursor_move = false
  local augrp = vim.api.nvim_create_augroup("SynvimHistoryInspector_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augrp,
    buffer = buf,
    callback = function()
      if in_cursor_move then return end
      local cur_pos = vim.api.nvim_win_get_cursor(win)
      local cur_line = cur_pos[1]
      local target_col = line_to_head_col[cur_line]

      if target_col and cur_pos[2] ~= target_col then
        in_cursor_move = true
        pcall(vim.api.nvim_win_set_cursor, win, { cur_line, target_col })
        in_cursor_move = false
      elseif not target_col and #node_lines > 0 then
        -- Cursor landed on a connector or empty row: snap to closest node line and its head number
        local best_line = node_lines[1]
        local min_dist = math.abs(best_line - cur_line)
        for _, l in ipairs(node_lines) do
          local dist = math.abs(l - cur_line)
          if dist < min_dist then
            min_dist = dist
            best_line = l
          end
        end
        local col = line_to_head_col[best_line] or 0
        in_cursor_move = true
        pcall(vim.api.nvim_win_set_cursor, win, { best_line, col })
        in_cursor_move = false
      end

      update_inspector()
    end,
    desc = "Dynamic graph stats in bottom bar and head snapping",
  })

  -- Snap cursor to next option in graph directly on the node head (the number)
  local function snap_next()
    local cur = vim.fn.line(".")
    for _, l in ipairs(node_lines) do
      if l > cur then
        local col = line_to_head_col[l] or 0
        vim.api.nvim_win_set_cursor(win, { l, col })
        return
      end
    end
    if #node_lines > 0 then
      local l = node_lines[1]
      local col = line_to_head_col[l] or 0
      vim.api.nvim_win_set_cursor(win, { l, col })
    end
  end

  -- Snap cursor to previous option in graph directly on the node head (the number)
  local function snap_prev()
    local cur = vim.fn.line(".")
    for i = #node_lines, 1, -1 do
      local l = node_lines[i]
      if l < cur then
        local col = line_to_head_col[l] or 0
        vim.api.nvim_win_set_cursor(win, { l, col })
        return
      end
    end
    if #node_lines > 0 then
      local l = node_lines[#node_lines]
      local col = line_to_head_col[l] or 0
      vim.api.nvim_win_set_cursor(win, { l, col })
    end
  end

  -- Initial snap directly to active file or first option at its head number
  if #node_lines > 0 then
    local start_line = node_lines[1]
    if current_file and path_to_line[current_file] then
      start_line = path_to_line[current_file]
    end
    local col = line_to_head_col[start_line] or 0
    pcall(vim.api.nvim_win_set_cursor, win, { start_line, col })
  end
  pcall(update_inspector)

  -- Keybindings: Navigation & Jumping
  vim.keymap.set("n", "<CR>", function() do_jump(true) end, { buffer = buf, silent = true, nowait = true, desc = "Jump to file:line and close" })
  vim.keymap.set("n", "o", function() do_jump(true) end, { buffer = buf, silent = true, nowait = true, desc = "Jump to file:line and close" })
  vim.keymap.set("n", "<2-LeftMouse>", function() do_jump(true) end, { buffer = buf, silent = true, nowait = true, desc = "Jump to file:line" })
  vim.keymap.set("n", "<Tab>", function() do_jump(false) end, { buffer = buf, silent = true, nowait = true, desc = "Preview file:line without closing" })
  vim.keymap.set("n", "p", function() do_jump(false) end, { buffer = buf, silent = true, nowait = true, desc = "Preview file:line without closing" })

  -- Snap directly to options: j / k / Down / Up / Ctrl-n / Ctrl-p / ] / [
  vim.keymap.set("n", "j", snap_next, { buffer = buf, silent = true, nowait = true, desc = "Snap to next option" })
  vim.keymap.set("n", "<Down>", snap_next, { buffer = buf, silent = true, nowait = true, desc = "Snap to next option" })
  vim.keymap.set("n", "<C-n>", snap_next, { buffer = buf, silent = true, nowait = true, desc = "Snap to next option" })
  vim.keymap.set("n", "]", snap_next, { buffer = buf, silent = true, nowait = true, desc = "Snap to next option" })

  vim.keymap.set("n", "k", snap_prev, { buffer = buf, silent = true, nowait = true, desc = "Snap to previous option" })
  vim.keymap.set("n", "<Up>", snap_prev, { buffer = buf, silent = true, nowait = true, desc = "Snap to previous option" })
  vim.keymap.set("n", "<C-p>", snap_prev, { buffer = buf, silent = true, nowait = true, desc = "Snap to previous option" })
  vim.keymap.set("n", "[", snap_prev, { buffer = buf, silent = true, nowait = true, desc = "Snap to previous option" })

  -- Follow outgoing edge forward in graph (l or right arrow)
  vim.keymap.set("n", "l", function()
    local cur = vim.fn.line(".")
    local entry = line_to_entry[cur] or line_to_entry[cur - 1] or line_to_entry[cur + 1]
    if entry and M.state.transitions[entry.path] then
      for tgt, _ in pairs(M.state.transitions[entry.path]) do
        if path_to_line[tgt] then
          local l = path_to_line[tgt]
          local col = line_to_head_col[l] or 0
          vim.api.nvim_win_set_cursor(win, { l, col })
          return
        end
      end
    end
  end, { buffer = buf, silent = true, nowait = true, desc = "Follow outgoing transition edge" })

  -- Follow incoming edge backward in graph (h or left arrow)
  vim.keymap.set("n", "h", function()
    local cur = vim.fn.line(".")
    local entry = line_to_entry[cur] or line_to_entry[cur - 1] or line_to_entry[cur + 1]
    if entry and M.state.incoming[entry.path] then
      for src, _ in pairs(M.state.incoming[entry.path]) do
        if path_to_line[src] then
          local l = path_to_line[src]
          local col = line_to_head_col[l] or 0
          vim.api.nvim_win_set_cursor(win, { l, col })
          return
        end
      end
    end
  end, { buffer = buf, silent = true, nowait = true, desc = "Follow incoming transition edge" })

  vim.keymap.set("n", "q", close_win, { buffer = buf, silent = true, nowait = true, desc = "Close history window" })
  vim.keymap.set("n", "<Esc>", close_win, { buffer = buf, silent = true, nowait = true, desc = "Close history window" })

  -- Clean up inspector when main window is closed by any means
  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = buf,
    callback = close_win,
    desc = "Close inspector window when history graph is closed",
  })

  -- Quick jump keys 1..9
  for i = 1, math.min(9, #entries) do
    vim.keymap.set("n", tostring(i), function()
      local target = entries[i]
      if target then
        close_win()
        M.jump_to(target, origin_win)
      end
    end, { buffer = buf, silent = true, nowait = true, desc = string.format("Jump to entry [%d]", i) })
  end

  -- Clear history shortcut
  vim.keymap.set("n", "c", function()
    M.clear()
    close_win()
  end, { buffer = buf, silent = true, nowait = true, desc = "Clear history" })
end

--- Push unique visited files into Quickfix list
function M.show_quickfix()
  M.update_current_position()
  local entries = M.get_history()
  if #entries == 0 then
    vim.notify("History: No visited files recorded in this session.", vim.log.levels.INFO)
    return
  end

  local qf = {}
  for idx, entry in ipairs(entries) do
    local bufnr_item = vim.fn.bufadd(entry.path)
    table.insert(qf, {
      bufnr = bufnr_item,
      filename = entry.rel_path,
      lnum = entry.line,
      col = entry.col,
      text = string.format("[#%d] %s", idx, (entry.snippet and entry.snippet ~= "") and entry.snippet or entry.rel_path),
    })
  end

  vim.fn.setqflist(qf, "r")
  vim.fn.setqflist({}, "a", { title = string.format("Visited Files History [%d files]", #entries) })
  vim.cmd("botright copen 8")
end

--- Setup autocmds to track file visits, active time, edits, and cursor movements automatically
function M.setup()
  local grp = vim.api.nvim_create_augroup("SynvimFileHistory", { clear = true })

  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = grp,
    callback = function(ev)
      if is_trackable_buffer(ev.buf) then
        local name = normalize_path(vim.api.nvim_buf_get_name(ev.buf))
        local cur = vim.api.nvim_win_get_cursor(0)
        M.record_visit(name, cur[1], cur[2], ev.buf)
        M.ensure_buffer_tracked(ev.buf)
        if M.state.files[name] then
          M.state.files[name].last_enter = os.time()
        end
      end
    end,
    desc = "Track visited file, active time, and edits",
  })

  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = grp,
    callback = function(ev)
      if is_trackable_buffer(ev.buf) then
        local name = normalize_path(vim.api.nvim_buf_get_name(ev.buf))
        if M.state.files[name] and M.state.files[name].last_enter then
          local delta = os.time() - M.state.files[name].last_enter
          if delta > 0 then
            M.state.files[name].time_spent_secs = (M.state.files[name].time_spent_secs or 0) + delta
          end
          M.state.files[name].last_enter = nil
        end
        local cur = vim.api.nvim_win_get_cursor(0)
        M.record_visit(name, cur[1], cur[2], ev.buf)
      end
    end,
    desc = "Update time spent and cursor position before leaving buffer",
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = grp,
    callback = function(ev)
      local b = ev.buf
      if is_trackable_buffer(b) then
        local name = normalize_path(vim.api.nvim_buf_get_name(b))
        if M.state.files[name] then
          local cur = vim.api.nvim_win_get_cursor(0)
          M.state.files[name].line = cur[1]
          M.state.files[name].col = cur[2]
        end
      end
    end,
    desc = "Update current file cursor line for history jump",
  })
end

return M
