-- TODO(support-for-tasks-delete-and-tasks-modify | tier:A | status:TODO): support for ':Tasks delete' and ':Tasks modify'
local M = {}
local state_mod = require("agent.state")
local ui = require("agent.ui")

local function get_comment_leader(filepath)
  local base = vim.fn.fnamemodify(filepath, ":t"):lower()
  if base == "makefile" or base == "dockerfile" or base:match("^dockerfile%.") then
    return "#"
  end
  local ext = vim.fn.fnamemodify(filepath, ":e"):lower()
  if ext == "py" or ext == "sh" or ext == "bash" or ext == "zsh" or ext == "yaml" or ext == "yml" or ext == "toml" or ext == "rb" or ext == "pl" then
    return "#"
  elseif ext == "lua" or ext == "lean" or ext == "hs" or ext == "sql" then
    return "--"
  elseif ext == "md" or ext == "markdown" then
    return "- [ ]"
  else
    return "//"
  end
end
M.get_comment_leader = get_comment_leader

function M.is_todo_comment(line)
  if not line or type(line) ~= "string" then return false end
  return line:match("^[ \t]*[#/%-%*%\"]+%s*TODO") ~= nil or
         line:match("^[ \t]*[#/%-%*%\"]+%s*FIXME") ~= nil or
         line:match("^[ \t]*[#/%-%*%\"]+%s*SPEC%(") ~= nil or
         line:match("^[ \t]*[-*]%s*%[%s*%]") ~= nil
end

function M.extract_task_info(line)
  if not line then return nil end
  local kind, inside, desc = line:match("^[ \t]*[#/%-%*%\"]+%s*(%a+)%(([^)]+)%)%s*:%s*(.*)$")
  if kind and inside then
    local parts = vim.split(inside, "%s*|%s*")
    local clean_id = vim.trim(parts[1] or "task")
    local tier = "U"
    local status = "TODO"
    local depends_on = {}
    local blocks = {}
    local requires = {}
    local allow = {}
    local forbid = {}
    local always = nil
    local ensures = nil
    local repair = nil

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
      local req_str = p:match("requires:%[([^%]]*)%]")
      if req_str then
        for r in req_str:gmatch("[^,%s%[%]]+") do
          table.insert(requires, vim.trim(r))
          if not vim.tbl_contains(depends_on, vim.trim(r)) then
            table.insert(depends_on, vim.trim(r))
          end
        end
      end
      local alw_str = p:match("allow:%[([^%]]+)%]")
      if alw_str then
        for a in alw_str:gmatch("[^,%s%[%]]+") do
          table.insert(allow, vim.trim(a))
        end
      end
      local fbd_str = p:match("forbid:%[([^%]]+)%]")
      if fbd_str then
        for f in fbd_str:gmatch("[^,%s%[%]]+") do
          table.insert(forbid, vim.trim(f))
        end
      end
      local alw_inv = p:match("always:\"([^\"]+)\"") or p:match("always:([^|]+)")
      if alw_inv then always = vim.trim(alw_inv) end
      local ens = p:match("ensures:\"([^\"]+)\"") or p:match("ensures:([^|]+)")
      if ens then ensures = vim.trim(ens) end
      local rep = p:match("repair:([^|]+)")
      if rep then repair = vim.trim(rep) end
    end

    return {
      kind = kind,
      id = clean_id,
      tier = tier,
      status = status,
      depends_on = depends_on,
      blocks = blocks,
      requires = requires,
      allow = allow,
      forbid = forbid,
      always = always,
      ensures = ensures,
      repair = repair,
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

function M.scan_repository_tasks(root)
  root = root or ui.get_root_dir()
  local pattern = "(#|//|--|/\\*).*\\b(TODO|FIXME|SPEC|CONTRACT)\\b"
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
        local t_info = M.extract_task_info(txt)
        if t_info then
          local desc = t_info.desc
          local abs_f = (fpath:match("^/") and fpath) or (root .. "/" .. fpath)
          local l_idx = tonumber(lnum) or 1
          local ok_f, next_lines = pcall(vim.fn.readfile, abs_f, "", l_idx + 25)
          local contract = {
            allow = vim.deepcopy(t_info.allow or {}),
            forbid = vim.deepcopy(t_info.forbid or {}),
            requires = vim.deepcopy(t_info.requires or {}),
            ensures = t_info.ensures,
            action = t_info.desc,
            always = t_info.always,
            repair = t_info.repair,
          }

          if ok_f and next_lines then
            for j = l_idx + 1, math.min(#next_lines, l_idx + 25) do
              local nxt = next_lines[j]
              local cleaned = nxt:match("^[ \t]*[#/%-%*%\"]+%s*(.*)$")
              if not cleaned or cleaned:match("^%a+%(") then
                break
              end

              if cleaned ~= "" then
                local act = cleaned:match("^[Aa]ction:%s*(.*)$")
                if act and act ~= "" then contract.action = act; desc = act end

                local req = cleaned:match("^[Rr]equires:%s*%[([^%]]*)%]") or cleaned:match("^%[PRE%]%s*(.*)$")
                if req then
                  for r in req:gmatch("[^,%s%[%]]+") do
                    table.insert(contract.requires, vim.trim(r))
                    if not vim.tbl_contains(t_info.depends_on, vim.trim(r)) then
                      table.insert(t_info.depends_on, vim.trim(r))
                    end
                  end
                end

                local ens = cleaned:match("^[Ee]nsures:%s*(.*)$") or cleaned:match("^%[POST%]%s*(.*)$")
                if ens and ens ~= "" then contract.ensures = ens end

                local alw = cleaned:match("^[Aa]llow:%s*%[([^%]]*)%]") or cleaned:match("^[Mm]odifies:%s*%[([^%]]*)%]")
                if alw then
                  for a in alw:gmatch("[^,%s%[%]]+") do
                    table.insert(contract.allow, vim.trim(a))
                  end
                end

                local fbd = cleaned:match("^[Ff]orbid:%s*%[([^%]]*)%]") or cleaned:match("^[Dd]eny:%s*%[([^%]]*)%]")
                if fbd then
                  for f in fbd:gmatch("[^,%s%[%]]+") do
                    table.insert(contract.forbid, vim.trim(f))
                  end
                end

                local alw_inv = cleaned:match("^[Aa]lways:%s*(.*)$") or cleaned:match("^[Ii]nvariant:%s*(.*)$")
                if alw_inv and alw_inv ~= "" then contract.always = alw_inv end

                local rep = cleaned:match("^[Rr]epair:%s*(.*)$") or cleaned:match("^[Cc][Tt][Dd]:%s*(.*)$")
                if rep and rep ~= "" then contract.repair = rep end
              end
            end
          end

          if not desc or vim.trim(desc) == "" then
            desc = (t_info.id and t_info.id ~= "task") and t_info.id or vim.trim(txt)
          end

          local resolved_tier = t_info.tier
          if not resolved_tier or resolved_tier == "U" then
            if #t_info.depends_on == 0 and #contract.requires == 0 then
              resolved_tier = "A"
            else
              resolved_tier = "B"
            end
          end

          table.insert(tasks, {
            file = fpath,
            line = tonumber(lnum) or 1,
            task_id = t_info.id,
            tier = resolved_tier,
            status = t_info.status or "TODO",
            depends_on = t_info.depends_on or {},
            blocks = t_info.blocks or {},
            kind = t_info.kind or "TODO",
            description = desc,
            raw = txt,
            contract = contract,
            allow = contract.allow,
            forbid = contract.forbid,
            requires = contract.requires,
            ensures = contract.ensures,
            always = contract.always,
            repair = contract.repair,
          })
        end
      end
    end
  end
  return tasks
end

function M.reindex_tasks()
  return M.scan_repository_tasks()
end

function M.resolve_task_identifier(arg)
  arg = vim.trim(arg or "")
  if arg == "" then return nil end

  local num_str = arg:match("^#?(%d+)$")
  local num = tonumber(num_str)

  local all_tasks = M.scan_repository_tasks()
  table.sort(all_tasks, function(a, b)
    if (a.tier or "U") ~= (b.tier or "U") then
      return (a.tier or "U") < (b.tier or "U")
    end
    if (a.file or "") ~= (b.file or "") then
      return (a.file or "") < (b.file or "")
    end
    return (a.line or 0) < (b.line or 0)
  end)

  -- 1. Direct agenda index matching what is shown in :Tasks list (#1, #2, ...)
  if num and all_tasks[num] then
    return all_tasks[num].task_id or all_tasks[num]
  end

  -- 2. Exact match on task_id slug (case-insensitive, ignoring optional leading #)
  local clean_arg = arg:gsub("^#", "")
  for _, t in ipairs(all_tasks) do
    if t.task_id and t.task_id ~= "task" and (t.task_id:lower() == arg:lower() or t.task_id:lower() == clean_arg:lower()) then
      return t.task_id
    end
  end

  -- 3. Fuzzy substring match on task_id slug
  for _, t in ipairs(all_tasks) do
    if t.task_id and t.task_id ~= "task" and t.task_id:lower():find(clean_arg:lower(), 1, true) then
      return t.task_id
    end
  end

  return arg
end

function M.rank_tasks_by_query(tasks, query)
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

function M.format_task_summary(t, idx)
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

function M.setup_agent_qf_keymaps(origin_win, qf_buf)
  local state = state_mod.state
  if not qf_buf or not vim.api.nvim_buf_is_valid(qf_buf) then
    local qf_win = vim.api.nvim_get_current_win()
    qf_buf = vim.api.nvim_win_get_buf(qf_win)
  end

  -- Informative statusline on quickfix window
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == qf_buf then
      pcall(function()
        if state.is_tasks_list then
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

    -- Target editor split in current tab (never the quickfix window itself)
    local qf_w = vim.api.nvim_get_current_win()
    local editor_win = origin_win or state.origin_win
    if not editor_win or not vim.api.nvim_win_is_valid(editor_win) or editor_win == qf_w or vim.bo[vim.api.nvim_win_get_buf(editor_win)].buftype == "quickfix" then
      editor_win = ui.get_primary_editor_win()
    end

    -- Check if this quickfix item represents a review
    local rev_id = item.text and item.text:match("ID:%s*([%w_%-]+)")
    if rev_id then
      local rev_mod = require("agent.reviews")
      local all_reviews = rev_mod.get_reviews("all")
      for _, r in ipairs(all_reviews) do
        if r.id == rev_id then
          if close_qf then
            vim.cmd("cclose")
          end
          rev_mod.show_review(r, editor_win)
          if not close_qf and vim.api.nvim_win_is_valid(qf_w) then
            pcall(vim.api.nvim_set_current_win, qf_w)
            pcall(vim.api.nvim_win_set_cursor, qf_w, { idx, 0 })
          end
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

    local cur_item = (state.queue and state.queue[idx]) or {
      path = filepath,
      line = item.lnum or 1,
      col = item.col or 1,
      action = "navigate",
    }
    state.queue_index = idx

    if close_qf then
      vim.cmd("cclose")
    end

    M.jump_to_target(cur_item, editor_win)
    if not state.is_tasks_list then
      M.update_queue_display(false)
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
    if state.is_tasks_list then
      vim.notify("Tasks: To accept a review, run :Tasks YES <id>", vim.log.levels.INFO)
      return
    end
    local diff_mod = require("agent.diff")
    diff_mod.accept_diff()
  end, { buffer = qf_buf, silent = true, noremap = true, desc = "Accept current diff" })

  vim.keymap.set("n", "r", function()
    if state.is_tasks_list then
      vim.notify("Tasks: To reject a review, run :Tasks NO <id>", vim.log.levels.INFO)
      return
    end
    local rev_mod = require("agent.reviews")
    rev_mod.reject("")
  end, { buffer = qf_buf, silent = true, noremap = true, desc = "Reject current diff" })

  vim.keymap.set("n", "w", function()
    if state.is_tasks_list then
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
      target_win = state.origin_win or ui.get_primary_editor_win()
    end
    if target_win and vim.api.nvim_win_is_valid(target_win) then
      vim.api.nvim_set_current_win(target_win)
    end
  end, { buffer = qf_buf, silent = true, noremap = true, desc = "Switch to editor split" })

  vim.keymap.set("n", "q", function()
    vim.cmd("cclose")
    local cur_target = origin_win
    if not cur_target or not vim.api.nvim_win_is_valid(cur_target) then
      cur_target = state.origin_win or ui.get_primary_editor_win()
    end
    if cur_target and vim.api.nvim_win_is_valid(cur_target) then
      vim.api.nvim_set_current_win(cur_target)
    end
  end, { buffer = qf_buf, silent = true, noremap = true, desc = "Close bottom pane" })
end

function M.update_queue_display(show_window)
  local state = state_mod.state
  state.is_tasks_list = false
  local qf = {}
  local root = ui.get_root_dir()
  for idx, item in ipairs(state.queue) do
    local fullpath = item.path:match("^/") and item.path or (root .. "/" .. item.path)
    local is_nav = (item.action == "navigate")
    local is_new = not is_nav and (item.is_new_file or (item.action == "create"))
    local tag = is_nav and "[MATCH]" or (is_new and "[NEW FILE]" or "[DIFF]")
    local status = item.done and "✓ [DONE]" or ((idx == state.queue_index) and "▶ [ACTIVE]" or "  [PENDING]")
    local desc = item.description or (is_nav and item.path or (is_new and ("Create " .. item.path) or ("Modify " .. item.path)))
    table.insert(qf, {
      filename = fullpath,
      lnum = item.line or 1,
      col = item.col or 1,
      text = string.format("%s %s %s", status, tag, desc),
      type = item.done and "I" or ((idx == state.queue_index) and "E" or "W"),
    })
  end

  vim.fn.setqflist(qf, "r")
  vim.fn.setqflist({}, "a", { title = string.format("Agent Task Queue [%d/%d] | :YES  :NO  :MAYBE", state.queue_index, #state.queue) })

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
    local orig_win = state.origin_win or vim.api.nvim_get_current_win()
    vim.cmd("botright copen 6")
    local qf_w = vim.api.nvim_get_current_win()
    local qf_b = vim.api.nvim_win_get_buf(qf_w)
    M.setup_agent_qf_keymaps(orig_win, qf_b)
    if orig_win and vim.api.nvim_win_is_valid(orig_win) then
      vim.api.nvim_set_current_win(orig_win)
    end
  elseif qf_win then
    local orig_win = state.origin_win or vim.api.nvim_get_current_win()
    local qf_b = vim.api.nvim_win_get_buf(qf_win)
    M.setup_agent_qf_keymaps(orig_win, qf_b)
  end
end

function M.next()
  local state = state_mod.state
  if #state.queue == 0 then
    vim.notify("Agent: Queue is empty", vim.log.levels.INFO)
    return
  end
  if state.queue_index >= #state.queue then
    vim.notify("Agent: All queued targets completed (end of queue)", vim.log.levels.INFO)
    return
  end

  state.queue_index = state.queue_index + 1
  local cur = state.queue[state.queue_index]
  M.jump_to_target(cur)
  M.update_queue_display(false)
  vim.api.nvim_echo({
    { string.format("● [Agent Queue %d/%d] ", state.queue_index, #state.queue), "ModeMsg" },
    { string.format("%s:%d", cur.path, cur.line or 1), "Directory" },
    { cur.description and (" — " .. cur.description) or "", "Comment" },
  }, false, {})
end

function M.prev()
  local state = state_mod.state
  if #state.queue == 0 then
    vim.notify("Agent: Queue is empty", vim.log.levels.INFO)
    return
  end
  if state.queue_index <= 1 then
    vim.notify("Agent: Already at the first queued target", vim.log.levels.INFO)
    return
  end

  state.queue_index = state.queue_index - 1
  local cur = state.queue[state.queue_index]
  M.jump_to_target(cur)
  M.update_queue_display(false)
  vim.api.nvim_echo({
    { string.format("● [Agent Queue %d/%d] ", state.queue_index, #state.queue), "ModeMsg" },
    { string.format("%s:%d", cur.path, cur.line or 1), "Directory" },
    { cur.description and (" — " .. cur.description) or "", "Comment" },
  }, false, {})
end

function M.show_tasks()
  local root = ui.get_root_dir()
  local state = state_mod.state
  local tasks = M.scan_repository_tasks(root)
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
    local text = M.format_task_summary(t, idx)
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

  state.is_tasks_list = true
  state.queue = task_queue
  state.queue_index = 1
  state.origin_win = ui.get_primary_editor_win()
  vim.fn.setqflist(qf_list, "r")
  vim.fn.setqflist({}, "a", { title = string.format("Tasks: %d items (%s)", #tasks, vim.fn.fnamemodify(root, ":t")) })
  vim.cmd("botright copen 10")
  if state.origin_win and vim.api.nvim_win_is_valid(state.origin_win) then
    M.setup_agent_qf_keymaps(state.origin_win, vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win()))
  end
end

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

function M.jump_to_target(target, win)
  if not target or not target.path or target.path == "" then return end
  local root = ui.get_root_dir()
  local state = state_mod.state
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
    target_win = state.origin_win
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
    local ns = state_mod.ns_flash
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    vim.api.nvim_buf_add_highlight(bufnr, ns, "IncSearch", line - 1, 0, -1)
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      end
    end, 1000)
  end)

  local diff_mod = require("agent.diff")
  -- If code implementation was suggested, display in-line green-red diff!
  if type(target.content) == "string" and vim.trim(target.content) ~= "" then
    local old_count = is_new and 0 or ((type(target.old_lines_count) == "number") and target.old_lines_count or ((target.action == "replace") and 1 or 0))
    diff_mod.show_inline_diff(bufnr, line, target.content, old_count, is_new, target.old_lines, target)
  else
    diff_mod.attach_pending_diff(bufnr, target.task_id)
  end
end

function M.scaffold_and_run_task(instruction)
  local cur_buf = vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(cur_buf)
  local root = ui.get_root_dir()

  if filepath == "" or vim.bo[cur_buf].buftype ~= "" then
    local spec_path = root .. "/specs/SPEC.md"
    if vim.fn.filereadable(spec_path) == 1 then
      filepath = spec_path
      cur_buf = vim.fn.bufadd(filepath)
      vim.fn.bufload(cur_buf)
      local origin_win = ui.get_primary_editor_win()
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
  local all_tasks = M.scan_repository_tasks()
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

  local leader = get_comment_leader(filepath)
  local rel_path = vim.fn.fnamemodify(filepath, ":.")
  local stub_lines = {
    string.format("%s SPEC(%s | tier:A | status:TODO):", leader, slug),
    string.format("%s   action:    %s", leader, instruction),
    string.format("%s   requires:  []", leader),
    string.format('%s   ensures:   review "%s"', leader, instruction),
    string.format('%s   invariant: "Module interfaces and type signatures preserved"', leader),
    string.format("%s   modifies:  [%s]", leader, rel_path),
  }

  local cur_win = ui.get_primary_editor_win()
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

function M.run_todo(bufnr, target_arg)
  local state = state_mod.state
  -- 1. If target_arg is a string query (e.g. :Tasks start normalize audio | :Tasks list)
  if type(target_arg) == "string" and vim.trim(target_arg) ~= "" and not tonumber(target_arg) then
    local query = vim.trim(target_arg)
    local all_tasks = M.scan_repository_tasks()
    if #all_tasks == 0 then
      vim.notify("Todo: No in-line TODO/FIXME tasks found in repository", vim.log.levels.WARN)
      return
    end

    if query:lower() == "list" or query:lower() == "all" then
      local qf = {}
      local root = ui.get_root_dir()
      for idx, t in ipairs(all_tasks) do
        local abs_path = (t.file:match("^/") and t.file) or (root .. "/" .. t.file)
        local rel_path = t.file:gsub("^" .. vim.pesc(root) .. "/", ""):gsub("^/+", "")
        local bufnr_item = vim.fn.bufadd(abs_path)
        table.insert(qf, {
          bufnr = bufnr_item,
          filename = rel_path,
          lnum = t.line,
          text = M.format_task_summary(t, idx),
        })
      end
      state.is_tasks_list = true
      vim.fn.setqflist(qf, "r")
      vim.fn.setqflist({}, "a", { title = string.format("Tasks: %d items (%s)", #all_tasks, vim.fn.fnamemodify(root, ":t")) })
      vim.cmd("botright copen 10")
      local cur_w = ui.get_primary_editor_win()
      local qf_win = vim.api.nvim_get_current_win()
      if cur_w and vim.api.nvim_win_is_valid(cur_w) then
        M.setup_agent_qf_keymaps(cur_w, vim.api.nvim_win_get_buf(qf_win))
        pcall(vim.api.nvim_set_current_win, cur_w)
      end
      vim.notify(string.format("Listed %d in-line tasks across repository.", #all_tasks), vim.log.levels.INFO)
      return
    end

    -- Exact task_id match takes absolute priority
    for _, t in ipairs(all_tasks) do
      if t.task_id and t.task_id ~= "task" and t.task_id:lower() == query:lower() then
        local root = ui.get_root_dir()
        local full_path = root .. "/" .. t.file
        local target_buf = vim.fn.bufadd(full_path)
        vim.fn.bufload(target_buf)
        local origin_win = ui.get_primary_editor_win()
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

    local matches = M.rank_tasks_by_query(all_tasks, query)
    if #matches == 0 then
      vim.notify(string.format("Todo: No in-line TODO found matching '%s' (%d total tasks in repo)", query, #all_tasks), vim.log.levels.WARN)
      local qf = {}
      local root = ui.get_root_dir()
      for idx, t in ipairs(all_tasks) do
        local abs_path = (t.file:match("^/") and t.file) or (root .. "/" .. t.file)
        local rel_path = t.file:gsub("^" .. vim.pesc(root) .. "/", ""):gsub("^/+", "")
        local bufnr_item = vim.fn.bufadd(abs_path)
        table.insert(qf, {
          bufnr = bufnr_item,
          filename = rel_path,
          lnum = t.line,
          text = M.format_task_summary(t, idx),
        })
      end
      state.is_tasks_list = true
      vim.fn.setqflist(qf, "r")
      vim.fn.setqflist({}, "a", { title = string.format("Tasks: %d items (none matched '%s')", #all_tasks, query) })
      vim.cmd("botright copen 10")
      local cur_w = ui.get_primary_editor_win()
      local qf_win = vim.api.nvim_get_current_win()
      if cur_w and vim.api.nvim_win_is_valid(cur_w) then
        M.setup_agent_qf_keymaps(cur_w, vim.api.nvim_win_get_buf(qf_win))
        pcall(vim.api.nvim_set_current_win, cur_w)
      end
      return
    end

    local best = matches[1]
    local root = ui.get_root_dir()
    local full_path = root .. "/" .. best.file
    local qf = {}
    for idx, t in ipairs(matches) do
      local abs_path = (t.file:match("^/") and t.file) or (root .. "/" .. t.file)
      local rel_path = t.file:gsub("^" .. vim.pesc(root) .. "/", ""):gsub("^/+", "")
      local bufnr_item = vim.fn.bufadd(abs_path)
      table.insert(qf, {
        bufnr = bufnr_item,
        filename = rel_path,
        lnum = t.line,
        text = M.format_task_summary(t, idx),
      })
    end
    state.is_tasks_list = true
    vim.fn.setqflist(qf, "r")
    vim.fn.setqflist({}, "a", { title = string.format("Tasks: %d matches for '%s'", #matches, query) })
    vim.cmd("botright copen 10")

    local target_buf = vim.fn.bufadd(full_path)
    vim.fn.bufload(target_buf)
    local origin_win = ui.get_primary_editor_win()
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

  local cur_win = ui.get_primary_editor_win()
  local cursor_line = 1
  if cur_win and vim.api.nvim_win_is_valid(cur_win) then
    cursor_line = vim.api.nvim_win_get_cursor(cur_win)[1]
  end

  local chosen_line = nil
  local chosen_desc = nil
  local old_lines_count = 1

  -- 1. Check if user specified target_line
  if target_line and target_line > 0 and target_line <= #lines then
    if M.is_todo_comment(lines[target_line]) then
      chosen_line = target_line
    else
      local preview = vim.trim(lines[target_line] or "")
      vim.notify(string.format("Agent: Line %d in %s is not a TODO comment: '%s'", target_line, vim.fn.fnamemodify(filepath, ":t"), preview:sub(1, 40)), vim.log.levels.WARN)
      return
    end
  -- 2. Check if cursor line is a TODO comment
  elseif lines[cursor_line] and M.is_todo_comment(lines[cursor_line]) then
    chosen_line = cursor_line
  else
    -- 3. Search forward from cursor
    for i = cursor_line, #lines do
      if M.is_todo_comment(lines[i]) then
        chosen_line = i
        break
      end
    end
    -- 4. Search from top of file
    if not chosen_line then
      for i = 1, cursor_line - 1 do
        if M.is_todo_comment(lines[i]) then
          chosen_line = i
          break
        end
      end
    end
  end

  -- If NO TODO comment was found in current file:
  if not chosen_line then
    local file_basename = vim.fn.fnamemodify(filepath, ":t")
    vim.notify(string.format("Agent: No in-line TODO/FIXME comments found in '%s'.", file_basename), vim.log.levels.INFO)

    local all_tasks = M.scan_repository_tasks()
    if #all_tasks > 0 then
      local root = ui.get_root_dir()
      local qf = {}
      for idx, t in ipairs(all_tasks) do
        local abs_path = (t.file:match("^/") and t.file) or (root .. "/" .. t.file)
        local rel_path = t.file:gsub("^" .. vim.pesc(root) .. "/", ""):gsub("^/+", "")
        local bufnr_item = vim.fn.bufadd(abs_path)
        table.insert(qf, {
          bufnr = bufnr_item,
          filename = rel_path,
          lnum = t.line,
          text = M.format_task_summary(t, idx),
        })
      end
      state.is_tasks_list = true
      vim.fn.setqflist(qf, "r")
      vim.fn.setqflist({}, "a", { title = string.format("Tasks: %d items (%s)", #all_tasks, vim.fn.fnamemodify(root, ":t")) })
      vim.cmd("botright copen 10")
      local qf_win = vim.api.nvim_get_current_win()
      if cur_win and vim.api.nvim_win_is_valid(cur_win) then
        M.setup_agent_qf_keymaps(cur_win, vim.api.nvim_win_get_buf(qf_win))
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

  -- Count multi-line task comments & duplicate consecutive task headers
  local cur_slug = raw_header:match("%(([a-zA-Z0-9_%-]+)")
  local j = chosen_line + 1
  while j <= #lines do
    local l = vim.trim(lines[j])
    local is_dup_task = cur_slug and l:find(cur_slug, 1, true) and (l:find("TODO%(") or l:find("SPEC%(") or l:find("CONTRACT%(") or l:find("FIXME%("))
    if is_dup_task
      or l:find("^[#/%-]+%s*[Dd]escription:")
      or l:find("^[#/%-]+%s*[Cc]riterion:")
      or l:find("^[#/%-]+%s*action:")
      or l:find("^[#/%-]+%s*requires:")
      or l:find("^[#/%-]+%s*ensures:")
      or l:find("^[#/%-]+%s*invariant:")
      or l:find("^[#/%-]+%s*modifies:")
      or l:find("^[#/%-]+%s*allow:")
      or l:find("^[#/%-]+%s*forbid:")
      or l:find("^[#/%-]+%s*always:")
      or l:find("^[#/%-]+%s*repair:")
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
      if not is_dup_task then
        chosen_desc = chosen_desc .. " " .. l:gsub("^[#/%-]+%s*", "")
      end
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

  local ws_mod = require("agent.workspaces")
  local base_snapshot = ws_mod.capture_file_base(filepath)

  state.is_busy = true
  if state.active_job then
    pcall(function() state.active_job:kill(9) end)
    state.active_job = nil
  end

  local stdout_chunks = {}
  local job_timeout = vim.uv.new_timer()
  job_timeout:start(45000, 0, vim.schedule_wrap(function()
    if state.active_job then
      vim.notify("Agent: Task execution timed out after 45s. Cancelled.", vim.log.levels.WARN)
      pcall(function() state.active_job:kill(9) end)
      state.active_job = nil
      state.is_busy = false
    end
    if job_timeout then
      pcall(function() job_timeout:stop(); job_timeout:close() end)
      job_timeout = nil
    end
  end))

  local llm_mod = require("agent.llm")
  local diff_mod = require("agent.diff")
  local rev_mod = require("agent.reviews")

  state.active_job = vim.system(cmd, { text = true, stdout = function(_, data)
    if data then table.insert(stdout_chunks, data) end
  end }, vim.schedule_wrap(function(res)
    state.active_job = nil
    state.is_busy = false
    if job_timeout then
      pcall(function() job_timeout:stop(); job_timeout:close() end)
      job_timeout = nil
    end

    local raw = table.concat(stdout_chunks, "")
    local solution = llm_mod.parse_solution_from_raw(raw)

    if not solution or not solution.content then
      vim.notify("Agent: Could not parse implementation for task", vim.log.levels.WARN)
      return
    end

    local start_lnum = tonumber(solution.start_line) or chosen_line
    local old_cnt = tonumber(solution.old_lines_count) or old_lines_count
    local new_content = solution.content
    if type(new_content) == "table" then
      local first = new_content[1]
      if type(first) == "table" then
        local parts = {}
        for _, sub in ipairs(new_content) do
          if type(sub) == "table" then
            table.insert(parts, table.concat(sub, ""))
          else
            table.insert(parts, tostring(sub))
          end
        end
        new_content = table.concat(parts, "\n")
      else
        new_content = table.concat(new_content, "\n")
      end
    elseif type(new_content) ~= "string" then
      new_content = tostring(new_content or "")
    end
    local new_lines = vim.split(new_content or "", "\n")

    -- Extract original lines before modification
    local total = vim.api.nvim_buf_line_count(bufnr)
    local s_idx = math.max(0, start_lnum - 1)
    local e_idx = math.min(total, s_idx + old_cnt)
    local orig_slice = vim.api.nvim_buf_get_lines(bufnr, s_idx, e_idx, false)

    new_lines = diff_mod.ensure_contract_preserved_as_done(orig_slice, new_lines)
    new_content = table.concat(new_lines, "\n")

    -- ── Layer 2: DTL Trajectory Validation ──
    local active_task_id = cur_slug or (raw_header and raw_header:match("%(([a-zA-Z0-9_%-]+)")) or "task"
    local dtl_mod = require("agent.dtl")
    local dtl_task_spec = {
      id = active_task_id,
      allow = {},
      forbid = {},
    }
    local all_tasks = M.scan_repository_tasks()
    for _, t in ipairs(all_tasks) do
      if t.task_id and t.task_id ~= "task" and active_task_id ~= "task" and t.task_id:lower() == active_task_id:lower() then
        dtl_task_spec.allow = t.allow or {}
        dtl_task_spec.forbid = t.forbid or {}
        break
      end
    end
    local dtl_ok, dtl_err, ctd_action = dtl_mod.validate_patch(dtl_task_spec, filepath, new_content)
    if not dtl_ok then
      vim.notify(string.format("⚠ [DTL TRAJECTORY VIOLATION]: %s\nExecuting CTD Action: %s", dtl_err, ctd_action or "auto_revert"), vim.log.levels.ERROR)
      state.is_busy = false
      return
    end

    -- Apply changes to buffer preview (without saving to disk until user accepts via :Tasks YES)
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, s_idx, e_idx, false, new_lines)

    -- Create review record and patch on disk marked UNREVIEWED with base hash tracking
    local rev = rev_mod.create_review(filepath, start_lnum, old_cnt, orig_slice, new_lines, raw_header, solution.description or chosen_desc, "unreviewed", nil, false, {
      base_hash = base_snapshot.hash,
      base_content = base_snapshot.content,
    })
    state.current_review = rev

    diff_mod.show_inline_diff(bufnr, start_lnum, new_content, old_cnt, false, orig_slice, rev)
    -- Focus, jump to first changed line, and refresh
    vim.schedule(function()
      local ok_win = pcall(vim.api.nvim_win_set_buf, 0, bufnr)
      local fw = vim.fn.win_findbuf(bufnr)
      if fw and fw[1] and vim.api.nvim_win_is_valid(fw[1]) then
        vim.api.nvim_set_current_win(fw[1])
        pcall(vim.api.nvim_win_set_cursor, fw[1], { start_lnum, 0 })
        pcall(function() vim.cmd("normal! zz") end)
      end
      vim.cmd("redraw")
    end)
  end))
end

function M.run_file(file_arg)
  file_arg = vim.trim(file_arg or "")
  if file_arg == "" then
    vim.notify("Usage: :Tasks start <path/to/file>", vim.log.levels.INFO)
    return
  end
  local root = ui.get_root_dir()
  local full = file_arg:match("^/") and file_arg or (root .. "/" .. file_arg)
  if vim.fn.filereadable(full) ~= 1 then
    vim.notify("Agent file: File not found: " .. file_arg, vim.log.levels.WARN)
    return
  end
  local bufnr = vim.fn.bufadd(full)
  vim.fn.bufload(bufnr)
  local origin_win = ui.get_primary_editor_win()
  vim.api.nvim_win_set_buf(origin_win, bufnr)
  M.run_todo(bufnr, 1)
end

function M.insert_single_task_stub(file_arg, line_arg, desc_arg, win)
  local root = ui.get_root_dir()
  local clean_desc = vim.trim(desc_arg or ""):gsub("[\r\n]+", " ")
  local raw_file = vim.trim(file_arg or "TODO.md")
  if raw_file:sub(1, #root) == root then
    raw_file = raw_file:sub(#root + 1)
  end
  local rel_file = raw_file:gsub("^/+", ""):gsub("^%./", "")
  if rel_file:match("%.%./") or rel_file:match("%.%.$") or rel_file == "" then
    rel_file = "TODO.md"
  end
  local full_path = root .. "/" .. rel_file
  local leader = get_comment_leader(rel_file)

  local is_new_file = (vim.fn.filereadable(full_path) ~= 1)
  vim.fn.mkdir(vim.fn.fnamemodify(full_path, ":h"), "p")
  local bufnr = vim.fn.bufadd(full_path)
  vim.fn.bufload(bufnr)
  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  local is_empty = (total_lines <= 1 and (vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or "") == "")
  local insert_idx = is_empty and 0 or math.min(total_lines, math.max(0, (line_arg or 1) - 1))

  local indent = ""
  if not is_empty and insert_idx < total_lines then
    local target_line_text = vim.api.nvim_buf_get_lines(bufnr, insert_idx, insert_idx + 1, false)[1] or ""
    indent = target_line_text:match("^(%s*)") or ""
  end

  local base_slug = clean_desc:lower():gsub("[^%a0-9%s_-]", ""):gsub("%s+", "-"):sub(1, 48):gsub("%-+$", "")
  if base_slug == "" then base_slug = "task" end

  local all_tasks = M.scan_repository_tasks()
  local existing_slugs = {}
  for _, t in ipairs(all_tasks) do
    local s = (t.task_id or ""):match("%(([%w_%-]+)") or (t.task_id or ""):match("%[([%w_%-]+)") or t.task_id
    if s and s ~= "" then existing_slugs[s:lower()] = true end
  end

  local slug = base_slug
  local counter = 2
  while existing_slugs[slug:lower()] do
    slug = base_slug .. "-" .. counter
    counter = counter + 1
  end

  local header = string.format("%s%s TODO(%s | tier:A | status:TODO): %s", indent, leader, slug, clean_desc)
  local stub_lines = { header }

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, insert_idx, is_empty and 1 or insert_idx, false, stub_lines)
  vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! write!") end)

  local rev_mod = require("agent.reviews")
  local rev = rev_mod.create_review(full_path, insert_idx + 1, 0, {}, stub_lines, slug, clean_desc, "unreviewed", 1, true)
  if rev then
    rev.is_new_file = is_new_file
    rev_mod.save_review_meta(rev)
    rev_mod.list_reviews_qf()
    rev_mod.show_review(rev)
    vim.notify(string.format("● [Tasks] Task stub '%s' added to :Tasks review.", slug), vim.log.levels.INFO)
  end
end

function M.apply_decomposed_parts(parts, specification, root, all_tasks)
  local rev_mod = require("agent.reviews")
  local existing_slug_map = {}
  for _, t in ipairs(all_tasks) do
    local s = (t.task_id or ""):match("%(([%w_%-]+)") or (t.task_id or ""):match("%[([%w_%-]+)") or t.task_id
    if s and s ~= "" then existing_slug_map[s:lower()] = true end
  end
  local seen_slugs = {}
  local file_line_offsets = {}

  local created_reviews = {}
  for idx, part in ipairs(parts) do
    local raw_file = vim.trim(part.file or part.filepath or part.path or "TODO.md")
    if raw_file:sub(1, #root) == root then
      raw_file = raw_file:sub(#root + 1)
    end
    local rel_file = raw_file:gsub("^/+", ""):gsub("^%./", "")
    if rel_file:match("%.%./") or rel_file:match("%.%.$") or rel_file == "" then
      rel_file = "TODO.md"
    end
    local full_path = root .. "/" .. rel_file
    local leader = get_comment_leader(rel_file)

    -- Disambiguate task_id / slug
    local raw_id = part.task_id or part.slug or part.id or part.name
    local clean_action = vim.trim(part.action or part.description or part.title or specification or ""):gsub("[\r\n]+", " ")
    local base_slug = raw_id and tostring(raw_id):lower():gsub("[^%a0-9%s_-]", ""):gsub("%s+", "-"):sub(1, 48):gsub("%-+$", "") or ""
    if base_slug == "" then
      base_slug = clean_action:lower():gsub("[^%a0-9%s_-]", ""):gsub("%s+", "-"):sub(1, 48):gsub("%-+$", "")
    end
    if base_slug == "" then base_slug = "task" end

    local slug = base_slug
    local counter = 2
    while seen_slugs[slug:lower()] or existing_slug_map[slug:lower()] do
      slug = base_slug .. "-" .. counter
      counter = counter + 1
    end
    seen_slugs[slug:lower()] = true

    -- Normalize depends_on and blocks if LLM gave string instead of table
    local dep_list = {}
    if type(part.depends_on) == "table" then
      dep_list = part.depends_on
    elseif type(part.depends_on) == "string" and vim.trim(part.depends_on) ~= "" then
      dep_list = { vim.trim(part.depends_on) }
    end

    local blk_list = {}
    if type(part.blocks) == "table" then
      blk_list = part.blocks
    elseif type(part.blocks) == "string" and vim.trim(part.blocks) ~= "" then
      blk_list = { vim.trim(part.blocks) }
    end

    local dep_str = ""
    if #dep_list > 0 then
      dep_str = string.format(" | depends_on:[%s]", table.concat(dep_list, ", "))
    end
    local blk_str = ""
    if #blk_list > 0 then
      blk_str = string.format(" | blocks:[%s]", table.concat(blk_list, ", "))
    end
    local tier_str = string.format(" | tier:%s", part.tier or "A")

    local is_new_file = (vim.fn.filereadable(full_path) ~= 1)
    vim.fn.mkdir(vim.fn.fnamemodify(full_path, ":h"), "p")
    local bufnr = vim.fn.bufadd(full_path)
    vim.fn.bufload(bufnr)
    local total_lines = vim.api.nvim_buf_line_count(bufnr)
    local is_empty = (total_lines <= 1 and (vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or "") == "")

    local parsed_line = tonumber(tostring(part.line or "1"):match("%d+")) or 1
    local offset = file_line_offsets[full_path] or 0
    local req_line = parsed_line + offset
    local insert_idx = is_empty and 0 or math.min(total_lines, math.max(0, req_line - 1))

    local indent = ""
    if not is_empty and insert_idx < total_lines then
      local target_line_text = vim.api.nvim_buf_get_lines(bufnr, insert_idx, insert_idx + 1, false)[1] or ""
      indent = target_line_text:match("^(%s*)") or ""
    end

    local header = string.format("%s%s TODO(%s%s%s | status:TODO): %s", indent, leader, slug, tier_str, dep_str .. blk_str, clean_action)

    local req_list = dep_list
    local req_str = #req_list > 0 and table.concat(req_list, ", ") or ""

    local raw_crit = (part.ensures and vim.trim(part.ensures) ~= "") and part.ensures or ((part.criteria and vim.trim(part.criteria) ~= "") and part.criteria or (clean_action .. " implementation verified"))
    local ensures_val = raw_crit:gsub('^review:%s*"?', ''):gsub('"?$', '')

    local allow_list = {}
    if type(part.allow) == "table" then
      allow_list = part.allow
    elseif type(part.allow) == "string" and vim.trim(part.allow) ~= "" then
      allow_list = { vim.trim(part.allow) }
    end
    if #allow_list == 0 then
      table.insert(allow_list, rel_file)
    end

    local forbid_list = {}
    if type(part.forbid) == "table" then
      forbid_list = part.forbid
    elseif type(part.forbid) == "string" and vim.trim(part.forbid) ~= "" then
      forbid_list = { vim.trim(part.forbid) }
    end
    if #forbid_list == 0 then
      forbid_list = { ".env*", "*.pem", "*.key" }
    end

    local raw_always = (part.always and vim.trim(part.always) ~= "") and part.always or ((part.invariant and vim.trim(part.invariant) ~= "") and part.invariant or "Existing repository code and interfaces preserved")
    local always_val = raw_always:gsub('^review:%s*"?', ''):gsub('"?$', '')

    local repair_val = (part.repair and vim.trim(part.repair) ~= "") and part.repair or ((part.ctd and vim.trim(part.ctd) ~= "") and part.ctd or "on_violation -> (auto_revert, mark:REVISE)")

    local stub_lines = {
      header,
      string.format("%s%s   [HOARE CODE CONTRACT]", indent, leader),
      string.format("%s%s   requires:  [%s]", indent, leader, req_str),
      string.format("%s%s   action:    %s", indent, leader, clean_action),
      string.format("%s%s   ensures:   review: \"%s\"", indent, leader, ensures_val),
      string.format("%s%s", indent, leader),
      string.format("%s%s   [DTL AGENT POLICY]", indent, leader),
      string.format("%s%s   allow:     [%s]", indent, leader, table.concat(allow_list, ", ")),
      string.format("%s%s   forbid:    [%s]", indent, leader, table.concat(forbid_list, ", ")),
      string.format("%s%s   always:    review: \"%s\"", indent, leader, always_val),
      string.format("%s%s   repair:    %s", indent, leader, repair_val),
    }

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, insert_idx, is_empty and 1 or insert_idx, false, stub_lines)
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! write!") end)

    file_line_offsets[full_path] = offset + #stub_lines

    local rev = rev_mod.create_review(full_path, insert_idx + 1, 0, {}, stub_lines, slug, clean_action, "unreviewed", idx, true)
    if rev then
      rev.is_new_file = is_new_file
      rev_mod.save_review_meta(rev)
      table.insert(created_reviews, rev)
    end
  end

  if #created_reviews > 0 then
    rev_mod.list_reviews_qf()
    rev_mod.show_review(created_reviews[1])
    vim.notify(string.format("● [Tasks] Specification split into %d tasks across repository in logical order. Use :Tasks review to inspect, :Tasks YES <id> to approve.", #created_reviews), vim.log.levels.INFO)
  end

  return created_reviews
end

function M.decompose_and_add_tasks(specification, win, test_parts)
  specification = vim.trim(specification or "")
  if specification == "" then return end

  local root = ui.get_root_dir()
  local state = state_mod.state
  pcall(vim.fn.chdir, root)

  local all_tasks = M.scan_repository_tasks()
  if test_parts then
    return M.apply_decomposed_parts(test_parts, specification, root, all_tasks)
  end

  -- Collect repository files
  local files_out = vim.fn.system({ "git", "-C", root, "ls-files" })
  local file_list = {}
  if vim.v.shell_error == 0 and files_out ~= "" then
    for line in files_out:gmatch("[^\r\n]+") do
      local low = line:lower()
      if not low:match("%.olean$") and not low:match("%.tex$") and not low:match("%.jsonl$")
         and not low:match("%.log$") and not low:match("%.min%.js$") and not low:match("%.lock$")
         and not low:match("%.png$") and not low:match("%.svg$") and not low:match("^%.git/") then
        if #file_list < 150 then
          table.insert(file_list, line)
        end
      end
    end
  end

  if #file_list == 0 then
    local find_out = vim.fn.system({ "find", root, "-maxdepth", "3", "-not", "-path", "*/.*", "-not", "-path", "*/target/*", "-not", "-path", "*/node_modules/*", "-type", "f" })
    if vim.v.shell_error == 0 and find_out ~= "" then
      for line in find_out:gmatch("[^\r\n]+") do
        local rel = line:gsub("^" .. vim.pesc(root) .. "/?", "")
        if rel ~= "" and not rel:match("%.olean$") and not rel:match("%.tex$") and #file_list < 150 then
          table.insert(file_list, rel)
        end
      end
    end
  end

  -- Collect existing tasks to give architecture context
  local all_tasks = M.scan_repository_tasks()
  local existing_tasks_list = {}
  for _, t in ipairs(all_tasks) do
    if #existing_tasks_list < 30 then
      local id_str = (t.task_id and t.task_id ~= "task") and t.task_id or ""
      table.insert(existing_tasks_list, string.format("- [%s] %s in %s:%d (%s)", t.status or "TODO", id_str, t.file, t.line, t.description or ""))
    end
  end

  -- Optional active editor context hint
  local active_hint = ""
  local cur_buf = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win)
  if cur_buf and vim.bo[cur_buf].buftype == "" then
    local cur_name = vim.api.nvim_buf_get_name(cur_buf)
    if cur_name ~= "" and vim.fn.filereadable(cur_name) == 1 then
      local rel = vim.fn.fnamemodify(cur_name, ":.")
      active_hint = string.format("CURRENTLY OPEN FILE: %s (DO NOT place tasks in this file unless it is genuinely the best architectural fit for the task).", rel)
    end
  end

  local prompt = string.format([[
You are an expert software architect.
A developer requested the following specification to be planned and split into in-tree tasks across the repository:

SPECIFICATION:
"%s"

%s

REPOSITORY ROOT: %s
KEY FILES IN REPOSITORY:
%s

EXISTING REPOSITORY TASKS:
%s

GOAL:
Analyze the repository structure, code conventions, and file hierarchy. Split this specification into discrete, actionable TODO task stubs placed across the appropriate files in the codebase, enforcing the repository's Two-Layer Architecture (Layer 1 Hoare Code Contract & Layer 2 Deontic Temporal Logic Agent Policy).

REQUIREMENTS:
1. Decompose the specification into 1 to 5 concrete subtasks/parts.
2. For each part, select the BEST architectural target file in the repository (inspect KEY FILES IN REPOSITORY) matching domain responsibility. DO NOT simply dump tasks into whatever file happened to be open in the editor unless it genuinely belongs there!
3. For each part, specify:
   - "task_id": concise unique kebab-case slug identifier (e.g. "auth-jwt-store", "auth-token-endpoint").
   - "file": repository-relative path where this stub should be inserted (use an existing file if suitable, or a standard new file path matching codebase conventions).
   - "line": 1-based line number where the stub should be inserted (e.g. 1 at top of file, or after imports, or near relevant struct/function).
   - "tier": "A" (foundational/prerequisite), "B" (core implementation), or "C" (integration/tests).
   - "depends_on": array of prerequisite task_id strings (Hoare preconditions). Tier A tasks have [].
   - "blocks": array of downstream task_id strings depending on this task.
   - "action": precise 1-2 sentence description of concrete implementation steps.
   - "ensures": verifiable acceptance postcondition string (e.g. 'review: "..."').
   - "allow": array of repository-relative files/globs permitted to be modified (must include the target file and direct auxiliaries).
   - "forbid": array of forbidden file patterns (must include [".env*", "*.pem", "*.key"]).
   - "always": safety invariant string that must hold across diff application (e.g. 'review: "..."').
   - "repair": CTD error recovery action on policy violation (default: "on_violation -> (auto_revert, mark:REVISE)").
4. Order the "parts" array in STRICT LOGICAL TOPOLOGICAL ORDER:
   Prerequisites and foundational parts MUST appear before parts that depend on them.
5. Output STRICT JSON ONLY matching this schema:
{
  "summary": "<one-sentence summary of decomposition>",
  "parts": [
    {
      "task_id": "slug-id",
      "file": "path/to/file.ext",
      "line": 1,
      "tier": "A",
      "depends_on": [],
      "blocks": ["downstream-slug"],
      "action": "Description of action",
      "ensures": "Acceptance criteria / postcondition",
      "allow": ["path/to/file.ext"],
      "forbid": [".env*", "*.pem", "*.key"],
      "always": "Safety invariant to maintain across changes",
      "repair": "on_violation -> (auto_revert, mark:REVISE)"
    }
  ]
}
Emit ONLY raw JSON. No markdown code blocks, no prose before or after.
]], specification, active_hint, root, table.concat(file_list, "\n"), table.concat(existing_tasks_list, "\n"))

  local agy_bin = vim.fn.exepath("agy")
  local opencode_bin = vim.fn.exepath("opencode")
  local cmd = {}
  if agy_bin ~= "" then
    cmd = { agy_bin, "-p", prompt, "--model", "Gemini 3.8 Flash (Low)", "--dangerously-skip-permissions", "--disable-slash-commands" }
  elseif opencode_bin ~= "" then
    cmd = { opencode_bin, "run", "--format", "json", prompt }
  else
    vim.notify("Tasks: Neither 'agy' nor 'opencode' found in PATH", vim.log.levels.ERROR)
    return
  end

  local ws_mod = require("agent.workspaces")
  local base_snapshot = ws_mod.capture_file_base(filepath)

  state.is_busy = true
  if state.active_job then
    pcall(function() state.active_job:kill(9) end)
    state.active_job = nil
  end

  vim.api.nvim_echo({ { string.format("● [Tasks] Planning and splitting '%s' across repository...", specification), "ModeMsg" } }, false, {})
  vim.cmd("redraw")

  local stdout_chunks = {}
  local job_timeout = vim.uv.new_timer()
  job_timeout:start(45000, 0, vim.schedule_wrap(function()
    if state.active_job then
      vim.notify("Tasks: Task decomposition timed out after 45s. Cancelled.", vim.log.levels.WARN)
      pcall(function() state.active_job:kill(9) end)
      state.active_job = nil
      state.is_busy = false
    end
    if job_timeout then
      pcall(function() job_timeout:stop(); job_timeout:close() end)
      job_timeout = nil
    end
  end))

  local llm_mod = require("agent.llm")
  local rev_mod = require("agent.reviews")

  state.active_job = vim.system(cmd, { text = true, stdout = function(_, data)
    if data then table.insert(stdout_chunks, data) end
  end }, vim.schedule_wrap(function(res)
    state.active_job = nil
    state.is_busy = false
    if job_timeout then
      pcall(function() job_timeout:stop(); job_timeout:close() end)
      job_timeout = nil
    end

    local raw = table.concat(stdout_chunks, "")
    local data = llm_mod.extract_json_object(raw)
    local parts = data and (data.parts or data.tasks or data.subtasks)

    if not parts or #parts == 0 then
      local fallback_file = "TODO.md"
      local spec_low = specification:lower()
      local best_score = 0
      local best_file = nil

      for _, f in ipairs(file_list) do
        local f_low = f:lower()
        local score = 0
        for word in spec_low:gmatch("[%a%d_-]+") do
          if #word >= 4 and f_low:find(word, 1, true) then
            score = score + 2
          end
        end
        if score > best_score then
          best_score = score
          best_file = f
        end
      end

      if best_file and best_score > 0 then
        fallback_file = best_file
      elseif cur_buf and vim.api.nvim_buf_is_valid(cur_buf) and vim.bo[cur_buf].buftype == "" then
        local cur_name = vim.api.nvim_buf_get_name(cur_buf)
        if cur_name ~= "" then fallback_file = vim.fn.fnamemodify(cur_name, ":.") end
      end

      local slug = specification:lower():gsub("[^%a0-9%s_-]", ""):gsub("%s+", "-"):sub(1, 48):gsub("%-+$", "")
      if slug == "" then slug = "task" end
      parts = {
        {
          task_id = slug,
          file = fallback_file,
          line = 1,
          tier = "A",
          depends_on = {},
          blocks = {},
          action = specification,
          ensures = specification .. " verified",
          allow = { fallback_file },
          forbid = { ".env*", "*.pem", "*.key" },
          always = "Existing repository code and interfaces preserved",
          repair = "on_violation -> (auto_revert, mark:REVISE)",
        }
      }
    end

    M.apply_decomposed_parts(parts, specification, root, all_tasks)
  end))
end

function M.add_task(arg_str, win)
  win = win or ui.get_primary_editor_win()
  arg_str = vim.trim(arg_str or "")
  if arg_str == "" then
    ui.open_docked_input("Tasks Add: Multi-line Task Entry", "", function(input)
      if input and vim.trim(input) ~= "" then
        M.add_task(input, win)
      end
    end)
    return
  end

  arg_str = arg_str:gsub('^["\']', ''):gsub('["\']$', '')
  local file_arg, line_arg, desc_arg = arg_str:match("^([^%s:]+):(%d+)%s+(.*)$")
  if file_arg and line_arg and desc_arg then
    M.insert_single_task_stub(file_arg, tonumber(line_arg), desc_arg, win)
    return
  end

  M.decompose_and_add_tasks(arg_str, win)
end

function M.start_task(raw)
  state_mod.state.origin_win = ui.get_primary_editor_win()
  raw = vim.trim(raw or "")

  -- If called without arguments: execute closest in-line task visible in the current window
  if raw == "" then
    local win = ui.get_primary_editor_win()
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

    local t_info = M.extract_task_info(best_text)
    if t_info and t_info.depends_on and #t_info.depends_on > 0 then
      local all_tasks = M.scan_repository_tasks()
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

    vim.api.nvim_win_set_cursor(win, { best_line, 0 })
    vim.cmd("normal! zz")
    local ns = state_mod.ns_flash
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

  local resolved_id = M.resolve_task_identifier(raw)
  local all_tasks = M.scan_repository_tasks()
  local matched_task = nil
  for _, t in ipairs(all_tasks) do
    if t.task_id and t.task_id ~= "task" and t.task_id:lower() == resolved_id:lower() then
      matched_task = t
      break
    end
  end

  if matched_task then
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

    local root = ui.get_root_dir()
    local full_path = (matched_task.file:sub(1, 1) == "/") and matched_task.file or (root .. "/" .. matched_task.file)
    local target_buf = vim.fn.bufadd(full_path)
    vim.fn.bufload(target_buf)
    local origin_win = ui.get_primary_editor_win()
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

function M.revise_task(task_arg)
  task_arg = vim.trim(task_arg or "")
  local cur_buf = vim.api.nvim_get_current_buf()
  local root = ui.get_root_dir()

  local target_buf = cur_buf
  local target_line = nil
  local target_task_id = nil

  if task_arg ~= "" then
    local all_tasks = M.scan_repository_tasks()
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
    local cur_win = ui.get_primary_editor_win()
    if cur_win and vim.api.nvim_win_is_valid(cur_win) then
      local lnum = vim.api.nvim_win_get_cursor(cur_win)[1]
      local lines = vim.api.nvim_buf_get_lines(cur_buf, 0, -1, false)
      for i = lnum, 1, -1 do
        if M.is_todo_comment(lines[i]) then
          target_line = i
          break
        end
      end
      if not target_line then
        for i = lnum, #lines do
          if M.is_todo_comment(lines[i]) then
            target_line = i
            break
          end
        end
      end
    end
  end

  if not target_line then
    vim.notify("Tasks: Place cursor on/near a task to revise, or specify :Tasks MAYBE <id>", vim.log.levels.INFO)
    return
  end

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

    local t_info = M.extract_task_info(header)
    target_task_id = (t_info and t_info.id) or target_task_id or "task"
  end

  local origin_win = ui.get_primary_editor_win()
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

function M.tasks_complete(arglead, cmdline)
  local parts = vim.split(vim.trim(cmdline), "%s+")
  local has_trailing = cmdline:match("%s+$") ~= nil
  local subcmds = { "list", "add", "start", "stop", "review", "YES", "MAYBE", "NO", "resolve", "rebase", "accept", "reject", "revise" }

  if #parts == 1 or (#parts == 2 and not has_trailing) then
    return vim.tbl_filter(function(s) return vim.startswith(s:lower(), arglead:lower()) or vim.startswith(s, arglead) end, subcmds)
  end

  local sub = (parts[2] or ""):lower()
  if sub == "start" or sub == "revise" or sub == "maybe" then
    local ids = {}
    local all_tasks = M.scan_repository_tasks()
    for idx, t in ipairs(all_tasks) do
      if t.task_id and t.task_id ~= "task" then
        table.insert(ids, t.task_id)
      end
      table.insert(ids, tostring(idx))
    end
    return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, ids)
  elseif sub == "accept" or sub == "reject" or sub == "yes" or sub == "no" or sub == "resolve" or sub == "rebase" then
    local ids = {}
    local rev_mod = require("agent.reviews")
    local reviews = rev_mod.get_reviews("all")
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
    local llm_mod = require("agent.llm")
    local diff_mod = require("agent.diff")
    llm_mod.stop()
    diff_mod.clear_diff()
    vim.notify("Tasks: Execution stopped and diff previews cleared.", vim.log.levels.INFO)
  elseif subcmd == "review" then
    local rev_mod = require("agent.reviews")
    rev_mod.review(rest)
  elseif subcmd == "yes" or subcmd == "accept" then
    local rev_mod = require("agent.reviews")
    rev_mod.accept(rest)
  elseif subcmd == "no" or subcmd == "reject" then
    local rev_mod = require("agent.reviews")
    rev_mod.reject(rest)
  elseif subcmd == "maybe" or subcmd == "revise" then
    M.revise_task(rest)
  elseif subcmd == "resolve" then
    local rev_mod = require("agent.reviews")
    rev_mod.review("resolve", rest)
  elseif subcmd == "rebase" then
    local rev_mod = require("agent.reviews")
    rev_mod.review("rebase", rest)
  else
    -- Check if subcmd matches a known task ID or numeric index
    local all_tasks = M.scan_repository_tasks()
    local resolved = M.resolve_task_identifier(subcmd)
    local found = false
    for _, t in ipairs(all_tasks) do
      if t.task_id and t.task_id ~= "task" and (t.task_id:lower() == resolved:lower() or t.task_id:lower() == subcmd:lower()) then
        found = true
        break
      end
    end
    if found then
      M.start_task(subcmd)
    else
      vim.notify(string.format("Tasks: Unknown subcommand or task ID '%s'. Available: list, add, start, stop, review, YES, MAYBE, NO", subcmd), vim.log.levels.WARN)
    end
  end
end

return M
