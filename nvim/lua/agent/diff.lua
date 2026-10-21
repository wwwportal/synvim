local M = {}
local state_mod = require("agent.state")
local ui = require("agent.ui")

function M.setup_highlights()
  local is_dark = (vim.o.background == "dark")
  if is_dark then
    vim.api.nvim_set_hl(0, "AgentDiffAdd", { fg = "#86efac", bg = "#143820", ctermfg = 10, ctermbg = 22, default = false })
    vim.api.nvim_set_hl(0, "AgentDiffAddWord", { fg = "#bbf7d0", bg = "#1e532d", bold = true, ctermfg = 15, ctermbg = 28, default = false })
    vim.api.nvim_set_hl(0, "AgentDiffAddSign", { fg = "#4ade80", bold = true, ctermfg = 10, default = false })
    vim.api.nvim_set_hl(0, "AgentDiffDelete", { fg = "#fca5a5", bg = "#381717", strikethrough = true, ctermfg = 9, ctermbg = 52, default = false })
    vim.api.nvim_set_hl(0, "AgentDiffDeleteWord", { fg = "#fecaca", bg = "#4f1e1e", bold = true, strikethrough = true, ctermfg = 15, ctermbg = 52, default = false })
    vim.api.nvim_set_hl(0, "AgentDiffDeleteDim", { fg = "#fca5a5", bg = "#381717", strikethrough = true, ctermfg = 8, ctermbg = 235, default = false })
    vim.api.nvim_set_hl(0, "AgentDiffUnchanged", { fg = "#9ca3af", bg = "#262626", ctermfg = 8, ctermbg = 236, default = false })
    vim.api.nvim_set_hl(0, "AgentDiffChangeSign", { fg = "#facc15", bold = true, ctermfg = 11, default = false })
  else
    vim.api.nvim_set_hl(0, "AgentDiffAdd", { fg = "#166534", bg = "#e6ffec", ctermfg = 28, ctermbg = 194, default = false })
    vim.api.nvim_set_hl(0, "AgentDiffAddWord", { fg = "#14532d", bg = "#bbf7d0", bold = true, ctermfg = 15, ctermbg = 28, default = false })
    vim.api.nvim_set_hl(0, "AgentDiffAddSign", { fg = "#16a34a", bold = true, ctermfg = 28, default = false })
    vim.api.nvim_set_hl(0, "AgentDiffDelete", { fg = "#991b1b", bg = "#ffeef0", strikethrough = true, ctermfg = 160, ctermbg = 224, default = false })
    vim.api.nvim_set_hl(0, "AgentDiffDeleteWord", { fg = "#7f1d1d", bg = "#fecaca", bold = true, strikethrough = true, ctermfg = 15, ctermbg = 160, default = false })
    vim.api.nvim_set_hl(0, "AgentDiffDeleteDim", { fg = "#991b1b", bg = "#ffeef0", strikethrough = true, ctermfg = 8, ctermbg = 254, default = false })
    vim.api.nvim_set_hl(0, "AgentDiffUnchanged", { fg = "#6b7280", bg = "#f9fafb", ctermfg = 8, ctermbg = 254, default = false })
    vim.api.nvim_set_hl(0, "AgentDiffChangeSign", { fg = "#d97706", bold = true, ctermfg = 94, default = false })
  end
  pcall(vim.api.nvim_set_hl, 0, "GitReviewAdd", { link = "AgentDiffAdd", default = false })
  pcall(vim.api.nvim_set_hl, 0, "GitReviewDelete", { link = "AgentDiffDelete", default = false })
end

--- Wrap virtual diff line into visual chunks not exceeding max_w
function M.wrap_diff_line(prefix, text, hl_group, max_w)
  max_w = max_w or 80
  local full = prefix .. text
  if #full <= max_w then
    return { { { full, hl_group } } }
  end
  local lines = {}
  local p_len = #prefix
  local avail = max_w - p_len
  if avail < 10 then avail = 10 end

  local pos = 1
  local is_first = true
  while pos <= #text do
    local chunk_len = is_first and avail or (max_w - 2)
    local piece = text:sub(pos, pos + chunk_len - 1)
    if is_first then
      table.insert(lines, { { prefix .. piece, hl_group } })
      is_first = false
    else
      table.insert(lines, { { "  " .. piece, hl_group } })
    end
    pos = pos + chunk_len
  end
  return (#lines > 0) and lines or { { { full, hl_group } } }
end

--- Tokenize line into words, whitespace, and punctuation symbols
function M.tokenize_line(line)
  local tokens = {}
  local pos = 1
  while pos <= #line do
    local s, e = line:find("[%w_]+", pos)
    if s == pos then
      table.insert(tokens, { text = line:sub(s, e), start_col = s - 1, end_col = e })
      pos = e + 1
    else
      local ws_s, ws_e = line:find("%s+", pos)
      if ws_s == pos then
        table.insert(tokens, { text = line:sub(ws_s, ws_e), start_col = ws_s - 1, end_col = ws_e, is_ws = true })
        pos = ws_e + 1
      else
        table.insert(tokens, { text = line:sub(pos, pos), start_col = pos - 1, end_col = pos })
        pos = pos + 1
      end
    end
  end
  return tokens
end

--- Compute inline token diff between old_line and new_line
--- Returns:
---   1. inline_deletes: array of { col = int, text = string } for inline virtual text (AgentDiffDeleteWord)
---   2. add_ranges: array of { start_col = int, end_col = int } for AgentDiffAddWord on the buffer line
function M.compute_char_diff(old_line, new_line)
  local old_toks = M.tokenize_line(old_line)
  local new_toks = M.tokenize_line(new_line)

  local ot = {}
  for _, t in ipairs(old_toks) do table.insert(ot, t.text) end
  local nt = {}
  for _, t in ipairs(new_toks) do table.insert(nt, t.text) end

  local hunk_indices = vim.diff(table.concat(ot, "\n") .. "\n", table.concat(nt, "\n") .. "\n", { result_type = "indices", algorithm = "histogram" }) or {}
  local inline_deletes = {}
  local add_ranges = {}

  for _, h in ipairs(hunk_indices) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    local del_str = ""
    if ca > 0 then
      for k = sa, sa + ca - 1 do
        del_str = del_str .. (old_toks[k] and old_toks[k].text or "")
      end
    end

    local anchor_col = #new_line
    if cb > 0 and new_toks[sb] then
      anchor_col = new_toks[sb].start_col
      local end_col = new_toks[sb + cb - 1] and new_toks[sb + cb - 1].end_col or anchor_col
      table.insert(add_ranges, { start_col = anchor_col, end_col = end_col })
    elseif sb <= #new_toks and new_toks[sb] then
      anchor_col = new_toks[sb].start_col
    end

    if #del_str > 0 then
      if cb > 0 and not del_str:match("%s$") and new_toks[sb] and not new_toks[sb].text:match("^%s") then
        del_str = del_str .. " "
      end
      table.insert(inline_deletes, { col = anchor_col, text = del_str })
    end
  end

  -- Fallback if diff found no hunks but lines differ
  if #inline_deletes == 0 and #add_ranges == 0 and old_line ~= new_line then
    table.insert(inline_deletes, { col = 0, text = old_line .. " " })
    table.insert(add_ranges, { start_col = 0, end_col = #new_line })
  end

  return inline_deletes, add_ranges
end

function M.promote_contract_to_approved(filepath, task_id)
  if not filepath or filepath == "" then return end
  local root = ui.get_root_dir()
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

function M.ensure_contract_preserved_as_done(orig_slice, new_lines)
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

--- Clear pending in-line diff
function M.clear_diff(keep_buffer)
  local state = state_mod.state
  local ns_diff = state_mod.ns_diff
  if state.pending_diff then
    local p = state.pending_diff
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
    state.pending_diff = nil
  end
end

--- Show suggested code in-line with green-red diff colors.
function M.show_inline_diff(bufnr, target_line, new_content, old_lines_count, is_new_file, old_lines, review_meta)
  M.setup_highlights()
  local state = state_mod.state
  local ns_diff = state_mod.ns_diff

  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local origin_win = ui.get_primary_editor_win()
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
  if type(old_lines) == "string" then
    deleted_lines = vim.split(old_lines, "\n")
  elseif type(old_lines) == "table" and #old_lines > 0 then
    deleted_lines = old_lines
  elseif already_applied and review_meta and review_meta.old_lines and #review_meta.old_lines > 0 then
    deleted_lines = review_meta.old_lines
  elseif not already_applied and old_lines_count > 0 then
    local e_idx = math.min(total_lines, s_idx + old_lines_count)
    deleted_lines = vim.api.nvim_buf_get_lines(bufnr, s_idx, e_idx, false)
  end

  -- If deleted_lines is still empty, look up unreviewed review or git history for original code
  if #deleted_lines == 0 and not is_new_file then
    local path = vim.api.nvim_buf_get_name(bufnr)
    local root = ui.get_root_dir()
    local abs = vim.fn.fnamemodify(path, ":p")
    local rel = vim.fn.fnamemodify(path, ":.")
    local reviews_mod = require("agent.reviews")
    local unrev = reviews_mod.get_reviews("unreviewed")
    for _, r in ipairs(unrev) do
      local r_abs = r.abs_file or (r.target_file and (root .. "/" .. r.target_file))
      if r_abs == abs or r.target_file == rel then
        if r.old_lines and #r.old_lines > 0 then
          deleted_lines = r.old_lines
          review_meta = review_meta or r
          break
        end
      end
    end
    if #deleted_lines == 0 and vim.fn.filereadable(path) == 1 then
      local git_old = vim.fn.systemlist({ "git", "-C", root, "show", "HEAD:" .. rel })
      if vim.v.shell_error == 0 and #git_old > 0 then
        local e_line = math.min(#git_old, s_idx + math.max(1, old_lines_count))
        local sub_old = {}
        for k = s_idx + 1, e_line do table.insert(sub_old, git_old[k]) end
        if #sub_old > 0 then deleted_lines = sub_old end
      end
    end
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

  local old_text = table.concat(deleted_lines, "\n")
  local new_text = table.concat(new_lines, "\n")
  local line_kind = {}
  for i = 1, #new_lines do line_kind[i] = "same" end
  local virt_by_line = {}
  local inline_deletes_by_line = {}
  local char_adds_by_line = {}

  local function add_virt_line(idx, vline_chunks)
    virt_by_line[idx] = virt_by_line[idx] or {}
    table.insert(virt_by_line[idx], vline_chunks)
  end

  -- Line-level diff via vim.diff (indices)
  local hunks = {}
  if type(old_text) == "string" and type(new_text) == "string" and (#deleted_lines > 0 or #new_lines > 0) then
    local ok, res = pcall(vim.diff, old_text, new_text, { result_type = "indices", algorithm = "histogram" })
    if ok and type(res) == "table" then hunks = res end
  end

  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    if ca == 0 and cb == 0 then goto continue end
    if ca == 0 then
      -- pure insertion: mark as added
      for k = 1, (cb or 0) do line_kind[sb + k - 1] = "added" end
    elseif cb == 0 then
      -- pure deletion: soft pink virtual line above the anchor line
      local anchor = math.max(1, math.min(sb, #new_lines))
      for k = 1, ca do
        local old_l = deleted_lines[sa + k - 1] or ""
        add_virt_line(anchor, { { "- " .. old_l, "AgentDiffDelete" } })
      end
    else
      -- mixed: pair min(ca,cb) as changed with inline interleaved diff
      local min_n = math.min(ca, cb)
      for k = 1, min_n do
        local old_i = sa + k - 1
        local new_i = sb + k - 1
        local old_l = deleted_lines[old_i] or ""
        local new_l = new_lines[new_i] or ""
        if old_l ~= new_l then
          line_kind[new_i] = "changed"
          local inlines, aranges = M.compute_char_diff(old_l, new_l)
          inline_deletes_by_line[new_i] = inlines
          char_adds_by_line[new_i] = aranges
        else
          line_kind[new_i] = "same"
        end
      end
      -- extra insertions beyond pairs -> green addition
      for k = min_n + 1, cb do line_kind[sb + k - 1] = "added" end
      -- extra deletions beyond pairs -> soft pink virtual line above next new line
      if min_n < ca then
        local anchor = math.max(1, math.min(sb + min_n, #new_lines))
        for k = min_n + 1, ca do
          local old_l = deleted_lines[sa + k - 1] or ""
          add_virt_line(anchor, { { "- " .. old_l, "AgentDiffDelete" } })
        end
      end
    end
    ::continue::
  end

  -- Fallback line-by-line compare if hunks were empty but texts differ
  if #hunks == 0 and old_text ~= new_text then
    for i = 1, #new_lines do
      local old_l = deleted_lines[i]
      local new_l = new_lines[i]
      if old_l and old_l ~= new_l then
        line_kind[i] = "changed"
        local inlines, aranges = M.compute_char_diff(old_l, new_l)
        inline_deletes_by_line[i] = inlines
        char_adds_by_line[i] = aranges
      end
    end
  end

  -- Render virtual lines (only for pure deleted lines with no replacement line)
  for i = 1, math.max(1, #new_lines) do
    local vlines = virt_by_line[i]
    if vlines and #vlines > 0 then
      local line_pos = math.max(0, s_idx + i - 1)
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_diff, line_pos, 0, {
        virt_lines = vlines,
        virt_lines_above = true,
        priority = 250,
      })
    end
  end

  -- Highlight added lines (soft green + '+') and changed lines ('~' with inline deleted tokens + added word highlights)
  for i = 1, #new_lines do
    local l_idx = s_idx + (i - 1)
    if line_kind[i] == "added" then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_diff, l_idx, 0, {
        line_hl_group = "AgentDiffAdd",
        sign_text = "+",
        sign_hl_group = "AgentDiffAddSign",
        priority = 250,
      })
    elseif line_kind[i] == "changed" then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_diff, l_idx, 0, {
        sign_text = "~",
        sign_hl_group = "AgentDiffChangeSign",
        priority = 250,
      })
      -- Render inline deleted tokens interleaved directly in the line
      local inlines = inline_deletes_by_line[i]
      if inlines and #inlines > 0 then
        for _, d in ipairs(inlines) do
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_diff, l_idx, d.col, {
            virt_text = { { d.text, "AgentDiffDeleteWord" } },
            virt_text_pos = "inline",
            priority = 255,
          })
        end
      end
      -- Highlight added token ranges
      local aranges = char_adds_by_line[i]
      if aranges and #aranges > 0 then
        for _, r in ipairs(aranges) do
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_diff, l_idx, r.start_col, {
            end_col = r.end_col,
            hl_group = "AgentDiffAddWord",
            priority = 255,
          })
        end
      else
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_diff, l_idx, 0, {
          line_hl_group = "AgentDiffAdd",
          priority = 250,
        })
      end
    end
  end

  -- Jump to first changed line and refresh (explicit win search; ignore pcall failures silently)
  vim.schedule(function()
    local fw = vim.fn.win_findbuf(bufnr)
    if fw and fw[1] and vim.api.nvim_win_is_valid(fw[1]) then
      pcall(vim.api.nvim_set_current_win, fw[1])
      pcall(vim.api.nvim_win_set_cursor, fw[1], { target_line, 0 })
      pcall(function() vim.cmd("normal! zz") end)
    end
    vim.cmd("redraw")
  end)

  state.pending_diff = {
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
    table.insert(state.pending_diff.bound_keys, lhs)
  end

  bind_buf_key("<M-a>", function()
    local rev_mod = require("agent.reviews")
    rev_mod.accept()
  end, "Accept diff (:Tasks accept)")
  bind_buf_key("<M-r>", function()
    local rev_mod = require("agent.reviews")
    rev_mod.reject()
  end, "Reject diff (:Tasks reject)")
  bind_buf_key("<M-w>", function()
    local tasks_mod = require("agent.tasks")
    tasks_mod.revise_task()
  end, "Revise diff (:Tasks revise)")
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

--- Accept and permanently apply the pending in-line diff
function M.accept_diff()
  local state = state_mod.state
  if state.current_review then
    local rev_id = state.current_review.id
    local rev_mod = require("agent.reviews")
    rev_mod.accept_review(rev_id)
    return
  end
  if not state.pending_diff then
    vim.notify("GitReview: No pending diff to accept", vim.log.levels.INFO)
    return
  end
  local p = state.pending_diff
  local bufnr = p.bufnr
  local origin_win = p.origin_win
  local target_line = p.target_line
  local new_lines = p.new_lines
  local old_count = p.old_count or 0
  local is_new_file = p.is_new_file
  local filepath = vim.api.nvim_buf_get_name(bufnr)

  M.promote_contract_to_approved(filepath, p.review and p.review.task_id)

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

  local tasks_mod = require("agent.tasks")
  -- Mark current task in queue as done
  if state.queue and state.queue_index and state.queue[state.queue_index] then
    state.queue[state.queue_index].done = true
    tasks_mod.update_queue_display(false)
  end

  -- Auto-advance to next queued task if present
  if state.queue and state.queue_index and state.queue_index < #state.queue then
    tasks_mod.next()
  end
end

--- Re-attach a pending (unreviewed) diff for a buffer.
function M.attach_pending_diff(bufnr, task_id)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return false end
  if vim.bo[bufnr].buftype ~= "" then return false end

  local state = state_mod.state
  -- Don't clear/revert an existing active diff for another file.
  if state.pending_diff and state.pending_diff.bufnr ~= bufnr then return false end

  -- Already showing a diff for this buffer -> nothing to do
  local p = state.pending_diff
  if p and p.bufnr == bufnr then return true end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return false end

  local root = ui.get_root_dir()
  local rel = name:gsub("^" .. vim.pesc(root) .. "/", ""):gsub("^/+", "")

  local rev_mod = require("agent.reviews")
  local unrev = rev_mod.get_reviews("unreviewed")
  if #unrev == 0 then return false end

  -- Prefer a review matching the requested task, fall back to a file match
  local match = nil
  if task_id and task_id ~= "" then
    for _, r in ipairs(unrev) do
      if r.task_id and r.task_id == task_id and rev_mod.review_matches_file(r, name, rel) then
        match = r
        break
      end
    end
  end
  if not match then
    for _, r in ipairs(unrev) do
      if rev_mod.review_matches_file(r, name, rel) then
        match = r
        break
      end
    end
  end
  if not match then return false end

  local new_lines = match.new_lines
  if type(new_lines) ~= "table" or #new_lines == 0 then return false end
  local content = table.concat(new_lines, "\n")
  if vim.trim(content) == "" then return false end

  local line = tonumber(match.start_line) or 1
  local old_count = tonumber(match.old_lines_count) or 0
  M.show_inline_diff(bufnr, line, content, old_count, false, match.old_lines or {}, match)
  return true
end

return M
