-- ==============================================================================
-- agent/dtl.lua: Deontic Temporal Logic (DTL) Verification via LuaJIT FFI
-- Provides microsecond in-process validation of agent patch permissions (P),
-- prohibitions (F), temporal invariants (Box), and DAG cycle detection.
-- ==============================================================================

local M = {}
local ffi = require("ffi")

-- Declare C ABI signatures
ffi.cdef[[
  typedef enum {
    DTL_OK              = 0,
    DTL_ERR_PROHIBITION = 1,
    DTL_ERR_PERMISSION  = 2,
    DTL_ERR_INVARIANT   = 3,
    DTL_ERR_CYCLE       = 4,
    DTL_ERR_SYNTAX      = 5
  } DtlStatusCode;

  typedef struct {
    DtlStatusCode code;
    const char* message;
    const char* ctd_action;
  } DtlValidationResult;

  typedef struct {
    DtlStatusCode code;
    const char* sorted_ids_json;
    const char* cycle_task_id;
  } DtlDagResult;

  DtlValidationResult dtl_validate_patch(
    const char* task_json,
    const char* target_file,
    const char* patch_diff
  );

  DtlDagResult dtl_sort_task_dag(const char* tasks_json);

  const char* dtl_version(void);
]]

-- Search candidate paths for libsynvim_dtl.so
local function find_dtl_library()
  local candidates = {
    -- 1. Project build directory
    vim.fn.getcwd() .. "/build/libsynvim_dtl.so",
    -- 2. Git root build directory
    (function()
      local git_root = vim.fs.root(0, { ".git" })
      return git_root and (git_root .. "/build/libsynvim_dtl.so") or nil
    end)(),
    -- 3. User local library directory
    vim.fn.expand("~/.local/lib/libsynvim_dtl.so"),
    -- 4. Neovim config directory
    vim.fn.stdpath("config") .. "/build/libsynvim_dtl.so",
    -- 5. Standard system paths
    "/usr/local/lib/libsynvim_dtl.so",
    "libsynvim_dtl.so",
  }

  for _, path in ipairs(candidates) do
    if path and (path == "libsynvim_dtl.so" or vim.uv.fs_stat(path)) then
      local ok, handle = pcall(ffi.load, path)
      if ok and handle then
        return handle, path
      end
    end
  end

  return nil, nil
end

local lib, loaded_path = find_dtl_library()

--- Check whether the native C++ DTL engine is loaded
--- @return boolean
function M.is_available()
  return lib ~= nil
end

--- Get active engine version string
--- @return string
function M.version()
  if lib then
    return ffi.string(lib.dtl_version())
  end
  return "0.1.0-pure-lua-fallback"
end

--- Get path of loaded shared library
--- @return string?
function M.loaded_path()
  return loaded_path
end

--- Pure-Lua fallback for permission/prohibition checking when native lib is absent
local function fallback_validate(task, target_file, patch_diff)
  local file = target_file or ""
  -- 1. Global Prohibitions
  if file:match("%.env") or file:match("Cargo%.lock$") or file:match("package%-lock%.json$") then
    return false, "PROHIBITION VIOLATION (F): Write access forbidden on sensitive file: " .. file, "auto_revert;mark_revise"
  end

  -- 2. Task Deny List
  for _, pat in ipairs(task.deny or {}) do
    if file:find(pat, 1, true) or file:match(pat) then
      return false, "PROHIBITION VIOLATION (F): File matches task deny policy: " .. pat, "auto_revert;mark_revise"
    end
  end

  -- 3. Task Allow List
  local allow = task.allow or task.modifies
  if allow and #allow > 0 then
    local permitted = false
    for _, pat in ipairs(allow) do
      if file:find(pat, 1, true) or file:match(pat) then
        permitted = true; break
      end
    end
    if not permitted then
      return false, "PERMISSION VIOLATION (P): File outside task modification scope: " .. file, "revert_patch;mark_revise"
    end
  end

  -- 4. Invariants
  local diff = patch_diff or ""
  if diff:match("BEGIN [A-Z%s]*PRIVATE KEY") or diff:match("AKIA[0-9A-Z]+") then
    return false, "INVARIANT VIOLATION (Box): Secret key pattern detected in diff", "purge_diff;alert_human"
  end

  return true, nil, nil
end

--- Validate a proposed patch against task-level normative contracts
--- @param task table: Task contract table (allow, deny, modifies, etc.)
--- @param target_file string: Target file path
--- @param patch_diff string: Proposed diff or new content
--- @return boolean ok: True if all normative checks passed
--- @return string? message: Violation diagnostic message if failed
--- @return string? ctd_action: Contrary-to-duty repair instruction ("auto_revert", "revert_patch", etc.)
function M.validate_patch(task, target_file, patch_diff)
  if not lib then
    return fallback_validate(task, target_file, patch_diff)
  end

  local task_json = vim.json.encode(task or {})
  local res = lib.dtl_validate_patch(task_json, target_file or "", patch_diff or "")

  if res.code == ffi.C.DTL_OK then
    return true, nil, nil
  end

  local msg = (res.message ~= nil) and ffi.string(res.message) or "Normative contract violation"
  local ctd = (res.ctd_action ~= nil) and ffi.string(res.ctd_action) or "revert_patch;mark_revise"
  return false, msg, ctd
end

--- Perform topological sort and cycle detection over a list of tasks
--- @param tasks table: Array of task tables with id, blocks, depends_on
--- @return table sorted_ids: Ordered task ID array
--- @return string? cycle_error: Cycle description if deadlock detected
function M.sort_tasks(tasks)
  if not lib then
    -- Fallback simple ID extraction
    local ids = {}
    for _, t in ipairs(tasks or {}) do
      if t.id then table.insert(ids, t.id) end
    end
    return ids, nil
  end

  local tasks_json = vim.json.encode(tasks or {})
  local res = lib.dtl_sort_task_dag(tasks_json)

  if res.code == ffi.C.DTL_OK then
    local sorted_json_str = (res.sorted_ids_json ~= nil) and ffi.string(res.sorted_ids_json) or "[]"
    local ok, parsed = pcall(vim.json.decode, sorted_json_str)
    return ok and parsed or {}, nil
  elseif res.code == ffi.C.DTL_ERR_CYCLE then
    local cycle_id = (res.cycle_task_id ~= nil) and ffi.string(res.cycle_task_id) or "unknown"
    return {}, "CYCLIC DEADLOCK DETECTED: Circular dependency involving task '" .. cycle_id .. "'"
  else
    return {}, "DAG SORT ERROR"
  end
end

return M
