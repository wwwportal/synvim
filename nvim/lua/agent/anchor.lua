-- ==============================================================================
-- agent/anchor.lua: Language-Agnostic Context-Hunk and Anti-Duplication Anchor
-- Uses native C++ FFI (libsynvim_anchor.so) with fast string_view sliding window
-- and duplicate sentinels to locate edit positions regardless of line drift.
-- ==============================================================================

local M = {}
local ffi = require("ffi")

-- Declare C ABI signature
ffi.cdef[[
  typedef struct {
    int start_line;
    int end_line;
    double confidence;
    int is_already_applied;
    int duplicate_line;
    char match_mode[32];
  } SynvimAnchorResult;

  SynvimAnchorResult synvim_find_context_anchor(
    const char* buffer_text,
    const char* context_before,
    const char* target_lines,
    const char* context_after,
    const char* new_lines,
    const char* identifier_slug
  );

  int synvim_find_nearest_block(
    const char* buffer_text,
    const char* block_text,
    int hint_line,
    int normalize_ws
  );

  int synvim_find_task_line(
    const char* buffer_text,
    const char* task_slug,
    int hint_line
  );

  typedef struct {
    int start_line;
    int line_count;
    int has_contract;
  } SynvimTaskBlockSpan;

  SynvimTaskBlockSpan synvim_find_task_block_span(
    const char* buffer_text,
    int start_line,
    const char* task_slug
  );

  const char* synvim_anchor_version(void);
]]

-- Search candidate paths for libsynvim_anchor.so
local function find_anchor_library()
  local candidates = {
    -- 1. Project build directory
    vim.fn.getcwd() .. "/build/libsynvim_anchor.so",
    -- 2. Git root build directory
    (function()
      local git_root = vim.fs.root(0, { ".git" })
      return git_root and (git_root .. "/build/libsynvim_anchor.so") or nil
    end)(),
    -- 3. User local library directory
    vim.fn.expand("~/.local/lib/libsynvim_anchor.so"),
    -- 4. Neovim config directory
    vim.fn.stdpath("config") .. "/build/libsynvim_anchor.so",
    -- 5. Standard system paths
    "/usr/local/lib/libsynvim_anchor.so",
    "libsynvim_anchor.so",
  }

  for _, path in ipairs(candidates) do
    if path and (vim.fn.filereadable(path) == 1 or path == "libsynvim_anchor.so") then
      local ok, handle = pcall(ffi.load, path)
      if ok and handle then
        return handle
      end
    end
  end

  local ok, handle = pcall(ffi.load, "libsynvim_anchor.so")
  if ok and handle then
    return handle
  end

  return nil
end

local lib_anchor = find_anchor_library()

--- Check if the native Anchor FFI engine is loaded
function M.is_available()
  return lib_anchor ~= nil
end

--- Get anchor engine version
function M.version()
  if not lib_anchor then
    return "fallback-lua"
  end
  return ffi.string(lib_anchor.synvim_anchor_version())
end

--- Format input string or table of lines into newline-delimited string
local function to_str(val)
  if type(val) == "table" then
    return table.concat(val, "\n")
  elseif type(val) == "string" then
    return val
  else
    return ""
  end
end

--- Find context anchor position and duplicate check in buffer
-- @param buffer_text string or bufnr or table of lines
-- @param opts table:
--   context_before: string or table of lines
--   target_lines: string or table of lines
--   context_after: string or table of lines
--   new_lines: string or table of lines
--   identifier_slug: string (e.g. task ID or function name)
-- @return table { start_line, end_line, confidence, is_already_applied, duplicate_line, match_mode }
function M.find_anchor(buffer_text, opts)
  opts = opts or {}

  -- Resolve buffer_text if a bufnr was passed
  local text_str = ""
  if type(buffer_text) == "number" and vim.api.nvim_buf_is_valid(buffer_text) then
    local lines = vim.api.nvim_buf_get_lines(buffer_text, 0, -1, false)
    text_str = table.concat(lines, "\n")
  elseif type(buffer_text) == "table" then
    text_str = table.concat(buffer_text, "\n")
  elseif type(buffer_text) == "string" then
    text_str = buffer_text
  end

  local before_str = to_str(opts.context_before)
  local target_str = to_str(opts.target_lines)
  local after_str = to_str(opts.context_after)
  local new_str = to_str(opts.new_lines)
  local slug_str = opts.identifier_slug or ""

  if lib_anchor then
    local res = lib_anchor.synvim_find_context_anchor(
      text_str,
      before_str,
      target_str,
      after_str,
      new_str,
      slug_str
    )

    return {
      start_line = res.start_line,
      end_line = res.end_line,
      confidence = res.confidence,
      is_already_applied = (res.is_already_applied == 1),
      duplicate_line = (res.duplicate_line > 0) and res.duplicate_line or nil,
      match_mode = ffi.string(res.match_mode),
    }
  end

  -- Fallback in pure Lua if native library is unavailable
  return M.fallback_find_anchor(text_str, before_str, target_str, after_str, new_str, slug_str)
end

--- Pure Lua fallback implementation
function M.fallback_find_anchor(buffer_text, context_before, target_lines, context_after, new_lines, identifier_slug)
  local buf_lines = vim.split(buffer_text or "", "\n")
  local total_lines = #buf_lines
  local res = {
    start_line = 1,
    end_line = 1,
    confidence = 0.0,
    is_already_applied = false,
    duplicate_line = nil,
    match_mode = "none",
  }

  -- 1. Check duplicate slug
  if identifier_slug and identifier_slug ~= "" and identifier_slug ~= "task" then
    for idx, l in ipairs(buf_lines) do
      if l:find(identifier_slug, 1, true) then
        res.duplicate_line = idx
        break
      end
    end
  end

  -- 2. Check if new_lines is already applied
  local new_list = vim.split(new_lines or "", "\n")
  if #new_list > 0 and new_list[1] ~= "" then
    for i = 1, total_lines - #new_list + 1 do
      local matched = true
      for k = 1, #new_list do
        if vim.trim(buf_lines[i + k - 1]) ~= vim.trim(new_list[k]) then
          matched = false
          break
        end
      end
      if matched then
        res.start_line = i
        res.end_line = i + #new_list - 1
        res.confidence = 1.0
        res.is_already_applied = true
        res.match_mode = "already_applied"
        return res
      end
    end
  end

  -- 3. Check target lines
  local tgt_list = vim.split(target_lines or "", "\n")
  if #tgt_list > 0 and tgt_list[1] ~= "" then
    for i = 1, total_lines - #tgt_list + 1 do
      local matched = true
      for k = 1, #tgt_list do
        if vim.trim(buf_lines[i + k - 1]) ~= vim.trim(tgt_list[k]) then
          matched = false
          break
        end
      end
      if matched then
        res.start_line = i
        res.end_line = i + #tgt_list - 1
        res.confidence = 0.95
        res.match_mode = "exact_target"
        return res
      end
    end
  end

  -- 4. Fallback to duplicate snap
  if res.duplicate_line then
    res.start_line = res.duplicate_line
    res.end_line = res.duplicate_line
    res.confidence = 0.85
    res.match_mode = "duplicate_snap"
    return res
  end

  return res
end

--- Locate the 1-based start line of `block` inside `buffer_text` closest to `hint_line`
--- Uses the native C++ LuaJIT FFI engine (`synvim_find_nearest_block`) when available.
function M.find_nearest_block(buffer_text, block_text, hint_line, normalize_ws)
  local buf_str = to_str(buffer_text)
  local blk_str = to_str(block_text)
  if buf_str == "" or blk_str == "" then return nil end
  hint_line = tonumber(hint_line) or 1
  local norm_flag = (normalize_ws == false) and 0 or 1

  if lib_anchor then
    local ok, line_1 = pcall(function()
      return lib_anchor.synvim_find_nearest_block(buf_str, blk_str, hint_line, norm_flag)
    end)
    if ok and line_1 then
      return (line_1 > 0) and line_1 or nil
    end
  end

  -- Pure Lua fallback
  local lines = (type(buffer_text) == "table") and buffer_text or vim.split(buf_str, "\n")
  local block = (type(block_text) == "table") and block_text or vim.split(blk_str, "\n")
  if #block == 0 or #block > #lines then return nil end
  local best, best_d = nil, math.huge
  for i = 1, #lines - #block + 1 do
    if lines[i] == block[1] then
      local m = true
      for k = 2, #block do
        if lines[i + k - 1] ~= block[k] then m = false; break end
      end
      if m then
        local d = math.abs(i - hint_line)
        if d < best_d then best, best_d = i, d end
      end
    end
  end
  if best or norm_flag == 0 then return best end
  for i = 1, #lines - #block + 1 do
    if vim.trim(lines[i]) == vim.trim(block[1]) then
      local m = true
      for k = 2, #block do
        if vim.trim(lines[i + k - 1]) ~= vim.trim(block[k]) then m = false; break end
      end
      if m then
        local d = math.abs(i - hint_line)
        if d < best_d then best, best_d = i, d end
      end
    end
  end
  return best
end

--- Locate the 1-based line number of a task comment matching `task_slug` closest to `hint_line`
function M.find_task_line(buffer_text, task_slug, hint_line)
  if not task_slug or task_slug == "" or task_slug == "task" then return nil end
  local buf_str = to_str(buffer_text)
  if buf_str == "" then return nil end
  hint_line = tonumber(hint_line) or 1

  if lib_anchor then
    local ok, line_1 = pcall(function()
      return lib_anchor.synvim_find_task_line(buf_str, task_slug, hint_line)
    end)
    if ok and line_1 then
      return (line_1 > 0) and line_1 or nil
    end
  end

  local lines = (type(buffer_text) == "table") and buffer_text or vim.split(buf_str, "\n")
  local slug_low = task_slug:lower()
  local best, best_d = nil, math.huge
  for i, l in ipairs(lines) do
    local ll = l:lower()
    if ll:find(slug_low, 1, true) and (ll:find("todo(") or ll:find("spec(") or ll:find("contract(") or ll:find("fixme(")) then
      local d = math.abs(i - hint_line)
      if d < best_d then best, best_d = i, d end
    end
  end
  return best
end

--- Compute the exact multi-line span of a single task comment block starting at `start_line` (1-based)
--- Uses the native C++ LuaJIT FFI engine (`synvim_find_task_block_span`) when available.
--- Strictly stops before any subsequent distinct task header (TODO/FIXME/SPEC/CONTRACT).
--- @param buffer_text string|table|number
--- @param start_line integer (1-based)
--- @param task_slug string|nil
--- @return table { start_line = int, line_count = int, has_contract = boolean }
function M.find_task_block_span(buffer_text, start_line, task_slug)
  local text_str = ""
  local lines = nil
  if type(buffer_text) == "number" and vim.api.nvim_buf_is_valid(buffer_text) then
    lines = vim.api.nvim_buf_get_lines(buffer_text, 0, -1, false)
    text_str = table.concat(lines, "\n")
  elseif type(buffer_text) == "table" then
    lines = buffer_text
    text_str = table.concat(lines, "\n")
  elseif type(buffer_text) == "string" then
    text_str = buffer_text
  end

  start_line = tonumber(start_line) or 1
  local slug_str = task_slug or ""

  if lib_anchor and text_str ~= "" then
    local ok, span = pcall(function()
      return lib_anchor.synvim_find_task_block_span(text_str, start_line, slug_str)
    end)
    if ok and span then
      return {
        start_line = span.start_line,
        line_count = math.max(1, span.line_count),
        has_contract = (span.has_contract == 1),
      }
    end
  end

  -- Pure Lua fallback
  lines = lines or vim.split(text_str, "\n")
  local count = 1
  local has_contract = false
  local cur_slug = (slug_str ~= "" and slug_str) or (lines[start_line] and lines[start_line]:match("%(([a-zA-Z0-9_%-]+)")) or nil
  local j = start_line + 1
  while j <= #lines do
    local l = vim.trim(lines[j])
    local next_slug = l:match("^[#/%-%*%\"]+%s*[A-Z]+%(([a-zA-Z0-9_%-]+)")
    local is_any_task_header = (next_slug ~= nil) or (l:match("^[#/%-%*%\"]+%s*(TODO|FIXME|SPEC|CONTRACT):") ~= nil)
    if is_any_task_header then
      if cur_slug and cur_slug ~= "task" and next_slug and cur_slug:lower() == next_slug:lower() then
        count = count + 1
        j = j + 1
      else
        break
      end
    elseif l:find("^[#/%-]+%s*%[")
      or l:find("^[#/%-]+%s*[Dd]escription:")
      or l:find("^[#/%-]+%s*[Cc]riterion:")
      or l:find("^[#/%-]+%s*[Aa]ction:")
      or l:find("^[#/%-]+%s*[Rr]equires:")
      or l:find("^[#/%-]+%s*[Ee]nsures:")
      or l:find("^[#/%-]+%s*[Ii]nvariant:")
      or l:find("^[#/%-]+%s*[Mm]odifies:")
      or l:find("^[#/%-]+%s*[Aa]llow:")
      or l:find("^[#/%-]+%s*[Ff]orbid:")
      or l:find("^[#/%-]+%s*[Dd]eny:")
      or l:find("^[#/%-]+%s*[Aa]lways:")
      or l:find("^[#/%-]+%s*[Rr]epair:")
      or l:find("^[#/%-]+%s*[Cc][Tt][Dd]:")
      or l:find("^[#/%-]+%s*[Ss]tatus:")
      or l:find("^[#/%-]+%s*def%s+")
      or l:find("^[#/%-]+%s*theorem%s+")
      or l:find("^[#/%-]+%s*inductive%s+")
      or l:find("^[#/%-]+%s*structure%s+")
      or l:find("^[#/%-]+%s*|%s+")
      or l:find("^[#/%-]+%s*[-*]")
    then
      has_contract = true
      count = count + 1
      j = j + 1
    elseif l:match("^[#/%-]+%s*$") and j + 1 <= #lines and vim.trim(lines[j + 1]):match("^[#/%-]+%s*%[") then
      count = count + 1
      j = j + 1
    else
      break
    end
  end
  return {
    start_line = start_line,
    line_count = count,
    has_contract = has_contract,
  }
end

return M
