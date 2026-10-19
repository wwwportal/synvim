return {
  {
    "nvim-tree/nvim-web-devicons",
    lazy = true,
  },
  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    event = "VeryLazy",
    config = function()
      local function agent_status()
        local ok, agent = pcall(require, "agent")
        if not ok then return "" end
        if agent.state.is_busy then
          return "● [Agent analyzing...]"
        elseif agent.state.pending_diff then
          return "● [DIFF: :Accept/:Reject]"
        elseif agent.state.queue and #agent.state.queue > 0 then
          return string.format("● [%d/%d] %s", agent.state.queue_index, #agent.state.queue, agent.state.queue[agent.state.queue_index] and agent.state.queue[agent.state.queue_index].path or "")
        end
        local lok, lgcc = pcall(require, "lgcc")
        if lok and lgcc.status then
          local s = lgcc.status()
          if s ~= "" then return s end
        end
        return "● Agent"
      end

      require("lualine").setup({
        options = {
          icons_enabled = true,
          theme = "auto",
          component_separators = { left = "│", right = "│" },
          section_separators = { left = "", right = "" },
          globalstatus = true,
          disabled_filetypes = {
            statusline = {},
            winbar = {},
          },
        },
        sections = {
          lualine_a = { "mode" },
          lualine_b = { "branch", "diff", "diagnostics" },
          lualine_c = {
            {
              "filename",
              path = 1, -- relative path
              symbols = { modified = " ●", readonly = " ", unnamed = "[No Name]" },
            },
          },
          lualine_x = {
            agent_status,
            "encoding",
            "fileformat",
            "filetype",
          },
          lualine_y = { "progress" },
          lualine_z = { "location" },
        },
        tabline = {
          lualine_a = {
            {
              "tabs",
              mode = 2, -- 0: just name, 1: index, 2: index and name
              max_length = vim.o.columns,
            },
          },
          lualine_z = {
            {
              function()
                return "Tabs: <A-1>..<A-9> | <A-t> New | <A-]> Next"
              end,
            },
          },
        },
      })
    end,
  },
}
