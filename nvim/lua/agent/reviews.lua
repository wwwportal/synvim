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
        obj._json_path = f
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

--- Robust review lookup supporting: numeric index, task slug, full id, partial id/suffix
function M.find_review(arg, prefer_unreviewed)
  if not arg or vim.trim(arg) == "" then return nil end
  arg = vim.trim(arg)
  if prefer_unreviewed == nil then prefer_unreviewed = true end

  local num = tonumber(arg:match("^#?(%d+)$"))
  local unrev = M.get_reviews("unreviewed")
  local all_revs = M.get_reviews("all")

  -- 1. Numeric index (e.g. "1" or "#1")
  if num then
    if prefer_unreviewed and unrev[num] then
      return unrev[num]
    end
    if all_revs[num] then
      return all_revs[num]
    end
  end

  local function match_in_list(list)
    -- Exact ID
    for _, r in ipairs(list) do
      if r.id and r.id:lower() == arg:lower() then return r end
    end
    -- Task slug extraction (e.g. "precommit-lang-gates" from "# SPEC(precommit-lang-gates | ...)")
    for _, r in ipairs(list) do
      local slug = (r.task_id or ""):match("%(([%w_%-]+)") or (r.task_id or ""):match("%[([%w_%-]+)") or r.task_id or ""
      if slug ~= "" and slug:lower() == arg:lower() then return r end
    end
    -- Task ID full or substring match
    for _, r in ipairs(list) do
      if r.task_id and r.task_id:lower():find(arg:lower(), 1, true) then return r end
    end
    -- ID suffix or substring (e.g. 4-digit or 6-digit random hash)
    for _, r in ipairs(list) do
      if r.id and (r.id:sub(-#arg) == arg or r.id:lower():find(arg:lower(), 1, true)) then
        return r
      end
    end
    return nil
  end

  if prefer_unreviewed then
    local m = match_in_list(unrev)
    if m then return m end
  end
  return match_in_list(all_revs)
end

--- Save review metadata to disk
function M.save_review_meta(rev)
  if not rev then return false end
  local root = ui.get_root_dir()
  local rdir = M.get_reviews_dir(root)
  local json_file = rev._json_path
  if not json_file or vim.fn.filereadable(json_file) ~= 1 then
    if rev.patch_file and root then
      local candidate = root .. "/" .. (rev.patch_file:gsub("%.patch$", ".json"))
      if vim.fn.filereadable(candidate) == 1 then json_file = candidate end
    end
  end
  if not json_file or vim.fn.filereadable(json_file) ~= 1 then
    if rev.id then
      local candidate = rdir .. "/" .. rev.id .. ".json"
      json_file = candidate
    end
  end
  if json_file then
    local save_obj = vim.deepcopy(rev)
    save_obj._json_path = nil
    save_obj._filepath = nil
    vim.fn.writefile({ vim.fn.json_encode(save_obj) }, json_file)
    return true
  end
  return false
end

--- Create a review record and patch on disk
function M.create_review(file_path, start_line, old_count, old_lines, new_lines, task_id, desc, status, order_idx, is_task_stub)
  status = status or "unreviewed"
  local root = ui.get_root_dir()
  local file_root = vim.fs.root(file_path, { ".git", "Cargo.toml", "Makefile", "pyproject.toml", "package.json" })
  if file_root then
    root = file_root
  end
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
  meta._json_path = meta_file
  vim.fn.writefile({ vim.fn.json_encode(meta) }, meta_file)
  return meta
end

--- Revert review cleanly using git apply -R or line replacement
function M.revert_review(rev_id)
  local root = ui.get_root_dir()
  local state = state_mod.state
  local diff_mod = require("agent.diff")

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

  local rev
  if state.current_review and (not rev_id or rev_id == "" or state.current_review.id == rev_id) then
    rev = state.current_review
  else
    rev = M.find_review(rev_id, true)
  end
  if not rev and state.current_review then
    rev = state.current_review
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
  M.save_review_meta(rev)

  state.current_review = nil
  vim.notify(string.format("✗ Tasks: Reverted %s on %s!", rev.id, vim.fn.fnamemodify(target_full, ":.")), vim.log.levels.INFO)

  -- Refresh review list
  local rem = M.get_reviews("unreviewed")
  if #rem > 0 then
    M.list_reviews_qf()
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

  local rev
  if state.current_review and (not rev_id or rev_id == "" or state.current_review.id == rev_id) then
    rev = state.current_review
  else
    rev = M.find_review(rev_id, true)
  end
  if not rev and state.current_review then
    rev = state.current_review
  end

  if not rev then
    vim.notify("GitReview: Review ID not found: " .. tostring(rev_id), vim.log.levels.WARN)
    return false
  end

  -- If diff is active for this review, accept without reverting
  if state.pending_diff then
    state.pending_diff.revert_lines = nil
    local p_buf = state.pending_diff.bufnr
    diff_mod.clear_diff(true)
    if p_buf and vim.api.nvim_buf_is_valid(p_buf) then
      local name = vim.api.nvim_buf_get_name(p_buf)
      if name ~= "" and vim.bo[p_buf].buftype == "" then
        pcall(vim.api.nvim_buf_call, p_buf, function() vim.cmd("silent! write!") end)
      end
    end
  else
    diff_mod.clear_diff(true)
  end

  local target_full = rev.abs_file or (rev.target_file and (rev.target_file:match("^/") and rev.target_file or (root .. "/" .. rev.target_file)))
  -- Ensure new lines are present on disk if accepting directly without active diff
  if not rev.is_task_stub and rev.new_lines and #rev.new_lines > 0 and target_full and vim.fn.filereadable(target_full) == 1 then
    local cur_lines = vim.fn.readfile(target_full)
    local first_nl = rev.new_lines[1]
    local has_content = false
    for _, cl in ipairs(cur_lines) do
      if cl == first_nl then has_content = true; break end
    end
    if not has_content then
      local s_line = math.max(0, (rev.start_line or 1) - 1)
      local old_cnt = rev.old_lines_count or (rev.old_lines and #rev.old_lines) or 0
      local e_line = math.min(#cur_lines, s_line + old_cnt)
      local updated = {}
      for i = 1, s_line do table.insert(updated, cur_lines[i]) end
      for _, nl in ipairs(rev.new_lines) do table.insert(updated, nl) end
      for i = e_line + 1, #cur_lines do table.insert(updated, cur_lines[i]) end
      vim.fn.writefile(updated, target_full)
      local b = vim.fn.bufnr(target_full)
      if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then
        vim.api.nvim_buf_call(b, function() vim.cmd("checktime") end)
      end
    end
  end

  if not rev.is_task_stub and target_full then
    diff_mod.promote_contract_to_approved(target_full, rev.task_id)
  end

  rev.status = "accepted"
  rev.reviewed_at = os.date("%Y-%m-%d %H:%M:%S")
  M.save_review_meta(rev)

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

--- List reviews in quickfix (:Tasks review)
function M.list_reviews_qf(filter)
  filter = filter or "unreviewed"
  local root = ui.get_root_dir()
  local reviews = M.get_reviews(filter)
  local unreviewed = (filter == "unreviewed") and reviews or M.get_reviews("unreviewed")

  if #reviews == 0 then
    if filter == "unreviewed" then
      local all_revs = M.get_reviews("all")
      if #all_revs > 0 then
        vim.notify("Tasks: All tasks have been reviewed! Run :Tasks review all to view past history.", vim.log.levels.INFO)
      else
        vim.notify("Tasks: No review changes recorded. Run :Tasks start to generate implementations.", vim.log.levels.INFO)
      end
    else
      vim.notify("Tasks: No review history found.", vim.log.levels.INFO)
    end
    vim.cmd("cclose")
    return
  end

  local qf_list = {}
  for idx, r in ipairs(reviews) do
    local f = r.target_file or r.file or r.filepath or ""
    local full = (f:match("^/") and f) or (root .. "/" .. f)
    local rel_f = f:gsub("^" .. vim.pesc(root) .. "/", ""):gsub("^/+", "")
    local status_label = (r.status == "accepted") and "[APPROVED]" or ((r.status == "rejected") and "[REJECTED]" or "[PENDING]")
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
      type = "", -- Blank so quickfix never displays the misleading red 'error' badge
    })
  end

  vim.fn.setqflist(qf_list, "r")
  local title_str = (filter == "unreviewed")
    and string.format("[Tasks Review: %d pending]", #reviews)
    or string.format("[Tasks Review History: %d total]", #reviews)
  vim.fn.setqflist({}, "a", { title = title_str })

  local calling_win = vim.api.nvim_get_current_win()
  if vim.bo[vim.api.nvim_win_get_buf(calling_win)].buftype ~= "quickfix" then
    state_mod.state.origin_win = calling_win
  end

  vim.cmd("botright copen 6")
  local qf_win = vim.api.nvim_get_current_win()
  pcall(function() vim.wo[qf_win].winfixheight = true end)

  local cur_w = state_mod.state.origin_win or ui.get_primary_editor_win()
  if cur_w and vim.api.nvim_win_is_valid(cur_w) and cur_w ~= qf_win then
    local tasks_mod = require("agent.tasks")
    tasks_mod.setup_agent_qf_keymaps(cur_w, vim.api.nvim_win_get_buf(qf_win))
    pcall(vim.api.nvim_set_current_win, qf_win)
  end
  vim.notify(string.format("Tasks: %d pending review%s (:Tasks accept <id> | :Tasks reject <id>)", #unreviewed, #unreviewed == 1 and "" or "s"), vim.log.levels.INFO)
end

--- Display a specific review in-line
function M.show_review(rev, target_win)
  if not rev then return end
  local root = ui.get_root_dir()
  local target_full = rev.abs_file or (rev.target_file:match("^/") and rev.target_file or (root .. "/" .. rev.target_file))
  if vim.fn.filereadable(target_full) ~= 1 then
    vim.notify("GitReview: Target file not found: " .. target_full, vim.log.levels.WARN)
    return
  end

  local bufnr = vim.fn.bufadd(target_full)
  vim.fn.bufload(bufnr)
  local origin_win = target_win or state_mod.state.origin_win or ui.get_primary_editor_win()
  if not origin_win or not vim.api.nvim_win_is_valid(origin_win) or vim.bo[vim.api.nvim_win_get_buf(origin_win)].buftype == "quickfix" then
    origin_win = ui.get_primary_editor_win()
  end
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

  if subcmd == "all" or subcmd == "history" then
    M.list_reviews_qf("all")
    return
  end

  -- If user passed a specific review id or index: :Tasks review <id|index>
  if subcmd ~= "" and subcmd ~= "list" then
    local matched = M.find_review(subcmd, true)
    if matched then
      M.show_review(matched)
      return
    else
      vim.notify("Tasks: Review '" .. subcmd .. "' not found.", vim.log.levels.WARN)
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

  if arg ~= "" then
    local rev = M.find_review(arg, true)
    if not rev then
      vim.notify("Tasks: Review ID '" .. arg .. "' not found. Run :Tasks review to see active reviews.", vim.log.levels.WARN)
      return
    end
    M.accept_review(rev.id)
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

  if arg ~= "" then
    local rev = M.find_review(arg, true)
    if not rev then
      vim.notify("Tasks: Review ID '" .. arg .. "' not found. Run :Tasks review to see active reviews.", vim.log.levels.WARN)
      return
    end
    M.revert_review(rev.id)
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
