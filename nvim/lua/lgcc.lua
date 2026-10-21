-- ==============================================================================
-- lgcc.lua: Native Neovim Logical Compiler & Invariant Verifier
-- Tiered execution: Uses Antigravity (agy) until quota/limits run out,
-- allows agy to orchestrate opencode worker subagents, and automatically
-- fails over to opencode (OpenRouter) on quota exhaustion.
-- Streams intermediate reasoning tokens live to the command-line ticker
-- and routes verified errors to Quickfix on demand.
-- ==============================================================================

local M = {}

local active_job = nil
local ticker_timer = nil
local ns_lgcc = vim.api.nvim_create_namespace("lgcc_diagnostics")

-- Configure ns_lgcc diagnostics: completely disable underlines and default virtual text
vim.diagnostic.config({
  signs = true,
  underline = false,
  virtual_text = false,
  virtual_lines = false,
}, ns_lgcc)

-- Disable diagnostic underlines globally across all buffers and colorschemes
vim.api.nvim_set_hl(0, "DiagnosticUnderlineError", { underline = false, undercurl = false, sp = "NONE" })
vim.api.nvim_set_hl(0, "DiagnosticUnderlineWarn", { underline = false, undercurl = false, sp = "NONE" })
vim.api.nvim_set_hl(0, "DiagnosticUnderlineInfo", { underline = false, undercurl = false, sp = "NONE" })
vim.api.nvim_set_hl(0, "DiagnosticUnderlineHint", { underline = false, undercurl = false, sp = "NONE" })

-- Setup custom highlight groups
vim.api.nvim_set_hl(0, "LgccStreamGray", { fg = "#7e8294", italic = true, default = true })
vim.api.nvim_set_hl(0, "LgccSpinner", { fg = "#7aa2f7", bold = true, default = true })
vim.api.nvim_set_hl(0, "LgccInlineError", { fg = "#f7768e", bold = true, default = true })

-- Close quickfix window easily with 'q' or '<Esc>'
vim.api.nvim_create_autocmd("FileType", {
  pattern = "qf",
  callback = function(ev)
    vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = ev.buf, silent = true, nowait = true })
    vim.keymap.set("n", "<Esc>", "<Cmd>close<CR>", { buffer = ev.buf, silent = true, nowait = true })
  end,
})

--- Speak textual summary using piper TTS asynchronously
--- @param text string
local function speak_summary(text)
  if not text or text == "" then return end
  local piper_bin = vim.fn.expand("~/myenv/bin/piper")
  local model_path = vim.fn.expand("~/code/agent/vendor/voices/en_US-kristin-medium.onnx")
  if vim.fn.executable(piper_bin) ~= 1 or not vim.uv.fs_stat(model_path) then
    return
  end
  local text_path = "/tmp/lgcc_speech_text.txt"
  local wav_path = "/tmp/lgcc_speech.wav"
  vim.fn.writefile({ text }, text_path)
  local cmd = string.format(
    "%s -m %s -i %s -f %s --sentence-silence 0.2 2>/dev/null && aplay -q %s 2>/dev/null",
    piper_bin, model_path, text_path, wav_path, wav_path
  )
  vim.fn.jobstart({ "sh", "-c", cmd })
end

local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local split_status = {} -- bufnr -> { state = "running"|"error"|"clean", engine = "...", tail = "...", count = N, frame = 1 }

--- Return formatted status for the split window's bottom bar (statusline)
--- @param winid? number
--- @return string
function M.status(winid)
  winid = winid or vim.g.statusline_winid or vim.api.nvim_get_current_win()
  if not winid or not vim.api.nvim_win_is_valid(winid) then return "" end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local info = split_status[bufnr]
  if not info then return "" end

  local win_w = vim.api.nvim_win_get_width(winid)
  if info.state == "running" then
    local spin = spinner[info.frame or 1]
    local prefix = string.format("%s [lgcc:%s] ", spin, info.engine or "agy")
    local max_tail = math.max(10, math.floor(win_w * 0.40) - #prefix)
    local tail = info.tail or "analyzing..."
    if #tail > max_tail then
      tail = "..." .. tail:sub(#tail - max_tail + 4)
    end
    return string.format("%%#LgccSpinner#%s%%*%%#LgccStreamGray#%s%%* ", prefix, tail)
  elseif info.state == "error" then
    return string.format("%%#DiagnosticError#● [lgcc:%s] %d error%s%%* ", info.engine or "agy", info.count or 0, (info.count == 1 and "" or "s"))
  elseif info.state == "clean" then
    return string.format("%%#DiagnosticOk#✓ [lgcc:%s] clean%%* ", info.engine or "agy")
  end
  return ""
end

--- Start the animated status ticker on the split's bottom bar
--- @param bufnr number
--- @param filename string
--- @param engine? string "agy" | "opencode" | "local"
local function start_ticker(bufnr, filename, engine)
  engine = engine or "agy"
  if ticker_timer then
    pcall(function() ticker_timer:stop(); ticker_timer:close() end)
    ticker_timer = nil
  end

  local frame = 1
  split_status[bufnr] = {
    state = "running",
    engine = engine,
    filename = filename,
    tail = "dispatching...",
    frame = 1,
  }

  local state = {
    engine = engine,
    raw_tail = "starting...",
  }

  local function render()
    frame = (frame % #spinner) + 1
    if split_status[bufnr] then
      split_status[bufnr].frame = frame
      split_status[bufnr].engine = state.engine
      split_status[bufnr].tail = state.raw_tail
    end
    vim.cmd("redrawstatus")
  end

  state.render = render

  ticker_timer = vim.uv.new_timer()
  ticker_timer:start(0, 80, vim.schedule_wrap(function()
    if not ticker_timer then return end
    render()
  end))

  vim.cmd("redrawstatus")
  return state
end

--- Stop the animated status ticker
local function stop_ticker()
  if ticker_timer then
    pcall(function() ticker_timer:stop(); ticker_timer:close() end)
    ticker_timer = nil
  end
end

--- Parse LLM diagnostic output into Quickfix items
--- @param raw string
--- @param filepath string
local function parse_diagnostics(raw, filepath)
  local qf_items = {}
  for line in raw:gmatch("[^\r\n]+") do
    -- Standard format: <file>:<line>:<col>: error: <msg> or <file>:<line>: error: <msg>
    local file, lnum, col, msg = line:match("^([^:]+):(%d+):(%d*):%s*error:%s*(.+)$")
    if not lnum then
      file, lnum, msg = line:match("^([^:]+):(%d+):%s*error:%s*(.+)$")
    end

    -- Alt format: [line N] msg or Line N: msg
    if not lnum then
      local lnum_alt, msg_alt = line:match("^%[?line%s*(%d+)%]?%s*:?%s*(.+)$")
      if lnum_alt then
        file = filepath
        lnum = lnum_alt
        msg = msg_alt
      end
    end

    if lnum and msg then
      table.insert(qf_items, {
        filename = (file and file ~= "") and file or filepath,
        lnum = tonumber(lnum),
        col = tonumber(col) or 1,
        text = vim.trim(msg),
        type = "E",
      })
    end
  end
  return qf_items
end

--- Locate native lgcc Rust binary
local function find_lgcc_bin()
  local exepath = vim.fn.exepath("lgcc")
  if exepath ~= "" and vim.fn.executable(exepath) == 1 then
    return exepath
  end
  local candidates = {
    vim.fn.expand("~/code/synvim/bin/lgcc"),
    vim.fn.expand("~/code/syn-nvim/bin/lgcc"),
    vim.fn.expand("~/code/syntra-nvim/bin/lgcc"),
    vim.fn.expand("~/.local/bin/lgcc"),
    vim.fn.expand("~/.config/nvim/bin/lgcc"),
    "/usr/local/bin/lgcc",
    "/usr/bin/lgcc",
  }
  for _, p in ipairs(candidates) do
    if vim.fn.executable(p) == 1 or vim.uv.fs_stat(p) then return p end
  end
  return nil
end

--- Known model context windows and budget profiles
local ENGINE_BUDGET_PROFILES = {
  ["local"] = {
    max_context = 8192,
    headroom = 2048, -- reserve for model reasoning/generation output
    default_dep_budget = 2048,
  },
  ["opencode"] = {
    max_context = 64000,
    headroom = 8000,
    default_dep_budget = 16000,
  },
  ["agy"] = {
    max_context = 128000,
    headroom = 16000,
    default_dep_budget = 8000,
  },
}

--- Calculate optimal dependency context budget dynamically based on model window
local function get_automatic_budget(engine, target_file_chars, user_budget)
  if user_budget and user_budget > 0 then
    return user_budget
  end
  local prof = ENGINE_BUDGET_PROFILES[engine] or ENGINE_BUDGET_PROFILES["agy"]
  local target_tokens = math.max(1, math.floor(target_file_chars / 4))
  local available = prof.max_context - target_tokens - prof.headroom
  if available < 500 then
    return 500
  end
  return math.min(available, prof.default_dep_budget)
end

--- Run native logical compiler on target file, directory, or active buffer
--- @param opts? { file?: string, spec?: string, engine?: string, speak?: boolean, bundle?: boolean, budget?: number, bufnr?: number }
function M.lint(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local origin_win = opts.win or vim.api.nvim_get_current_win()
  local filepath = (opts.file and opts.file ~= "") and vim.fn.expand(opts.file) or vim.api.nvim_buf_get_name(bufnr)

  local stat = (filepath ~= "") and vim.uv.fs_stat(filepath) or nil
  if filepath == "" or not stat then
    vim.notify("lgcc: Target path not found or buffer not saved: " .. (filepath ~= "" and filepath or "[unnamed]"), vim.log.levels.WARN)
    return
  end
  local is_dir = (stat.type == "directory")

  -- Cancel existing job if running
  if active_job then
    pcall(function() active_job:kill(9) end)
    active_job = nil
  end

  -- Auto-save if buffer is modified and modifiable
  if not is_dir and bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
    if vim.api.nvim_get_option_value("modifiable", { buf = bufnr }) and vim.api.nvim_get_option_value("buftype", { buf = bufnr }) == "" then
      vim.cmd("silent! write")
    end
  end

  local lines = is_dir and {} or vim.fn.readfile(filepath)
  local target_chars = is_dir and 0 or #table.concat(lines, "\n")
  local initial_engine = opts.engine or "agy"
  local auto_budget = get_automatic_budget(initial_engine, target_chars, opts.budget)

  -- Assemble source code or hermetic Code Graph dependency bundle
  -- SPEC(lgcc-compressed-ir | tier:B | status:APPROVED | blocks:[lgcc-project-scan]):
  --   action:    Implement a compact AST/interface representation (symbol dependency graph and skeletonized type stubs) to keep full repository context in the model's active window without blowing up token limits.
  --   requires:  [lgcc-cli-router-hook]
  --   ensures:   review: "Intermediate representation compacts multi-file repository context by >70% while retaining all exported types, signatures, and call invariants"
  --   invariant: "Compressed representation preserves all exported function signatures"
  --   modifies:  [nvim/lua/lgcc.lua]
  -- [lean:spec]
  -- def lgcc_compressed_ir : Bool := lgcc_cli_router_hook
  -- theorem lgcc_compressed_ir_verified : lgcc_compressed_ir = true := by rfl
  local code_section = ""
  local used_budget = nil

  -- Enable smart Code Graph routing by default or when bundle/directory mode is active
  if is_dir or opts.bundle ~= false then
    local lgcc_bin = find_lgcc_bin()
    if lgcc_bin then
      local res = vim.system({ lgcc_bin, "--route", filepath, "--budget", tostring(auto_budget), "--format", "ir" }, { text = true }):wait()
      if res.code == 0 and res.stdout and res.stdout ~= "" then
        code_section = res.stdout
        used_budget = auto_budget
      end
    end
  end

  if code_section == "" and not is_dir then
    local numbered_lines = {}
    for i, line in ipairs(lines) do
      table.insert(numbered_lines, string.format("%d: %s", i, line))
    end
    code_section = string.format("--- SOURCE CODE (prefixed with line numbers) ---\n%s\n\nFile: %s",
      table.concat(numbered_lines, "\n"), filepath)
  end

  -- Build prompt
  local spec_section = ""
  if opts.spec and opts.spec ~= "" then
    local spec_path = vim.fn.expand(opts.spec)
    if vim.fn.filereadable(spec_path) == 1 then
      spec_section = string.format("--- SPECIFICATION DOCUMENT ---\n%s\n\n", table.concat(vim.fn.readfile(spec_path), "\n"))
    end
  end

  local system_prompt = [[CRITICAL INSTRUCTION: You are the Logical Compiler (lgcc).
Do NOT call any tools or commands (do NOT run view_file, grep, or bash). All context is provided below.
Analyze the provided source code, Code Graph IR, and Task Graph specifications for semantic bugs, invariant violations, and cross-module logical flaws.
- CODE GRAPH TOPOLOGY G=(V, E) provides the symbol call graph, type edges, and line ranges across the repository.
- TASK GRAPH FORMAL SPECIFICATIONS & INVARIANTS provides the formal `SPEC` contracts, acceptance criteria, and LexLean theorems that the code must satisfy.
- ROUTED INTERFACE CONTRACTS provides the skeletonized module interfaces and full implementations of high-centrality dependencies.
Ignore syntax, formatting, and naming conventions.
Output your verdict immediately in this turn.
If flaws or specification violations exist, output each strictly on its own line in this format:
<file>:<line>: error: <clear description of logical flaw or invariant violation>
If there are no logic errors, output: CLEAN]]

  local full_prompt = string.format("%s\n\n%s%s", system_prompt, spec_section, code_section)

  local clean_path = filepath:gsub("/+$", "")
  local file_basename = is_dir and (vim.fn.fnamemodify(clean_path, ":t") .. "/") or vim.fn.fnamemodify(clean_path, ":t")
  local budget_label = used_budget and string.format(" [+%dtok]", used_budget) or (opts.bundle and " [+deps]" or "")
  local state = start_ticker(bufnr, file_basename .. budget_label, initial_engine)

  local function execute_run(engine_name)
    state.engine = engine_name
    if split_status[bufnr] then
      split_status[bufnr].engine = engine_name
    end
    local agy_model = opts.model or "gemini-3.8-flash-low"
    state.raw_tail = "dispatching to " .. engine_name .. " (" .. agy_model .. ")..."
    vim.cmd("redrawstatus")

    local cmd = {}
    if engine_name == "agy" then
      cmd = { "agy", "-p", full_prompt, "--model", agy_model, "--dangerously-skip-permissions", "--disable-slash-commands", "--effort", "low", "--output-format", "stream-json" }
    elseif engine_name == "opencode" then
      cmd = { "opencode", "run", "--auto", full_prompt }
    else
      -- Local fallback
      local model = vim.fn.expand("~/code/agent/vendor/models/qwen2.5-coder-7b/qwen2.5-coder-7b-instruct-q6_k.gguf")
      cmd = { "llama-cli", "-m", model, "-ngl", "12", "-t", "8", "-c", "8192", "--temp", "0.0", "-p", full_prompt }
    end

    local stdout_chunks = {}
    local stderr_chunks = {}
    local model_output = ""
    local job_timeout = nil

    -- 35-second hard timeout guard to prevent hangs
    job_timeout = vim.uv.new_timer()
    job_timeout:start(35000, 0, vim.schedule_wrap(function()
      if active_job then
        vim.notify("lgcc: " .. engine_name .. " reasoning timed out after 35s. Cancelling.", vim.log.levels.WARN)
        pcall(function() active_job:kill(9) end)
        active_job = nil
        stop_ticker()
      end
      if job_timeout then
        pcall(function() job_timeout:stop(); job_timeout:close() end)
        job_timeout = nil
      end
    end))

    active_job = vim.system(cmd, {
      text = true,
      stdout = function(_, data)
        if not data then return end
        table.insert(stdout_chunks, data)

        -- Stream ONLY the model's generated output tokens (never input code/ast/tools)
        local updated = false
        for line in data:gmatch("[^\r\n]+") do
          local delta = line:match('"text_delta"%s*:%s*"(.-)"')
          if delta then
            delta = delta:gsub("\\n", " "):gsub('\\"', '"'):gsub("\\\\", "\\")
            model_output = model_output .. delta
            updated = true
          elseif engine_name ~= "agy" and not line:find('^{"event"') then
            local clean = line:gsub("\27%[[0-9;]*[a-zA-Z]", ""):gsub("[\r\n]+", " "):gsub("%s+", " "):gsub("^%s+", "")
            if clean ~= "" and not clean:find("^--- SOURCE") and not clean:find("^--- INTERFACE") and not clean:find("^TARGET FILE") then
              model_output = model_output .. " " .. clean
              updated = true
            end
          end
        end

        if updated then
          state.raw_tail = model_output
          vim.schedule(function()
            if ticker_timer and state.render then
              state.render()
            end
          end)
        end
      end,
      stderr = function(_, data)
        if not data then return end
        table.insert(stderr_chunks, data)
        -- Never leak stderr debug or compiler startup logs into ticker
      end,
    }, function(res)
      active_job = nil
      if job_timeout then
        pcall(function() job_timeout:stop(); job_timeout:close() end)
        job_timeout = nil
      end

      local raw_out = table.concat(stdout_chunks, "")
      local out = ""
      -- Extract final response from stream-json if present
      for line in raw_out:gmatch("[^\r\n]+") do
        local resp = line:match('"response"%s*:%s*"(.-)"')
        if resp then
          out = out .. resp:gsub("\\n", "\n"):gsub('\\"', '"'):gsub("\\\\", "\\")
        end
      end
      if out == "" then
        out = raw_out
      end

      -- Failover condition: If agy failed (exit non-zero, quota exceeded, or empty output)
      local is_quota_error = out:match("RESOURCE_EXHAUSTED") or out:match("quota") or out:match("429") or out:match("Rate limit")
      if engine_name == "agy" and (res.code ~= 0 or is_quota_error or vim.trim(out) == "") then
        vim.schedule(function()
          if agy_model:find("argon") then
            vim.notify("lgcc: Argon quota reached, falling back to gemini-3.8-flash-low...", vim.log.levels.WARN)
            opts.model = "gemini-3.8-flash-low"
            execute_run("agy")
          elseif agy_model:find("flash") then
            vim.notify("lgcc: Flash quota reached, falling back to claude-sonnet-5-5-low...", vim.log.levels.WARN)
            opts.model = "claude-sonnet-5-5-low"
            execute_run("agy")
          else
            vim.notify("lgcc: agy quota reached, failing over to opencode...", vim.log.levels.WARN)
            execute_run("opencode")
          end
        end)
        return
      end

      vim.schedule(function()
        stop_ticker()

        -- Clear previous in-line diagnostics
        vim.diagnostic.reset(ns_lgcc)
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          pcall(vim.api.nvim_buf_clear_namespace, b, ns_lgcc, 0, -1)
        end

        local qf_items = parse_diagnostics(out, filepath)

        if #qf_items > 0 then
          local diags_by_buf = {}
          for _, item in ipairs(qf_items) do
            local fname = item.filename
            local b = vim.fn.bufnr(fname)
            if b == -1 or not vim.api.nvim_buf_is_loaded(b) then
              b = vim.fn.bufadd(fname)
              pcall(vim.fn.bufload, b)
            end
            diags_by_buf[b] = diags_by_buf[b] or {}
            local lnum = math.max(0, (item.lnum or 1) - 1)
            table.insert(diags_by_buf[b], {
              bufnr = b,
              lnum = lnum,
              col = math.max(0, (item.col or 1) - 1),
              severity = vim.diagnostic.severity.ERROR,
              source = "lgcc:" .. engine_name,
              message = item.text,
            })

            -- Wrap error text based on the actual target split window width (not full columns)
            local wins = vim.fn.win_findbuf(b)
            local min_w = 999
            for _, w in ipairs(wins) do
              if vim.api.nvim_win_is_valid(w) then
                min_w = math.min(min_w, vim.api.nvim_win_get_width(w))
              end
            end
            if min_w == 999 then
              min_w = (origin_win and vim.api.nvim_win_is_valid(origin_win) and vim.api.nvim_win_get_width(origin_win)) or vim.api.nvim_win_get_width(0)
            end
            local win_w = min_w

            -- Clean subtle prefix: 2 spaces, vertical bar, 1 space (total 4 cols)
            local prefix = "  │ "
            -- Reserve gutter columns: number column (~5) + sign column (2) + split border/margin (3) = 10 cols
            local gutter = 10
            local max_w = math.max(15, win_w - gutter - #prefix - 2)

            local wrapped_lines = {}
            for raw_line in item.text:gmatch("[^\r\n]+") do
              local current = ""
              for word in raw_line:gmatch("%S+") do
                while #word > max_w do
                  if current ~= "" then
                    table.insert(wrapped_lines, current)
                    current = ""
                  end
                  table.insert(wrapped_lines, word:sub(1, max_w))
                  word = word:sub(max_w + 1)
                end
                if word ~= "" then
                  if current == "" then
                    current = word
                  elseif #current + 1 + #word <= max_w then
                    current = current .. " " .. word
                  else
                    table.insert(wrapped_lines, current)
                    current = word
                  end
                end
              end
              if current ~= "" then
                table.insert(wrapped_lines, current)
              end
            end
            if #wrapped_lines == 0 then
              table.insert(wrapped_lines, item.text)
            end

            local virt_lines = {}
            for _, wline in ipairs(wrapped_lines) do
              table.insert(virt_lines, { { prefix .. wline, "DiagnosticError" } })
            end

            pcall(vim.api.nvim_buf_set_extmark, b, ns_lgcc, lnum, 0, {
              virt_lines = virt_lines,
              virt_lines_above = false,
            })
          end

          for b, diags in pairs(diags_by_buf) do
            vim.diagnostic.set(ns_lgcc, b, diags, {
              signs = true,
              underline = false,
              virtual_text = false,
            })
            split_status[b] = {
              state = "error",
              engine = engine_name,
              count = #diags,
            }
          end

          vim.fn.setqflist(qf_items, "r")
          vim.fn.setqflist({}, "a", { title = string.format("lgcc [%s]: %s (%d logical errors)", engine_name, file_basename, #qf_items) })
          if opts.qf then
            vim.cmd("botright copen 8")
          end

          if opts.speak then
            local summary = string.format("Logical compiler found %d error%s in %s. First error at line %d: %s",
              #qf_items, #qf_items == 1 and "" or "s", file_basename, qf_items[1].lnum, qf_items[1].text)
            speak_summary(summary)
          end
        else
          pcall(vim.cmd, "cclose")
          vim.fn.setqflist({}, "r")
          split_status[bufnr] = {
            state = "clean",
            engine = engine_name,
          }

          if opts.speak then
            speak_summary("Logical compiler check clean. No logical errors found in " .. file_basename)
          end
        end
        vim.cmd("redrawstatus")
      end)
    end)
  end

  execute_run(initial_engine)
end

--- Clear lgcc results and remove in-line diagnostics
function M.clear()
  local was_running = active_job ~= nil
  if active_job then
    pcall(function() active_job:kill(9) end)
    active_job = nil
  end
  stop_ticker()
  pcall(vim.cmd, "cclose")
  vim.fn.setqflist({}, "r")
  vim.diagnostic.reset(ns_lgcc)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    pcall(vim.api.nvim_buf_clear_namespace, b, ns_lgcc, 0, -1)
    split_status[b] = nil
  end
  vim.cmd("redrawstatus")
end

M.cancel = M.clear
M.stop = M.clear

-- SPEC(lgcc-cli-router-hook | tier:B | status:APPROVED | blocks:[lgcc-compressed-ir]):
--   action:    Integrate bundle_ir.py --route --budget into lgcc.lua with optional --budget argument for dynamic context allocation.
--   requires:  [ir-schema-formatter]
--   ensures:   review: ":Lgcc --budget 4000 dynamically queries router and passes knapsack-allocated IR context"
--   invariant: "Context allocation strictly respects active token budget"
--   modifies:  [nvim/lua/lgcc.lua]
-- [lean:spec]
-- def lgcc_cli_router_hook : Bool := ir_schema_formatter
-- theorem lgcc_cli_router_hook_verified : lgcc_cli_router_hook = true := by rfl


-- SPEC(lgcc-project-scan | tier:C | status:APPROVED):
--   action:    Extend lgcc to scan entire directories and multi-file projects using the compressed intermediate representation to detect cross-module invariant violations and systemic flaws.
--   requires:  [lgcc-compressed-ir]
--   ensures:   review: "lgcc directory execution passes compressed project context and populates Quickfix with multi-file error locations"
--   invariant: "Multi-file scan terminates and populates quickfix without UI freezes"
--   modifies:  [nvim/lua/lgcc.lua]
-- [lean:spec]
-- def lgcc_project_scan : Bool := lgcc_compressed_ir
-- theorem lgcc_project_scan_verified : lgcc_project_scan = true := by rfl

return M
