-- ==============================================================================
-- lsp.lua: Language Server Buffer Configuration & Lean Spec Engine
-- Auto-starts Lean 4 LSP for .lean files and annotates in-tree spec comments
-- with Lean 4 verification status directly in source code.
-- ==============================================================================

local ns_specs = vim.api.nvim_create_namespace("specs_inline_status")

vim.api.nvim_create_autocmd("LspAttach", {
  desc = "LSP keybindings and buffer attachments",
  callback = function(args)
    local opts = { buffer = args.buf, silent = true }
    vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)
    vim.keymap.set("n", "gD", vim.lsp.buf.declaration, opts)
    vim.keymap.set("n", "gr", vim.lsp.buf.references, opts)
    vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)
    vim.keymap.set("n", "[d", vim.diagnostic.goto_prev, opts)
    vim.keymap.set("n", "]d", vim.diagnostic.goto_next, opts)
  end,
})

-- Keep background diagnostic display clean and focused.
vim.diagnostic.config({
  signs = true,
  underline = false,
  virtual_text = false,
  virtual_lines = false,
  severity_sort = true,
  float = { border = "single", source = true, max_width = 80 },
})

-- 1. Auto-start Lean 4 Language Server for .lean files
vim.api.nvim_create_autocmd("FileType", {
  pattern = "lean",
  desc = "Start Lean 4 language server for .lean files",
  callback = function(args)
    local lean_bin = vim.fn.exepath("lean")
    if lean_bin == "" then
      lean_bin = vim.fn.expand("~/.elan/bin/lean")
    end
    if vim.fn.executable(lean_bin) == 1 then
      local root = vim.fs.root(args.buf, { "lakefile.lean", "lakefile.toml", "lean-toolchain", ".git" }) or vim.fn.getcwd()
      vim.lsp.start({
        name = "lean-lsp",
        cmd = { lean_bin, "--server" },
        root_dir = root,
      })
    end
  end,
})

local M = {}

return M
