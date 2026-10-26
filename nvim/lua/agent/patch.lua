-- ==============================================================================
-- agent/patch.lua: Content-anchored patch location, apply & revert.
--
-- Reviews record `old_lines` (before) and `new_lines` (after) plus a hint
-- `start_line`. Line numbers drift whenever the user edits a file, so every
-- operation re-locates the block by CONTENT (nearest match to the hint) and
-- refuses to touch the file when neither block can be found (conflict).
-- ==============================================================================
local M = {}

local anchor_mod = require("agent.anchor")

--- Find `block` as a contiguous run inside `lines`, nearest to `near` (1-based).
--- Accelerated by the native C++ LuaJIT FFI engine (`libsynvim_anchor.so`).
--- @return integer|nil 1-based start index
function M.find_block(lines, block, near)
  if type(block) ~= "table" or #block == 0 then return nil end
  return anchor_mod.find_nearest_block(lines, block, near or 1, true)
end

--- Locate a review inside `lines`.
--- @return string state  "applied" | "pending" | "missing"
--- @return integer|nil idx 1-based start of the located block
function M.locate(lines, rev)
  local old = rev.old_lines or {}
  local new = rev.new_lines or {}
  local hint = tonumber(rev.start_line) or 1

  if #new > 0 then
    local i = M.find_block(lines, new, hint)
    if i then return "applied", i end
  end
  if #old > 0 then
    local i = M.find_block(lines, old, hint)
    if i then return "pending", i end
    if #new == 0 then return "applied", math.min(hint, #lines + 1) end
    return "missing", nil
  end
  -- Pure insertion (task stubs): not present -> can be (re)inserted at hint
  return "pending", math.max(1, math.min(hint, #lines + 1))
end

local function splice(lines, idx, remove_count, insert)
  local out = {}
  for i = 1, idx - 1 do out[#out + 1] = lines[i] end
  for _, l in ipairs(insert) do out[#out + 1] = l end
  for i = idx + remove_count, #lines do out[#out + 1] = lines[i] end
  return out
end

--- Transform lines so that the review is applied.
--- @return table|nil lines, string status ("changed"|"unchanged"|"conflict"), integer|nil idx
function M.apply(lines, rev)
  local st, idx = M.locate(lines, rev)
  if st == "applied" then return lines, "unchanged", idx end
  if st == "missing" then return nil, "conflict", nil end
  return splice(lines, idx, #(rev.old_lines or {}), rev.new_lines or {}), "changed", idx
end

--- Transform lines so that the review is reverted.
function M.unapply(lines, rev)
  local st, idx = M.locate(lines, rev)
  if st == "pending" then
    -- original content (or absence of an inserted stub) already in place
    return lines, "unchanged", idx
  end
  if st == "missing" then return nil, "conflict", nil end
  if #(rev.new_lines or {}) == 0 then
    return splice(lines, idx, 0, rev.old_lines or {}), "changed", idx
  end
  return splice(lines, idx, #rev.new_lines, rev.old_lines or {}), "changed", idx
end

local function same(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end
M.same = same

--- Apply `fn` (M.apply / M.unapply) to both the buffer and the file on disk,
--- then persist without clobbering unrelated unsaved user edits.
--- @return boolean ok, string status, integer|nil bufnr
function M.commit(abs_path, rev, fn)
  local bufnr = vim.fn.bufadd(abs_path)
  vim.fn.bufload(bufnr)
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local exists = vim.fn.filereadable(abs_path) == 1
  local disk_lines = exists and vim.fn.readfile(abs_path) or nil

  local b2, bst = fn(buf_lines, rev)
  local d2, dst = nil, nil
  if disk_lines then d2, dst = fn(disk_lines, rev) end

  if bst == "conflict" then
    return false, "conflict", bufnr
  end

  if bst == "changed" then
    local was_mod = vim.bo[bufnr].modifiable
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, b2)
    vim.bo[bufnr].modifiable = was_mod
  end

  if not disk_lines or dst == "conflict" or (d2 and same(b2, d2)) then
    -- Buffer content is exactly what the file should contain -> write to disk
    if not (disk_lines and same(b2, disk_lines)) then
      pcall(vim.fn.mkdir, vim.fn.fnamemodify(abs_path, ":h"), "p")
      pcall(vim.fn.writefile, b2, abs_path)
      local bname = vim.api.nvim_buf_get_name(bufnr)
      if bname ~= "" and vim.bo[bufnr].buftype == "" then
        pcall(vim.api.nvim_buf_call, bufnr, function() vim.cmd("silent! write!") end)
      end
    end
    vim.bo[bufnr].modified = false
  else
    -- Buffer carries unrelated unsaved edits: patch disk independently and
    -- keep the user's other edits pending in the buffer.
    if dst == "changed" then
      pcall(vim.fn.mkdir, vim.fn.fnamemodify(abs_path, ":h"), "p")
      pcall(vim.fn.writefile, d2, abs_path)
    end
  end
  return true, bst, bufnr
end

return M
