local M = {}

M.state = {
  origin_win = nil,
  last_terminal_cwd = nil,
  last_terminal_buf = nil,
  last_terminal_win = nil,
  latest_focus_cwd = nil,
  latest_focus_type = nil,
}

return M
