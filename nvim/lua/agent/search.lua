-- ==============================================================================
-- agent/search.lua: Hybrid Deterministic Code & File Search Engine + :Ask
-- Uses native C++20 LuaJIT FFI (libsynvim_search.so) combining:
--   1. Smith-Waterman / FZF affine-gap subsequence path & filename alignment
--   2. Okapi BM25 with corpus IDF rarity & 5-line sliding window proximity
--   3. Multi-language structural AST / symbol definition detection
--   4. Bounded Damerau-Levenshtein typo tolerance & camelCase/snake_case splitting
--   5. Whole-repository or location-scoped search (`in <path>`, `@<path>`, globs)
-- ==============================================================================

local M = {}
local ffi = require("ffi")
local state_mod = require("agent.state")
local ui = require("agent.ui")

pcall(ffi.cdef, [[
  const char* synvim_search_repo(
    const char* root_dir,
    const char* query_raw,
    const char* locations_json,
    int max_results
  );
  const char* synvim_search_version(void);
]])

local function find_search_library()
  local candidates = {
    vim.fn.getcwd() .. "/build/libsynvim_search.so",
    (function()
      local git_root = vim.fs.root(0, { ".git" })
      return git_root and (git_root .. "/build/libsynvim_search.so") or nil
    end)(),
    vim.fn.expand("~/.local/lib/libsynvim_search.so"),
    vim.fn.stdpath("config") .. "/build/libsynvim_search.so",
    "/usr/local/lib/libsynvim_search.so",
    "libsynvim_search.so",
  }

  for _, path in ipairs(candidates) do
    if path and (vim.fn.filereadable(path) == 1 or path == "libsynvim_search.so") then
      local ok, handle = pcall(ffi.load, path)
      if ok and handle then
        return handle
      end
    end
  end

  local ok, handle = pcall(ffi.load, "libsynvim_search.so")
  if ok and handle then
    return handle
  end
  return nil
end

local lib_search = find_search_library()

--- Check whether the native C++20 search engine is loaded via LuaJIT FFI
function M.is_native_available()
  return lib_search ~= nil
end

--- Return search engine version string
function M.version()
  if not lib_search then
    return "fallback-lua"
  end
  return ffi.string(lib_search.synvim_search_version())
end

--- Split a camelCase / PascalCase / snake_case / kebab-case identifier into lowercase subtokens
function M.split_subtokens(str)
  if not str or str == "" then return {} end
  local norm = str:gsub("([a-z0-9])([A-Z])", "%1_%2"):gsub("([A-Z]+)([A-Z][a-z])", "%1_%2")
  local out = {}
  local seen = {}
  for w in norm:lower():gmatch("[a-z0-9]+") do
    if #w >= 2 and not seen[w] then
      seen[w] = true
      table.insert(out, w)
    end
  end
  return out
end

--- Check if a token looks like a valid location specifier (existing file/dir, path with '/', or glob)
local function is_location_token(tok, root, allow_ext_or_basename)
  if not tok or tok == "" then return false end
  local clean = tok:gsub("^%./", ""):gsub("/+$", "")
  if clean == "" then return false end
  if tok == "." or tok == "./" then return true end
  local full = (clean:sub(1, 1) == "/") and clean or (root .. "/" .. clean)
  if vim.fn.isdirectory(full) == 1 or vim.fn.filereadable(full) == 1 then
    return true
  end
  if tok:find("[/%*%?]") then
    return true
  end
  if allow_ext_or_basename and tok:match("%.[a-zA-Z0-9]+$") then
    return true
  end
  return false
end

--- Parse user input to `:Find` into `(clean_query, locations)`
--- Supports:
---   1. `<query> in <loc1> [loc2 ...]`
---   2. `@<loc>`, `path:<loc>`, `dir:<loc>`, `file:<loc>`, `in:<loc>`, `-p <loc>`
---   3. Positional existing file/dir/glob tokens at start or end of multi-word queries
function M.parse_find_args(raw_input, root)
  root = root or ui.get_root_dir()
  local str = vim.trim(raw_input or "")
  if str == "" then
    return "", {}
  end

  local locations = {}
  local seen_loc = {}
  local function add_loc(loc)
    if not loc then return end
    local cl = vim.trim(loc):gsub("^['\"]", ""):gsub("['\"]$", "")
    if cl ~= "" and not seen_loc[cl] then
      seen_loc[cl] = true
      table.insert(locations, cl)
    end
  end

  -- 1. Extract explicit `@path`, `path:...`, `dir:...`, `file:...`, `in:...`, `loc:...`, `-p <path>` tokens
  local words = vim.split(str, "%s+", { trimempty = true })
  local filtered = {}
  local i = 1
  while i <= #words do
    local w = words[i]
    if w:sub(1, 1) == "@" and #w > 1 then
      add_loc(w:sub(2))
    elseif w:match("^[pP]ath:(.+)$") then
      add_loc(w:match("^[pP]ath:(.+)$"))
    elseif w:match("^[dD]ir:(.+)$") then
      add_loc(w:match("^[dD]ir:(.+)$"))
    elseif w:match("^[fF]ile:(.+)$") then
      add_loc(w:match("^[fF]ile:(.+)$"))
    elseif w:match("^[iI]n:(.+)$") then
      add_loc(w:match("^[iI]n:(.+)$"))
    elseif w:match("^[lL]oc:(.+)$") then
      add_loc(w:match("^[lL]oc:(.+)$"))
    elseif (w == "-p" or w == "--path") and i < #words then
      add_loc(words[i + 1])
      i = i + 1
    else
      table.insert(filtered, w)
    end
    i = i + 1
  end

  -- 2. Check for `<query> in <loc1> [loc2 ...]` suffix
  local in_idx = nil
  for idx = #filtered - 1, 2, -1 do
    if filtered[idx]:lower() == "in" then
      local all_locs = true
      for j = idx + 1, #filtered do
        if not is_location_token(filtered[j], root, true) then
          all_locs = false
          break
        end
      end
      if all_locs then
        in_idx = idx
        break
      end
    end
  end

  if in_idx then
    for j = in_idx + 1, #filtered do
      add_loc(filtered[j])
    end
    local head = {}
    for j = 1, in_idx - 1 do
      table.insert(head, filtered[j])
    end
    filtered = head
  end

  -- 3. Check leading or trailing positional directory/file/glob tokens when multiple tokens exist
  if #filtered >= 2 and #locations == 0 then
    -- Check leading tokens that are existing directories/files or globs
    while #filtered >= 2 and is_location_token(filtered[1], root, false) do
      add_loc(table.remove(filtered, 1))
    end
    -- If no leading location was stripped, check trailing tokens that are existing dirs/files/globs
    if #locations == 0 then
      local tail_locs = {}
      while #filtered >= 2 and is_location_token(filtered[#filtered], root, false) do
        table.insert(tail_locs, 1, table.remove(filtered))
      end
      for _, tl in ipairs(tail_locs) do
        add_loc(tl)
      end
    end
  end

  local clean_query = vim.trim(table.concat(filtered, " "))
  return clean_query, locations
end

--- Extract core search keywords from natural language or symbol queries
function M.extract_search_keywords(query)
  local stop_words = {
    ["where"]=true, ["did"]=true, ["we"]=true, ["implement"]=true, ["implementation"]=true,
    ["the"]=true, ["a"]=true, ["an"]=true, ["in"]=true, ["is"]=true, ["of"]=true, ["to"]=true,
    ["and"]=true, ["or"]=true, ["for"]=true, ["with"]=true, ["find"]=true, ["show"]=true,
    ["me"]=true, ["how"]=true, ["what"]=true, ["which"]=true, ["can"]=true, ["you"]=true,
    ["at"]=true, ["on"]=true, ["file"]=true, ["line"]=true, ["code"]=true, ["function"]=true,
    ["class"]=true, ["this"]=true, ["that"]=true, ["there"]=true, ["are"]=true, ["was"]=true,
    ["our"]=true, ["us"]=true, ["it"]=true, ["its"]=true, ["my"]=true, ["i"]=true,
    ["definition"]=true, ["defined"]=true, ["locate"]=true, ["look"]=true, ["up"]=true,
  }
  local keywords = {}
  local seen = {}
  for word in (query or ""):gmatch("[%a%d_%-]+") do
    local w_low = word:lower()
    if #w_low >= 2 and not stop_words[w_low] and not seen[w_low] then
      seen[w_low] = true
      table.insert(keywords, w_low)
    end
    for _, st in ipairs(M.split_subtokens(word)) do
      if #st >= 2 and not stop_words[st] and not seen[st] then
        seen[st] = true
        table.insert(keywords, st)
      end
    end
  end
  if #keywords == 0 then
    for word in (query or ""):gmatch("%S+") do
      table.insert(keywords, word:lower())
    end
  end
  return keywords
end

--- Parse and split multiple questions from a user query (numbered lists, multiple ?, conjunctions, multi-line)
function M.split_questions(input)
  if not input or type(input) ~= "string" then return {} end
  -- Unescape literal \n or \r\n
  local str = input:gsub("\\r\\n", "\n"):gsub("\\n", "\n")
  str = vim.trim(str)
  if str == "" then return {} end

  local questions = {}

  -- 1. Numbered questions (single line or spanning multiple lines)
  if str:match("^%s*[0-9]+[%.)]") or str:match("%s+[0-9]+[%.)]%s+") then
    local norm = ("\n" .. str):gsub("([%s\r\n]+[0-9]+[%.)]%s+)", "\n%1")
    local current_q = nil
    for line in norm:gmatch("[^\r\n]+") do
      local num_prefix, text = line:match("^%s*([0-9]+)[%.)]%s*(.*)$")
      if num_prefix then
        if current_q and vim.trim(current_q) ~= "" then
          table.insert(questions, vim.trim(current_q))
        end
        current_q = text
      elseif current_q and vim.trim(line) ~= "" then
        current_q = current_q .. " " .. vim.trim(line)
      end
    end
    if current_q and vim.trim(current_q) ~= "" then
      table.insert(questions, vim.trim(current_q))
    end
    if #questions >= 2 then return questions end
  end

  -- 2. Bullet points (single line or spanning multiple lines)
  if str:match("^%s*[-*]%s+") or str:match("[\r\n]%s*[-*]%s+") then
    local current_q = nil
    for line in str:gmatch("[^\r\n]+") do
      local bullet, text = line:match("^%s*([-%*])%s+(.*)$")
      if bullet then
        if current_q and vim.trim(current_q) ~= "" then
          table.insert(questions, vim.trim(current_q))
        end
        current_q = text
      elseif current_q then
        current_q = current_q .. " " .. vim.trim(line)
      end
    end
    if current_q and vim.trim(current_q) ~= "" then
      table.insert(questions, vim.trim(current_q))
    end
    if #questions >= 2 then return questions end
  end

  -- 3. Multiple question marks
  local q_count = 0
  for _ in str:gmatch("%?") do q_count = q_count + 1 end
  if q_count >= 2 then
    for part in str:gmatch("([^%?]+%?)") do
      local q = part:gsub("[\r\n]+", " ")
      q = vim.trim(q)
      q = q:gsub("^[%s,;]+", ""):gsub("^[aA]nd%s+", ""):gsub("^[aA]lso%s*,?%s*", "")
      if #q >= 5 then
        table.insert(questions, q)
      end
    end
    local tail = str:match("%?[^%?]+$")
    if tail then
      local t = tail:sub(2):gsub("[\r\n]+", " ")
      t = vim.trim(t)
      t = t:gsub("^[%s,;]+", ""):gsub("^[aA]nd%s+", ""):gsub("^[aA]lso%s*,?%s*", "")
      if #t >= 8 and (t:lower():find("where") or t:lower():find("how") or t:lower():find("what") or t:lower():find("which")) then
        table.insert(questions, t)
      end
    end
    if #questions >= 2 then return questions end
  end

  -- 4. Compound questions with conjunctions ("and where", "and how", "and what", "also where")
  for _, sep in ipairs({ ", and where", " and where", ", and how", " and how", ", and what", " and what", ", also where", "; where", "; how" }) do
    local s = str:lower():find(sep, 1, true)
    if s then
      local q1 = vim.trim(str:sub(1, s - 1):gsub("[\r\n]+", " "))
      local q2 = vim.trim(str:sub(s + #sep - 5):gsub("[\r\n]+", " "))
      if #q1 >= 5 and #q2 >= 5 then
        return { q1, q2 }
      end
    end
  end

  -- 5. Explicit line breaks (raw newlines or \n)
  local raw_lines = {}
  for line in str:gmatch("[^\r\n]+") do
    local t = vim.trim(line)
    if t ~= "" then
      table.insert(raw_lines, t)
    end
  end
  if #raw_lines >= 2 then
    return raw_lines
  end

  return { vim.trim(str:gsub("[\r\n]+", " ")) }
end

--- Helper: check if a relative path matches any location in `locations`
local function path_matches_lua_locations(rel_path, locations)
  if not locations or #locations == 0 then return true end
  local basename = rel_path:match("([^/]+)$") or rel_path
  for _, loc_raw in ipairs(locations) do
    local loc = (loc_raw or ""):gsub("^%./", ""):gsub("/+$", "")
    if loc == "" or loc == "." then return true end
    if rel_path == loc or basename == loc then return true end
    if vim.startswith(rel_path, loc .. "/") then return true end
    if loc:find("[%*%?]") then
      local ok, rx = pcall(vim.fn.glob2regpat, loc)
      if ok and rx then
        if vim.fn.match(rel_path, rx) ~= -1 or vim.fn.match(basename, rx) ~= -1 then
          return true
        end
      end
    end
    if rel_path:find(loc, 1, true) then
      return true
    end
  end
  return false
end

--- Search codebase (both file names/paths and file contents) across entire repo or specified locations
--- @param query string Raw user query (may include `in <path>`, `@<path>`, `path:<path>`, etc.)
--- @param root string|nil Repository root directory
--- @param locations table|nil Optional list of directory/file/glob scopes
--- @return table Ranked list of `{ path, line, col, action = "navigate", description, score, match_type }`
function M.search_and_rank(query, root, locations)
  root = root or ui.get_root_dir()
  local clean_query = vim.trim(query or "")
  local locs = {}
  if type(locations) == "table" and #locations > 0 then
    for _, l in ipairs(locations) do
      table.insert(locs, l)
    end
  else
    local parsed_q, parsed_locs = M.parse_find_args(clean_query, root)
    clean_query = parsed_q
    locs = parsed_locs
  end

  if clean_query == "" and #locs == 0 then
    return {}
  end

  -- 1. Primary Path: Native C++20 Hybrid Search Engine via LuaJIT FFI
  if lib_search then
    local ok_json, locs_json = pcall(vim.json.encode, locs)
    if not ok_json then locs_json = "[]" end
    local ok_ffi, raw_ptr = pcall(function()
      return lib_search.synvim_search_repo(root, clean_query, locs_json, 60)
    end)
    if ok_ffi and raw_ptr ~= nil then
      local json_str = ffi.string(raw_ptr)
      local ok_dec, decoded = pcall(vim.json.decode, json_str)
      if ok_dec and type(decoded) == "table" then
        for _, item in ipairs(decoded) do
          item.action = "navigate"
          item.line = tonumber(item.line) or 1
          item.col = tonumber(item.col) or 1
        end
        return decoded
      end
    end
  end

  -- 2. Pure-Lua Fallback (used only if libsynvim_search.so is not compiled)
  local keywords = M.extract_search_keywords(clean_query)
  if #keywords == 0 and #locs == 0 then return {} end

  local candidates = {}
  local seen_locs = {}

  local find_cmd = { "git", "-C", root, "ls-files" }
  local find_out = vim.fn.system(find_cmd)
  if vim.v.shell_error == 0 and find_out ~= "" then
    local q_low = clean_query:lower()
    for line in find_out:gmatch("[^\r\n]+") do
      if not line:match("%.olean$") and not line:match("%.jsonl$") and not line:match("%.log$") and not line:match("%.ipynb$") then
        if path_matches_lua_locations(line, locs) then
          local line_low = line:lower()
          local base_low = (line:match("([^/]+)$") or line):lower()
          local f_score = 0
          if base_low == q_low or line_low == q_low then
            f_score = 750
          elseif base_low:find(q_low, 1, true) then
            f_score = 240
          elseif line_low:find(q_low, 1, true) then
            f_score = 180
          else
            for _, kw in ipairs(keywords) do
              if line_low:find(kw, 1, true) then
                f_score = f_score + 60
              end
            end
          end
          if f_score >= 120 then
            local loc_key = line .. ":1"
            if not seen_locs[loc_key] then
              seen_locs[loc_key] = true
              table.insert(candidates, {
                path = line,
                line = 1,
                col = 1,
                action = "navigate",
                match_type = "file",
                description = "[FILE] " .. line,
                score = f_score,
              })
            end
          end
        end
      end
    end
  end

  if #keywords > 0 then
    local grep_matches = {}
    local pattern = table.concat(keywords, "|")
    local rg_bin = vim.fn.exepath("rg")
    if rg_bin ~= "" then
      local rg_cmd = { rg_bin, "-n", "--no-heading", "-i", "-e", pattern,
        "-g", "!*.jsonl", "-g", "!*.log", "-g", "!*.json", "-g", "!*.ipynb", "-g", "!*.olean", "-g", "!specs/.lexlean/*", "-g", "!logs/*", "-g", "!target/*", root }
      local rg_out = vim.fn.system(rg_cmd)
      if rg_out and rg_out ~= "" then
        for line in rg_out:gmatch("[^\r\n]+") do
          local rel = line:gsub("^" .. vim.pesc(root) .. "/", "")
          table.insert(grep_matches, rel)
        end
      end
    end

    for _, line in ipairs(grep_matches) do
      local fpath, lnum, txt = line:match("^([^:]+):(%d+):(.*)$")
      if fpath and lnum and txt and path_matches_lua_locations(fpath, locs) then
        local lnum_num = tonumber(lnum) or 1
        local loc_key = fpath .. ":" .. lnum_num
        if not seen_locs[loc_key] then
          seen_locs[loc_key] = true
          local txt_low = txt:lower()
          local fpath_low = fpath:lower()
          local query_low = clean_query:lower()
          local score = 10
          local match_type = "content"

          if txt:find(clean_query, 1, true) then
            score = score + 140
          elseif txt_low:find(query_low, 1, true) then
            score = score + 90
          end

          for _, kw in ipairs(keywords) do
            if txt_low:find("fn%s+" .. kw) or txt_low:find("def%s+" .. kw)
              or txt_low:find("function%s+" .. kw) or txt_low:find("function%s+[%a0-9_]*[:%.]" .. kw)
              or txt_low:find("struct%s+" .. kw) or txt_low:find("class%s+" .. kw)
              or txt_low:find(kw .. "%s*=") then
              score = score + 160
              match_type = "symbol"
              break
            end
          end

          if fpath_low:match("%.hpp$") or fpath_low:match("%.cpp$") or fpath_low:match("%.rs$") or fpath_low:match("%.c$") or fpath_low:match("%.h$") or fpath_low:match("%.py$") or fpath_low:match("%.lua$") or fpath_low:match("%.go$") then
            score = score + 40
          end

          table.insert(candidates, {
            path = fpath,
            line = lnum_num,
            col = 1,
            action = "navigate",
            match_type = match_type,
            description = vim.trim(txt),
            score = score,
          })
        end
      end
    end
  end

  table.sort(candidates, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.path < b.path
  end)

  return candidates
end

M.state = {
  win = nil,
  buf = nil,
  inspector_win = nil,
  inspector_buf = nil,
  origin_win = nil,
  root = nil,
  query = "",
  clean_query = "",
  locations = {},
  candidates = {},
  selected_idx = 1,
  scroll_offset = 0,
  max_visible = 14,
  width = 96,
  height = 18,
  line_to_idx = {},
  line_to_head_col = {},
  callback = nil,
  updating = false,
  ns = vim.api.nvim_create_namespace("synvim_find_menu"),
  ns_inspector = vim.api.nvim_create_namespace("synvim_find_inspector"),
}

--- Build default initial candidates when the search bar is empty (visited files + repository source files)
function M.get_initial_candidates(root, locations, limit)
  root = root or ui.get_root_dir()
  limit = limit or 40
  local out = {}
  local seen = {}

  -- 1. Recently visited files from :History
  local ok_hist, history = pcall(require, "agent.history")
  if ok_hist and history.get_history then
    for _, h in ipairs(history.get_history()) do
      local rel = h.rel_path or h.path
      if rel and rel ~= "" and not seen[rel] and path_matches_lua_locations(rel, locations) then
        seen[rel] = true
        table.insert(out, {
          path = rel,
          line = (h.anchor and h.anchor.line) or h.line or 1,
          col = (h.col and h.col + 1) or 1,
          action = "navigate",
          match_type = "file",
          description = (h.snippet and h.snippet ~= "") and h.snippet or ("[RECENT] " .. rel),
          score = 500,
        })
        if #out >= limit then return out end
      end
    end
  end

  -- 2. Repository source files via native FFI in-memory cache (zero shell overhead)
  if lib_search then
    local ok_json, locs_json = pcall(vim.json.encode, locations or {})
    if not ok_json then locs_json = "[]" end
    local ok_ffi, raw_ptr = pcall(function()
      return lib_search.synvim_search_repo(root, "", locs_json, limit)
    end)
    if ok_ffi and raw_ptr ~= nil then
      local ok_dec, decoded = pcall(vim.json.decode, ffi.string(raw_ptr))
      if ok_dec and type(decoded) == "table" then
        for _, item in ipairs(decoded) do
          if not seen[item.path] then
            seen[item.path] = true
            item.action = "navigate"
            item.line = tonumber(item.line) or 1
            item.col = tonumber(item.col) or 1
            table.insert(out, item)
            if #out >= limit then return out end
          end
        end
        return out
      end
    end
  end

  local find_cmd = { "git", "-C", root, "ls-files" }
  local find_out = vim.fn.system(find_cmd)
  if vim.v.shell_error == 0 and find_out ~= "" then
    for line in find_out:gmatch("[^\r\n]+") do
      if not seen[line]
        and not line:match("%.olean$")
        and not line:match("%.jsonl$")
        and not line:match("%.log$")
        and not line:match("%.ipynb$")
        and path_matches_lua_locations(line, locations)
      then
        seen[line] = true
        table.insert(out, {
          path = line,
          line = 1,
          col = 1,
          action = "navigate",
          match_type = "file",
          description = "[FILE] " .. line,
          score = 100,
        })
        if #out >= limit then break end
      end
    end
  end

  return out
end

--- Close the floating :Find menu and its docked Inspector Bar if open
function M.close_find_menu()
  if M.state.win and vim.api.nvim_win_is_valid(M.state.win) then
    pcall(vim.api.nvim_win_close, M.state.win, true)
  end
  if M.state.inspector_win and vim.api.nvim_win_is_valid(M.state.inspector_win) then
    pcall(vim.api.nvim_win_close, M.state.inspector_win, true)
  end
  M.state.win = nil
  M.state.buf = nil
  M.state.inspector_win = nil
  M.state.inspector_buf = nil
  M.state.line_to_idx = {}
  M.state.line_to_head_col = {}
end

--- Update the docked bottom Code Context & Task Placement Inspector Bar below the :Find floating box
function M.update_find_inspector()
  local insp_buf = M.state.inspector_buf
  local insp_win = M.state.inspector_win
  if not insp_buf or not vim.api.nvim_buf_is_valid(insp_buf) then return end

  local candidates = M.state.candidates or {}
  local idx = M.state.selected_idx or 0
  local chosen = candidates[idx]
  local width = M.state.width or 96
  local root = M.state.root or ui.get_root_dir()

  local p_state = state_mod.state
  local placement_badge = ""
  if p_state.placement_active and p_state.placement_queue and #p_state.placement_queue > 0 then
    local p_idx = p_state.placement_index or 1
    local cur_spec = p_state.placement_queue[p_idx]
    if cur_spec then
      placement_badge = string.format(
        " │ 📌 Placement [%d/%d]: CONTRACT(%s) [<M-p>: Drop]",
        p_idx, #p_state.placement_queue, cur_spec.task_id or "task"
      )
    end
  end

  if not chosen then
    local empty_lines = {
      " No match selected" .. placement_badge,
      " ────────────────────────────────────────────────────────────────────────",
      " Type a query in the search bar above to inspect matching code context.",
      " Supports file names, symbols, natural language, 'in <dir>', and '@<path>'.",
      "",
    }
    vim.api.nvim_buf_set_lines(insp_buf, 0, -1, false, empty_lines)
    vim.api.nvim_buf_clear_namespace(insp_buf, M.state.ns_inspector, 0, -1)
    pcall(vim.api.nvim_buf_set_extmark, insp_buf, M.state.ns_inspector, 0, 0, { end_col = -1, hl_group = "Comment" })
    return
  end

  local kind_tag = "[BM25]"
  if chosen.match_type == "symbol" then
    kind_tag = "[SYMBOL]"
  elseif chosen.match_type == "file" then
    kind_tag = "[FILE]"
  end

  local header_line
  if placement_badge ~= "" then
    local short_path = chosen.path:match("([^/]+)$") or chosen.path
    header_line = string.format(
      " [%d/%d] %s:%d%s",
      idx, #candidates, short_path, chosen.line or 1, placement_badge
    )
  else
    header_line = string.format(
      " [%d/%d] %s %s:%d:%d  (Score: %.1f)",
      idx, #candidates, kind_tag, chosen.path, chosen.line or 1, chosen.col or 1, tonumber(chosen.score) or 0.0
    )
    if #header_line > width then
      header_line = header_line:sub(1, width - 1) .. "…"
    end
  end

  -- Load surrounding code context lines [target_line - 1 .. target_line + 2]
  local full_path = (chosen.path:sub(1, 1) == "/") and chosen.path or (root .. "/" .. chosen.path)
  local file_lines = nil
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_is_loaded(b) then
      local bname = vim.api.nvim_buf_get_name(b)
      if bname == full_path or vim.fn.fnamemodify(bname, ":p") == vim.fn.fnamemodify(full_path, ":p") then
        file_lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
        break
      end
    end
  end

  local target_l = math.max(1, tonumber(chosen.line) or 1)
  local start_l = math.max(1, target_l - 1)
  local end_l = start_l + 3

  if not file_lines and vim.fn.filereadable(full_path) == 1 then
    local ok, read_l = pcall(vim.fn.readfile, full_path, "", end_l + 2)
    if ok and type(read_l) == "table" then
      file_lines = read_l
    end
  end

  local insp_lines = { header_line }
  local target_insp_row_0 = nil

  if file_lines and #file_lines > 0 then
    end_l = math.min(#file_lines, start_l + 3)
    for lnum = start_l, start_l + 3 do
      if lnum <= #file_lines then
        local raw_code = (file_lines[lnum] or ""):gsub("\t", "  "):gsub("\r", "")
        local is_tgt = (lnum == target_l)
        local marker = is_tgt and " ▶ " or "   "
        local fmt_line = string.format("%s%4d │ %s", marker, lnum, raw_code)
        if #fmt_line > width then
          fmt_line = fmt_line:sub(1, width - 1) .. "…"
        end
        table.insert(insp_lines, fmt_line)
        if is_tgt then
          target_insp_row_0 = #insp_lines - 1
        end
      else
        table.insert(insp_lines, "      ~ │")
      end
    end
  else
    table.insert(insp_lines, string.format(" ▶ %4d │ %s", target_l, chosen.description or chosen.path))
    table.insert(insp_lines, "      ~ │")
    table.insert(insp_lines, "      ~ │")
    table.insert(insp_lines, "      ~ │")
    target_insp_row_0 = 1
  end

  vim.api.nvim_buf_set_lines(insp_buf, 0, -1, false, insp_lines)
  vim.api.nvim_buf_clear_namespace(insp_buf, M.state.ns_inspector, 0, -1)

  -- Highlight header line
  pcall(vim.api.nvim_buf_set_extmark, insp_buf, M.state.ns_inspector, 0, 0, {
    end_col = #header_line,
    hl_group = "Title",
  })

  -- Highlight context rows and emphasize target line
  for r0 = 1, #insp_lines - 1 do
    local row_txt = insp_lines[r0 + 1] or ""
    local bar_pos = row_txt:find("│", 1, true)
    if r0 == target_insp_row_0 then
      pcall(vim.api.nvim_buf_set_extmark, insp_buf, M.state.ns_inspector, r0, 0, {
        end_col = #row_txt,
        hl_group = "CursorLine",
        hl_eol = true,
      })
      if bar_pos then
        pcall(vim.api.nvim_buf_set_extmark, insp_buf, M.state.ns_inspector, r0, 0, {
          end_col = bar_pos + #("│") - 1,
          hl_group = "ModeMsg",
        })
        pcall(vim.api.nvim_buf_set_extmark, insp_buf, M.state.ns_inspector, r0, bar_pos + #("│") - 1, {
          end_col = #row_txt,
          hl_group = "Function",
        })
      end
    else
      if bar_pos then
        pcall(vim.api.nvim_buf_set_extmark, insp_buf, M.state.ns_inspector, r0, 0, {
          end_col = bar_pos + #("│") - 1,
          hl_group = "LineNr",
        })
        pcall(vim.api.nvim_buf_set_extmark, insp_buf, M.state.ns_inspector, r0, bar_pos + #("│") - 1, {
          end_col = #row_txt,
          hl_group = "Comment",
        })
      end
    end
  end

  if insp_win and vim.api.nvim_win_is_valid(insp_win) then
    local insp_title = p_state.placement_active
      and " Code Context & Task Placement Target (<M-p>: Drop Task Here | <CR>: Jump) "
      or " Code Context & Match Inspector "
    pcall(vim.api.nvim_win_set_config, insp_win, {
      title = insp_title,
      title_pos = "left",
    })
  end
end

--- Render the divider (Line 2) and visible results list (Lines 3..H) + highlights inside the floating :Find box
function M.render_find_menu()
  local buf = M.state.buf
  local win = M.state.win
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  local width = M.state.width or 96
  local max_visible = M.state.max_visible or 16
  local candidates = M.state.candidates or {}
  local total = #candidates

  if total == 0 then
    M.state.selected_idx = 0
    M.state.scroll_offset = 0
  else
    M.state.selected_idx = math.max(1, math.min(total, M.state.selected_idx or 1))
    if M.state.selected_idx <= M.state.scroll_offset then
      M.state.scroll_offset = M.state.selected_idx - 1
    elseif M.state.selected_idx > M.state.scroll_offset + max_visible then
      M.state.scroll_offset = M.state.selected_idx - max_visible
    end
    M.state.scroll_offset = math.max(0, math.min(math.max(0, total - max_visible), M.state.scroll_offset))
  end

  local divider = string.rep("─", width)
  local body_lines = { divider }
  local row_highlights = {}
  M.state.line_to_idx = {}
  M.state.line_to_head_col = {}

  -- Determine clean column alignment width for file:line:col
  local max_loc_len = 28
  local start_i = M.state.scroll_offset + 1
  local end_i = math.min(total, M.state.scroll_offset + max_visible)
  for idx = start_i, end_i do
    local c = candidates[idx]
    local loc_str = string.format("%s:%d", c.path, c.line or 1)
    if #loc_str > max_loc_len and #loc_str <= 44 then
      max_loc_len = #loc_str
    end
  end

  if total == 0 then
    local scope_msg = (#M.state.locations > 0) and (" in " .. table.concat(M.state.locations, ", ")) or ""
    local empty_msg = (M.state.clean_query ~= "")
      and string.format("   No files or code found matching '%s'%s", M.state.clean_query, scope_msg)
      or "   Type a search query above (supports file names, symbols, natural language, 'in <dir>', '@<path>')"
    table.insert(body_lines, empty_msg)
    table.insert(row_highlights, {
      line = 2, -- 0-based line 2 (Line 3 in buffer)
      col_start = 0,
      col_end = #empty_msg,
      hl_group = (M.state.clean_query ~= "") and "WarningMsg" or "Comment",
    })
  else
    local kw_Highlight = M.extract_search_keywords(M.state.clean_query)
    for idx = start_i, end_i do
      local c = candidates[idx]
      local is_sel = (idx == M.state.selected_idx)
      local prefix = is_sel and "▶ " or "  "
      local idx_str = string.format("[%d]", idx)

      local badge = "[BM25]  "
      local badge_hl = "Identifier"
      if c.match_type == "symbol" then
        badge = "[SYMBOL]"
        badge_hl = "Special"
      elseif c.match_type == "file" then
        badge = "[FILE]  "
        badge_hl = "Directory"
      end

      local loc_str = string.format("%s:%d", c.path, c.line or 1)
      if #loc_str > 44 then
        loc_str = "…" .. loc_str:sub(#loc_str - 42)
      end
      local padded_loc = loc_str .. string.rep(" ", math.max(2, max_loc_len - #loc_str + 2))

      local desc = (c.description or ""):gsub("[\r\n\t]+", " ")
      desc = vim.trim(desc)
      local avail_desc = math.max(12, width - (#prefix + 5 + 1 + #badge + 2 + #padded_loc + 2))
      if #desc > avail_desc then
        desc = desc:sub(1, avail_desc - 1) .. "…"
      end

      local line_str = string.format("%s%-5s %s  %s%s", prefix, idx_str, badge, padded_loc, desc)
      table.insert(body_lines, line_str)

      local buf_line_1 = #body_lines + 1 -- 1-based buffer line (since Line 1 is search bar)
      local buf_line_0 = buf_line_1 - 1  -- 0-based buffer line for extmarks
      M.state.line_to_idx[buf_line_1] = idx

      local s_b = line_str:find("%[(%d+)%]") or 3
      M.state.line_to_head_col[buf_line_1] = s_b - 1

      if is_sel then
        table.insert(row_highlights, {
          line = buf_line_0,
          col_start = 0,
          col_end = #line_str,
          hl_group = "CursorLine",
          hl_eol = true,
        })
        table.insert(row_highlights, {
          line = buf_line_0,
          col_start = 0,
          col_end = #prefix,
          hl_group = "ModeMsg",
        })
      end

      -- [idx] highlight
      table.insert(row_highlights, {
        line = buf_line_0,
        col_start = s_b - 1,
        col_end = s_b - 1 + #idx_str,
        hl_group = "Title",
      })

      -- Badge highlight
      local b_start = #prefix + 5 + 1
      local b_end = b_start + #vim.trim(badge)
      table.insert(row_highlights, {
        line = buf_line_0,
        col_start = b_start,
        col_end = b_end,
        hl_group = badge_hl,
      })

      -- File:line highlight
      local l_start = #prefix + 5 + 1 + #badge + 2
      local l_end = l_start + #loc_str
      table.insert(row_highlights, {
        line = buf_line_0,
        col_start = l_start,
        col_end = l_end,
        hl_group = "Function",
      })

      -- Snippet highlight
      local d_start = l_start + #padded_loc
      local d_end = #line_str
      if d_end > d_start then
        table.insert(row_highlights, {
          line = buf_line_0,
          col_start = d_start,
          col_end = d_end,
          hl_group = (c.match_type == "symbol") and "String" or "Comment",
        })
      end

      -- Highlight matching query tokens inside the row
      local line_low = line_str:lower()
      for _, kw in ipairs(kw_Highlight) do
        if #kw >= 2 then
          local search_from = b_end + 1
          while search_from <= #line_low do
            local m_s, m_e = line_low:find(kw, search_from, true)
            if not m_s then break end
            table.insert(row_highlights, {
              line = buf_line_0,
              col_start = m_s - 1,
              col_end = m_e,
              hl_group = "IncSearch",
            })
            search_from = m_e + 1
          end
        end
      end
    end
  end

  M.state.updating = true
  -- Ensure Line 1 exists and replace Lines 2..end with divider + results
  local cur_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local line1 = cur_lines[1] or M.state.query or ""
  if #cur_lines == 0 then
    local all_lines = { line1 }
    for _, bl in ipairs(body_lines) do table.insert(all_lines, bl) end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
  else
    vim.api.nvim_buf_set_lines(buf, 1, -1, false, body_lines)
  end
  M.state.updating = false

  -- Apply extmarks for search bar prompt, divider, and result rows
  vim.api.nvim_buf_clear_namespace(buf, M.state.ns, 0, -1)

  -- Line 1: Inline search bar prefix and right-aligned match counter
  local scope_str = (#M.state.locations > 0) and (" in " .. table.concat(M.state.locations, ",")) or ""
  local right_status = (total > 0)
    and string.format(" [%d/%d%s | ↓/↑/C-n/C-p: Select | Tab: Preview | Enter: Jump | Esc: Close] ", M.state.selected_idx, total, scope_str)
    or string.format(" [0 matches%s | Enter query or 'query in <dir>' | Esc: Close] ", scope_str)

  pcall(vim.api.nvim_buf_set_extmark, buf, M.state.ns, 0, 0, {
    virt_text = { { " 🔍 Find: ", "Title" } },
    virt_text_pos = "inline",
    right_gravity = false,
  })
  pcall(vim.api.nvim_buf_set_extmark, buf, M.state.ns, 0, 0, {
    virt_text = { { right_status, "Comment" } },
    virt_text_pos = "right_align",
  })

  -- Line 2: Divider highlight
  pcall(vim.api.nvim_buf_set_extmark, buf, M.state.ns, 1, 0, {
    end_col = #divider,
    hl_group = "FloatBorder",
  })

  -- Lines 3..H: Result row highlights
  for _, hl in ipairs(row_highlights) do
    pcall(vim.api.nvim_buf_set_extmark, buf, M.state.ns, hl.line, hl.col_start, {
      end_col = hl.col_end,
      hl_group = hl.hl_group,
      hl_eol = hl.hl_eol or false,
    })
  end

  if win and vim.api.nvim_win_is_valid(win) then
    local title_str = (total > 0)
      and string.format(" Find — Files & Code (%d matches%s) ", total, scope_str)
      or " Find — Files & Code (FZF + BM25 + AST) "
    pcall(vim.api.nvim_win_set_config, win, {
      title = title_str,
      title_pos = "left",
    })
  end

  M.update_find_inspector()
end

--- Recompute search results from the current query text on Line 1 of the floating menu
function M.refresh_find_results(query_override)
  local buf = M.state.buf
  if query_override ~= nil then
    M.state.query = query_override
  elseif buf and vim.api.nvim_buf_is_valid(buf) then
    local l1 = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
    M.state.query = l1
  end

  local root = M.state.root or ui.get_root_dir()
  local clean_q, locs = M.parse_find_args(M.state.query, root)
  M.state.clean_query = clean_q
  M.state.locations = locs

  if vim.trim(clean_q) == "" then
    M.state.candidates = M.get_initial_candidates(root, locs, 40)
  else
    M.state.candidates = M.search_and_rank(clean_q, root, locs)
  end

  M.state.selected_idx = (#M.state.candidates > 0) and 1 or 0
  M.state.scroll_offset = 0
  state_mod.state.queue = M.state.candidates
  state_mod.state.queue_index = math.max(1, M.state.selected_idx)

  M.render_find_menu()
end

--- Move selection to next result in the floating :Find menu
function M.select_next(step)
  step = step or 1
  local total = #(M.state.candidates or {})
  if total == 0 then return end
  local next_idx = M.state.selected_idx + step
  if next_idx > total then
    next_idx = (step == 1) and 1 or total
  end
  M.state.selected_idx = next_idx
  state_mod.state.queue_index = next_idx
  M.render_find_menu()

  -- If cursor is on the results section in Normal mode, move cursor to the selected row
  local win = M.state.win
  if win and vim.api.nvim_win_is_valid(win) then
    local cur_row = vim.api.nvim_win_get_cursor(win)[1]
    if cur_row >= 2 then
      local target_buf_line = (M.state.selected_idx - M.state.scroll_offset) + 2
      local col = M.state.line_to_head_col[target_buf_line] or 2
      M.state.updating = true
      pcall(vim.api.nvim_win_set_cursor, win, { target_buf_line, col })
      M.state.updating = false
    end
  end
end

--- Move selection to previous result in the floating :Find menu
function M.select_prev(step)
  step = step or 1
  local total = #(M.state.candidates or {})
  if total == 0 then return end
  local prev_idx = M.state.selected_idx - step
  if prev_idx < 1 then
    prev_idx = (step == 1) and total or 1
  end
  M.state.selected_idx = prev_idx
  state_mod.state.queue_index = prev_idx
  M.render_find_menu()

  local win = M.state.win
  if win and vim.api.nvim_win_is_valid(win) then
    local cur_row = vim.api.nvim_win_get_cursor(win)[1]
    if cur_row >= 2 then
      local target_buf_line = (M.state.selected_idx - M.state.scroll_offset) + 2
      local col = M.state.line_to_head_col[target_buf_line] or 2
      M.state.updating = true
      pcall(vim.api.nvim_win_set_cursor, win, { target_buf_line, col })
      M.state.updating = false
    end
  end
end

--- Jump to or preview the currently selected result in the primary editor window
function M.activate_selected_result(close_after, explicit_idx)
  local candidates = M.state.candidates or {}
  local idx = explicit_idx or M.state.selected_idx or 1
  local chosen = candidates[idx]
  local cb = M.state.callback
  local origin_win = M.state.origin_win

  if not chosen then
    if close_after then
      M.close_find_menu()
      if cb then cb(nil, {}) end
    end
    return nil
  end

  M.state.selected_idx = idx
  state_mod.state.queue = candidates
  state_mod.state.queue_index = idx

  local tasks_mod = require("agent.tasks")
  local floating_win = M.state.win

  if close_after then
    pcall(vim.cmd, "stopinsert")
    M.close_find_menu()
  end

  local target_win = origin_win
  if not target_win or not vim.api.nvim_win_is_valid(target_win) or target_win == floating_win then
    target_win = ui.get_primary_editor_win()
  end

  tasks_mod.jump_to_target(chosen, target_win)
  if state_mod.state.placement_active then
    pcall(tasks_mod.render_placement_preview)
  else
    tasks_mod.update_queue_display(#candidates > 1)
  end

  if not close_after and floating_win and vim.api.nvim_win_is_valid(floating_win) then
    pcall(vim.api.nvim_set_current_win, floating_win)
    M.render_find_menu()
  else
    local kind_label = "BM25"
    if chosen.match_type == "symbol" then
      kind_label = "Symbol"
    elseif chosen.match_type == "file" then
      kind_label = "File"
    end
    local scope_suffix = (#M.state.locations > 0) and (" in " .. table.concat(M.state.locations, ", ")) or ""
    vim.api.nvim_echo({
      { string.format("● [Found (%s)] ", kind_label), "ModeMsg" },
      { string.format("%s:%d:%d", chosen.path, chosen.line or 1, chosen.col or 1), "Directory" },
      {
        string.format(
          " — %s (%d/%d match%s%s)",
          chosen.description or chosen.path,
          idx,
          #candidates,
          #candidates > 1 and "es" or "",
          scope_suffix
        ),
        "Normal",
      },
    }, false, {})
    if cb then
      M.state.callback = nil
      cb(chosen, candidates)
    end
  end

  return chosen
end

--- Jump to the selected :Find result AND immediately drop the active queued task at that line (<M-p> in :Find)
function M.drop_task_at_selected_result(explicit_idx)
  local chosen = M.activate_selected_result(true, explicit_idx)
  if not chosen then return nil end
  if state_mod.state.placement_active then
    local tasks_mod = require("agent.tasks")
    return tasks_mod.drop_current_task_at_cursor()
  end
  return chosen
end

--- Open the unified floating :Find menu (search bar on top + live results below in the same rounded box)
function M.open_find_menu(initial_query, root_override, callback, opts)
  opts = opts or {}
  M.close_find_menu()

  local origin_win = state_mod.state.origin_win
  if not origin_win or not vim.api.nvim_win_is_valid(origin_win) then
    origin_win = ui.get_primary_editor_win()
  end

  local root = root_override or ui.get_root_dir()
  local query_str = vim.trim(initial_query or "")

  local total_cols = vim.o.columns
  local total_lines = vim.o.lines
  local width = math.min(114, math.max(72, total_cols - 10))
  local inspector_h = 5
  local height = math.min(18, math.max(8, total_lines - inspector_h - 10))
  local max_visible = math.max(4, height - 2)
  local total_block_h = height + 2 + inspector_h + 2
  local row = math.max(1, math.floor((total_lines - total_block_h) / 2))
  local col = math.max(1, math.floor((total_cols - width) / 2))

  M.state.origin_win = origin_win
  M.state.root = root
  M.state.query = query_str
  M.state.width = width
  M.state.height = height
  M.state.max_visible = max_visible
  M.state.callback = callback

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "synvim-find"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { query_str })

  local win_config = {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Find — Files & Code (FZF + BM25 + AST) ",
    title_pos = "left",
    zindex = 150,
  }

  local win = vim.api.nvim_open_win(buf, true, win_config)
  M.state.win = win
  M.state.buf = buf

  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"

  -- Create docked bottom Code Context & Task Placement Inspector Bar (matching :History)
  local insp_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[insp_buf].buftype = "nofile"
  vim.bo[insp_buf].bufhidden = "wipe"
  vim.bo[insp_buf].swapfile = false
  vim.bo[insp_buf].filetype = "synvim-find-inspector"

  local insp_win_config = {
    relative = "editor",
    row = row + height + 2,
    col = col,
    width = width,
    height = inspector_h,
    style = "minimal",
    border = "rounded",
    title = " Code Context & Match Inspector ",
    title_pos = "left",
    focusable = false,
    zindex = 150,
  }

  local insp_win = vim.api.nvim_open_win(insp_buf, false, insp_win_config)
  M.state.inspector_win = insp_win
  M.state.inspector_buf = insp_buf
  vim.wo[insp_win].wrap = false
  vim.wo[insp_win].cursorline = false

  -- Populate initial search results and render Lines 2..H + Inspector Bar
  M.refresh_find_results(query_str)

  -- Place cursor at end of Line 1 (the top search bar)
  pcall(vim.api.nvim_win_set_cursor, win, { 1, #query_str })

  local function focus_search_bar(enter_insert)
    if not vim.api.nvim_win_is_valid(win) then return end
    local l1 = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
    M.state.updating = true
    pcall(vim.api.nvim_win_set_cursor, win, { 1, #l1 })
    M.state.updating = false
    if enter_insert then
      pcall(vim.cmd, "startinsert!")
    end
  end

  local function close_action()
    pcall(vim.cmd, "stopinsert")
    M.close_find_menu()
    if origin_win and vim.api.nvim_win_is_valid(origin_win) then
      pcall(vim.api.nvim_set_current_win, origin_win)
    end
  end

  -- Live search updates as the user types in the top search bar (Line 1)
  local augrp = vim.api.nvim_create_augroup("SynvimFindMenu_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    group = augrp,
    buffer = buf,
    callback = function()
      if M.state.updating then return end
      local l1 = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
      M.refresh_find_results(l1)
    end,
  })

  -- Keep Insert mode pinned to Line 1 (search bar) and sync Normal mode cursor on result rows
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = augrp,
    buffer = buf,
    callback = function()
      if M.state.updating or not vim.api.nvim_win_is_valid(win) then return end
      local pos = vim.api.nvim_win_get_cursor(win)
      local r = pos[1]
      local mode = vim.api.nvim_get_mode().mode

      if mode:match("^i") then
        if r > 1 then
          local l1 = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
          M.state.updating = true
          pcall(vim.api.nvim_win_set_cursor, win, { 1, #l1 })
          M.state.updating = false
        end
        return
      end

      -- Normal mode on divider (Line 2) -> snap to first visible result (Line 3) or search bar (Line 1)
      if r == 2 then
        local target_r = (#M.state.candidates > 0) and 3 or 1
        local col_t = M.state.line_to_head_col[target_r] or 0
        M.state.updating = true
        pcall(vim.api.nvim_win_set_cursor, win, { target_r, col_t })
        M.state.updating = false
        r = target_r
      end

      if r >= 3 then
        local idx = M.state.line_to_idx[r]
        if idx and idx ~= M.state.selected_idx then
          M.state.selected_idx = idx
          state_mod.state.queue_index = idx
          M.render_find_menu()
        end
        local head_col = M.state.line_to_head_col[r]
        if head_col and pos[2] ~= head_col then
          M.state.updating = true
          pcall(vim.api.nvim_win_set_cursor, win, { r, head_col })
          M.state.updating = false
        end
      end
    end,
  })

  -- Keymaps: Both Insert mode (in search bar) and Normal mode (in search bar or results list)
  for _, m in ipairs({ "i", "n" }) do
    vim.keymap.set(m, "<CR>", function() M.activate_selected_result(true) end, { buffer = buf, silent = true, nowait = true, desc = "Jump to selected result and close" })
    vim.keymap.set(m, "<M-p>", function() M.drop_task_at_selected_result() end, { buffer = buf, silent = true, nowait = true, desc = "Jump to selected result and drop active queued task here" })
    vim.keymap.set(m, "<Down>", function() M.select_next(1) end, { buffer = buf, silent = true, nowait = true, desc = "Next search result" })
    vim.keymap.set(m, "<Up>", function() M.select_prev(1) end, { buffer = buf, silent = true, nowait = true, desc = "Previous search result" })
    vim.keymap.set(m, "<C-n>", function() M.select_next(1) end, { buffer = buf, silent = true, nowait = true, desc = "Next search result" })
    vim.keymap.set(m, "<C-p>", function() M.select_prev(1) end, { buffer = buf, silent = true, nowait = true, desc = "Previous search result" })
    vim.keymap.set(m, "<M-j>", function() M.select_next(1) end, { buffer = buf, silent = true, nowait = true, desc = "Next search result" })
    vim.keymap.set(m, "<M-k>", function() M.select_prev(1) end, { buffer = buf, silent = true, nowait = true, desc = "Previous search result" })
    vim.keymap.set(m, "<PageDown>", function() M.select_next(8) end, { buffer = buf, silent = true, nowait = true, desc = "Page down results" })
    vim.keymap.set(m, "<PageUp>", function() M.select_prev(8) end, { buffer = buf, silent = true, nowait = true, desc = "Page up results" })
    vim.keymap.set(m, "<C-d>", function() M.select_next(8) end, { buffer = buf, silent = true, nowait = true, desc = "Page down results" })
    vim.keymap.set(m, "<C-u>", function() M.select_prev(8) end, { buffer = buf, silent = true, nowait = true, desc = "Page up results" })
    vim.keymap.set(m, "<Tab>", function() M.activate_selected_result(false) end, { buffer = buf, silent = true, nowait = true, desc = "Preview selected result in editor" })
    vim.keymap.set(m, "<C-c>", close_action, { buffer = buf, silent = true, nowait = true, desc = "Close Find menu" })
    vim.keymap.set(m, "<M-q>", close_action, { buffer = buf, silent = true, nowait = true, desc = "Close Find menu" })
  end

  -- Normal-mode navigation & quick-jump shortcuts (matching :History)
  vim.keymap.set("n", "j", function() M.select_next(1) end, { buffer = buf, silent = true, nowait = true, desc = "Next search result" })
  vim.keymap.set("n", "k", function() M.select_prev(1) end, { buffer = buf, silent = true, nowait = true, desc = "Previous search result" })
  vim.keymap.set("n", "]", function() M.select_next(1) end, { buffer = buf, silent = true, nowait = true, desc = "Next search result" })
  vim.keymap.set("n", "[", function() M.select_prev(1) end, { buffer = buf, silent = true, nowait = true, desc = "Previous search result" })
  vim.keymap.set("n", "o", function() M.activate_selected_result(true) end, { buffer = buf, silent = true, nowait = true, desc = "Jump to selected result and close" })
  vim.keymap.set("n", "<2-LeftMouse>", function() M.activate_selected_result(true) end, { buffer = buf, silent = true, nowait = true, desc = "Jump to selected result" })
  vim.keymap.set("n", "p", function() M.activate_selected_result(false) end, { buffer = buf, silent = true, nowait = true, desc = "Preview selected result" })
  vim.keymap.set("n", "q", close_action, { buffer = buf, silent = true, nowait = true, desc = "Close Find menu" })
  vim.keymap.set("n", "<Esc>", close_action, { buffer = buf, silent = true, nowait = true, desc = "Close Find menu" })

  -- Redirect editing keys in Normal mode directly to the top Search Bar (Line 1)
  for _, edit_key in ipairs({ "i", "a", "I", "A", "/", "s", "C" }) do
    vim.keymap.set("n", edit_key, function()
      focus_search_bar(true)
    end, { buffer = buf, silent = true, nowait = true, desc = "Focus top search bar and edit query" })
  end

  -- Quick numeric jump 1..9 in Normal mode (matching :History)
  for num = 1, 9 do
    vim.keymap.set("n", tostring(num), function()
      if M.state.candidates and M.state.candidates[num] then
        M.activate_selected_result(true, num)
      end
    end, { buffer = buf, silent = true, nowait = true, desc = "Jump directly to result " .. num })
  end

  if opts.start_insert ~= false and query_str == "" then
    pcall(vim.cmd, "startinsert!")
  end

  return win, buf
end

--- Hybrid Deterministic Code & File Search (:Find [query] [in <locations...> | @<location>])
--- Opens the interactive floating menu with the search bar at the top and live results below it in the same box.
function M.find(query, root_override, callback)
  if type(root_override) == "function" then
    callback = root_override
    root_override = nil
  end
  query = vim.trim(query or "")
  return M.open_find_menu(query, root_override, callback)
end

--- Ask a question about the code: navigates to the exact lines that answer it
function M.ask(question, root_override, callback)
  if type(root_override) == "function" then
    callback = root_override
    root_override = nil
  end

  question = question or ""
  -- Unescape literal \n or \r\n from command-line arguments
  question = question:gsub("\\r\\n", "\n"):gsub("\\n", "\n")
  question = vim.trim(question)

  if question == "" then
    ui.open_multiline_input("Ask Code Question (multi-line & multi-question)", "", function(submitted_text)
      M.ask(submitted_text, root_override, callback)
    end)
    return
  end

  local root = root_override or ui.get_root_dir()
  local state = state_mod.state
  local llm_mod = require("agent.llm")
  local tasks_mod = require("agent.tasks")

  -- Identify currently open buffer and determine if it is genuinely relevant
  local cur_win = ui.get_primary_editor_win()
  local cur_buf = cur_win and vim.api.nvim_win_is_valid(cur_win) and vim.api.nvim_win_get_buf(cur_win)
  local cur_file = (cur_buf and vim.bo[cur_buf].buftype == "") and vim.api.nvim_buf_get_name(cur_buf) or ""
  local rel_cur_file = ""
  if cur_file ~= "" and not cur_file:match("^%a+://") then
    rel_cur_file = vim.fn.fnamemodify(cur_file, ":.")
  end

  local sub_questions = M.split_questions(question)
  local is_multi = (#sub_questions > 1)

  local candidates = {}
  local sub_candidates = {}

  if is_multi then
    for idx, sub_q in ipairs(sub_questions) do
      local cands = M.search_and_rank(sub_q, root)
      sub_candidates[idx] = cands
      for _, c in ipairs(cands) do
        table.insert(candidates, c)
      end
    end
  else
    candidates = M.search_and_rank(question, root)
    sub_candidates[1] = candidates
  end

  local cur_file_is_relevant = false
  for idx = 1, math.min(3, #candidates) do
    if candidates[idx].path == rel_cur_file then
      cur_file_is_relevant = true
      break
    end
  end

  local cand_lines = {}
  for i = 1, math.min(8, #candidates) do
    local c = candidates[i]
    table.insert(cand_lines, string.format("- %s:%d: %s", c.path, c.line, vim.trim(c.description or "")))
  end
  local cand_str = #cand_lines > 0 and ("\nRanked repository code matches:\n" .. table.concat(cand_lines, "\n")) or ""

  local anti_blind_comment_rule = ""
  if rel_cur_file ~= "" and not cur_file_is_relevant then
    anti_blind_comment_rule = string.format(
      "\nCRITICAL: Currently open file is '%s', which is UNRELATED to the question(s). Do NOT place active_target or comments in '%s'! Target the relevant file(s) (e.g. '%s').\n",
      rel_cur_file, rel_cur_file, candidates[1] and candidates[1].path or "the matching file"
    )
  end

  local prompt
  if is_multi then
    local q_list = {}
    for i, sq in ipairs(sub_questions) do
      table.insert(q_list, string.format("Question %d: '%s'", i, sq))
    end
    prompt = string.format(
      [[The developer asked MULTIPLE questions about the codebase:
%s%s%s

INSTRUCTIONS FOR MULTIPLE QUESTIONS:
1. active_target MUST pinpoint the exact file and line answering Question 1, with an in-line clarifying comment (e.g. // NOTE: ... or # NOTE: ... or -- NOTE: ...) in active_target.content.
2. In 'queue', provide an entry for EACH subsequent question (Question 2, Question 3, etc.) containing:
   - "path": repository-relative path to the file answering that question.
   - "line": line number answering that question.
   - "description": "[Q%%d] Summary of answer to Question %%d",
   - "content": concise in-line clarifying comment for that question.
3. Output STRICT JSON with "action": "navigate", "active_target": {...}, "queue": [...] ]],
      table.concat(q_list, "\n"), cand_str, anti_blind_comment_rule
    )
  else
    prompt = string.format(
      [[Code question: '%s'.%s%s

INSTRUCTIONS:
1. Pinpoint the exact source file and line answering this question.
2. In active_target.content, produce a concise, professional in-line comment (using the target language's native comment prefix, e.g. // NOTE: ... or # NOTE: ... or -- NOTE: ...) placed directly above the target line that makes the code self-documenting and clarifies the answer.
3. Output STRICT JSON with "action": "navigate", "active_target": {"path": "<file>", "line": <line>, "content": "<comment + target line>"}]],
      question, cand_str, anti_blind_comment_rule
    )
  end

  vim.api.nvim_echo({ { "● [Navigating to Code] ", "ModeMsg" }, { is_multi and string.format("Locating answers for %d questions...", #sub_questions) or "Locating line & preparing in-line clarification...", "Comment" } }, false, {})

  llm_mod.run(prompt, false, function(res)
    local target = res and res.active_target
    local function sanitize_item(it, default_best, label)
      if not it or not it.path or it.path == "" then
        if default_best then
          return {
            path = default_best.path,
            line = default_best.line,
            col = default_best.col or 1,
            action = "navigate",
            description = (label and ("[" .. label .. "] ") or "") .. default_best.description,
            content = nil,
          }
        end
        return nil
      end
      local t_path = vim.trim(it.path)
      if t_path:sub(1, #root) == root then
        t_path = t_path:sub(#root + 1):gsub("^/+", "")
      end
      t_path = t_path:gsub("^/+", ""):gsub("^%./", "")

      local full_t = t_path:match("^/") and t_path or (root .. "/" .. t_path)
      local full_c = cur_file ~= "" and (cur_file:match("^/") and cur_file or (root .. "/" .. cur_file)) or ""
      local is_blind = (full_t == full_c or t_path == rel_cur_file) and not cur_file_is_relevant
      local exists = (vim.fn.filereadable(full_t) == 1)

      if (not exists or is_blind) and default_best then
        local leader = tasks_mod.get_comment_leader(default_best.path)
        local comment_text = it.content and (it.content:match("NOTE:%s*(.*)") or it.content:match("[#/%-]+%s*(.*)") or it.content)
        local clean_content = comment_text and string.format("%s NOTE: %s", leader, vim.trim(comment_text)) or nil
        return {
          path = default_best.path,
          line = default_best.line,
          col = default_best.col or 1,
          action = "navigate",
          description = (label and ("[" .. label .. "] ") or "") .. default_best.description,
          content = clean_content,
        }
      end

      return {
        path = t_path,
        line = tonumber(it.line) or 1,
        col = tonumber(it.col) or 1,
        action = "navigate",
        description = (label and ("[" .. label .. "] ") or "") .. (it.description or t_path),
        content = it.content,
      }
    end

    local q1_best = (sub_candidates[1] and sub_candidates[1][1]) or candidates[1]
    target = sanitize_item(target, q1_best, is_multi and "Q1" or nil)

    local full_queue = {}
    if target then table.insert(full_queue, target) end

    if is_multi then
      if res and res.queue and #res.queue > 0 then
        for q_idx, q_item in ipairs(res.queue) do
          local sub_best = (sub_candidates[q_idx + 1] and sub_candidates[q_idx + 1][1]) or candidates[q_idx + 1]
          local clean_q = sanitize_item(q_item, sub_best, string.format("Q%d", q_idx + 1))
          if clean_q then table.insert(full_queue, clean_q) end
        end
      end

      if #full_queue < #sub_questions then
        for q_idx = #full_queue + 1, #sub_questions do
          local sub_c = sub_candidates[q_idx]
          if sub_c and #sub_c > 0 then
            local best_c = sub_c[1]
            local leader = tasks_mod.get_comment_leader(best_c.path)
            local clean_q = {
              path = best_c.path,
              line = best_c.line,
              col = best_c.col or 1,
              action = "navigate",
              description = string.format("[Q%d] %s", q_idx, best_c.description),
              content = string.format("%s NOTE: [Q%d] Answering: %s", leader, q_idx, sub_questions[q_idx]),
            }
            table.insert(full_queue, clean_q)
          end
        end
      end
    elseif res and res.queue and #res.queue > 0 then
      for _, q_item in ipairs(res.queue) do
        local clean_q = sanitize_item(q_item, nil, nil)
        if clean_q and (clean_q.path ~= target.path or clean_q.line ~= target.line) then
          table.insert(full_queue, clean_q)
        end
      end
    end

    if #full_queue == 0 and #candidates > 0 then
      full_queue = candidates
      target = candidates[1]
    end

    if target and target.path and (vim.fn.filereadable(root .. "/" .. target.path) == 1 or target.path:match("^/")) then
      state.queue = full_queue
      state.queue_index = 1
      tasks_mod.jump_to_target(target, cur_win)
      tasks_mod.update_queue_display(#full_queue > 1)
      if is_multi then
        vim.api.nvim_echo({
          { string.format("● [Code Located: %d Questions Answered] ", #full_queue), "ModeMsg" },
          { string.format("[Q1] %s:%d", target.path, target.line or 1), "Directory" },
          { " — Use <C-n> / :Tasks next to navigate all answers", "Normal" },
        }, false, {})
      else
        vim.api.nvim_echo({
          { "● [Code Located] ", "ModeMsg" },
          { string.format("%s:%d", target.path, target.line or 1), "Directory" },
          { target.description and (" — " .. target.description) or " (clarification previewed in-line)", "Normal" },
        }, false, {})
      end
      if callback then callback(target, full_queue) end
    elseif #candidates > 0 then
      local best = candidates[1]
      state.queue = candidates
      state.queue_index = 1
      tasks_mod.jump_to_target(best, cur_win)
      tasks_mod.update_queue_display(#candidates > 1)
      vim.api.nvim_echo({
        { "● [Code Located (Local)] ", "ModeMsg" },
        { string.format("%s:%d", best.path, best.line), "Directory" },
        { string.format(" — %s", best.description), "Normal" },
      }, false, {})
      if callback then callback(best, candidates) end
    else
      vim.notify("Could not locate code answering: '" .. question .. "'", vim.log.levels.WARN)
      if callback then callback(nil, {}) end
    end
  end)
end

return M
