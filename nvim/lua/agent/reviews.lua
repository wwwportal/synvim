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
function M.create_review(file_path, start_line, old_count, old_lines, new_lines, task_id, desc, status, order_idx, is_task_stub, extra_opts)
  status = status or "unreviewed"
  extra_opts = extra_opts or {}
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

  local ws_mod = require("agent.workspaces")
  local base_snapshot = ws_mod.capture_file_base(file_path)

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
    base_hash = extra_opts.base_hash or base_snapshot.hash,
    base_content = extra_opts.base_content or base_snapshot.content,
    worktree = extra_opts.worktree or nil,
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

--- Extract the bare task slug from a review (task_id may be a raw header line)
function M.review_slug(r)
  if not r then return nil end
  local tid = r.task_id or ""
  local slug = tid:match("%(([%w_%-]+)") or tid:match("%[([%w_%-]+)") or tid
  slug = vim.trim(slug or "")
  if slug == "" or slug == "task" or slug:find("%s") then return nil end
  return slug
end

local function review_target_path(rev, root)
  root = root or ui.get_root_dir()
  if rev.abs_file and rev.abs_file ~= "" then return rev.abs_file end
  local f = rev.target_file or rev.file or ""
  return f:match("^/") and f or (root .. "/" .. f)
end
M.review_target_path = review_target_path

--- Resolve a review for accept/reject. An explicit id that matches nothing
--- NEVER falls back to another review.
local function resolve_review(rev_id)
  local state = state_mod.state
  if not rev_id or rev_id == "" then
    if state.current_review and state.current_review.id then
      return M.find_review(state.current_review.id, false) or state.current_review
    end
    local unrev = M.get_reviews("unreviewed")
    return unrev[1]
  end
  if state.current_review and state.current_review.id == rev_id then
    -- prefer the on-disk record (authoritative status), keep live fields
    local disk = M.find_review(rev_id, false)
    if disk and disk.id == rev_id then return disk end
    return state.current_review
  end
  return M.find_review(rev_id, true)
end

--- Clear the in-line diff UI only if it belongs to the given file
local function clear_diff_for(target_full)
  local state = state_mod.state
  local p = state.pending_diff
  if not p then return end
  local name = (p.bufnr and vim.api.nvim_buf_is_valid(p.bufnr)) and vim.api.nvim_buf_get_name(p.bufnr) or ""
  if name == target_full or vim.fn.fnamemodify(name, ":p") == vim.fn.fnamemodify(target_full, ":p") then
    p.revert_lines = nil
    require("agent.diff").clear_diff(true)
  end
end

local function finish_review(rev, status)
  local state = state_mod.state
  rev.status = status
  rev.reviewed_at = os.date("%Y-%m-%d %H:%M:%S")
  M.save_review_meta(rev)
  if state.current_review and state.current_review.id == rev.id then
    state.current_review = nil
  end
  if rev.worktree then
    pcall(require("agent.workspaces").remove_workspace, rev.worktree)
  end
end

--- Revert review: content-anchored, never touches unrelated lines
function M.revert_review(rev_id)
  local root = ui.get_root_dir()
  local patch = require("agent.patch")

  local rev = resolve_review(rev_id)
  if not rev then
    vim.notify(rev_id and rev_id ~= "" and ("Tasks: Review '" .. rev_id .. "' not found") or "Tasks: No review to reject", vim.log.levels.WARN)
    return false
  end
  if rev.status and rev.status ~= "unreviewed" then
    vim.notify(string.format("Tasks: Review %s is already %s.", rev.id, rev.status), vim.log.levels.WARN)
    return false
  end

  local target_full = review_target_path(rev, root)
  clear_diff_for(target_full)

  local bufnr = vim.fn.bufnr(target_full)
  local buf_loaded = bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr)
  if vim.fn.filereadable(target_full) ~= 1 and not buf_loaded then
    finish_review(rev, "rejected")
    vim.notify(string.format("✗ Tasks: %s discarded (target file %s no longer exists).", rev.id, rev.target_file or target_full), vim.log.levels.INFO)
  else
    local ok, st, b = patch.commit(target_full, rev, patch.unapply)
    if not ok then
      rev.is_conflict = true
      vim.notify(string.format(
        "⚠ Tasks: Cannot revert %s — the generated block in %s was edited since generation, so it can't be located safely. Fix the file manually, then run ':Tasks review discard %s'.",
        rev.id, rev.target_file or target_full, rev.id), vim.log.levels.WARN)
      return false
    end
    -- Remove files that only existed because of this review
    if rev.is_new_file and b and vim.api.nvim_buf_is_valid(b) then
      local cur = vim.api.nvim_buf_get_lines(b, 0, -1, false)
      if #cur == 0 or (#cur == 1 and vim.trim(cur[1]) == "") then
        pcall(vim.fn.delete, target_full)
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    finish_review(rev, "rejected")
    vim.notify(string.format("✗ Tasks: Reverted %s on %s%s", rev.id, vim.fn.fnamemodify(target_full, ":."), st == "unchanged" and " (already reverted)" or ""), vim.log.levels.INFO)
  end

  local rem = M.get_reviews("unreviewed")
  if #rem > 0 then
    M.list_reviews_qf()
  else
    pcall(vim.cmd, "cclose")
    vim.notify("✓ Tasks: All implementations have been reviewed by a human!", vim.log.levels.INFO)
  end
  return true
end

--- Mark a review rejected without touching any file (manual conflict escape hatch)
function M.discard_review(rev_id)
  local rev = resolve_review(rev_id)
  if not rev then
    vim.notify("Tasks: Review '" .. tostring(rev_id) .. "' not found", vim.log.levels.WARN)
    return false
  end
  if rev.status and rev.status ~= "unreviewed" then
    vim.notify(string.format("Tasks: Review %s is already %s.", rev.id, rev.status), vim.log.levels.WARN)
    return false
  end
  clear_diff_for(review_target_path(rev))
  finish_review(rev, "rejected")
  vim.notify(string.format("Tasks: Discarded %s (files left untouched).", rev.id), vim.log.levels.INFO)
  return true
end

--- Accept review: apply (content-anchored) and persist, mark human-approved
function M.accept_review(rev_id)
  local root = ui.get_root_dir()
  local diff_mod = require("agent.diff")
  local patch = require("agent.patch")

  local rev = resolve_review(rev_id)
  if not rev then
    vim.notify(rev_id and rev_id ~= "" and ("Tasks: Review '" .. rev_id .. "' not found") or "Tasks: No review to accept", vim.log.levels.WARN)
    return false
  end
  if rev.status and rev.status ~= "unreviewed" then
    vim.notify(string.format("Tasks: Review %s is already %s.", rev.id, rev.status), vim.log.levels.WARN)
    return false
  end

  local target_full = review_target_path(rev, root)
  clear_diff_for(target_full)

  local ok = patch.commit(target_full, rev, patch.apply)
  if not ok then
    rev.is_conflict = true
    vim.notify(string.format(
      "⚠ Tasks: Cannot accept %s — the original code in %s changed since generation. Run ':Tasks rebase %s' to regenerate, or ':Tasks NO %s'.",
      rev.id, rev.target_file or target_full, rev.id, rev.id), vim.log.levels.WARN)
    return false
  end

  local slug = M.review_slug(rev)
  if not rev.is_task_stub and slug then
    diff_mod.promote_contract_to_approved(target_full, slug)
  end

  finish_review(rev, "accepted")
  if rev.is_task_stub then
    vim.notify(string.format("✓ Tasks: Task stub '%s' accepted! Ready to implement via :Tasks start %s", slug or rev.id, slug or rev.id), vim.log.levels.INFO)
  else
    vim.notify(string.format("✓ Tasks: %s accepted and approved!", rev.id), vim.log.levels.INFO)
  end

  -- Notify downstream tasks that became unblocked
  if slug then
    local tasks_mod = require("agent.tasks")
    local all_tasks = tasks_mod.scan_repository_tasks()
    local status_of = {}
    for _, t in ipairs(all_tasks) do
      if t.task_id then status_of[t.task_id:lower()] = t.status end
    end
    status_of[slug:lower()] = "APPROVED"
    for _, t in ipairs(all_tasks) do
      if t.status ~= "DONE" and t.status ~= "APPROVED" then
        local blocked_by_this, all_met = false, true
        for _, dep in ipairs(t.depends_on or {}) do
          if dep:lower() == slug:lower() then blocked_by_this = true end
          local s = status_of[dep:lower()]
          if s ~= "DONE" and s ~= "APPROVED" then all_met = false end
        end
        if blocked_by_this and all_met then
          vim.notify(string.format("● [Tasks] '%s' is now UNBLOCKED and ready to start (:Tasks start %s)", t.task_id, t.task_id), vim.log.levels.INFO)
        end
      end
    end
  end

  local rem = M.get_reviews("unreviewed")
  if #rem > 0 then
    M.list_reviews_qf()
  else
    pcall(vim.cmd, "cclose")
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
    local status_label = (r.status == "accepted") and "[APPROVED]"
      or ((r.status == "rejected") and "[REJECTED]"
      or ((r.status == "superseded") and "[SUPERSEDED]" or "[PENDING]"))
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
  vim.notify(string.format("Tasks: %d pending review%s (:Tasks YES <id> | :Tasks NO <id>)", #unreviewed, #unreviewed == 1 and "" or "s"), vim.log.levels.INFO)
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
  local new_content = table.concat(rev.new_lines or {}, "\n")
  local old_cnt = (rev.old_lines and #rev.old_lines) or rev.old_lines_count or 0
  state_mod.state.current_review = rev

  -- Locate the review by CONTENT (line numbers drift as the file is edited)
  local patch = require("agent.patch")
  local cur_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local st, idx = patch.locate(cur_lines, rev)
  if st == "missing" then
    rev.is_conflict = true
    pcall(vim.api.nvim_win_set_cursor, origin_win, { math.min(lnum, #cur_lines), 0 })
    vim.notify(string.format("⚠ [AGENT CONFLICT]: Code targeted by review '%s' in '%s' was changed since generation. Run ':Tasks rebase %s' to regenerate or ':Tasks NO %s'.", rev.id, rev.target_file, rev.id, rev.id), vim.log.levels.WARN)
    return
  end
  rev.is_conflict = false
  lnum = idx
  rev.start_line = idx

  pcall(vim.api.nvim_win_set_cursor, origin_win, { math.min(lnum, math.max(1, #cur_lines)), 0 })
  pcall(function() vim.cmd("normal! zz") end)

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

  if subcmd == "accept" or subcmd == "a" or subcmd == "yes" or subcmd == "y" then
    local target_id = arg or (state_mod.state.current_review and state_mod.state.current_review.id)
    if target_id then
      M.accept_review(target_id)
    else
      vim.notify("Review: No active review to accept. Run :Tasks review to select one.", vim.log.levels.WARN)
    end
    return
  elseif subcmd == "reject" or subcmd == "r" or subcmd == "no" or subcmd == "n" then
    local target_id = arg or (state_mod.state.current_review and state_mod.state.current_review.id)
    if target_id then
      M.revert_review(target_id)
    else
      vim.notify("Review: No active review to reject. Run :Tasks review to select one.", vim.log.levels.WARN)
    end
    return
  elseif subcmd == "revise" or subcmd == "w" or subcmd == "maybe" or subcmd == "m" then
    local tasks_mod = require("agent.tasks")
    tasks_mod.revise_task(arg)
    return
  elseif subcmd == "discard" then
    M.discard_review(arg or (state_mod.state.current_review and state_mod.state.current_review.id))
    return
  elseif subcmd == "resolve" then
    local target_id = arg or (state_mod.state.current_review and state_mod.state.current_review.id)
    local rev = target_id and M.find_review(target_id, true) or state_mod.state.current_review
    if rev then
      local ws_mod = require("agent.workspaces")
      local patch = require("agent.patch")
      local target_full = review_target_path(rev)
      local bufnr = vim.fn.bufadd(target_full)
      vim.fn.bufload(bufnr)
      local cur_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local cur_str = table.concat(cur_lines, "\n")
      -- Build the full-file incoming version: base content with the patch applied
      local base_lines = vim.split(rev.base_content or "", "\n")
      local incoming = patch.apply(base_lines, rev)
      local incoming_str = incoming and table.concat(incoming, "\n") or table.concat(rev.new_lines or {}, "\n")
      local rec = ws_mod.reconcile_changes(cur_str, rev.base_content or "", incoming_str)
      ws_mod.open_conflict_resolver(rev, bufnr, rec)
    else
      vim.notify("Review: No review found to resolve.", vim.log.levels.WARN)
    end
    return
  elseif subcmd == "rebase" then
    local target_id = arg or (state_mod.state.current_review and state_mod.state.current_review.id)
    local rev = target_id and M.find_review(target_id, true) or state_mod.state.current_review
    local slug = rev and M.review_slug(rev)
    if rev and slug then
      local tasks_mod = require("agent.tasks")
      vim.notify(string.format("● [Tasks] Rebasing task '%s' against updated file...", slug), vim.log.levels.INFO)
      local reverted = (rev.status ~= "unreviewed") or M.revert_review(rev.id) or M.discard_review(rev.id)
      if reverted then
        tasks_mod.start_task(slug)
      end
    else
      vim.notify("Review: No task-backed review found to rebase.", vim.log.levels.WARN)
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
    vim.notify("Tasks: Batch accept is disabled. Please accept changes individually by review ID: :Tasks YES <id>", vim.log.levels.WARN)
    return
  end

  if arg ~= "" then
    local rev = M.find_review(arg, true)
    if not rev then
      vim.notify("Tasks: Review ID '" .. arg .. "' not found. Run :Tasks review to see active reviews.", vim.log.levels.WARN)
      return false
    end
    return M.accept_review(rev.id)
  end

  -- In-line diff active
  if state.pending_diff then
    local review = state.pending_diff.review
    if review and review.id then
      return M.accept_review(review.id)
    else
      diff_mod.accept_diff()
      return true
    end
  end

  if state.current_review then
    return M.accept_review(state.current_review.id)
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
    vim.notify(string.format("Tasks: Multiple pending reviews exist (%d). Specify review ID: :Tasks YES <id>. Run :Tasks review to list them.", #unrev), vim.log.levels.INFO)
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
    vim.notify("Tasks: Batch reject is disabled. Please reject changes individually by review ID: :Tasks NO <id>", vim.log.levels.WARN)
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
    vim.notify(string.format("Tasks: Multiple pending reviews exist (%d). Specify review ID: :Tasks NO <id>. Run :Tasks review to list them.", #unrev), vim.log.levels.INFO)
    M.list_reviews_qf()
    return
  else
    vim.notify("Tasks: No pending review to reject", vim.log.levels.INFO)
    return
  end
end

return M
