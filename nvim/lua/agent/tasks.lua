-- TODO(support-for-tasks-delete-and-tasks-modify | status:TODO): support for ':Tasks delete' and ':Tasks modify'
-- CONTRACT(review-todo-routing-decomposition-model):
--   [HOARE CODE CONTRACT]
--   requires:  []
--   action:    Review and optimize TODO routing and contextual placement heuristics across multi-language repositories with a high-capacity model (e.g. Pro/Claude-3.5-Sonnet) to ensure semantic placement and zero header corruption.
--   ensures:   review: "Smart TODO placement heuristics correctly handle shebangs, docstrings, symbols, and language-specific sections without corrupting files"
--
--   [DTL AGENT POLICY]
--   allow:     [nvim/lua/agent/tasks.lua, tests/test_todo_routing_suite.lua]
--   forbid:    [.env*, *.pem, *.key]
--   always:    review: "Existing task scanning and execution workflows remain functional"
--   repair:    on_violation -> (auto_revert, mark:REVISE)
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
         line:match("^[ \t]*[#/%-%*%\"]+%s*CONTRACT%(") ~= nil or
         line:match("^[ \t]*[-*]%s*%[%s*%]") ~= nil
end

function M.extract_task_info(line)
  if not line then return nil end
  local kind, inside, desc = line:match("^[ \t]*[#/%-%*%\"]+%s*(%a+)%(([^)]*)%)%s*:?%s*(.*)$")
  if kind and inside then
    local parts = vim.split(inside, "%s*|%s*")
    local clean_id = vim.trim(parts[1] or "task")
    if clean_id == "" then clean_id = "task" end
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
      local s = p:match("status:([%w_%-]+)")
      if s then status = s:upper() end
      local dep_str = p:match("depends_on:%[([^%]]+)%]")
      if dep_str then
        for d in dep_str:gmatch("[^,%s%[%]]+") do
          table.insert(depends_on, vim.trim(d))
          if not vim.tbl_contains(requires, vim.trim(d)) then
            table.insert(requires, vim.trim(d))
          end
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
  if kind3 and (kind3 == "TODO" or kind3 == "FIXME" or kind3 == "SPEC" or kind3 == "CONTRACT") then
    return { kind = kind3, id = "task", status = "TODO", requires = {}, depends_on = {}, blocks = {}, desc = desc3 }
  end
  local kind4, desc4 = line:match("^[ \t]*[#/%-%*%\"]+%s*(%a+)%s+(.*)$")
  if kind4 and (kind4 == "TODO" or kind4 == "FIXME" or kind4 == "SPEC" or kind4 == "CONTRACT") then
    return { kind = kind4, id = "task", status = "TODO", requires = {}, depends_on = {}, blocks = {}, desc = desc4 }
  end
  return nil
end

function M.scan_repository_tasks(root)
  root = root or ui.get_root_dir()
  local pattern = "(#|//|--|/\\*).*\\b(TODO|FIXME|SPEC|CONTRACT)\\b"
  local grep_cmd = { "git", "-C", root, "grep", "--untracked", "-n", "-I", "-E", pattern, "--", ":!*.json*", ":!*.log", ":!*.ipynb", ":!*.olean", ":!specs/.lexlean/*", ":!logs/*" }
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
            test = t_info.test,
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
                local tst = cleaned:match("^[Tt]est:%s*(.*)$")
                if tst and tst ~= "" then contract.test = vim.trim(tst) end

                local act = cleaned:match("^[Aa]ction:%s*(.*)$")
                if act and act ~= "" then contract.action = act; desc = act end

                local req = cleaned:match("^[Rr]equires:%s*%[([^%]]*)%]") or cleaned:match("^%[PRE%]%s*(.*)$")
                if req then
                  for r in req:gmatch("[^,%s%[%]]+") do
                    if not vim.tbl_contains(contract.requires, vim.trim(r)) then
                      table.insert(contract.requires, vim.trim(r))
                    end
                    if not vim.tbl_contains(t_info.depends_on, vim.trim(r)) then
                      table.insert(t_info.depends_on, vim.trim(r))
                    end
                  end
                end

                local ens = cleaned:match("^[Ee]nsures:%s*(.*)$") or cleaned:match("^%[POST%]%s*(.*)$")
                if ens and ens ~= "" then
                  local emb_test, rest_ens = ens:match('^test:%s*"?([^"|%s]+)"?%s*|%s*(.*)$')
                  if emb_test then
                    contract.test = emb_test
                    contract.ensures = rest_ens
                  else
                    contract.ensures = ens
                  end
                end

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

          table.insert(tasks, {
            file = fpath,
            line = tonumber(lnum) or 1,
            task_id = t_info.id,
            status = t_info.status or "TODO",
            depends_on = t_info.depends_on or {},
            blocks = t_info.blocks or {},
            kind = t_info.kind or "CONTRACT",
            description = desc,
            raw = txt,
            contract = contract,
            allow = contract.allow,
            forbid = contract.forbid,
            requires = contract.requires,
            test = contract.test,
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

function M.sort_tasks(tasks)
  -- First sort deterministically by file and line
  table.sort(tasks, function(a, b)
    if (a.file or "") ~= (b.file or "") then
      return (a.file or "") < (b.file or "")
    end
    return (a.line or 0) < (b.line or 0)
  end)

  -- Check if any tasks declare Hoare `requires` or `blocks` dependencies
  local any_deps = false
  for _, t in ipairs(tasks) do
    if #(t.requires or t.depends_on or {}) > 0 or #(t.blocks or {}) > 0 then
      any_deps = true
      break
    end
  end
  if not any_deps then
    return tasks
  end

  -- Use native C++ LuaJIT FFI topological DAG sorter (dtl_sort_task_dag) over Hoare `requires`
  local ok_dtl, dtl_mod = pcall(require, "agent.dtl")
  local dag_rank = {}
  if ok_dtl and dtl_mod and dtl_mod.sort_tasks and #tasks > 1 then
    local dag_nodes = {}
    for _, t in ipairs(tasks) do
      if t.task_id and t.task_id ~= "task" then
        table.insert(dag_nodes, {
          id = t.task_id,
          requires = t.requires or t.depends_on or {},
          blocks = t.blocks or {},
        })
      end
    end
    local sorted_ids = dtl_mod.sort_tasks(dag_nodes)
    for idx, id in ipairs(sorted_ids or {}) do
      if not dag_rank[id] then
        dag_rank[id] = idx
      end
    end
  end

  table.sort(tasks, function(a, b)
    local req_a = #(a.requires or a.depends_on or {})
    local req_b = #(b.requires or b.depends_on or {})
    if (req_a == 0) ~= (req_b == 0) then
      return req_a == 0
    end
    local ra = a.task_id and dag_rank[a.task_id]
    local rb = b.task_id and dag_rank[b.task_id]
    if ra and rb and ra ~= rb then
      return ra < rb
    end
    if (a.file or "") ~= (b.file or "") then
      return (a.file or "") < (b.file or "")
    end
    return (a.line or 0) < (b.line or 0)
  end)
  return tasks
end

--- Resolve an argument to a concrete task record (file + line), in agenda order.
--- Numbers index the agenda exactly as shown by :Tasks list, so duplicate slugs
--- resolve to the right occurrence.
function M.resolve_task_record(arg)
  arg = vim.trim(arg or "")
  if arg == "" then return nil end
  local all_tasks = M.sort_tasks(M.scan_repository_tasks())

  local num = tonumber(arg:match("^#?(%d+)$"))
  if num then return all_tasks[num] end

  local clean = arg:gsub("^#", ""):lower()
  for _, t in ipairs(all_tasks) do
    if t.task_id and t.task_id ~= "task" and t.task_id:lower() == clean then
      return t
    end
  end
  for _, t in ipairs(all_tasks) do
    if t.task_id and t.task_id ~= "task" and t.task_id:lower():find(clean, 1, true) then
      return t
    end
  end
  return nil
end

function M.resolve_task_identifier(arg)
  arg = vim.trim(arg or "")
  if arg == "" then return nil end
  local t = M.resolve_task_record(arg)
  return (t and t.task_id) or arg
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
      if #(t.requires or t.depends_on or {}) == 0 then
        score = score + 5
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
          vim.wo[w].statusline = "%#AgentDiffHeader# ● TASKS %#AgentDiffMenuSel# [<CR>] Jump %#AgentDiffHeader#  %#AgentDiffMenuBtn# [s/Space] Start Task %#AgentDiffHeader#  %#AgentDiffMenuBtn# [o] Jump & Close %#AgentDiffHeader#  %#Normal# [q] Close %="
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

  local function start_task_from_qf()
    local idx = vim.fn.line(".")
    local qf_list = vim.fn.getqflist()
    local item = qf_list[idx]
    if not item then return end
    local q = state.queue and state.queue[idx]
    vim.cmd("cclose")
    if q and q.path and q.line then
      -- Start by exact location: robust against duplicate slugs
      M.start_task_record({ file = q.path, line = q.line, task_id = q.task_id, description = q.description })
    else
      M.start_task(tostring(idx))
    end
  end

  vim.keymap.set("n", "s", function()
    if state.is_tasks_list then
      start_task_from_qf()
      return
    end
  end, { buffer = qf_buf, silent = true, noremap = true, desc = "Start selected task" })

  vim.keymap.set("n", "<Space>", function()
    if state.is_tasks_list then
      start_task_from_qf()
      return
    end
    jump_in_origin(false)
  end, { buffer = qf_buf, silent = true, noremap = true, desc = "Start selected task (in tasks list) or jump" })

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

  vim.keymap.set("n", "m", function()
    if state.is_tasks_list then
      local idx = vim.fn.line(".")
      local qf_list = vim.fn.getqflist()
      local item = qf_list[idx]
      local t_id = item and item.text and item.text:match("%[[%w_%-]+%]%s*([%w_%-]+)")
      vim.cmd("cclose")
      if t_id then
        M.move_task(t_id)
      else
        M.move_task(tostring(idx))
      end
    end
  end, { buffer = qf_buf, silent = true, noremap = true, desc = "Pick up task and enter interactive placement mode to move it" })

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
  local tasks = M.sort_tasks(M.scan_repository_tasks(root))
  if #tasks == 0 then
    vim.notify("Tasks: No in-tree task contracts found in " .. vim.fn.fnamemodify(root, ":t"), vim.log.levels.INFO)
    return
  end

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
    string.format("%s CONTRACT(%s):", leader, slug),
    string.format("%s   [HOARE CODE CONTRACT]", leader),
    string.format("%s   requires:  []", leader),
    string.format("%s   action:    %s", leader, instruction),
    string.format('%s   ensures:   review: "%s"', leader, instruction),
    string.format("%s", leader),
    string.format("%s   [DTL AGENT POLICY]", leader),
    string.format("%s   allow:     [%s]", leader, rel_path),
    string.format("%s   forbid:    [.env*, *.pem, *.key]", leader),
    string.format('%s   always:    review: "Existing repository code and interfaces preserved"', leader),
    string.format("%s   repair:    on_violation -> (auto_revert, mark:REVISE)", leader),
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
          { tostring(t.task_id), "Directory" },
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
      { tostring(best.task_id), "Directory" },
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

  -- Compute exact multi-line span of THIS single task comment block via native C++ LuaJIT FFI engine
  -- (strictly prevents merging distinct adjacent TODO headers like line 1 + line 2!)
  local cur_slug = raw_header:match("%(([a-zA-Z0-9_%-]+)")
  local anchor_mod = require("agent.anchor")
  local span = anchor_mod.find_task_block_span(lines, chosen_line, cur_slug)
  old_lines_count = math.max(1, span.line_count or 1)

  for j = chosen_line + 1, math.min(#lines, chosen_line + old_lines_count - 1) do
    local l = vim.trim(lines[j])
    local is_dup_task = cur_slug and l:find(cur_slug, 1, true) and (l:find("TODO%(") or l:find("SPEC%(") or l:find("CONTRACT%(") or l:find("FIXME%("))
    if not is_dup_task and l ~= "" then
      local cleaned = l:gsub("^[#/%-]+%s*", "")
      if cleaned ~= "" then
        chosen_desc = chosen_desc .. " " .. cleaned
      end
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
    context_end = math.min(total_lines, chosen_line + old_lines_count + 60)
  end
  for idx = context_start, context_end do
    table.insert(numbered_lines, string.format("%d: %s", idx, lines[idx]))
  end
  local code_section = table.concat(numbered_lines, "\n")

  -- Collect file symbol map & tail context so the model can see where functions,
  -- dispatchers, and autocompletions live even in large files (e.g. >2,000 lines)
  local structure_outline = ""
  if total_lines > 120 then
    local sym_lines = {}
    for idx = 1, total_lines do
      local l = lines[idx]
      if l:match("^%s*function%s+") or l:match("^%s*local%s+function%s+")
        or l:match("^%s*def%s+") or l:match("^%s*async%s+def%s+")
        or l:match("^%s*class%s+") or l:match("^%s*pub%s+fn%s+")
        or l:match("^%s*fn%s+") or l:match("^%s*pub%s+struct%s+")
        or l:match("^%s*struct%s+")
      then
        table.insert(sym_lines, string.format("  line %d: %s", idx, vim.trim(l)))
      end
    end
    local tail_start = math.max(context_end + 1, total_lines - 110)
    local tail_numbered = {}
    if tail_start <= total_lines then
      for idx = tail_start, total_lines do
        table.insert(tail_numbered, string.format("%d: %s", idx, lines[idx]))
      end
    end
    local parts_ctx = {}
    if #sym_lines > 0 then
      table.insert(parts_ctx, "FILE SYMBOL & FUNCTION INDEX (" .. rel_path .. "):\n" .. table.concat(sym_lines, "\n"))
    end
    if #tail_numbered > 0 then
      table.insert(parts_ctx, string.format("FILE TAIL / DISPATCHER CONTEXT (lines %d to %d of %d):\n%s",
        tail_start, total_lines, total_lines, table.concat(tail_numbered, "\n")))
    end
    if #parts_ctx > 0 then
      structure_outline = "\n\n" .. table.concat(parts_ctx, "\n\n")
    end
  end

  -- Scan for in-line revision critique comments within the target function/block
  local critiques = {}
  local scan_end = math.min(#lines, chosen_line + old_lines_count + 40)
  for k = chosen_line + 1, scan_end do
    local l = vim.trim(lines[k])
    if k >= chosen_line + old_lines_count and l:match("^[#/%-]+%s*[A-Z]+%(") then
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

  -- Resolve task contract details (allow list, etc.) before building prompt
  local active_task_id = cur_slug or (raw_header and raw_header:match("%(([a-zA-Z0-9_%-]+)")) or "task"
  local dtl_task_spec = {
    id = active_task_id,
    allow = {},
    forbid = {},
  }
  local all_tasks_pre = M.scan_repository_tasks()
  for _, t in ipairs(all_tasks_pre) do
    if t.task_id and t.task_id ~= "task" and active_task_id ~= "task" and t.task_id:lower() == active_task_id:lower() then
      dtl_task_spec.allow = t.allow or {}
      dtl_task_spec.forbid = t.forbid or {}
      break
    end
  end
  local allow_hint = (#dtl_task_spec.allow > 0) and ("\nALLOWED FILES POLICY: [" .. table.concat(dtl_task_spec.allow, ", ") .. "]") or ""

  local prompt = string.format([[You are an expert autonomous software engineer implementing an in-tree task in %s.
You MAY use read-only tools (such as `read_file` or `grep`) if you need to inspect other lines of `%s` or related modules in the repository before generating the implementation.
HOWEVER, do NOT modify any files on disk using write/edit tools and do NOT run destructive bash commands — our review engine will apply your returned JSON patch into an interactive in-buffer diff preview for human approval.

TARGET FILE: %s
TASK: %s
DESCRIPTION: %s
TASK COMMENT LOCATION: line %d (spans %d line(s), lines %d to %d)%s%s

SURROUNDING SOURCE CODE AROUND TASK (with 1-based line numbers):
%s%s

RULES:
1. Provide the complete, working, production-quality code implementation for this task (never just replace a comment with another comment!).
2. If the task comment is placed directly where the implementation belongs, replace it (`start_line`: %d, `old_lines_count`: %d).
3. If the task comment is at the top of the file (e.g. line 1) or requires adding functions/subcommand handlers elsewhere in `%s` (for example in the command dispatcher or completion function at the bottom of the file), either:
   - Use `start_line` and `old_lines_count` to target the exact lines in `%s` where the code should be inserted/updated, OR
   - Return an `"edits"` array of hunks (ordered top-to-bottom), where the first hunk updates the task header status to `status:DONE` and subsequent hunks insert/update the functions and command dispatchers at their proper line numbers!
4. Maintain existing indentation, variable names, type signatures, and module patterns (`M.<fn>`).
5. Do NOT include placeholder comments or ellipsis; write the full, verified implementation.
6. Output STRICT JSON ONLY matching one of these schemas:
Single-region schema:
{
  "start_line": %d,
  "old_lines_count": %d,
  "content": "<exact replacement code lines without line number prefixes>",
  "description": "<one-line summary of what was implemented>"
}
Or multi-region schema (when updating task header at line %d AND adding/updating functions elsewhere in the file):
{
  "start_line": %d,
  "old_lines_count": %d,
  "content": "<primary implementation code>",
  "description": "<one-line summary of what was implemented>",
  "edits": [
    {
      "start_line": %d,
      "old_lines_count": %d,
      "content": "<updated task comment with status:DONE>"
    },
    {
      "start_line": <target_line_for_implementation>,
      "old_lines_count": <lines_replaced_at_target>,
      "content": "<complete implementation and dispatcher wiring>"
    }
  ]
}
Emit ONLY raw JSON. No markdown code blocks, no prose before or after.
]], rel_path, rel_path, rel_path, raw_header, chosen_desc, chosen_line, old_lines_count, chosen_line, chosen_line + old_lines_count - 1,
    allow_hint, critique_section, code_section, structure_outline,
    chosen_line, old_lines_count, rel_path, rel_path,
    chosen_line, old_lines_count, chosen_line, chosen_line, old_lines_count, chosen_line, old_lines_count)

  local agy_bin = vim.fn.exepath("agy")
  local opencode_bin = vim.fn.exepath("opencode")
  local cmd = {}

  if agy_bin ~= "" then
    cmd = { agy_bin, "-p", prompt, "--output-format", "json", "--dangerously-skip-permissions", "--disable-slash-commands" }
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
  job_timeout:start(90000, 0, vim.schedule_wrap(function()
    if state.active_job then
      vim.notify("Agent: Task execution timed out after 90s. Cancelled.", vim.log.levels.WARN)
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

    if not solution or (not solution.content and not (solution.edits and #solution.edits > 0)) then
      vim.notify("Agent: Could not parse implementation for task", vim.log.levels.WARN)
      return
    end

    local function normalize_content_str(c)
      if type(c) == "table" then
        local first = c[1]
        if type(first) == "table" then
          local parts = {}
          for _, sub in ipairs(c) do
            if type(sub) == "table" then
              table.insert(parts, table.concat(sub, ""))
            else
              table.insert(parts, tostring(sub))
            end
          end
          return table.concat(parts, "\n")
        else
          return table.concat(c, "\n")
        end
      elseif type(c) ~= "string" then
        return tostring(c or "")
      end
      return c
    end

    local total = vim.api.nvim_buf_line_count(bufnr)
    local buf_all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local start_lnum, old_cnt, new_content, new_lines, orig_slice

    if type(solution.edits) == "table" and #solution.edits > 0 then
      -- Sort edits by start_line ascending and coalesce into a single encompassing slice or apply bottom-up
      local edits = vim.deepcopy(solution.edits)
      table.sort(edits, function(a, b)
        return (tonumber(a.start_line) or 1) < (tonumber(b.start_line) or 1)
      end)
      if #edits == 1 then
        local e = edits[1]
        start_lnum = tonumber(e.start_line) or chosen_line
        old_cnt = tonumber(e.old_lines_count) or old_lines_count
        new_content = normalize_content_str(e.content)
        new_lines = vim.split(new_content or "", "\n")
        local s_idx = math.max(0, start_lnum - 1)
        local e_idx = math.min(total, s_idx + old_cnt)
        orig_slice = vim.api.nvim_buf_get_lines(bufnr, s_idx, e_idx, false)
        if start_lnum == chosen_line then
          new_lines = diff_mod.ensure_contract_preserved_as_done(orig_slice, new_lines)
          new_content = table.concat(new_lines, "\n")
        end
      else
        -- Apply multiple hunks to a copy of the buffer lines (bottom-to-top to preserve line indices)
        local working = vim.deepcopy(buf_all_lines)
        local min_start = total
        local max_orig_end = 1
        for i = #edits, 1, -1 do
          local e = edits[i]
          local eline = math.max(1, math.min(#working + 1, tonumber(e.start_line) or chosen_line))
          local ecnt = math.max(0, tonumber(e.old_lines_count) or 0)
          local e_new = vim.split(normalize_content_str(e.content), "\n")
          if eline == chosen_line and ecnt > 0 then
            local orig_sub = {}
            for k = eline, math.min(#working, eline + ecnt - 1) do
              table.insert(orig_sub, working[k])
            end
            e_new = diff_mod.ensure_contract_preserved_as_done(orig_sub, e_new)
          end
          if eline < min_start then min_start = eline end
          if eline + ecnt - 1 > max_orig_end then max_orig_end = eline + ecnt - 1 end

          local updated = {}
          for k = 1, eline - 1 do updated[#updated + 1] = working[k] end
          for _, nl in ipairs(e_new) do updated[#updated + 1] = nl end
          for k = eline + ecnt, #working do updated[#updated + 1] = working[k] end
          working = updated
        end
        -- Focus review on the primary implementation hunk (last edit if first was just status header at line 1)
        local primary_edit = edits[#edits]
        if #edits == 2 and (tonumber(edits[1].start_line) or 1) == chosen_line and (tonumber(edits[2].start_line) or 1) - chosen_line > 80 then
          -- Update the task header in buffer to DONE and focus the inline diff on the implementation hunk
          local h_line = chosen_line
          local h_cnt = tonumber(edits[1].old_lines_count) or old_lines_count
          local h_orig = vim.api.nvim_buf_get_lines(bufnr, h_line - 1, math.min(total, h_line - 1 + h_cnt), false)
          local h_new = diff_mod.ensure_contract_preserved_as_done(h_orig, vim.split(normalize_content_str(edits[1].content), "\n"))
          vim.bo[bufnr].modifiable = true
          vim.api.nvim_buf_set_lines(bufnr, h_line - 1, math.min(total, h_line - 1 + h_cnt), false, h_new)
          local delta = #h_new - #h_orig
          total = vim.api.nvim_buf_line_count(bufnr)
          start_lnum = math.max(1, (tonumber(primary_edit.start_line) or chosen_line) + delta)
          old_cnt = math.max(0, tonumber(primary_edit.old_lines_count) or 0)
          new_content = normalize_content_str(primary_edit.content)
          new_lines = vim.split(new_content or "", "\n")
          local s_idx = math.max(0, start_lnum - 1)
          local e_idx = math.min(total, s_idx + old_cnt)
          orig_slice = vim.api.nvim_buf_get_lines(bufnr, s_idx, e_idx, false)
        else
          start_lnum = min_start
          old_cnt = math.max(1, max_orig_end - min_start + 1)
          local s_idx = math.max(0, start_lnum - 1)
          local e_idx = math.min(total, s_idx + old_cnt)
          orig_slice = vim.api.nvim_buf_get_lines(bufnr, s_idx, e_idx, false)
          local new_end = #working - (total - e_idx)
          new_lines = {}
          for k = start_lnum, math.max(start_lnum - 1, new_end) do
            table.insert(new_lines, working[k])
          end
          new_content = table.concat(new_lines, "\n")
        end
      end
    else
      start_lnum = tonumber(solution.start_line) or chosen_line
      old_cnt = tonumber(solution.old_lines_count) or old_lines_count
      new_content = normalize_content_str(solution.content)
      new_lines = vim.split(new_content or "", "\n")

      -- Extract original lines before modification
      local s_idx = math.max(0, start_lnum - 1)
      local e_idx = math.min(total, s_idx + old_cnt)
      orig_slice = vim.api.nvim_buf_get_lines(bufnr, s_idx, e_idx, false)

      if start_lnum == chosen_line then
        new_lines = diff_mod.ensure_contract_preserved_as_done(orig_slice, new_lines)
        new_content = table.concat(new_lines, "\n")
      end
    end

    local s_idx = math.max(0, start_lnum - 1)
    local e_idx = math.min(vim.api.nvim_buf_line_count(bufnr), s_idx + old_cnt)

    -- ── Layer 2: DTL Trajectory Validation ──
    local dtl_mod = require("agent.dtl")
    local dtl_ok, dtl_err, ctd_action = dtl_mod.validate_patch(dtl_task_spec, filepath, new_content)
    if not dtl_ok then
      vim.notify(string.format("⚠ [DTL TRAJECTORY VIOLATION]: %s\nExecuting CTD Action: %s", dtl_err, ctd_action or "auto_revert"), vim.log.levels.ERROR)
      state.is_busy = false
      return
    end

    -- Supersede any prior unreviewed implementation review for the same task & file
    local existing_unrev = rev_mod.get_reviews("unreviewed")
    for _, old_r in ipairs(existing_unrev) do
      if not old_r.is_task_stub then
        local old_slug = rev_mod.review_slug and rev_mod.review_slug(old_r) or old_r.task_id
        if old_slug and active_task_id ~= "task" and old_slug:lower() == active_task_id:lower() and old_r.abs_file == vim.fn.fnamemodify(filepath, ":p") then
          old_r.status = "superseded"
          rev_mod.save_review_meta(old_r)
        end
      end
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

--- Determine the optimal contextual line index (0-based for nvim_buf_set_lines)
--- to place a task stub, avoiding corruption of shebangs, headers, and docstrings,
--- and placing above target symbols when mentioned in the action.
--- @param bufnr integer
--- @param full_path string
--- @param action string
--- @param clean_slug string
--- @param requested_line integer|nil (1-based line hint, default nil)
--- @return integer insert_idx (0-based)
--- @return string indent
function M.find_optimal_insertion_line(bufnr, full_path, action, clean_slug, requested_line)
  local total_lines = (bufnr and vim.api.nvim_buf_is_valid(bufnr)) and vim.api.nvim_buf_line_count(bufnr) or 0
  if total_lines == 0 then
    return 0, ""
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines == 0 or (#lines == 1 and lines[1] == "") then
    return 0, ""
  end

  local ext = vim.fn.fnamemodify(full_path or "", ":e"):lower()

  -- Step 1: Detect shebang at line 1
  local min_line_idx = 0
  if lines[1] and lines[1]:match("^#!") then
    min_line_idx = 1 -- at least line 2 (0-based index 1)
  end

  -- Step 2: Detect file-level docstrings, encoding, pragmas, or frontmatter
  if ext == "py" then
    local cur = min_line_idx + 1
    while cur <= #lines and (lines[cur]:match("^#.*coding") or lines[cur]:match("^%s*$")) do
      cur = cur + 1
    end
    if cur <= #lines then
      local is_triple_double = lines[cur]:match('^%s*"""')
      local is_triple_single = lines[cur]:match("^%s*'''")
      local quote = is_triple_double and '"""' or (is_triple_single and "'''" or nil)
      if quote then
        if lines[cur]:match('^%s*' .. quote .. '.-' .. quote .. '%s*$') and #lines[cur] > 6 then
          min_line_idx = cur
        else
          cur = cur + 1
          while cur <= #lines do
            if lines[cur]:find(quote, 1, true) then
              min_line_idx = cur
              break
            end
            cur = cur + 1
          end
        end
      end
    end
  elseif ext == "rs" then
    local cur = min_line_idx + 1
    while cur <= #lines and (lines[cur]:match("^%s*//!") or lines[cur]:match("^%s*#!%[") or lines[cur]:match("^%s*$")) do
      min_line_idx = cur
      cur = cur + 1
    end
  elseif ext == "c" or ext == "cpp" or ext == "h" or ext == "hpp" then
    local cur = min_line_idx + 1
    if cur <= #lines and lines[cur]:match("^%s*#pragma%s+once") then
      min_line_idx = cur
    end
    if cur <= #lines and lines[cur]:match("^%s*/%*") then
      while cur <= #lines do
        if lines[cur]:match("%*/") then
          min_line_idx = cur
          break
        end
        cur = cur + 1
      end
    end
  elseif ext == "md" or ext == "markdown" then
    if lines[1] and lines[1]:match("^%-%-%-%s*$") then
      for i = 2, #lines do
        if lines[i]:match("^%-%-%-%s*$") then
          min_line_idx = i
          break
        end
      end
    end
  end

  -- If user requested an explicit line > 1 (or 0 for clamping)
  local user_req = tonumber(requested_line)
  if user_req ~= nil then
    if user_req == 0 then
      return min_line_idx, ""
    end
    if user_req > 1 then
      local target_idx = math.min(#lines, math.max(min_line_idx, user_req - 1))
      local indent = ""
      if target_idx < #lines then
        indent = lines[target_idx + 1]:match("^(%s*)") or ""
      elseif #lines > 0 then
        indent = lines[#lines]:match("^(%s*)") or ""
      end
      return target_idx, indent
    end
  end

  -- Step 3: Target symbol extraction from action and clean_slug
  local target_symbol = nil
  local candidates = {}
  local full_text = (action or "") .. " " .. (clean_slug or "")
  for word in full_text:gmatch("[%a_][%w_]+") do
    local w_low = word:lower()
    local is_stop = (w_low == "the" or w_low == "and" or w_low == "for" or w_low == "with" or
                     w_low == "implement" or w_low == "add" or w_low == "create" or w_low == "update" or
                     w_low == "fix" or w_low == "test" or w_low == "should" or w_low == "return" or
                     w_low == "function" or w_low == "class" or w_low == "method" or w_low == "contract" or
                     w_low == "policy" or w_low == "task" or w_low == "tier" or w_low == "status" or
                     w_low == "none" or w_low == "true" or w_low == "false" or #word < 3)
    if not is_stop then
      table.insert(candidates, word)
    end
  end

  for _, sym in ipairs(candidates) do
    local sym_pats = {
      "^%s*def%s+" .. sym .. "%s*%(",
      "^%s*async%s+def%s+" .. sym .. "%s*%(",
      "^%s*class%s+" .. sym .. "[%s%(:]",
      "^%s*pub%s+class%s+" .. sym .. "[%s%(:]",
      "^%s*function%s+" .. sym .. "%s*%(",
      "^%s*function%s+[%w_]+%." .. sym .. "%s*%(",
      "^%s*local%s+function%s+" .. sym .. "%s*%(",
      "^%s*fn%s+" .. sym .. "[%s<%(]",
      "^%s*pub%s+fn%s+" .. sym .. "[%s<%(]",
      "^%s*pub%s+async%s+fn%s+" .. sym .. "[%s<%(]",
      "^%s*async%s+fn%s+" .. sym .. "[%s<%(]",
      "^%s*struct%s+" .. sym .. "[%s<{]",
      "^%s*pub%s+struct%s+" .. sym .. "[%s<{]",
      "^%s*enum%s+" .. sym .. "[%s<{]",
      "^%s*pub%s+enum%s+" .. sym .. "[%s<{]",
      "^%s*type%s+" .. sym .. "[%s=<{]",
      "^%s*pub%s+type%s+" .. sym .. "[%s=<{]",
    }
    for l_i, l_str in ipairs(lines) do
      if l_i > min_line_idx then
        for _, pat in ipairs(sym_pats) do
          if l_str:match(pat) then
            target_symbol = { line = l_i, text = l_str }
            break
          end
        end
        if target_symbol then break end
      end
    end
    if target_symbol then break end
  end

  if target_symbol then
    local sym_line = target_symbol.line
    local insert_pos = sym_line - 1
    while insert_pos > min_line_idx do
      local prev_line = lines[insert_pos]
      if prev_line:match("^%s*@") or prev_line:match("^%s*#%[") then
        insert_pos = insert_pos - 1
      else
        break
      end
    end
    local indent = target_symbol.text:match("^(%s*)") or ""
    return insert_pos, indent
  end

  -- Step 4: Language-specific insertion heuristics
  if ext == "py" then
    local last_import_line = min_line_idx
    local in_imports = false
    for i = min_line_idx + 1, math.min(#lines, 60) do
      local l = lines[i]
      if l:match("^%s*import%s+") or l:match("^%s*from%s+[%w_.]+%s+import") then
        last_import_line = i
        in_imports = true
      elseif in_imports and l:match("^%s*$") then
        -- blank line within imports
      elseif in_imports and not (l:match("^%s*#") or l:match("^%s*import") or l:match("^%s*from")) then
        break
      end
    end
    return math.max(min_line_idx, last_import_line), ""
  elseif ext == "lua" then
    local last_req_line = min_line_idx
    for i = min_line_idx + 1, math.min(#lines, 50) do
      local l = lines[i]
      if l:match("^%s*local%s+[%w_]+%s*=%s*require") or l:match("^%s*local%s+M%s*=%s*{}") then
        last_req_line = i
      end
    end
    return math.max(min_line_idx, last_req_line), ""
  elseif ext == "rs" then
    local last_use_line = min_line_idx
    for i = min_line_idx + 1, math.min(#lines, 60) do
      local l = lines[i]
      if l:match("^%s*use%s+") or l:match("^%s*pub%s+use%s+") or l:match("^%s*mod%s+") then
        last_use_line = i
      end
    end
    return math.max(min_line_idx, last_use_line), ""
  elseif ext == "c" or ext == "cpp" or ext == "h" or ext == "hpp" then
    local last_inc_line = min_line_idx
    for i = min_line_idx + 1, math.min(#lines, 60) do
      local l = lines[i]
      if l:match("^%s*#include") or l:match("^%s*#define") then
        last_inc_line = i
      end
    end
    return math.max(min_line_idx, last_inc_line), ""
  elseif ext == "yml" or ext == "yaml" then
    for i = 1, #lines do
      if lines[i]:match("^%s*steps:%s*$") then
        local base_indent = lines[i]:match("^(%s*)") or ""
        local step_indent = base_indent .. "      "
        return i, step_indent
      end
    end
    return #lines, ""
  end

  local fallback_idx = math.max(min_line_idx, 0)
  local indent = ""
  if fallback_idx < #lines then
    indent = lines[fallback_idx + 1]:match("^(%s*)") or ""
  end
  return fallback_idx, indent
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

  local base_slug = clean_desc:lower():gsub("[^%a0-9%s_-]", ""):gsub("%s+", "-"):sub(1, 48):gsub("%-+$", "")
  if base_slug == "" then base_slug = "task" end

  local all_tasks = M.scan_repository_tasks()
  local existing_slugs = {}
  for _, t in ipairs(all_tasks) do
    local s = (t.task_id or ""):match("%(([%w_%-]+)") or (t.task_id or ""):match("%[([%w_%-]+)") or t.task_id
    if s and s ~= "" then existing_slugs[s:lower()] = true end
  end

  local anchor_mod = require("agent.anchor")
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local slug = base_slug
  local counter = 2
  while existing_slugs[slug:lower()] or anchor_mod.find_task_line(buf_lines, slug, 1) do
    slug = base_slug .. "-" .. counter
    counter = counter + 1
  end

  local insert_idx, indent = M.find_optimal_insertion_line(bufnr, full_path, clean_desc, slug, line_arg)
  if is_empty then
    insert_idx = 0
    indent = ""
  end

  local header = string.format("%s%s TODO(%s | status:TODO): %s", indent, leader, slug, clean_desc)
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

    local anchor_mod = require("agent.anchor")
    local bufnr_pre = vim.fn.bufnr(full_path)
    local pre_lines = (bufnr_pre ~= -1 and vim.api.nvim_buf_is_loaded(bufnr_pre)) and vim.api.nvim_buf_get_lines(bufnr_pre, 0, -1, false) or nil

    local slug = base_slug
    local counter = 2
    while seen_slugs[slug:lower()] or existing_slug_map[slug:lower()] or (pre_lines and anchor_mod.find_task_line(pre_lines, slug, 1)) do
      slug = base_slug .. "-" .. counter
      counter = counter + 1
    end
    seen_slugs[slug:lower()] = true

    -- Normalize requires / depends_on if LLM gave string instead of table
    local dep_list = {}
    local raw_reqs = part.requires or part.depends_on
    if type(raw_reqs) == "table" then
      dep_list = raw_reqs
    elseif type(raw_reqs) == "string" and vim.trim(raw_reqs) ~= "" then
      dep_list = { vim.trim(raw_reqs) }
    end

    local is_new_file = (vim.fn.filereadable(full_path) ~= 1)
    vim.fn.mkdir(vim.fn.fnamemodify(full_path, ":h"), "p")
    local bufnr = vim.fn.bufadd(full_path)
    vim.fn.bufload(bufnr)
    local total_lines = vim.api.nvim_buf_line_count(bufnr)
    local is_empty = (total_lines <= 1 and (vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or "") == "")

    local req_line = nil
    if part.line and tonumber(part.line) and tonumber(part.line) > 1 then
      req_line = tonumber(part.line)
    end

    local insert_idx, indent = M.find_optimal_insertion_line(bufnr, full_path, clean_action, slug, req_line)
    local offset = file_line_offsets[full_path] or 0
    if offset > 0 then
      insert_idx = math.min(vim.api.nvim_buf_line_count(bufnr), insert_idx + offset)
    end
    if is_empty then
      insert_idx = 0
      indent = ""
    end

    local header = string.format("%s%s CONTRACT(%s):", indent, leader, slug)

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
   - "requires": array of prerequisite task_id strings (Hoare preconditions). Foundational tasks have [].
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
      "requires": [],
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
          requires = {},
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

-- CONTRACT(image-viewer-zoom-pan):
--   [HOARE CODE CONTRACT]
--   requires:  []
--   test:      tests/test_image_viewer_suite.lua
--   action:    Define tests first (tests/test_image_viewer_suite.lua), then implement a native Neovim image viewer buffer with LuaJIT FFI libpng sub-rectangle cropping and Kitty graphics protocol rendering (+/= and - to zoom in/out, h/j/k/l to pan, 0 to reset view) for inspecting rendered .png/.svg architectural diagrams directly inside Neovim splits.
--   ensures:   review: "Tests in tests/test_image_viewer_suite.lua pass and image buffers render and support interactive zoom and pan in Neovim"
--
--   [DTL AGENT POLICY]
--   allow:     [c_src/image_engine.h, c_src/image_engine.cpp, Makefile, nvim/lua/agent/image.lua, nvim/lua/agent/init.lua, nvim/lua/agent/tasks.lua, tests/test_image_viewer_suite.lua]
--   forbid:    [.env*, *.pem, *.key]
--   always:    review: "Existing buffer autocmds, terminal splits, and SmartQuit workflows remain unbroken"
--   repair:    on_violation -> (auto_revert, mark:REVISE)
function M.add_task(arg_str, win)
  win = win or ui.get_primary_editor_win()
  arg_str = vim.trim(arg_str or "")
  if arg_str == "" then
    M.open_architecture_review(function()
      M.open_task_form(win)
    end, { win = win })
    return
  end

  local raw_trimmed = arg_str
  arg_str = arg_str:gsub('^["\']', ''):gsub('["\']$', '')
  local file_arg, line_arg, desc_arg = arg_str:match("^([^%s:]+):(%d+)%s+(.*)$")
  if file_arg and line_arg and desc_arg then
    M.insert_single_task_stub(file_arg, tonumber(line_arg), desc_arg, win)
    return
  end

  -- Check if input is a structured task form (contains CONTRACT/action:/requires:/ensures: or ---blocks)
  if raw_trimmed:find("^[%s]*#") or raw_trimmed:find("CONTRACT%(") or raw_trimmed:find("%[HOARE") or raw_trimmed:find("[Aa]ction%s*:") or raw_trimmed:find("[Tt]ask_id%s*:") or raw_trimmed:find("\n%-%-%-") then
    M.process_task_form_submission(raw_trimmed, win)
    return
  end

  M.decompose_and_add_tasks(arg_str, win)
end

--- Default multi-task form template in the canonical Two-Layer Architecture
--- (Layer 1: Hoare Code Contract & Layer 2: DTL Agent Policy)
function M.get_task_form_template(prefill_action, default_allow, default_test)
  local act = prefill_action or ""
  local alw = default_allow or ""
  local tst = default_test or ""
  return table.concat({
    "# ── Two-Layer Task Contract Form (<C-n>: +Task | <C-l>: LLM Fill | <C-s>/<CR>: Place) ──",
    "CONTRACT():",
    "  [HOARE CODE CONTRACT]",
    "  requires:  []",
    "  test:      " .. tst,
    "  action:    " .. act,
    "  ensures:   ",
    "",
    "  [DTL AGENT POLICY]",
    "  allow:     [" .. alw .. "]",
    "  forbid:    [.env*, *.pem, *.key]",
    "  always:    ",
    "  repair:    on_violation -> (auto_revert, mark:REVISE)",
  }, "\n")
end

--- Parse a multi-task form text into an array of raw task spec tables
function M.parse_task_form(text)
  if not text or vim.trim(text) == "" then return {} end

  -- Split on horizontal rule `---` lines or repeated `CONTRACT(...)` headers into discrete task blocks
  local blocks = {}
  local cur_lines = {}
  local seen_header_in_cur = false
  for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local is_rule = line:match("^%s*%-%-%-+%s*$") ~= nil
    local is_header = line:match("^%s*(CONTRACT|SPEC|TODO)%([^)]*%)%s*:?") ~= nil
    if is_rule or (is_header and seen_header_in_cur) then
      if #cur_lines > 0 then
        table.insert(blocks, table.concat(cur_lines, "\n"))
        cur_lines = {}
        seen_header_in_cur = false
      end
      if is_header then
        table.insert(cur_lines, line)
        seen_header_in_cur = true
      end
    else
      if not line:match("^%s*#") then
        if is_header then seen_header_in_cur = true end
        table.insert(cur_lines, line)
      end
    end
  end
  if #cur_lines > 0 then
    table.insert(blocks, table.concat(cur_lines, "\n"))
  end

  local function parse_list_field(val)
    if not val or val == "" then return {} end
    local inner = val:match("^%[(.*)%]$") or val
    local out = {}
    for item in inner:gmatch("[^,%s%[%]]+") do
      local t = vim.trim(item)
      if t ~= "" then table.insert(out, t) end
    end
    return out
  end

  local tasks_out = {}
  for _, blk in ipairs(blocks) do
    local t = {
      task_id = "",
      file = "",
      line = nil,
      action = "",
      requires = {},
      depends_on = {},
      blocks = {},
      ensures = "",
      allow = {},
      forbid = {},
      always = "",
      repair = "",
    }
    local freeform_lines = {}
    local has_key = false

    for line in blk:gmatch("[^\r\n]+") do
      local trimmed = vim.trim(line)
      -- Skip section markers like [HOARE CODE CONTRACT] and [DTL AGENT POLICY]
      if trimmed:match("^%[HOARE") or trimmed:match("^%[DTL") then
        has_key = true
      else
        local hdr_kind, hdr_inside, hdr_after = trimmed:match("^(%a+)%(([^)]*)%)%s*:?%s*(.*)$")
        if hdr_kind and (hdr_kind == "CONTRACT" or hdr_kind == "SPEC" or hdr_kind == "TODO" or hdr_kind == "FIXME") then
          has_key = true
          local clean_id = vim.trim(vim.split(hdr_inside, "%s*|%s*")[1] or "")
          if clean_id ~= "" then t.task_id = clean_id end
          if hdr_after and vim.trim(hdr_after) ~= "" and t.action == "" then
            t.action = vim.trim(hdr_after)
          end
        else
          local k, v = line:match("^%s*([%w_%-]+)%s*:%s*(.*)$")
          local kl = k and k:lower() or nil
          if kl and (kl == "task_id" or kl == "id" or kl == "slug" or kl == "file" or kl == "line" or kl == "test"
            or kl == "action" or kl == "description" or kl == "desc" or kl == "requires" or kl == "depends_on"
            or kl == "blocks" or kl == "ensures" or kl == "criteria" or kl == "allow" or kl == "modifies"
            or kl == "forbid" or kl == "deny" or kl == "always" or kl == "invariant" or kl == "repair" or kl == "ctd")
          then
            has_key = true
            v = vim.trim(v or "")
            if kl == "task_id" or kl == "id" or kl == "slug" then
              t.task_id = v
            elseif kl == "file" then
              t.file = v
            elseif kl == "line" then
              t.line = tonumber(v)
            elseif kl == "test" then
              t.test = v:gsub('^"?', ''):gsub('"?$', '')
            elseif kl == "action" or kl == "description" or kl == "desc" then
              t.action = v
            elseif kl == "requires" or kl == "depends_on" then
              t.requires = parse_list_field(v)
              t.depends_on = t.requires
            elseif kl == "blocks" then
              t.blocks = parse_list_field(v)
            elseif kl == "ensures" or kl == "criteria" then
              local emb_t, rest_e = v:match('^test:%s*"?([^"|%s]+)"?%s*|%s*(.*)$')
              if emb_t then
                t.test = emb_t
                t.ensures = rest_e:gsub('^review:%s*"?', ''):gsub('"?$', '')
              else
                t.ensures = v:gsub('^review:%s*"?', ''):gsub('"?$', '')
              end
            elseif kl == "allow" or kl == "modifies" then
              t.allow = parse_list_field(v)
            elseif kl == "forbid" or kl == "deny" then
              t.forbid = parse_list_field(v)
            elseif kl == "always" or kl == "invariant" then
              t.always = v:gsub('^review:%s*"?', ''):gsub('"?$', '')
            elseif kl == "repair" or kl == "ctd" then
              t.repair = v
            end
          elseif trimmed ~= "" then
            local bullet = line:match("^%s*[0-9]+[%.)]%s*(.*)$") or line:match("^%s*[-*]%s*(.*)$")
            if bullet and not has_key then
              table.insert(tasks_out, { action = vim.trim(bullet), requires = {}, depends_on = {}, blocks = {}, allow = {}, forbid = {} })
            else
              table.insert(freeform_lines, trimmed)
            end
          end
        end
      end
    end

    if has_key then
      if t.action == "" and #freeform_lines > 0 then
        t.action = table.concat(freeform_lines, " ")
      end
      -- Include if at least action or task_id or ensures was filled
      if t.action ~= "" or t.task_id ~= "" or t.ensures ~= "" then
        table.insert(tasks_out, t)
      end
    elseif #freeform_lines > 0 then
      table.insert(tasks_out, {
        action = table.concat(freeform_lines, " "),
        requires = {},
        depends_on = {},
        blocks = {},
        allow = {},
        forbid = {},
      })
    end
  end

  return tasks_out
end

--- Clean up and fill missing fields in parsed task specs (deterministically or with optional LLM enrichment)
function M.finalize_task_specs(raw_specs, default_rel_file, existing_tasks)
  existing_tasks = existing_tasks or M.scan_repository_tasks()
  local used_slugs = {}
  for _, et in ipairs(existing_tasks) do
    local s = (et.task_id or ""):match("%(([%w_%-]+)") or (et.task_id or ""):match("%[([%w_%-]+)") or et.task_id
    if s and s ~= "" then used_slugs[s:lower()] = true end
  end

  local finalized = {}
  for idx, raw in ipairs(raw_specs) do
    local action = vim.trim(raw.action or raw.description or raw.task_id or ("Task " .. idx)):gsub("[\r\n]+", " ")
    local base_slug = vim.trim(raw.task_id or ""):lower():gsub("[^%a0-9%s_-]", ""):gsub("%s+", "-"):sub(1, 48):gsub("%-+$", "")
    if base_slug == "" then
      base_slug = action:lower():gsub("[^%a0-9%s_-]", ""):gsub("%s+", "-"):sub(1, 48):gsub("%-+$", "")
    end
    if base_slug == "" then base_slug = "task-" .. idx end

    local slug = base_slug
    local counter = 2
    while used_slugs[slug:lower()] do
      slug = base_slug .. "-" .. counter
      counter = counter + 1
    end
    used_slugs[slug:lower()] = true

    local reqs = (type(raw.requires) == "table" and #raw.requires > 0) and raw.requires
      or ((type(raw.depends_on) == "table" and #raw.depends_on > 0) and raw.depends_on or {})
    local blks = (type(raw.blocks) == "table") and raw.blocks or {}

    local ensures = vim.trim(raw.ensures or "")
    if ensures == "" then
      ensures = action .. " implementation verified"
    end
    ensures = ensures:gsub('^review:%s*"?', ''):gsub('"?$', '')

    local allow = (type(raw.allow) == "table" and #raw.allow > 0) and vim.deepcopy(raw.allow) or {}
    if #allow == 0 and default_rel_file and default_rel_file ~= "" then
      table.insert(allow, default_rel_file)
    end

    local test_path = vim.trim(raw.test or "")
    if test_path == "" then
      -- Extract test path if mentioned in action/ensures/allow, else generate canonical test suite path
      test_path = action:match("(tests/[%w_%-%.%/]+)") or ensures:match("(tests/[%w_%-%.%/]+)") or ""
      if test_path == "" then
        for _, a in ipairs(allow) do
          if a:match("^tests/") then
            test_path = a
            break
          end
        end
      end
      if test_path == "" then
        test_path = "tests/test_" .. slug:gsub("%-", "_") .. "_suite.lua"
      end
    end
    if test_path ~= "" and not vim.tbl_contains(allow, test_path) then
      table.insert(allow, test_path)
    end

    local forbid = (type(raw.forbid) == "table" and #raw.forbid > 0) and vim.deepcopy(raw.forbid)
      or { ".env*", "*.pem", "*.key" }

    local always = vim.trim(raw.always or "")
    if always == "" then
      always = "Existing repository code and interfaces preserved"
    end
    always = always:gsub('^review:%s*"?', ''):gsub('"?$', '')

    local repair = vim.trim(raw.repair or "")
    if repair == "" then
      repair = "on_violation -> (auto_revert, mark:REVISE)"
    end

    table.insert(finalized, {
      task_id = slug,
      file = (raw.file and raw.file ~= "") and raw.file or nil,
      line = tonumber(raw.line),
      test = test_path,
      action = action,
      requires = reqs,
      depends_on = reqs,
      blocks = blks,
      ensures = ensures,
      allow = allow,
      forbid = forbid,
      always = always,
      repair = repair,
    })
  end

  -- Auto-wire sequential Hoare `requires` preconditions if user created multiple tasks without explicit requires
  if #finalized > 1 then
    local any_explicit = false
    for _, f in ipairs(finalized) do
      if #f.requires > 0 or #f.blocks > 0 then any_explicit = true; break end
    end
    if not any_explicit then
      for i = 1, #finalized do
        if i > 1 then
          table.insert(finalized[i].requires, finalized[i - 1].task_id)
          finalized[i].depends_on = finalized[i].requires
        end
        if i < #finalized then
          table.insert(finalized[i].blocks, finalized[i + 1].task_id)
        end
      end
    end
  end

  return finalized
end

--- Validate that a task specification has a defined test-first target
function M.validate_task_has_test(spec)
  return type(spec) == "table" and type(spec.test) == "string" and vim.trim(spec.test) ~= ""
end

--- Render a finalized task spec table into Two-Layer Architecture comment lines for a given file & indentation
function M.format_task_stub_lines(spec, filepath, indent)
  indent = indent or ""
  local root = ui.get_root_dir()
  local rel_file = filepath or spec.file or "TODO.md"
  if rel_file:sub(1, #root) == root then
    rel_file = rel_file:sub(#root + 2)
  else
    rel_file = vim.fn.fnamemodify(rel_file, ":.")
  end
  local leader = get_comment_leader(rel_file)

  local allow_list = vim.deepcopy(spec.allow or {})
  if #allow_list == 0 and rel_file ~= "" then
    table.insert(allow_list, rel_file)
  elseif rel_file ~= "" and not vim.tbl_contains(allow_list, rel_file) then
    table.insert(allow_list, 1, rel_file)
  end

  local forbid_list = (spec.forbid and #spec.forbid > 0) and spec.forbid or { ".env*", "*.pem", "*.key" }
  local req_list = spec.requires or spec.depends_on or {}

  local header = string.format("%s%s CONTRACT(%s):", indent, leader, spec.task_id or "task")
  local ensures_str = spec.ensures or ((spec.action or "Task") .. " verified")
  local ensures_line
  if spec.test and vim.trim(spec.test) ~= "" then
    ensures_line = string.format("%s%s   ensures:   test: \"%s\" | review: \"%s\"", indent, leader, vim.trim(spec.test), ensures_str)
  else
    ensures_line = string.format("%s%s   ensures:   review: \"%s\"", indent, leader, ensures_str)
  end

  return {
    header,
    string.format("%s%s   [HOARE CODE CONTRACT]", indent, leader),
    string.format("%s%s   requires:  [%s]", indent, leader, table.concat(req_list, ", ")),
    string.format("%s%s   action:    %s", indent, leader, spec.action or ""),
    ensures_line,
    string.format("%s%s", indent, leader),
    string.format("%s%s   [DTL AGENT POLICY]", indent, leader),
    string.format("%s%s   allow:     [%s]", indent, leader, table.concat(allow_list, ", ")),
    string.format("%s%s   forbid:    [%s]", indent, leader, table.concat(forbid_list, ", ")),
    string.format("%s%s   always:    review: \"%s\"", indent, leader, spec.always or "Existing repository code and interfaces preserved"),
    string.format("%s%s   repair:    %s", indent, leader, spec.repair or "on_violation -> (auto_revert, mark:REVISE)"),
  }
end

--- Format finalized task specs back into the Two-Layer Architecture form representation
function M.format_specs_as_form(specs)
  local lines = {
    "# ── Two-Layer Task Contract Form (<C-n>: +Task | <C-l>: LLM Fill | <C-s>/<CR>: Place) ──",
  }
  for idx, s in ipairs(specs) do
    if idx > 1 then
      table.insert(lines, "---")
    end
    table.insert(lines, string.format("CONTRACT(%s):", s.task_id or ""))
    table.insert(lines, "  [HOARE CODE CONTRACT]")
    table.insert(lines, "  requires:  [" .. table.concat(s.requires or {}, ", ") .. "]")
    table.insert(lines, "  test:      " .. (s.test or ""))
    table.insert(lines, "  action:    " .. (s.action or ""))
    table.insert(lines, string.format('  ensures:   review: "%s"', s.ensures or ""))
    table.insert(lines, "")
    table.insert(lines, "  [DTL AGENT POLICY]")
    table.insert(lines, "  allow:     [" .. table.concat(s.allow or {}, ", ") .. "]")
    table.insert(lines, "  forbid:    [" .. table.concat(s.forbid or { ".env*", "*.pem", "*.key" }, ", ") .. "]")
    table.insert(lines, string.format('  always:    review: "%s"', s.always or ""))
    table.insert(lines, "  repair:    " .. (s.repair or "on_violation -> (auto_revert, mark:REVISE)"))
  end
  return lines
end

--- Open the interactive task template form in a docked split
function M.open_task_form(win, prefill_action)
  win = win or ui.get_primary_editor_win()
  local cur_buf = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win)
  local rel_file = ""
  if cur_buf and vim.bo[cur_buf].buftype == "" then
    local name = vim.api.nvim_buf_get_name(cur_buf)
    if name ~= "" then
      rel_file = vim.fn.fnamemodify(name, ":.")
    end
  end

  local template = M.get_task_form_template(prefill_action, rel_file)
  local form_win, form_buf = ui.open_docked_input(
    "Tasks Add: Two-Layer Contract Form",
    template,
    function(submitted_text)
      M.process_task_form_submission(submitted_text, win)
    end,
    {
      height = 13,
      filetype = "yaml",
      statusline = " ● TASK CONTRACT FORM %=[<C-n>: +Task | <C-l>: Auto-Fill Blanks | <C-s>/<CR>: Place at Cursor | <Esc>/q: Cancel] ",
      start_insert = false,
      on_setup = function(fwin, fbuf)
        -- Position cursor right on the `  action:    ` line (line 5, col 13)
        pcall(vim.api.nvim_win_set_cursor, fwin, { 5, 13 })
        local function append_new_task_block()
          local block = {
            "---",
            "CONTRACT():",
            "  [HOARE CODE CONTRACT]",
            "  requires:  []",
            "  action:    ",
            "  ensures:   ",
            "",
            "  [DTL AGENT POLICY]",
            "  allow:     [" .. rel_file .. "]",
            "  forbid:    [.env*, *.pem, *.key]",
            "  always:    ",
            "  repair:    on_violation -> (auto_revert, mark:REVISE)",
          }
          local cnt = vim.api.nvim_buf_line_count(fbuf)
          vim.api.nvim_buf_set_lines(fbuf, cnt, cnt, false, block)
          if vim.api.nvim_win_is_valid(fwin) then
            pcall(vim.api.nvim_win_set_cursor, fwin, { cnt + 5, 13 })
          end
        end
        local function autofill_blanks_in_form()
          if not vim.api.nvim_buf_is_valid(fbuf) then return end
          local cur_lines = vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)
          local raw_specs = M.parse_task_form(table.concat(cur_lines, "\n"))
          if #raw_specs == 0 then
            vim.notify("Tasks Form: Fill at least 'action:' first before auto-filling.", vim.log.levels.WARN)
            return
          end
          local filled = M.finalize_task_specs(raw_specs, rel_file)
          vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, M.format_specs_as_form(filled))

          -- If LLM CLI is available, also offer async LLM polish of ensures/always/slug
          local agy_bin = vim.fn.exepath("agy")
          local opencode_bin = vim.fn.exepath("opencode")
          if agy_bin ~= "" or opencode_bin ~= "" then
            vim.notify("● [Tasks Form] Blanks filled! Refining Two-Layer Contract fields with LLM...", vim.log.levels.INFO)
            local prompt = string.format([[You are a task specification assistant for a Two-Layer Architecture (Layer 1: Hoare Code Contract, Layer 2: DTL Agent Policy). Clean up and fill any blank fields in the following %d task specification(s) and return strict JSON immediately. Do NOT call any tools.
INPUT SPECS:
%s

Output STRICT JSON matching:
{
  "tasks": [
    {
      "task_id": "concise-kebab-slug",
      "requires": [],
      "action": "Polished action description",
      "ensures": "Verifiable postcondition",
      "allow": ["%s"],
      "forbid": [".env*", "*.pem", "*.key"],
      "always": "Safety invariant",
      "repair": "on_violation -> (auto_revert, mark:REVISE)"
    }
  ]
}]], #filled, vim.fn.json_encode(raw_specs), rel_file)
            local cmd = (agy_bin ~= "")
              and { agy_bin, "-p", prompt, "--output-format", "json", "--dangerously-skip-permissions", "--disable-slash-commands" }
              or { opencode_bin, "run", "--format", "json", prompt }
            local stdout_chunks = {}
            vim.system(cmd, { text = true, stdout = function(_, d) if d then table.insert(stdout_chunks, d) end end }, vim.schedule_wrap(function()
              if not vim.api.nvim_buf_is_valid(fbuf) then return end
              local llm_mod = require("agent.llm")
              local parsed = llm_mod.extract_json_object(table.concat(stdout_chunks, ""))
              if parsed and type(parsed.tasks) == "table" and #parsed.tasks > 0 then
                local refined = M.finalize_task_specs(parsed.tasks, rel_file)
                vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, M.format_specs_as_form(refined))
                vim.notify("✓ [Tasks Form] LLM contract refinement complete. Press <CR> or <C-s> to place!", vim.log.levels.INFO)
              end
            end))
          else
            vim.notify("✓ [Tasks Form] Auto-filled blank fields! Press <CR> or <C-s> to place at cursor.", vim.log.levels.INFO)
          end
        end
        pcall(vim.keymap.set, { "n", "i" }, "<C-n>", append_new_task_block, {
          buffer = fbuf,
          silent = true,
          nowait = true,
          desc = "Append another task template block to form",
        })
        pcall(vim.keymap.set, { "n", "i" }, "<C-l>", autofill_blanks_in_form, {
          buffer = fbuf,
          silent = true,
          nowait = true,
          desc = "Auto-fill and clean up blank fields in task form",
        })
      end,
    }
  )
  return form_win, form_buf
end

-- ==============================================================================
-- Iterative PlantUML Architectural Model Review on Task Creation
-- Opens docs/architecture/*.puml alongside the rendered .png diagram in a split,
-- allowing live iteration on the PlantUML text with instant FFI image refresh
-- until the human indicates satisfaction (<C-s> / <M-a>) to proceed to placement.
-- ==============================================================================

local function discover_puml_files(root)
  root = root or ui.get_root_dir()
  local arch_dir = root .. "/docs/architecture"
  local found = vim.fn.glob(arch_dir .. "/*.puml", false, true)
  if type(found) == "table" and #found > 0 then
    table.sort(found)
    return found
  end
  vim.fn.mkdir(arch_dir, "p")
  local default_puml = arch_dir .. "/architecture.puml"
  if vim.fn.filereadable(default_puml) ~= 1 then
    vim.fn.writefile({
      "@startuml architecture",
      "title Architecture Model",
      "@enduml",
    }, default_puml)
  end
  return { default_puml }
end

local function corresponding_png_for_puml(puml_path)
  return (puml_path:gsub("%.puml$", ".png"))
end

function M.rerender_architecture_model(opts)
  opts = opts or {}
  local session = state_mod.state.arch_review
  if not session or not session.active then return false end

  local puml_path = session.current_puml
  if not puml_path or puml_path == "" then return false end

  if session.puml_buf and vim.api.nvim_buf_is_valid(session.puml_buf) and vim.bo[session.puml_buf].modified then
    pcall(vim.api.nvim_buf_call, session.puml_buf, function() vim.cmd("silent! write") end)
  end

  local root = ui.get_root_dir()
  local gen_script = root .. "/docs/architecture/generate_diagrams.sh"
  local png_path = corresponding_png_for_puml(puml_path)
  local image_mod = require("agent.image")

  session.render_count = (session.render_count or 0) + 1

  if opts.sync then
    -- If plantuml binary exists locally, run generate_diagrams.sh -f png; otherwise refresh existing PNG
    if vim.fn.executable("plantuml") == 1 and vim.fn.filereadable(gen_script) == 1 then
      vim.fn.system({ gen_script, "-f", "png", "-e", "local", puml_path })
    end
    if session.img_buf and vim.api.nvim_buf_is_valid(session.img_buf) and vim.fn.filereadable(png_path) == 1 then
      image_mod.refresh(session.img_buf)
    end
    return true
  end

  if vim.fn.filereadable(gen_script) == 1 and (vim.fn.executable("plantuml") == 1 or vim.fn.executable("curl") == 1) then
    vim.system({ gen_script, "-f", "png", puml_path }, { text = true }, vim.schedule_wrap(function()
      if session.active and session.img_buf and vim.api.nvim_buf_is_valid(session.img_buf) and vim.fn.filereadable(png_path) == 1 then
        image_mod.refresh(session.img_buf)
        vim.notify("✓ [Arch Review] Re-rendered " .. vim.fn.fnamemodify(png_path, ":t"), vim.log.levels.INFO)
      end
    end))
  elseif session.img_buf and vim.api.nvim_buf_is_valid(session.img_buf) and vim.fn.filereadable(png_path) == 1 then
    image_mod.refresh(session.img_buf)
  end
  return true
end

function M.cycle_architecture_model(delta)
  local session = state_mod.state.arch_review
  if not session or not session.active or not session.puml_files or #session.puml_files == 0 then
    return nil
  end
  delta = tonumber(delta) or 1
  session.index = ((session.index - 1 + delta) % #session.puml_files) + 1
  local next_puml = session.puml_files[session.index]
  session.current_puml = next_puml

  local puml_buf = vim.fn.bufadd(next_puml)
  vim.fn.bufload(puml_buf)
  session.puml_buf = puml_buf
  if session.puml_win and vim.api.nvim_win_is_valid(session.puml_win) then
    vim.api.nvim_win_set_buf(session.puml_win, puml_buf)
  end
  M.setup_arch_review_buf_keymaps(puml_buf)

  local png_path = corresponding_png_for_puml(next_puml)
  session.current_png = png_path
  if session.img_buf and vim.api.nvim_buf_is_valid(session.img_buf) and vim.fn.filereadable(png_path) == 1 then
    require("agent.image").open_image_buffer(session.img_buf, png_path, session.img_win)
  end
  return session
end

function M.confirm_architecture_review()
  local session = state_mod.state.arch_review
  if not session or not session.active then return false end
  session.active = false

  if session.puml_buf and vim.api.nvim_buf_is_valid(session.puml_buf) and vim.bo[session.puml_buf].modified then
    pcall(vim.api.nvim_buf_call, session.puml_buf, function() vim.cmd("silent! write") end)
  end

  if session.img_buf and vim.api.nvim_buf_is_valid(session.img_buf) then
    pcall(require("agent.image").clear, session.img_buf)
  end
  if session.img_win and vim.api.nvim_win_is_valid(session.img_win) and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    pcall(vim.api.nvim_win_close, session.img_win, true)
  end

  local cb = session.on_satisfied
  state_mod.state.arch_review = nil
  if type(cb) == "function" then
    cb()
  end
  return true
end

function M.cancel_architecture_review()
  local session = state_mod.state.arch_review
  if not session or not session.active then return false end
  session.active = false
  if session.img_buf and vim.api.nvim_buf_is_valid(session.img_buf) then
    pcall(require("agent.image").clear, session.img_buf)
  end
  if session.img_win and vim.api.nvim_win_is_valid(session.img_win) and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    pcall(vim.api.nvim_win_close, session.img_win, true)
  end
  state_mod.state.arch_review = nil
  vim.notify("● [Tasks] Cancelled architectural model review.", vim.log.levels.INFO)
  return true
end

function M.setup_arch_review_buf_keymaps(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local kopts = { buffer = bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "<C-s>", function() M.confirm_architecture_review() end,
    vim.tbl_extend("force", kopts, { desc = "Confirm architectural model satisfaction & proceed to task placement" }))
  vim.keymap.set("n", "<M-a>", function() M.confirm_architecture_review() end,
    vim.tbl_extend("force", kopts, { desc = "Confirm architectural model satisfaction & proceed to task placement" }))
  vim.keymap.set("n", "<C-r>", function() M.rerender_architecture_model() end,
    vim.tbl_extend("force", kopts, { desc = "Re-render PlantUML diagram image" }))
  vim.keymap.set("n", "<Tab>", function() M.cycle_architecture_model(1) end,
    vim.tbl_extend("force", kopts, { desc = "Cycle to next architectural .puml model" }))
  vim.keymap.set("n", "<M-q>", function() M.cancel_architecture_review() end,
    vim.tbl_extend("force", kopts, { desc = "Cancel architectural model review" }))

  local group = vim.api.nvim_create_augroup("SynvimArchReview_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = bufnr,
    callback = function()
      M.rerender_architecture_model()
    end,
    desc = "Auto re-render PlantUML diagram image on save",
  })
end

function M.open_architecture_review(on_satisfied_cb, opts)
  opts = opts or {}
  local root = opts.root or ui.get_root_dir()
  local puml_files = discover_puml_files(root)
  local first_puml = puml_files[1]
  local first_png = corresponding_png_for_puml(first_puml)

  local puml_win = opts.win or ui.get_primary_editor_win() or vim.api.nvim_get_current_win()
  local puml_buf = vim.fn.bufadd(first_puml)
  vim.fn.bufload(puml_buf)
  if vim.api.nvim_win_is_valid(puml_win) then
    vim.api.nvim_win_set_buf(puml_win, puml_buf)
    vim.api.nvim_set_current_win(puml_win)
  end

  vim.cmd("vsplit")
  local img_win = vim.api.nvim_get_current_win()
  local img_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(img_win, img_buf)

  local image_mod = require("agent.image")
  if vim.fn.filereadable(first_png) == 1 then
    image_mod.open_image_buffer(img_buf, first_png, img_win)
  end
  M.setup_arch_review_buf_keymaps(puml_buf)
  M.setup_arch_review_buf_keymaps(img_buf)

  if vim.api.nvim_win_is_valid(puml_win) then
    vim.api.nvim_set_current_win(puml_win)
  end

  local session = {
    active = true,
    puml_files = puml_files,
    index = 1,
    current_puml = first_puml,
    current_png = first_png,
    puml_buf = puml_buf,
    puml_win = puml_win,
    img_buf = img_buf,
    img_win = img_win,
    render_count = 0,
    on_satisfied = on_satisfied_cb,
  }
  state_mod.state.arch_review = session

  vim.notify(
    "● [Arch Review] Iterate on .puml model (<C-r>/save to re-render, <Tab> switch model, +/-/h/j/k/l zoom image). Press <C-s> or <M-a> when satisfied!",
    vim.log.levels.INFO
  )
  return session
end

--- Process submitted task form: auto-fill blanks (instant + optional LLM cleanup if needed) and enter Interactive Placement Mode
-- CONTRACT(puml-arch-review-on-task-add):
--   [HOARE CODE CONTRACT]
--   requires:  [image-viewer-zoom-pan]
--   test:      tests/e2e_puml_task_review_suite.lua
--   action:    Define tests first (tests/e2e_puml_task_review_suite.lua), then update the task creation workflow (:Tasks add) to prompt the user to review and iterate on docs/architecture/*.puml models alongside the live-rendered diagram image in a split (re-rendering via docs/architecture/generate_diagrams.sh on edit/save) until the user confirms satisfaction via a dedicated keybinding to proceed to code placement.
--   ensures:   review: "Tests in tests/e2e_puml_task_review_suite.lua pass and creating a task opens the iterative PlantUML text + rendered image review loop before placement"
--
--   [DTL AGENT POLICY]
--   allow:     [nvim/lua/agent/tasks.lua, nvim/lua/agent/ui.lua, docs/architecture/generate_diagrams.sh, tests/e2e_puml_task_review_suite.lua]
--   forbid:    [.env*, *.pem, *.key]
--   always:    review: "Existing non-interactive and headless :Tasks add flows remain backwards-compatible"
--   repair:    on_violation -> (auto_revert, mark:REVISE)
function M.process_task_form_submission(raw_text, win, use_llm)
  local raw_specs = M.parse_task_form(raw_text)
  if #raw_specs == 0 then
    vim.notify("Tasks: Form was empty (fill at least 'action:' to create a task).", vim.log.levels.INFO)
    return {}
  end

  win = win or ui.get_primary_editor_win()
  local cur_buf = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win)
  local rel_file = ""
  if cur_buf and vim.bo[cur_buf].buftype == "" then
    local name = vim.api.nvim_buf_get_name(cur_buf)
    if name ~= "" then rel_file = vim.fn.fnamemodify(name, ":.") end
  end

  local needs_llm = false
  if use_llm then
    for _, s in ipairs(raw_specs) do
      if (not s.task_id or s.task_id == "") or (not s.ensures or s.ensures == "") or (not s.always or s.always == "") then
        needs_llm = true
        break
      end
    end
  end

  local finalized = M.finalize_task_specs(raw_specs, rel_file)

  if not needs_llm then
    M.start_placement_mode(finalized, win)
    return finalized
  end

  -- Optional async LLM cleanup if explicitly requested
  local agy_bin = vim.fn.exepath("agy")
  local opencode_bin = vim.fn.exepath("opencode")
  if agy_bin == "" and opencode_bin == "" then
    M.start_placement_mode(finalized, win)
    return finalized
  end

  local prompt = string.format([[You are a task specification assistant for a Two-Layer Architecture (Layer 1: Hoare Code Contract, Layer 2: DTL Agent Policy). Clean up and fill any blank fields in the following %d task specification(s) and return strict JSON immediately. Do NOT call any tools.
INPUT SPECS:
%s

Output STRICT JSON matching:
{
  "tasks": [
    {
      "task_id": "concise-kebab-slug",
      "requires": [],
      "action": "Polished action description",
      "ensures": "Verifiable postcondition",
      "allow": ["%s"],
      "forbid": [".env*", "*.pem", "*.key"],
      "always": "Safety invariant",
      "repair": "on_violation -> (auto_revert, mark:REVISE)"
    }
  ]
}]], #finalized, vim.fn.json_encode(raw_specs), rel_file)

  local cmd = (agy_bin ~= "")
    and { agy_bin, "-p", prompt, "--output-format", "json", "--dangerously-skip-permissions", "--disable-slash-commands" }
    or { opencode_bin, "run", "--format", "json", prompt }

  local stdout_chunks = {}
  vim.system(cmd, { text = true, stdout = function(_, d) if d then table.insert(stdout_chunks, d) end end }, vim.schedule_wrap(function()
    local llm_mod = require("agent.llm")
    local parsed = llm_mod.extract_json_object(table.concat(stdout_chunks, ""))
    if parsed and type(parsed.tasks) == "table" and #parsed.tasks > 0 then
      finalized = M.finalize_task_specs(parsed.tasks, rel_file)
    end
    M.start_placement_mode(finalized, win)
  end))
  return finalized
end

-- ==============================================================================
-- Interactive Task Placement & Reposition Mode
-- Allows the human to navigate across any buffer/file (:History, :Find, splits)
-- with a live virtual-lines preview floating above the cursor, and drop/place
-- each queued task stub at the exact cursor line!
-- ==============================================================================

function M.clear_placement_preview()
  local ns = state_mod.ns_placement
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_is_loaded(b) then
      pcall(vim.api.nvim_buf_clear_namespace, b, ns, 0, -1)
    end
  end
end

function M.render_placement_preview()
  local state = state_mod.state
  M.clear_placement_preview()
  if not state.placement_active or not state.placement_queue or #state.placement_queue == 0 then
    return
  end

  local idx = state.placement_index or 1
  local cur_spec = state.placement_queue[idx]
  if not cur_spec then return end

  local win = vim.api.nvim_get_current_win()
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local buf = vim.api.nvim_win_get_buf(win)
  if not buf or not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return
  end

  local filepath = vim.api.nvim_buf_get_name(buf)
  local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
  local total_lines = vim.api.nvim_buf_line_count(buf)
  local line_text = vim.api.nvim_buf_get_lines(buf, math.max(0, cursor_line - 1), cursor_line, false)[1] or ""
  local indent = line_text:match("^(%s*)") or ""

  local stub_lines = M.format_task_stub_lines(cur_spec, filepath, indent)
  local virt_lines = {}
  local badge = string.format(
    "%s── ● [PLACEMENT MODE %d/%d] '%s' — [<M-p> / :Tasks drop] Place Here | [<M-f>] :Find Target | [<M-s>] Split Task | [<M-n>/<M-b>] Next/Prev | [<M-q>] Cancel ──",
    indent, idx, #state.placement_queue, cur_spec.task_id or "task"
  )
  table.insert(virt_lines, { { badge, "Title" } })
  for _, sl in ipairs(stub_lines) do
    table.insert(virt_lines, { { sl, "AgentDiffAdd" } })
  end

  local mark_row = math.max(0, math.min(total_lines - 1, cursor_line - 1))
  pcall(vim.api.nvim_buf_set_extmark, buf, state_mod.ns_placement, mark_row, 0, {
    virt_lines = virt_lines,
    virt_lines_above = true,
    priority = 300,
  })
end

function M.stop_placement_mode(silent)
  local state = state_mod.state
  state.placement_active = false
  state.placement_queue = {}
  state.placement_index = 1
  M.clear_placement_preview()
  if state.placement_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.placement_augroup)
    state.placement_augroup = nil
  end
  pcall(vim.keymap.del, "n", "<M-p>")
  pcall(vim.keymap.del, "n", "<M-f>")
  pcall(vim.keymap.del, "n", "<M-s>")
  pcall(vim.keymap.del, "n", "<M-n>")
  pcall(vim.keymap.del, "n", "<M-b>")
  pcall(vim.keymap.del, "n", "<M-q>")
  if not silent then
    vim.notify("● [Tasks] Exited task placement mode.", vim.log.levels.INFO)
  end
end

--- Split the currently active queued task in Placement Mode:
--- In interactive mode (<M-s> at Location A), opens the Two-Layer Contract Form to carve off
--- a sub-task for Location A, drops that sub-task right at Location A on submit, and keeps
--- the remaining task (wired with Hoare `requires: [<carved-id>]`) on the cursor for Location B!
function M.split_current_placement_task(sub_specs_or_actions, opts)
  opts = opts or {}
  local state = state_mod.state
  if not state.placement_active or not state.placement_queue or #state.placement_queue == 0 then
    vim.notify("Tasks: No active task in placement mode to split.", vim.log.levels.WARN)
    return {}
  end

  local idx = state.placement_index or 1
  local cur = state.placement_queue[idx]
  if not cur then return {} end

  -- If sub_specs_or_actions is passed programmatically, replace current task in-place
  -- and optionally drop the first carved sub-task right at the target location (opts.drop_first)
  if type(sub_specs_or_actions) == "table" and #sub_specs_or_actions > 0 then
    local raw_list = {}
    for i, item in ipairs(sub_specs_or_actions) do
      if type(item) == "string" then
        table.insert(raw_list, {
          task_id = string.format("%s-part-%d", cur.task_id or "task", i),
          action = item,
          allow = vim.deepcopy(cur.allow or {}),
          forbid = vim.deepcopy(cur.forbid or { ".env*", "*.pem", "*.key" }),
          always = cur.always,
          repair = cur.repair,
        })
      elseif type(item) == "table" then
        table.insert(raw_list, item)
      end
    end
    local finalized = M.finalize_task_specs(raw_list, cur.file or "", {})
    table.remove(state.placement_queue, idx)
    for i = #finalized, 1, -1 do
      table.insert(state.placement_queue, idx, finalized[i])
    end
    state.placement_index = idx

    if opts.drop_first then
      M.drop_current_task_at_cursor(opts.target_buf, opts.target_line)
    else
      M.render_placement_preview()
    end
    return finalized
  end

  -- Interactive "Carve & Drop Here" (<M-s> at Location A):
  local win = (type(opts) == "number" and opts) or opts.win or ui.get_primary_editor_win()
  local anchor_buf = (win and vim.api.nvim_win_is_valid(win)) and vim.api.nvim_win_get_buf(win) or vim.api.nvim_get_current_buf()
  local anchor_line = (win and vim.api.nvim_win_is_valid(win)) and vim.api.nvim_win_get_cursor(win)[1] or 1
  local rel_loc_file = ""
  if anchor_buf and vim.api.nvim_buf_is_valid(anchor_buf) and vim.bo[anchor_buf].buftype == "" then
    local bname = vim.api.nvim_buf_get_name(anchor_buf)
    if bname ~= "" then
      rel_loc_file = vim.fn.fnamemodify(bname, ":.")
    end
  end

  local carved = vim.deepcopy(cur)
  carved.task_id = (cur.task_id or "task") .. "-part-1"
  carved.test = "tests/test_" .. carved.task_id:gsub("%-", "_") .. "_suite.lua"
  carved.allow = (rel_loc_file ~= "") and { rel_loc_file, carved.test } or { carved.test }

  local remainder = vim.deepcopy(cur)
  remainder.requires = { carved.task_id }
  remainder.depends_on = { carved.task_id }

  local form_lines = {
    string.format("# ── Carve & Drop Sub-Task at %s:%d (Block 1 drops HERE; Block 2+ stays on cursor for next location) ──",
      rel_loc_file ~= "" and rel_loc_file or "[buffer]", anchor_line),
  }
  local spec_lines = M.format_specs_as_form({ carved, remainder })
  for i = 2, #spec_lines do
    table.insert(form_lines, spec_lines[i])
  end

  ui.open_docked_input(
    "Carve Sub-Task Here & Carry Remainder",
    table.concat(form_lines, "\n"),
    function(submitted_text)
      local parsed = M.parse_task_form(submitted_text)
      if #parsed > 0 then
        M.split_current_placement_task(parsed, {
          drop_first = (#parsed >= 2),
          target_buf = anchor_buf,
          target_line = anchor_line,
          win = win,
        })
      end
    end,
    { height = 16, filetype = "yaml", start_insert = false }
  )
  return { carved, remainder }
end

--- Carve off `carved_spec` and drop it immediately at `(target_buf, target_line)` (Location A),
--- while keeping `remaining_spec` (wired with Hoare `requires: [<carved_id>]`) active on the cursor for Location B.
function M.carve_and_drop_at_cursor(carved_spec, remaining_spec, target_buf, target_line)
  return M.split_current_placement_task({ carved_spec, remaining_spec }, {
    drop_first = true,
    target_buf = target_buf,
    target_line = target_line,
  })
end

--- Drop the currently active queued task at the human's cursor (or explicit target_buf, target_line)
function M.drop_current_task_at_cursor(target_buf, target_line)
  local state = state_mod.state
  if not state.placement_active or not state.placement_queue or #state.placement_queue == 0 then
    vim.notify("Tasks: No tasks queued in placement mode. Run :Tasks add to create tasks.", vim.log.levels.WARN)
    return nil
  end

  local idx = state.placement_index or 1
  local spec = state.placement_queue[idx]
  if not spec then return nil end

  local win = ui.get_primary_editor_win()
  local bufnr = target_buf or (win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win)) or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    vim.notify("Tasks: Navigate to an editable file buffer before dropping the task.", vim.log.levels.WARN)
    return nil
  end

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then
    local root = ui.get_root_dir()
    filepath = root .. "/" .. (spec.file or "TODO.md")
    vim.api.nvim_buf_set_name(bufnr, filepath)
  end

  local is_new_file = (vim.fn.filereadable(filepath) ~= 1)
  vim.fn.mkdir(vim.fn.fnamemodify(filepath, ":h"), "p")

  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  local first_line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
  local is_empty = (total_lines <= 1 and first_line == "")

  local lnum = target_line
  if not lnum then
    if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      lnum = vim.api.nvim_win_get_cursor(win)[1]
    else
      lnum = 1
    end
  end
  lnum = math.max(1, math.min(total_lines, lnum))

  -- Protect shebang at line 1 if user drops on line 1 of a script
  local insert_idx = lnum - 1
  if insert_idx == 0 and first_line:match("^#!") then
    insert_idx = 1
  end
  if is_empty then
    insert_idx = 0
  end

  local ref_line = vim.api.nvim_buf_get_lines(bufnr, insert_idx, insert_idx + 1, false)[1] or ""
  local indent = is_empty and "" or (ref_line:match("^(%s*)") or "")

  local stub_lines = M.format_task_stub_lines(spec, filepath, indent)

  M.clear_placement_preview()
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, insert_idx, is_empty and 1 or insert_idx, false, stub_lines)
  pcall(vim.api.nvim_buf_call, bufnr, function() vim.cmd("silent! write!") end)

  local rev_mod = require("agent.reviews")
  local rev = rev_mod.create_review(filepath, insert_idx + 1, 0, {}, stub_lines, spec.task_id, spec.action, "unreviewed", idx, true)
  if rev then
    rev.is_new_file = is_new_file
    rev_mod.save_review_meta(rev)
  end

  -- Move cursor right below or onto the placed task stub
  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
    pcall(vim.api.nvim_win_set_cursor, win, { insert_idx + 1, 0 })
  end

  -- Remove placed task from queue and advance to next task if any remain
  table.remove(state.placement_queue, idx)
  if #state.placement_queue == 0 then
    M.stop_placement_mode(true)
    vim.notify(string.format("✓ [Tasks] Placed '%s' at %s:%d! All queued tasks placed.", spec.task_id, vim.fn.fnamemodify(filepath, ":."), insert_idx + 1), vim.log.levels.INFO)
  else
    if state.placement_index > #state.placement_queue then
      state.placement_index = 1
    end
    local next_spec = state.placement_queue[state.placement_index]
    M.render_placement_preview()
    vim.notify(string.format("✓ [Tasks] Placed '%s' at %s:%d. Next up (%d remaining): '%s' — navigate and press <M-p> (or :Tasks drop) to place.",
      spec.task_id, vim.fn.fnamemodify(filepath, ":."), insert_idx + 1, #state.placement_queue, next_spec.task_id), vim.log.levels.INFO)
  end

  return rev
end

--- Pick up an existing in-tree task (under cursor or by task_id/index), remove it from its old spot,
--- and enter Interactive Placement Mode so the human can move/drop it anywhere!
function M.move_task(task_arg)
  task_arg = vim.trim(task_arg or "")
  local root = ui.get_root_dir()
  local win = ui.get_primary_editor_win()
  local target_buf = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) or vim.api.nvim_get_current_buf()
  local target_line = nil
  local matched_rec = nil

  if task_arg ~= "" then
    matched_rec = M.resolve_task_record(task_arg)
    if not matched_rec then
      vim.notify("Tasks: Task '" .. task_arg .. "' not found to move.", vim.log.levels.WARN)
      return false
    end
    local full_path = (matched_rec.file:sub(1, 1) == "/") and matched_rec.file or (root .. "/" .. matched_rec.file)
    if vim.fn.filereadable(full_path) ~= 1 then
      vim.notify("Tasks: File not found: " .. matched_rec.file, vim.log.levels.WARN)
      return false
    end
    target_buf = vim.fn.bufadd(full_path)
    vim.fn.bufload(target_buf)
    local blines = vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)
    target_line = require("agent.anchor").find_task_line(blines, matched_rec.task_id, matched_rec.line) or matched_rec.line
  else
    local lnum = (win and vim.api.nvim_win_is_valid(win)) and vim.api.nvim_win_get_cursor(win)[1] or 1
    local blines = vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)
    for i = lnum, 1, -1 do
      if M.is_todo_comment(blines[i]) then
        target_line = i
        break
      end
    end
    if not target_line then
      for i = lnum, #blines do
        if M.is_todo_comment(blines[i]) then
          target_line = i
          break
        end
      end
    end
  end

  if not target_line then
    vim.notify("Tasks: No task found at cursor to move. Specify :Tasks move <id>", vim.log.levels.WARN)
    return false
  end

  local blines = vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)
  local header = blines[target_line]
  local t_info = M.extract_task_info(header)
  local slug = (t_info and t_info.id) or (matched_rec and matched_rec.task_id) or "task"

  local anchor_mod = require("agent.anchor")
  local span = anchor_mod.find_task_block_span(blines, target_line, slug)
  local line_count = math.max(1, span.line_count or 1)

  -- Extract contract fields before removing lines
  local spec = {
    task_id = slug,
    action = (matched_rec and matched_rec.description) or (t_info and t_info.desc) or slug,
    requires = (matched_rec and matched_rec.requires) or (t_info and t_info.requires) or {},
    depends_on = (matched_rec and matched_rec.depends_on) or (t_info and t_info.depends_on) or {},
    blocks = (matched_rec and matched_rec.blocks) or (t_info and t_info.blocks) or {},
    ensures = (matched_rec and matched_rec.ensures) or (t_info and t_info.ensures) or "",
    allow = (matched_rec and matched_rec.allow) or (t_info and t_info.allow) or {},
    forbid = (matched_rec and matched_rec.forbid) or (t_info and t_info.forbid) or { ".env*", "*.pem", "*.key" },
    always = (matched_rec and matched_rec.always) or (t_info and t_info.always) or "",
    repair = (matched_rec and matched_rec.repair) or (t_info and t_info.repair) or "on_violation -> (auto_revert, mark:REVISE)",
  }

  for j = target_line + 1, math.min(#blines, target_line + line_count - 1) do
    local cleaned = blines[j]:match("^[ \t]*[#/%-%*%\"]+%s*(.*)$") or ""
    local act = cleaned:match("^[Aa]ction:%s*(.*)$")
    if act and act ~= "" then spec.action = vim.trim(act) end
    local ens = cleaned:match("^[Ee]nsures:%s*(.*)$")
    if ens and ens ~= "" then spec.ensures = vim.trim(ens):gsub('^review:%s*"?', ''):gsub('"?$', '') end
    local alw_inv = cleaned:match("^[Aa]lways:%s*(.*)$")
    if alw_inv and alw_inv ~= "" then spec.always = vim.trim(alw_inv):gsub('^review:%s*"?', ''):gsub('"?$', '') end
    local rep = cleaned:match("^[Rr]epair:%s*(.*)$")
    if rep and rep ~= "" then spec.repair = vim.trim(rep) end
  end

  -- Remove old task block from buffer & save
  vim.bo[target_buf].modifiable = true
  vim.api.nvim_buf_set_lines(target_buf, target_line - 1, target_line - 1 + line_count, false, {})
  pcall(vim.api.nvim_buf_call, target_buf, function() vim.cmd("silent! write!") end)

  -- Enter placement mode with this picked-up task!
  M.start_placement_mode({ spec }, win)
  return true
end

--- Start Interactive Placement Mode for one or more finalized task specs
-- CONTRACT(task-placement-split-and-test-first-gate):
--   [HOARE CODE CONTRACT]
--   requires:  [puml-arch-review-on-task-add]
--   test:      tests/test_task_split_and_tdd_gate_suite.lua
--   action:    Define tests first (tests/test_task_split_and_tdd_gate_suite.lua), then enhance Interactive Placement Mode so that after architectural model approval the user is prompted to anchor/link each task to a specific line of code; provide an in-placement split/decompose keybinding for tasks that do not fit a single code location, and enforce a test-first gate requiring every task contract to specify or stub its target test before execution.
--   ensures:   review: "Tests in tests/test_task_split_and_tdd_gate_suite.lua pass, tasks can be split interactively when a single anchor line is ambiguous, and every finalized task contract defines its test expectation first"
--
--   [DTL AGENT POLICY]
--   allow:     [nvim/lua/agent/tasks.lua, nvim/lua/agent/anchor.lua, tests/test_task_split_and_tdd_gate_suite.lua]
--   forbid:    [.env*, *.pem, *.key]
--   always:    review: "Existing placement mode keybindings (<M-p>, <M-n>, <M-b>, <M-q>) and task scanning remain functional"
--   repair:    on_violation -> (auto_revert, mark:REVISE)
function M.start_placement_mode(specs, win)
  if not specs or #specs == 0 then return end
  local state = state_mod.state

  -- If already in placement mode, append to existing queue
  if state.placement_active and state.placement_queue and #state.placement_queue > 0 then
    for _, s in ipairs(specs) do
      table.insert(state.placement_queue, s)
    end
  else
    state.placement_queue = vim.deepcopy(specs)
    state.placement_index = 1
    state.placement_active = true
  end

  if state.placement_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.placement_augroup)
  end
  state.placement_augroup = vim.api.nvim_create_augroup("SynvimTaskPlacement", { clear = true })

  vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter", "WinEnter" }, {
    group = state.placement_augroup,
    callback = function()
      if state.placement_active then
        M.render_placement_preview()
      end
    end,
    desc = "Live virtual-lines task stub preview at cursor during placement mode",
  })

  -- Global Normal-mode placement shortcuts while placement_active is true
  vim.keymap.set("n", "<M-p>", function()
    M.drop_current_task_at_cursor()
  end, { silent = true, desc = "Place/drop current task stub at cursor" })

  vim.keymap.set("n", "<M-f>", function()
    require("agent.search").open_find_menu("")
  end, { silent = true, desc = "Open :Find floating menu to locate placement target" })

  vim.keymap.set("n", "<M-s>", function()
    M.split_current_placement_task()
  end, { silent = true, desc = "Split current task into smaller single-location tasks" })

  vim.keymap.set("n", "<M-n>", function()
    if state.placement_active and #state.placement_queue > 1 then
      state.placement_index = (state.placement_index % #state.placement_queue) + 1
      M.render_placement_preview()
      local cur = state.placement_queue[state.placement_index]
      vim.notify(string.format("● [Placement %d/%d] Selected task '%s'", state.placement_index, #state.placement_queue, cur.task_id), vim.log.levels.INFO)
    end
  end, { silent = true, desc = "Cycle to next queued task in placement mode" })

  vim.keymap.set("n", "<M-b>", function()
    if state.placement_active and #state.placement_queue > 1 then
      state.placement_index = ((state.placement_index - 2) % #state.placement_queue) + 1
      M.render_placement_preview()
      local cur = state.placement_queue[state.placement_index]
      vim.notify(string.format("● [Placement %d/%d] Selected task '%s'", state.placement_index, #state.placement_queue, cur.task_id), vim.log.levels.INFO)
    end
  end, { silent = true, desc = "Cycle to previous queued task in placement mode" })

  vim.keymap.set("n", "<M-q>", function()
    M.stop_placement_mode()
  end, { silent = true, desc = "Cancel task placement mode" })

  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_set_current_win, win)
  end

  M.render_placement_preview()
  local first = state.placement_queue[state.placement_index]
  vim.notify(string.format(
    "● [Placement Mode: %d task%s ready] Navigate to any file/line (via :History, :Find, or splits) and press <M-p> (or :Tasks drop) to place '%s' at cursor!",
    #state.placement_queue, #state.placement_queue == 1 and "" or "s", first and first.task_id or "task"
  ), vim.log.levels.INFO)
end

function M.start_task(raw)
  state_mod.state.origin_win = ui.get_primary_editor_win()
  raw = vim.trim(raw or "")

  -- If called without arguments: execute task under quickfix cursor, or closest visible in-line task
  if raw == "" then
    local cur_w = vim.api.nvim_get_current_win()
    local cur_b = vim.api.nvim_win_get_buf(cur_w)
    if vim.bo[cur_b].buftype == "quickfix" and state_mod.state.is_tasks_list then
      local idx = vim.fn.line(".")
      local q = state_mod.state.queue and state_mod.state.queue[idx]
      vim.cmd("cclose")
      if q and q.path and q.line then
        return M.start_task_record({ file = q.path, line = q.line, task_id = q.task_id, description = q.description })
      end
      return M.start_task(tostring(idx))
    end

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
      local has_task = l:find("%f[%a]CONTRACT%f[%A]") or l:find("%f[%a]TODO%f[%A]") or l:find("%f[%a]FIXME%f[%A]") or l:find("%f[%a]SPEC%f[%A]")
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
      vim.notify(string.format("Tasks: No in-line task (CONTRACT/TODO/FIXME/SPEC) visible in current window (lines %d–%d). Specify task: :Tasks start <id>", w0, w_dollar), vim.log.levels.ERROR)
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

  local matched_task = M.resolve_task_record(raw)
  if matched_task then
    M.start_task_record(matched_task)
    return
  end

  if raw:match("^#?%d+$") then
    vim.notify(string.format("Tasks: Task index '%s' not found. Run :Tasks to view available tasks.", raw), vim.log.levels.WARN)
    return
  end

  M.scaffold_and_run_task(raw)
end

--- Start a concrete task record ({ file, line, task_id, ... })
function M.start_task_record(matched_task)
  local all_tasks = M.scan_repository_tasks()
  if (matched_task.status or ""):upper() == "APPROVED" then
    vim.notify(string.format("Tasks: '%s' is already APPROVED. Use :Tasks MAYBE %s to reopen it for revision.", matched_task.task_id or "task", matched_task.task_id or ""), vim.log.levels.WARN)
    return
  end
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
  if vim.fn.filereadable(full_path) ~= 1 then
    vim.notify(string.format("Tasks: File for task '%s' no longer exists: %s", matched_task.task_id or "task", matched_task.file), vim.log.levels.WARN)
    return
  end
  local target_buf = vim.fn.bufadd(full_path)
  vim.fn.bufload(target_buf)
  local origin_win = ui.get_primary_editor_win()
  if origin_win and vim.api.nvim_win_is_valid(origin_win) then
    vim.api.nvim_set_current_win(origin_win)
    vim.api.nvim_win_set_buf(origin_win, target_buf)
    pcall(vim.api.nvim_win_set_cursor, origin_win, { matched_task.line, 0 })
    pcall(function() vim.cmd("normal! zz") end)
  end

  -- The on-disk scan may be stale relative to an edited buffer: re-anchor via FFI
  local target_line = matched_task.line
  local blines = vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)
  if matched_task.task_id and matched_task.task_id ~= "task" and not (blines[target_line] and blines[target_line]:find(matched_task.task_id, 1, true) and M.is_todo_comment(blines[target_line])) then
    local anchor_mod = require("agent.anchor")
    local best = anchor_mod.find_task_line(blines, matched_task.task_id, target_line)
    if not best then
      vim.notify(string.format("Tasks: Task '%s' is no longer present in %s.", matched_task.task_id, matched_task.file), vim.log.levels.WARN)
      return
    end
    target_line = best
  end

  vim.api.nvim_echo({
    { "● [Executing Task Contract: ", "ModeMsg" },
    { tostring(matched_task.task_id or "task"), "Directory" },
    { string.format("] %s in %s:%d", matched_task.description or "", matched_task.file, target_line), "Normal" },
  }, false, {})
  M.run_todo(target_buf, target_line)
end

function M.revise_task(task_arg)
  task_arg = vim.trim(task_arg or "")
  local cur_buf = vim.api.nvim_get_current_buf()
  local root = ui.get_root_dir()

  local target_buf = cur_buf
  local target_line = nil
  local target_task_id = nil

  if task_arg ~= "" then
    local matched = M.resolve_task_record(task_arg)
    if matched then
      local full_path = (matched.file:sub(1, 1) == "/") and matched.file or (root .. "/" .. matched.file)
      if vim.fn.filereadable(full_path) ~= 1 then
        vim.notify(string.format("Tasks: File for task '%s' no longer exists: %s", matched.task_id or task_arg, matched.file), vim.log.levels.WARN)
        return
      end
      target_buf = vim.fn.bufadd(full_path)
      vim.fn.bufload(target_buf)
      local blines = vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)
      target_line = require("agent.anchor").find_task_line(blines, matched.task_id, matched.line) or matched.line
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

function M.test_task(task_arg)
  task_arg = vim.trim(task_arg or "")
  local root = ui.get_root_dir()
  local matched = nil

  if task_arg ~= "" then
    matched = M.resolve_task_record(task_arg)
  else
    local win = ui.get_primary_editor_win()
    local bufnr = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) or vim.api.nvim_get_current_buf()
    local lnum = (win and vim.api.nvim_win_is_valid(win)) and vim.api.nvim_win_get_cursor(win)[1] or 1
    local blines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i = lnum, 1, -1 do
      if M.is_todo_comment(blines[i]) then
        local info = M.extract_task_info(blines[i])
        if info and info.id then
          matched = M.resolve_task_record(info.id)
          break
        end
      end
    end
  end

  if not matched then
    vim.notify("Tasks: Task '" .. (task_arg ~= "" and task_arg or "<cursor>") .. "' not found.", vim.log.levels.WARN)
    return nil
  end

  local test_rel = matched.test
  if not test_rel or test_rel == "" then
    local desc = (matched.description or "") .. " " .. (matched.ensures or "")
    test_rel = desc:match("(tests/[%w_%-%.%/]+)")
  end
  if not test_rel or test_rel == "" then
    for _, a in ipairs(matched.allow or {}) do
      if a:match("^tests/") then
        test_rel = a
        break
      end
    end
  end
  if not test_rel or test_rel == "" then
    test_rel = "tests/test_" .. (matched.task_id or "task"):gsub("%-", "_") .. "_suite.lua"
  end

  local full_test_path = (test_rel:sub(1, 1) == "/") and test_rel or (root .. "/" .. test_rel)

  -- If the test file does not exist yet, scaffold it (test-first) and open it in the editor
  if vim.fn.filereadable(full_test_path) ~= 1 then
    vim.fn.mkdir(vim.fn.fnamemodify(full_test_path, ":h"), "p")
    vim.fn.writefile({
      "-- ==============================================================================",
      string.format("-- %s: Test-First Specification Suite for CONTRACT(%s)", test_rel, matched.task_id or "task"),
      string.format("-- Action:  %s", matched.description or ""),
      string.format("-- Ensures: %s", matched.ensures or ""),
      "-- ==============================================================================",
      "",
      "error('TODO: Define failing test expectations for " .. (matched.task_id or "task") .. " first')",
    }, full_test_path)
    ui.find_or_open_file(full_test_path, 7, ui.get_primary_editor_win())
    vim.notify(string.format("● [Tasks Test-First] Scaffolded '%s' for '%s'. Write your test expectations first!", test_rel, matched.task_id), vim.log.levels.INFO)
    return {
      status = "SCAFFOLDED",
      scaffolded = true,
      test_file = full_test_path,
      task_id = matched.task_id,
    }
  end

  local src_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
  local nvim_dir = vim.fn.fnamemodify(src_dir, ":h")
  local runner_expr = string.format(
    "vim.opt.rtp:prepend(%q); package.path = %q .. '/?.lua;' .. %q .. '/?/init.lua;' .. package.path; local ok, err = pcall(dofile, %q); if not ok then io.stderr:write(tostring(err) .. '\\n'); os.exit(1) end; os.exit(0)",
    nvim_dir,
    src_dir,
    src_dir,
    full_test_path
  )
  local cmd = {
    "nvim",
    "--headless",
    "-u",
    "NONE",
    "-c",
    "lua " .. runner_expr,
  }
  local out = vim.fn.system(cmd)
  local code = vim.v.shell_error
  local status = (code == 0) and "PASSED" or "FAILED"

  if status == "PASSED" then
    vim.notify(string.format("✓ [Tasks Test PASSED] %s (%s)", matched.task_id, test_rel), vim.log.levels.INFO)
  else
    vim.notify(string.format("✗ [Tasks Test FAILED] %s (%s):\n%s", matched.task_id, test_rel, vim.trim(out or "")), vim.log.levels.ERROR)
  end

  return {
    status = status,
    scaffolded = false,
    code = code,
    output = out or "",
    test_file = full_test_path,
    task_id = matched.task_id,
  }
end

function M.tasks_complete(arglead, cmdline)
  local parts = vim.split(vim.trim(cmdline), "%s+")
  local has_trailing = cmdline:match("%s+$") ~= nil
  local subcmds = { "list", "add", "form", "place", "drop", "cancel", "test" }

  if #parts == 1 or (#parts == 2 and not has_trailing) then
    return vim.tbl_filter(function(s) return vim.startswith(s:lower(), arglead:lower()) or vim.startswith(s, arglead) end, subcmds)
  end

  local sub = (parts[2] or ""):lower()
  if sub == "test" then
    local ids = {}
    local all_tasks = M.scan_repository_tasks()
    for idx, t in ipairs(all_tasks) do
      if t.task_id and t.task_id ~= "task" then
        table.insert(ids, t.task_id)
      end
      table.insert(ids, tostring(idx))
    end
    return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, ids)
  end

  return {}
end

-- CONTRACT(tasks-cli-simplify-and-test-subcmd):
--   [HOARE CODE CONTRACT]
--   requires:  [task-placement-split-and-test-first-gate]
--   test:      tests/test_tasks_cli_simplify_suite.lua
--   action:    Define tests first (tests/test_tasks_cli_simplify_suite.lua), then remove obsolete agent-centric :Tasks subcommands (move, start, maybe, review, yes, no, stop, accept, reject, revise, resolve, rebase) from tasks_command and tasks_complete, and add ':Tasks test <id>' (with tab-completion over task IDs) to execute or open the test associated with a task contract.
--   ensures:   review: "Tests in tests/test_tasks_cli_simplify_suite.lua pass, removed subcommands are rejected cleanly, and ':Tasks test <id>' resolves and runs/opens the task's associated test"
--
--   [DTL AGENT POLICY]
--   allow:     [nvim/lua/agent/tasks.lua, nvim/lua/agent/init.lua, nvim/lua/agent/cmdline.lua, tests/test_tasks_cli_simplify_suite.lua]
--   forbid:    [.env*, *.pem, *.key]
--   always:    review: "Core human-driven subcommands (:Tasks [list|add|form|place|drop|cancel|test]) and Quickfix navigation remain functional"
--   repair:    on_violation -> (auto_revert, mark:REVISE)
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
  elseif subcmd == "form" then
    M.open_task_form(vim.api.nvim_get_current_win(), rest)
  elseif subcmd == "place" or subcmd == "drop" then
    M.drop_current_task_at_cursor()
  elseif subcmd == "cancel" then
    if state_mod.state.placement_active then
      M.stop_placement_mode()
    else
      vim.notify("Tasks: Placement mode is not active.", vim.log.levels.INFO)
    end
  elseif subcmd == "test" then
    return M.test_task(rest)
  else
    vim.notify(
      string.format("Tasks: Unknown subcommand '%s'. Available: list, add, form, drop, cancel, test", subcmd),
      vim.log.levels.WARN
    )
  end
end

return M
