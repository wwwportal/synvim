local M = {}

local state_mod = require("synvim.state")
local ui = require("synvim.ui")
local history = require("synvim.history")
local search = require("synvim.search")

M.state = state_mod.state
M.ui = ui
M.history = history
M.search = search

function M.setup()
  -- Autocmd: Track active working directory across terminal and editor splits
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "TermOpen" }, {
    callback = function(args)
      local buf = args.buf
      if not vim.api.nvim_buf_is_valid(buf) then return end
      local bt = vim.bo[buf].buftype
      if bt == "terminal" then
        local cwd = ui.get_terminal_cwd(buf)
        if cwd then
          M.state.last_terminal_cwd = cwd
          M.state.last_terminal_buf = buf
          M.state.last_terminal_win = vim.api.nvim_get_current_win()
          M.state.latest_focus_cwd = cwd
          M.state.latest_focus_type = "terminal"
        end
      elseif bt == "" then
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= "" and not name:match("^%a+://") and vim.fn.filereadable(name) == 1 then
          local dir = vim.fs.root(name, { ".git", "Cargo.toml", "Makefile", "pyproject.toml" }) or vim.fn.fnamemodify(name, ":p:h")
          if dir and dir ~= vim.fn.expand("~") and dir ~= "/" then
            M.state.latest_focus_cwd = dir
            M.state.latest_focus_type = "editor"
          end
        end
      end
    end,
    desc = "Track active directory across terminal and editor splits",
  })

  -- Visited Files List (:History)
  vim.api.nvim_create_user_command("History", function(ctx)
    local arg = vim.trim(ctx.args or ""):lower()
    if arg == "clear" then
      history.clear()
    elseif arg == "qf" or arg == "list" then
      history.show_quickfix()
    else
      history.show_history()
    end
  end, {
    nargs = "?",
    complete = function(arglead, _)
      return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, { "qf", "list", "clear" })
    end,
    desc = "Visited files list in recent order (:History [qf|list|clear])",
  })

  -- Hybrid Search Bar (:Find)
  vim.api.nvim_create_user_command("Find", function(ctx)
    M.state.origin_win = vim.api.nvim_get_current_win()
    search.find(ctx.args)
  end, {
    nargs = "*",
    complete = function(arglead, _)
      local scopes = { "@algo", "@deps", "@loogle", "@docs", "@code", "in" }
      local out = {}
      for _, s in ipairs(scopes) do
        if vim.startswith(s, arglead) then
          table.insert(out, s)
        end
      end
      local files = vim.fn.getcompletion(arglead, "file")
      for _, f in ipairs(files) do
        table.insert(out, f)
      end
      return out
    end,
    desc = "Hybrid FZF + BM25 + AST Symbol search (:Find [@deps|@loogle|@docs] <query> [in <path...>])",
  })

  -- Help command (:Synvim)
  vim.api.nvim_create_user_command("Synvim", function(_)
    ui.show_help()
  end, {
    nargs = "?",
    complete = function(arglead, _)
      return vim.tbl_filter(function(s) return vim.startswith(s:lower(), arglead:lower()) end, { "help" })
    end,
    desc = "Show synvim commands and usage (:Synvim help)",
  })

  -- Enable native lowercase abbreviations
  pcall(vim.cmd, [[
    cnoreabbrev <expr> find (getcmdtype() ==# ':' && getcmdline() ==# 'find') ? 'Find' : 'find'
    cnoreabbrev <expr> synvim (getcmdtype() ==# ':' && getcmdline() ==# 'synvim') ? 'Synvim' : 'synvim'
    cnoreabbrev <expr> history (getcmdtype() ==# ':' && getcmdline() ==# 'history') ? 'History' : 'history'
  ]])

  history.setup()
end

return M
