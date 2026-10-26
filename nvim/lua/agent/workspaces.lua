-- ==============================================================================
-- agent/workspaces.lua: Multi-Agent Workspace Isolation & 3-Way Conflict Reconciliation
-- Provides:
--   1. Ephemeral git worktree isolation (.agent/worktrees/<task_id>)
--   2. Base-hash divergence tracking for optimistic concurrency control
--   3. Automated 3-way non-overlapping hunk reconciliation (git merge-file)
--   4. Direct conflict detection and visual resolution splits
-- ==============================================================================

local M = {}
local ui = require("agent.ui")

--- Sanitize task ID into filesystem-safe directory slug
local function sanitize_slug(task_id)
  if not task_id or task_id == "" then return "agent-task-" .. os.time() end
  local slug = task_id:gsub("[^a-zA-Z0-9_%-]", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
  return (slug ~= "") and slug or ("agent-task-" .. os.time())
end

--- Get root directory of project
function M.get_root_dir()
  return ui.get_root_dir()
end

--- Create an isolated workspace for a task (using git worktree or shadow directory)
-- @param task_id string identifier of task
-- @return table { path, mode = "worktree"|"shadow", slug }
function M.create_workspace(task_id)
  local root = M.get_root_dir()
  local slug = sanitize_slug(task_id)
  local wt_dir = root .. "/.agent/worktrees/" .. slug

  vim.fn.mkdir(root .. "/.agent/worktrees", "p")

  -- Check if we are in a valid git repository
  local is_git = (vim.fn.isdirectory(root .. "/.git") == 1) or (vim.fn.system({ "git", "-C", root, "rev-parse", "--is-inside-work-tree" }):find("true") ~= nil)

  if is_git then
    -- Clean up previous worktree if it exists
    if vim.fn.isdirectory(wt_dir) == 1 then
      vim.fn.system({ "git", "-C", root, "worktree", "remove", "--force", wt_dir })
      vim.fn.delete(wt_dir, "rf")
    end

    local cmd = { "git", "-C", root, "worktree", "add", "--detach", wt_dir, "HEAD" }
    local res = vim.fn.system(cmd)
    if vim.v.shell_error == 0 and vim.fn.isdirectory(wt_dir) == 1 then
      return {
        path = wt_dir,
        mode = "worktree",
        slug = slug,
        task_id = task_id,
        created_at = os.time(),
      }
    end
  end

  -- Fallback to shadow directory if git worktree unavailable
  if vim.fn.isdirectory(wt_dir) == 1 then
    vim.fn.delete(wt_dir, "rf")
  end
  vim.fn.mkdir(wt_dir, "p")

  return {
    path = wt_dir,
    mode = "shadow",
    slug = slug,
    task_id = task_id,
    created_at = os.time(),
  }
end

--- Remove an isolated workspace cleanly
function M.remove_workspace(workspace_or_id)
  local root = M.get_root_dir()
  local slug = type(workspace_or_id) == "table" and (workspace_or_id.slug or sanitize_slug(workspace_or_id.task_id)) or sanitize_slug(workspace_or_id)
  local wt_dir = root .. "/.agent/worktrees/" .. slug

  if vim.fn.isdirectory(wt_dir) == 1 then
    -- If it was a git worktree, remove via git
    pcall(vim.fn.system, { "git", "-C", root, "worktree", "remove", "--force", wt_dir })
    pcall(vim.fn.system, { "git", "-C", root, "worktree", "prune" })
    vim.fn.delete(wt_dir, "rf")
  end
end

--- Capture current file content and sha256 hash
function M.capture_file_base(filepath)
  if not filepath or vim.fn.filereadable(filepath) ~= 1 then
    return { content = "", hash = "", lines = {} }
  end

  local lines = vim.fn.readfile(filepath)
  local content = table.concat(lines, "\n")
  local hash = vim.fn.sha256(content)

  return {
    content = content,
    hash = hash,
    lines = lines,
  }
end

--- Reconcile concurrent changes using 3-way merge (git merge-file)
-- @param current_content string (active buffer/disk content)
-- @param base_content string (content when agent started)
-- @param incoming_content string (what agent generated)
-- @return table { status = "clean"|"already_applied"|"merged"|"conflict", merged_content = string, has_conflict = bool }
function M.reconcile_changes(current_content, base_content, incoming_content)
  current_content = current_content or ""
  base_content = base_content or ""
  incoming_content = incoming_content or ""

  -- Fast path 1: No upstream changes since agent started
  if current_content == base_content then
    return {
      status = "clean",
      merged_content = incoming_content,
      has_conflict = false,
    }
  end

  -- Fast path 2: Incoming changes are already present in current content
  if current_content == incoming_content then
    return {
      status = "already_applied",
      merged_content = current_content,
      has_conflict = false,
    }
  end

  -- Upstream changes occurred! Run 3-way hunk reconciliation via git merge-file
  local f_cur = vim.fn.tempname() .. ".current"
  local f_base = vim.fn.tempname() .. ".base"
  local f_inc = vim.fn.tempname() .. ".incoming"

  local cur_lines = vim.split(current_content, "\n")
  local base_lines = vim.split(base_content, "\n")
  local inc_lines = vim.split(incoming_content, "\n")

  if #cur_lines > 1 and cur_lines[#cur_lines] == "" then table.remove(cur_lines, #cur_lines) end
  if #base_lines > 1 and base_lines[#base_lines] == "" then table.remove(base_lines, #base_lines) end
  if #inc_lines > 1 and inc_lines[#inc_lines] == "" then table.remove(inc_lines, #inc_lines) end

  vim.fn.writefile(cur_lines, f_cur)
  vim.fn.writefile(base_lines, f_base)
  vim.fn.writefile(inc_lines, f_inc)

  local cmd = {
    "git", "merge-file", "-p",
    "-L", "CURRENT_BUFFER",
    "-L", "BASE_VERSION",
    "-L", "INCOMING_AGENT",
    f_cur, f_base, f_inc
  }

  local res = vim.system(cmd, { text = true }):wait()
  pcall(vim.fn.delete, f_cur)
  pcall(vim.fn.delete, f_base)
  pcall(vim.fn.delete, f_inc)

  local merged_text = res.stdout or ""

  if res.code == 0 then
    -- Clean 3-way merge: non-overlapping changes reconciled automatically
    return {
      status = "merged",
      merged_content = merged_text,
      has_conflict = false,
    }
  else
    -- Direct overlapping conflict! Contains conflict markers
    return {
      status = "conflict",
      merged_content = merged_text,
      has_conflict = true,
      conflict_markers = merged_text,
    }
  end
end

--- Open an interactive 3-way conflict resolution split
function M.open_conflict_resolver(review, bufnr, reconciled)
  if not review or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

  local origin_win = vim.api.nvim_get_current_win()
  local conflict_text = (reconciled and reconciled.conflict_markers) or ""

  -- Open a vertical split showing the 3-way conflict view
  vim.cmd("vnew")
  local conf_win = vim.api.nvim_get_current_win()
  local conf_buf = vim.api.nvim_get_current_buf()

  vim.bo[conf_buf].buftype = "nofile"
  vim.bo[conf_buf].bufhidden = "wipe"
  vim.bo[conf_buf].filetype = vim.bo[bufnr].filetype
  vim.bo[conf_buf].swapfile = false

  local conf_lines = vim.split(conflict_text, "\n")
  vim.api.nvim_buf_set_lines(conf_buf, 0, -1, false, conf_lines)

  vim.api.nvim_buf_set_name(conf_buf, "CONFLICT: " .. (review.target_file or "patch"))
  vim.notify(string.format("⚠ [Tasks] Conflict Resolver: Reconcile conflict markers in buffer. Run :Tasks YES %s to accept resolved changes.", review.id), vim.log.levels.WARN)
end

return M
