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

return M
