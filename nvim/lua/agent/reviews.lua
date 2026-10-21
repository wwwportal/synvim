local M = {}
local state_mod = require("agent.state")
local ui = require("agent.ui")

--- Get reviews directory in root and ensure .agent/ is ignored
function M.get_reviews_dir(root)
  root = root or ui.get_root_dir()
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

--- Does a review record target the given file?
function M.review_matches_file(review, abs_path, rel_path)
  if not review then return false end
  if review.abs_file and review.abs_file == abs_path then return true end
  if review.target_file and (review.target_file == rel_path or review.target_file == abs_path) then return true end
  if review.file and (review.file == rel_path or review.file == abs_path) then return true end
  if review.filepath and (review.filepath == rel_path or review.filepath == abs_path) then return true end
  return false
end

--- Load reviews from .agent/reviews/*.json
function M.get_reviews(status_filter)
  status_filter = status_filter or "unreviewed"
  local root = ui.get_root_dir()
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
    local oa = a.order or 999999
    local ob = b.order or 999999
    if oa ~= ob then
      return oa < ob
    end
    if (a.created_at or "") ~= (b.created_at or "") then
      return (a.created_at or "") < (b.created_at or "")
    end
    return (a.id or "") < (b.id or "")
  end)
  return reviews
end

--- Create a review record and patch on disk
function M.create_review(file_path, start_line, old_count, old_lines, new_lines, task_id, desc, status, order_idx, is_task_stub)
  status = status or "unreviewed"
  local root = ui.get_root_dir()
  local rdir = M.get_reviews_dir(root)
  local ts = os.time()
  local rev_id = string.format("rev-%d-%04d", ts, math.random(1000, 9999))
  local rel_file = file_path
  if file_path:sub(1, #root) == root then
    rel_file = file_path:sub(#root + 2)
  else
    rel_file = vim.fn.fnamemodify(file_path, ":.")
  end

  -- Build unified patch
  local patch_lines = {
    "--- a/" .. rel_file,
    "+++ b/" .. rel_file,
    string.format("@@ -%d,%d +%d,%d @@", start_line, math.max(1, old_count), start_line, math.max(1, #new_lines)),
  }
  for _, l in ipairs(old_lines or {}) do
    table.insert(patch_lines, "-" .. l)
  end
  for _, l in ipairs(new_lines or {}) do
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
    old_lines = old_lines or {},
    new_lines = new_lines or {},
    description = desc or "",
    order = order_idx or 9999,
    is_task_stub = is_task_stub or false,
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
  local root = ui.get_root_dir()
  local state = state_mod.state
  local diff_mod = require("agent.diff")
  local reviews = M.get_reviews("all")

  if not rev_id or rev_id == "" then
    if state.current_review and state.current_review.id then
      rev_id = state.current_review.id
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

  diff_mod.clear_diff(true)
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

  if rev.is_new_file and vim.fn.filereadable(target_full) == 1 then
    local cur_content = vim.fn.readfile(target_full)
    if #cur_content == 0 or (#cur_content == 1 and vim.trim(cur_content[1]) == "") then
      pcall(vim.fn.delete, target_full)
      if bufnr and bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
  end

  -- Update review JSON
  rev.status = "rejected"
  rev.reviewed_at = os.date("%Y-%m-%d %H:%M:%S")
  local meta_path = root .. "/" .. (rev.patch_file:gsub("%.patch$", ".json"))
  if vim.fn.filereadable(meta_path) == 1 then
    vim.fn.writefile({ vim.fn.json_encode(rev) }, meta_path)
  end

  state.current_review = nil
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
  local root = ui.get_root_dir()
  local state = state_mod.state
  local diff_mod = require("agent.diff")
  local reviews = M.get_reviews("all")

  if not rev_id or rev_id == "" then
    if state.current_review and state.current_review.id then
      rev_id = state.current_review.id
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

  diff_mod.clear_diff(true)
  if not rev.is_task_stub then
    diff_mod.promote_contract_to_approved(rev.filepath or rev.file or rev.abs_file or rev.target_file, rev.task_id)
  end
  rev.status = "accepted"
  rev.reviewed_at = os.date("%Y-%m-%d %H:%M:%S")
  local meta_path = root .. "/" .. (rev.patch_file:gsub("%.patch$", ".json"))
  if vim.fn.filereadable(meta_path) == 1 then
    vim.fn.writefile({ vim.fn.json_encode(rev) }, meta_path)
  end

  state.current_review = nil
  if rev.is_task_stub then
    vim.notify(string.format("✓ Tasks: Task stub '%s' accepted! Ready to implement via :Tasks start %s", rev.task_id or rev.id, rev.task_id or rev.id), vim.log.levels.INFO)
  else
    vim.notify(string.format("✓ Tasks: %s accepted and approved!", rev.id), vim.log.levels.INFO)
  end

  -- Check and notify if this task unblocks downstream tasks
  local accepted_id = rev.task_id
  if accepted_id and accepted_id ~= "" and accepted_id ~= "task" then
    local tasks_mod = require("agent.tasks")
    local all_tasks = tasks_mod.scan_repository_tasks()
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
  local root = ui.get_root_dir()
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
  local cur_w = ui.get_primary_editor_win()
  if cur_w and vim.api.nvim_win_is_valid(cur_w) then
    local tasks_mod = require("agent.tasks")
    tasks_mod.setup_agent_qf_keymaps(cur_w, vim.api.nvim_win_get_buf(qf_win))
    pcall(vim.api.nvim_set_current_win, cur_w)
  end
  vim.notify(string.format("Tasks: %d pending review%s (:Tasks accept <id> | :Tasks reject <id>)", #unreviewed, #unreviewed == 1 and "" or "s"), vim.log.levels.INFO)
end

--- Display a specific review in-line
function M.show_review(rev)
  if not rev then return end
  local root = ui.get_root_dir()
  local target_full = rev.abs_file or (rev.target_file:match("^/") and rev.target_file or (root .. "/" .. rev.target_file))
  if vim.fn.filereadable(target_full) ~= 1 then
    vim.notify("GitReview: Target file not found: " .. target_full, vim.log.levels.WARN)
    return
  end

  local bufnr = vim.fn.bufadd(target_full)
  vim.fn.bufload(bufnr)
  local origin_win = ui.get_primary_editor_win()
  vim.api.nvim_win_set_buf(origin_win, bufnr)

  local lnum = rev.start_line or 1
  pcall(vim.api.nvim_win_set_cursor, origin_win, { lnum, 0 })
  pcall(function() vim.cmd("normal! zz") end)

  state_mod.state.current_review = rev
  local new_content = table.concat(rev.new_lines or {}, "\n")
  local old_cnt = rev.old_lines_count or (rev.old_lines and #rev.old_lines) or 1

  local diff_mod = require("agent.diff")
  diff_mod.show_inline_diff(bufnr, lnum, new_content, old_cnt, false, rev.old_lines, rev)

  vim.api.nvim_echo({
    { "● [Git Review: ", "ModeMsg" },
    { rev.id, "Directory" },
  }, false, {})
end

--- Human Review Command Dispatcher (:Tasks review [id])
function M.review(subcmd, arg)
  subcmd = (subcmd or ""):lower()

  if subcmd == "accept" or subcmd == "a" then
    local target_id = arg or (state_mod.state.current_review and state_mod.state.current_review.id)
    if target_id then
      M.accept_review(target_id)
    else
      vim.notify("Review: No active review to accept. Run :Tasks review to select one.", vim.log.levels.WARN)
    end
    return
  elseif subcmd == "reject" or subcmd == "r" then
    local target_id = arg or (state_mod.state.current_review and state_mod.state.current_review.id)
    if target_id then
      M.revert_review(target_id)
    else
      vim.notify("Review: No active review to reject. Run :Tasks review to select one.", vim.log.levels.WARN)
    end
    return
  elseif subcmd == "clear" or subcmd == "close" then
    local diff_mod = require("agent.diff")
    diff_mod.clear_diff()
    state_mod.state.current_review = nil
    vim.cmd("cclose")
    vim.notify("Review: Closed review queue", vim.log.levels.INFO)
    return
  end

  local all_reviews = M.get_reviews("all")

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

  -- Always open the review list so user can navigate; never auto-jump to file
  M.list_reviews_qf()
end

--- Accept review by ID or active pending diff
function M.accept(arg)
  arg = vim.trim(arg or "")
  local state = state_mod.state
  local diff_mod = require("agent.diff")
  local tasks_mod = require("agent.tasks")

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
  if state.pending_diff then
    local review = state.pending_diff.review
    diff_mod.accept_diff()
    if review and review.id then
      M.accept_review(review.id)
    end
    return
  end

  if state.current_review then
    M.accept_review(state.current_review.id)
    return
  end

  -- Dir preview:
  if state.dir_preview_win then
    local fn = state.on_path_accept
    state.on_path_accept = nil
    if fn then
      fn()
    else
      ui.close_dir_preview()
      if state.pending_target then
        local target = state.pending_target
        state.pending_target = nil
        state.last_target = target
        tasks_mod.jump_to_target(target)
      end
    end
    return
  end

  if state.pending_target then
    local target = state.pending_target
    state.pending_target = nil
    state.last_target = target
    tasks_mod.jump_to_target(target)
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
  end
end

--- Reject and revert review by ID or active pending diff
function M.reject(arg)
  arg = vim.trim(arg or "")
  local state = state_mod.state
  local diff_mod = require("agent.diff")

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
  if state.pending_diff then
    local review = state.pending_diff.review
    if review and review.id then
      M.revert_review(review.id)
    else
      diff_mod.clear_diff()
      vim.notify("Tasks: In-line diff reverted", vim.log.levels.INFO)
    end
    return
  end

  if state.current_review then
    M.revert_review(state.current_review.id)
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

return M
