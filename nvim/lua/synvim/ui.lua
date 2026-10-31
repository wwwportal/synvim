local M = {}
local state_mod = require("synvim.state")

--- Resolve suggested target path cleanly without doubling base_dir
function M.resolve_suggested_path(base_dir, sugg)
  if not sugg or sugg == "" then return base_dir or "" end
  sugg = sugg:gsub("^%./", "")
  base_dir = (base_dir or ""):gsub("^%./", ""):gsub("/+$", "")

  if sugg:match("^/") then return sugg end
  if base_dir == "" or base_dir == "." then return sugg end

  if sugg == base_dir or sugg:find("^" .. vim.pesc(base_dir) .. "/") then
    return sugg
  end

  return base_dir .. "/" .. sugg
end

--- Resolve current working directory of a terminal buffer via /proc/<pid>/cwd or term:// URI
function M.get_terminal_cwd(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return nil end
  if vim.bo[buf].buftype ~= "terminal" then return nil end

  local chan = vim.bo[buf].channel
  if not chan or chan <= 0 then
    chan = vim.b[buf].terminal_job_id
  end
  if chan and chan > 0 then
    local ok, pid = pcall(vim.fn.jobpid, chan)
    if ok and pid and pid > 0 then
      local cwd = vim.uv.fs_realpath("/proc/" .. pid .. "/cwd")
      if cwd and cwd ~= "" and vim.fn.isdirectory(cwd) == 1 then
        return cwd
      end
    end
  end

  local name = vim.api.nvim_buf_get_name(buf)
  local term_path = name:match("^term://(.-)//")
  if term_path and term_path ~= "" then
    local expanded = vim.fn.expand(term_path)
    if vim.fn.isdirectory(expanded) == 1 then
      return vim.uv.fs_realpath(expanded) or expanded
    end
  end
  return nil
end

--- Get root directory of current project, prioritizing active or latest-navigated terminal split
function M.get_root_dir()
  local state = state_mod.state
  local cur_win = vim.api.nvim_get_current_win()
  local cur_buf = vim.api.nvim_win_get_buf(cur_win)
  local candidate = nil

  -- 1. If currently in a terminal split, its live CWD is primary
  if vim.bo[cur_buf].buftype == "terminal" then
    candidate = M.get_terminal_cwd(cur_buf)
  end

  -- 2. If currently in an editor buffer with a valid saved file on disk
  if not candidate and vim.bo[cur_buf].buftype == "" then
    local name = vim.api.nvim_buf_get_name(cur_buf)
    if name ~= "" and not name:match("^%a+://") and vim.fn.filereadable(name) == 1 then
      local root = vim.fs.root(name, { ".git", "Cargo.toml", "Makefile", "pyproject.toml", "package.json" })
      if root and root ~= vim.fn.expand("~") and root ~= "/" then
        candidate = root
      end
    end
  end

  -- 3. If latest focused split was a terminal, check live CWD of that terminal buffer
  if not candidate and state.last_terminal_buf and vim.api.nvim_buf_is_valid(state.last_terminal_buf) then
    candidate = M.get_terminal_cwd(state.last_terminal_buf)
  end

  -- 4. Check active terminal buffers in open windows
  if not candidate then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(win)
      if vim.bo[b].buftype == "terminal" then
        local cwd = M.get_terminal_cwd(b)
        if cwd then
          candidate = cwd
          break
        end
      end
    end
  end

  -- 5. Fallback to global CWD
  if not candidate then
    candidate = vim.fn.getcwd()
  end

  return candidate
end

--- Locate primary non-terminal editor window
function M.get_primary_editor_win()
  local cur_win = vim.api.nvim_get_current_win()
  local cur_buf = vim.api.nvim_win_get_buf(cur_win)
  if vim.bo[cur_buf].buftype ~= "terminal" then
    return cur_win
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(win)
    if vim.bo[b].buftype == "" then
      return win
    end
  end
  return cur_win
end

--- Find or open file in targeted or primary window
function M.find_or_open_file(filepath, line, col, target_win)
  if not filepath or filepath == "" then return end
  local win = target_win or M.get_primary_editor_win()
  if not vim.api.nvim_win_is_valid(win) then
    win = vim.api.nvim_get_current_win()
  end

  vim.api.nvim_set_current_win(win)
  local full = vim.fn.fnamemodify(filepath, ":p")
  if vim.fn.filereadable(full) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(full))
    if line and line > 0 then
      pcall(vim.api.nvim_win_set_cursor, win, { line, math.max(0, (col or 1) - 1) })
      vim.cmd("normal! zz")
    end
  end
end

--- Show synvim help window
function M.show_help()
  local lines = {
    "╭─────────────────────────────────────────────────────────────╮",
    "│               synvim — Sovereign Text Editor                │",
    "╰─────────────────────────────────────────────────────────────╯",
    "",
    " ── Core Commands ──",
    "  :Find [query]         Hybrid C++20 search (FZF + BM25 + AST symbols)",
    "  :Find @deps <query>   Search in project dependencies",
    "  :Find @algo <query>   Search algorithms & data structures",
    "  :Find @loogle <query> Search Lean 4 / Mathlib theorems",
    "  :Find @docs <query>   Search programming language documentation",
    "  :History              Show visited files list (<leader>h)",
    "  :History clear        Reset file history tracking",
    "  :Listen               Voice dictation into buffer via scribe (<leader>v)",
    "  :Synvim help          Show this reference help",
    "",
    " ── Tiling & Split Management ──",
    "  Alt + Arrow           Move focus across splits",
    "  Alt + h/j/k/l         Swap active split with adjacent neighbor",
    "  Alt + z               Toggle zoom / maximize active split",
    "  Alt + q / Alt + w     Close active split",
    "  Alt + +               Split right with a new terminal",
    "  Alt + _               Split down with a new terminal",
    "",
    "Press <Esc> or q to close this window.",
  }

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "synvim-help"

  local width = math.min(70, vim.o.columns - 4)
  local height = #lines + 2
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "single",
  })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })
end

return M
