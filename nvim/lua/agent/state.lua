local M = {}

M.ns_diff = vim.api.nvim_create_namespace("agent_inline_diff")
M.ns_flash = vim.api.nvim_create_namespace("agent_jump_flash")
M.ns_placement = vim.api.nvim_create_namespace("agent_task_placement")

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
  placement_queue = {},
  placement_index = 1,
  placement_active = false,
  placement_augroup = nil,
  active_job = nil,
  status_tail = "",
  is_busy = false,
  origin_win = nil,
  last_terminal_cwd = nil,
  last_terminal_buf = nil,
  last_terminal_win = nil,
  latest_focus_cwd = nil,
  latest_focus_type = nil,
  -- Re-entrancy guard while re-attaching diffs during BufEnter.
  _attaching = false,
}

return M
