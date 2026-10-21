return {
  {
    "nvim-lua/plenary.nvim",
    lazy = true,
  },
  {
    "nvim-tree/nvim-web-devicons",
    lazy = true,
  },
  {
    "folke/todo-comments.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    event = { "BufReadPost", "BufNewFile" },
    config = function()
      require("todo-comments").setup({
        signs = true,
        keywords = {
          FIX = { icon = " ", color = "error", alt = { "FIXME", "BUG", "FIXIT", "ISSUE" } },
          TODO = { icon = " ", color = "info" },
          SPEC = { icon = " ", color = "hint", alt = { "CONTRACT", "TIER" } },
          HACK = { icon = " ", color = "warning" },
          WARN = { icon = " ", color = "warning", alt = { "WARNING", "XXX" } },
          PERF = { icon = " ", alt = { "OPTIM", "PERFORMANCE", "OPTIMIZE" } },
          NOTE = { icon = " ", color = "hint", alt = { "INFO" } },
        },
      })
    end,
  },
  {
    "lewis6991/gitsigns.nvim",
    event = { "BufReadPre", "BufNewFile" },
    opts = {
      signs = {
        add          = { text = "│" },
        change       = { text = "│" },
        delete       = { text = "_" },
        topdelete    = { text = "‾" },
        changedelete = { text = "~" },
        untracked    = { text = "┆" },
      },
    },
  },
  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    event = "VeryLazy",
    config = function()
      -- Vivid, high-contrast color palette for clear legibility and distinct mode states
      local colors = {
        blue       = "#2563eb", -- Normal mode: vibrant sapphire blue
        blue_dark  = "#1e40af",
        green      = "#16a34a", -- Insert mode: vibrant emerald green
        green_dark = "#15803d",
        purple     = "#9333ea", -- Visual mode: vivid royal purple
        purple_dark= "#7e22ce",
        orange     = "#ea580c", -- Command mode: vivid amber/orange
        orange_dark= "#c2410c",
        red        = "#dc2626", -- Replace mode: vivid ruby red
        red_dark   = "#b91c1c",
        cyan       = "#0891b2", -- Terminal mode: vivid teal/cyan
        cyan_dark  = "#0e7490",
        white      = "#ffffff",
        fg_bright  = "#f8fafc", -- Crisp high-contrast foreground
        fg_muted   = "#94a3b8",
        bg_bar     = "#0f172a", -- Deep polished slate navy (replaces unreadable pure black)
        bg_section = "#1e293b", -- Rich slate for secondary blocks
        bg_subtle  = "#334155",
        diff_add   = "#4ade80",
        diff_mod   = "#facc15",
        diff_del   = "#f87171",
      }

      local vibrant_theme = {
        normal = {
          a = { fg = colors.white, bg = colors.blue, gui = "bold" },
          b = { fg = colors.fg_bright, bg = colors.bg_section },
          c = { fg = colors.fg_bright, bg = colors.bg_bar },
          x = { fg = colors.fg_bright, bg = colors.bg_bar },
          y = { fg = colors.fg_bright, bg = colors.bg_section },
          z = { fg = colors.white, bg = colors.blue_dark, gui = "bold" },
        },
        insert = {
          a = { fg = colors.white, bg = colors.green, gui = "bold" },
          b = { fg = colors.fg_bright, bg = colors.bg_section },
          c = { fg = colors.fg_bright, bg = colors.bg_bar },
          x = { fg = colors.fg_bright, bg = colors.bg_bar },
          y = { fg = colors.fg_bright, bg = colors.bg_section },
          z = { fg = colors.white, bg = colors.green_dark, gui = "bold" },
        },
        visual = {
          a = { fg = colors.white, bg = colors.purple, gui = "bold" },
          b = { fg = colors.fg_bright, bg = colors.bg_section },
          c = { fg = colors.fg_bright, bg = colors.bg_bar },
          x = { fg = colors.fg_bright, bg = colors.bg_bar },
          y = { fg = colors.fg_bright, bg = colors.bg_section },
          z = { fg = colors.white, bg = colors.purple_dark, gui = "bold" },
        },
        command = {
          a = { fg = colors.white, bg = colors.orange, gui = "bold" },
          b = { fg = colors.fg_bright, bg = colors.bg_section },
          c = { fg = colors.fg_bright, bg = colors.bg_bar },
          x = { fg = colors.fg_bright, bg = colors.bg_bar },
          y = { fg = colors.fg_bright, bg = colors.bg_section },
          z = { fg = colors.white, bg = colors.orange_dark, gui = "bold" },
        },
        replace = {
          a = { fg = colors.white, bg = colors.red, gui = "bold" },
          b = { fg = colors.fg_bright, bg = colors.bg_section },
          c = { fg = colors.fg_bright, bg = colors.bg_bar },
          x = { fg = colors.fg_bright, bg = colors.bg_bar },
          y = { fg = colors.fg_bright, bg = colors.bg_section },
          z = { fg = colors.white, bg = colors.red_dark, gui = "bold" },
        },
        terminal = {
          a = { fg = colors.white, bg = colors.cyan, gui = "bold" },
          b = { fg = colors.fg_bright, bg = colors.bg_section },
          c = { fg = colors.fg_bright, bg = colors.bg_bar },
          x = { fg = colors.fg_bright, bg = colors.bg_bar },
          y = { fg = colors.fg_bright, bg = colors.bg_section },
          z = { fg = colors.white, bg = colors.cyan_dark, gui = "bold" },
        },
        inactive = {
          a = { fg = colors.fg_muted, bg = colors.bg_section },
          b = { fg = colors.fg_muted, bg = colors.bg_bar },
          c = { fg = colors.fg_muted, bg = colors.bg_bar },
          x = { fg = colors.fg_muted, bg = colors.bg_bar },
          y = { fg = colors.fg_muted, bg = colors.bg_section },
          z = { fg = colors.fg_muted, bg = colors.bg_subtle },
        },
      }

      local function agent_status()
        local ok, agent = pcall(require, "agent")
        if not ok then return "" end
        if agent.state.is_busy then
          return "● [Agent: analyzing...]"
        elseif agent.state.pending_diff then
          return "● [DIFF: :GitReview]"
        elseif agent.state.queue and #agent.state.queue > 0 then
          local cur = agent.state.queue[agent.state.queue_index]
          return string.format("● [%d/%d] %s", agent.state.queue_index, #agent.state.queue, cur and cur.path or "")
        end
        return "● Agent"
      end

      local function agent_color()
        local ok, agent = pcall(require, "agent")
        if ok then
          if agent.state.is_busy then
            return { fg = colors.orange, gui = "bold" }
          elseif agent.state.pending_diff then
            return { fg = colors.diff_add, gui = "bold" }
          elseif agent.state.queue and #agent.state.queue > 0 then
            return { fg = colors.cyan, gui = "bold" }
          end
        end
        return { fg = colors.fg_muted }
      end

      require("lualine").setup({
        options = {
          icons_enabled = true,
          theme = vibrant_theme,
          component_separators = { left = "", right = "" },
          section_separators = { left = "", right = "" },
          globalstatus = true,
          disabled_filetypes = {
            statusline = {},
            winbar = {},
          },
        },
        sections = {
          lualine_a = {
            {
              "mode",
              fmt = function(str)
                return " " .. str .. " "
              end,
            },
          },
          lualine_b = {
            {
              "branch",
              icon = "",
              color = { fg = colors.white, gui = "bold" },
            },
            {
              "diff",
              colored = true,
              diff_color = {
                added = { fg = colors.diff_add, gui = "bold" },
                modified = { fg = colors.diff_mod, gui = "bold" },
                removed = { fg = colors.diff_del, gui = "bold" },
              },
            },
            {
              "diagnostics",
              sources = { "nvim_diagnostic" },
              symbols = { error = " ", warn = " ", info = " ", hint = " " },
              colored = true,
            },
          },
          lualine_c = {
            {
              "filename",
              path = 1, -- 1: relative path
              symbols = { modified = " ●", readonly = " ", unnamed = "[No Name]" },
              color = { fg = colors.white, gui = "bold" },
            },
          },
          lualine_x = {
            {
              agent_status,
              color = agent_color,
            },
            {
              "encoding",
              color = { fg = colors.fg_muted },
            },
            {
              "fileformat",
              color = { fg = colors.fg_muted },
            },
            {
              "filetype",
              colored = true,
            },
          },
          lualine_y = {
            {
              "progress",
              color = { fg = colors.fg_bright, gui = "bold" },
            },
          },
          lualine_z = {
            {
              "location",
              color = { fg = colors.white, gui = "bold" },
            },
          },
        },
        tabline = {
          lualine_a = {
            {
              "tabs",
              mode = 2, -- 2: index and name
              max_length = vim.o.columns,
              tabs_color = {
                active = { fg = colors.white, bg = colors.blue, gui = "bold" },
                inactive = { fg = colors.fg_muted, bg = colors.bg_section },
              },
            },
          },
          lualine_z = {
            {
              function()
                return "Tabs: <A-1>..<A-9> | <A-t> New | <A-]> Next"
              end,
              color = { fg = colors.fg_muted, bg = colors.bg_bar },
            },
          },
        },
      })
    end,
  },
}
