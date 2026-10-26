local M = {}
local state_mod = require("agent.state")
local ui = require("agent.ui")

--- Record voice from microphone and transcribe using faster-whisper
function M.record_voice(callback)
  require("voice").record_once(callback)
end

--- Collect repository context summary (git files, active buffer context, and query keyword search)
function M.collect_context(prompt)
  local root = ui.get_root_dir()
  local files_out = vim.fn.system({ "git", "-C", root, "ls-files" })
  local file_list = {}
  if vim.v.shell_error == 0 and files_out ~= "" then
    for line in files_out:gmatch("[^\r\n]+") do
      if not line:match("%.olean$") and not line:match("%.tex$") and not line:match("%.jsonl$") and not line:match("%.log$") then
        if #file_list < 80 then
          table.insert(file_list, line)
        end
      end
    end
  end

  -- Fallback to find if not a git repo or git ls-files is empty
  if #file_list == 0 then
    local find_out = vim.fn.system({ "find", root, "-maxdepth", "3", "-not", "-path", "*/.*", "-not", "-path", "*/target/*", "-not", "-path", "*/node_modules/*", "-type", "f" })
    if vim.v.shell_error == 0 and find_out ~= "" then
      for line in find_out:gmatch("[^\r\n]+") do
        local rel = line:gsub("^" .. vim.pesc(root) .. "/?", "")
        if rel ~= "" and not rel:match("%.olean$") and not rel:match("%.tex$") and not rel:match("%.jsonl$") and #file_list < 80 then
          table.insert(file_list, rel)
        end
      end
    end
  end

  -- Search matches in repository for query keywords
  local search_matches = {}
  if prompt and prompt ~= "" then
    local stop_words = {
      ["where"]=true, ["did"]=true, ["we"]=true, ["implement"]=true, ["the"]=true,
      ["a"]=true, ["an"]=true, ["in"]=true, ["is"]=true, ["of"]=true, ["to"]=true,
      ["and"]=true, ["or"]=true, ["for"]=true, ["with"]=true, ["find"]=true,
      ["show"]=true, ["me"]=true, ["how"]=true, ["what"]=true, ["which"]=true,
      ["can"]=true, ["you"]=true, ["go"]=true, ["at"]=true, ["on"]=true,
      ["file"]=true, ["line"]=true, ["code"]=true, ["function"]=true, ["class"]=true,
      ["this"]=true, ["that"]=true, ["there"]=true, ["are"]=true, ["was"]=true,
      ["were"]=true, ["our"]=true, ["us"]=true, ["it"]=true, ["its"]=true,
      ["my"]=true, ["i"]=true, ["do"]=true, ["does"]=true, ["done"]=true,
      ["have"]=true, ["has"]=true, ["had"]=true, ["be"]=true, ["been"]=true,
      ["get"]=true, ["got"]=true, ["put"]=true, ["set"]=true,
    }
    local keywords = {}
    for word in prompt:lower():gmatch("[%a%d_-]+") do
      if #word >= 3 and not stop_words[word] then
        table.insert(keywords, word)
      end
    end

    for _, kw in ipairs(keywords) do
      local grep_out = vim.fn.system({ "git", "-C", root, "grep", "-n", "-I", "-i", kw, "--", ":!*.jsonl", ":!*.log", ":!*.json", ":!*.ipynb", ":!*.olean", ":!*.tex", ":!specs/.lexlean/*", ":!logs/*" })
      if vim.v.shell_error ~= 0 or grep_out == "" then
        local rg_bin = vim.fn.exepath("rg")
        if rg_bin ~= "" then
          grep_out = vim.fn.system({ rg_bin, "-n", "--no-heading", "-i", "-g", "!*.jsonl", "-g", "!*.log", "-g", "!*.json", "-g", "!*.ipynb", "-g", "!*.olean", "-g", "!*.tex", "-g", "!specs/.lexlean/*", "-g", "!logs/*", kw, root })
        else
          grep_out = vim.fn.system({ "grep", "-rn", "-I", "-i", "--exclude-dir=.git", "--exclude-dir=target", "--exclude-dir=logs", "--exclude-dir=.lexlean", "--exclude=*.jsonl", "--exclude=*.log", "--exclude=*.json", "--exclude=*.ipynb", "--exclude=*.olean", "--exclude=*.tex", kw, root })
        end
      end
      if grep_out and grep_out ~= "" then
        for gline in grep_out:gmatch("[^\r\n]+") do
          local rel = gline:gsub("^" .. vim.pesc(root) .. "/", "")
          local filepart = rel:match("^([^:]+)") or rel
          if not filepart:match("%.json")
            and not filepart:match("%.log")
            and not filepart:match("%.ipynb")
            and not filepart:match("%.olean")
            and not filepart:match("%.tex")
            and not filepart:match("/%.")
            and not filepart:match("^%.")
            and not filepart:match("^logs/")
            and #rel < 300 then
            if #search_matches < 35 then
              table.insert(search_matches, rel:sub(1, 200))
            else
              break
            end
          end
        end
      end
      if #search_matches >= 35 then break end
    end
  end

  local cur_win = ui.get_primary_editor_win()
  local cur_buf = vim.api.nvim_win_get_buf(cur_win)
  local cur_file = vim.api.nvim_buf_get_name(cur_buf)
  local rel_cur_file = ""
  if cur_file ~= "" and not cur_file:match("^%a+://") then
    rel_cur_file = vim.fn.fnamemodify(cur_file, ":.")
  end

  local cursor = vim.api.nvim_win_get_cursor(cur_win)
  local cur_line = cursor[1]
  local cur_col = cursor[2] + 1

  -- Snippet around cursor
  local snippet = ""
  if vim.api.nvim_buf_is_valid(cur_buf) and vim.bo[cur_buf].buftype == "" then
    local total_lines = vim.api.nvim_buf_line_count(cur_buf)
    local s_line = math.max(0, cur_line - 25)
    local e_line = math.min(total_lines, cur_line + 25)
    local lines = vim.api.nvim_buf_get_lines(cur_buf, s_line, e_line, false)
    snippet = table.concat(lines, "\n")
  end

  return {
    root = root,
    current_file = rel_cur_file,
    current_line = cur_line,
    current_col = cur_col,
    snippet = snippet,
    files = file_list,
    search_matches = search_matches,
  }
end

function M.parse_solution_from_raw(raw)
  if not raw or type(raw) ~= "string" or vim.trim(raw) == "" then
    return nil
  end

  -- 1. Reassemble text parts from opencode / agy streaming JSON Lines
  local full_text = ""
  for line in raw:gmatch("[^\r\n]+") do
    local ok, obj = pcall(vim.fn.json_decode, line)
    if ok and type(obj) == "table" then
      if obj.type == "text" and obj.part and obj.part.text then
        full_text = full_text .. obj.part.text
      elseif obj.response and type(obj.response) == "string" then
        full_text = full_text .. obj.response
      elseif obj.content then
        return obj
      end
    end
  end

  if full_text == "" then
    full_text = raw
  end

  -- 2. Direct JSON decode of full_text
  local ok, data = pcall(vim.fn.json_decode, vim.trim(full_text))
  if ok and type(data) == "table" and (data.content or data.code) then
    if not data.content and data.code then data.content = data.code end
    return data
  end

  -- 3. Check for ```json ... ``` code fence
  local json_block = full_text:match("```[jJ][sS][oO][nN]%s*\n(.-)\n%s*```")
  if json_block then
    local jok, jdata = pcall(vim.fn.json_decode, vim.trim(json_block))
    if jok and type(jdata) == "table" and (jdata.content or jdata.code) then
      if not jdata.content and jdata.code then jdata.content = jdata.code end
      return jdata
    end
  end

  -- 4. Delimiter-depth JSON object parser (string-literal aware)
  local s_idx = 1
  while s_idx <= #full_text do
    local b_start = full_text:find("{", s_idx, true)
    if not b_start then break end

    local depth = 0
    local in_str = false
    local escape = false
    local b_end = nil

    for i = b_start, #full_text do
      local c = full_text:sub(i, i)
      if escape then
        escape = false
      elseif c == "\\" then
        escape = true
      elseif c == '"' then
        in_str = not in_str
      elseif not in_str then
        if c == "{" then
          depth = depth + 1
        elseif c == "}" then
          depth = depth - 1
          if depth == 0 then
            b_end = i
            break
          end
        end
      end
    end

    if b_end then
      local candidate = full_text:sub(b_start, b_end)
      local cok, cdata = pcall(vim.fn.json_decode, candidate)
      if cok and type(cdata) == "table" and (cdata.content or cdata.code) then
        if not cdata.content and cdata.code then cdata.content = cdata.code end
        return cdata
      end
      s_idx = b_start + 1
    else
      break
    end
  end

  -- 5. Fallback: extract generic markdown code fence ```...``` if model wrote code directly
  local code_block = full_text:match("```[%w%-_]*%s*\n(.-)\n%s*```")
  if code_block and vim.trim(code_block) ~= "" then
    return {
      content = code_block,
      description = "Implementation from agent",
    }
  end

  -- 6. If we accumulated text fragments but never found a JSON wrapper, treat as direct content
  if full_text ~= "" and vim.trim(full_text):sub(1, 1) ~= "{" then
    return {
      content = full_text,
      description = "Agent response",
    }
  end

  return nil
end

--- Robust JSON extractor for LLM responses (supports raw JSON, NDJSON streaming from opencode/agy, markdown code blocks, and bracket scanning)
function M.extract_json_object(raw)
  if not raw or raw == "" then return nil end

  -- 0. Reassemble text parts from opencode / agy streaming JSON Lines if present
  local full_text = ""
  for line in raw:gmatch("[^\r\n]+") do
    local ok, obj = pcall(vim.fn.json_decode, line)
    if ok and type(obj) == "table" then
      if obj.type == "text" and obj.part and obj.part.text then
        full_text = full_text .. obj.part.text
      elseif obj.response and type(obj.response) == "string" then
        full_text = full_text .. obj.response
      end
    end
  end
  if full_text ~= "" then
    raw = full_text
  end

  -- 1. Try direct decode
  local ok, data = pcall(vim.fn.json_decode, vim.trim(raw))
  if ok and type(data) == "table" then return data end

  -- 2. Try markdown code block
  local block = raw:match("```json%s*\n(.-)\n%s*```") or raw:match("```%s*\n(.-)\n%s*```")
  if block then
    local ok_b, data_b = pcall(vim.fn.json_decode, vim.trim(block))
    if ok_b and type(data_b) == "table" then return data_b end
  end

  -- 3. Bracket scanner (favor objects with meaningful keys)
  local first_valid = nil
  local s_idx = 1
  while s_idx <= #raw do
    local b_start = raw:find("{", s_idx, true)
    if not b_start then break end
    local depth = 0
    local in_str = false
    local escape = false
    local b_end = nil
    for i = b_start, #raw do
      local c = raw:sub(i, i)
      if escape then
        escape = false
      elseif c == "\\" then
        escape = true
      elseif c == '"' then
        in_str = not in_str
      elseif not in_str then
        if c == "{" then
          depth = depth + 1
        elseif c == "}" then
          depth = depth - 1
          if depth == 0 then
            b_end = i
            break
          end
        end
      end
    end
    if b_end then
      local candidate = raw:sub(b_start, b_end)
      local cok, cdata = pcall(vim.fn.json_decode, candidate)
      if cok and type(cdata) == "table" then
        if cdata.parts or cdata.content or cdata.code or cdata.summary or cdata.task_id or cdata.action then
          return cdata
        end
        first_valid = first_valid or cdata
      end
      s_idx = b_start + 1
    else
      break
    end
  end
  return first_valid
end

--- Shared processor for agent JSON output
function M.process_agent_response(data, on_done)
  local state = state_mod.state
  local tasks_mod = require("agent.tasks")

  if not data or type(data) ~= "table" then
    vim.notify("Agent: Received invalid response from model", vim.log.levels.ERROR)
    if on_done then on_done(nil) end
    return
  end

  if data.action == "clean" then
    state.is_busy = false
    vim.notify("✓ Agent: Code logic check clean. No logical errors found.", vim.log.levels.INFO)
    if on_done then on_done(data) end
    return
  end

  local origin_win = state.origin_win or ui.get_primary_editor_win()

  -- 1. Determine primary target (file edit, new file, or proposed dir)
  local primary_target = nil
  if (data.action == "propose_dir" and not data.active_target) or (data.dir_preview and not data.active_target and not data.path) then
    local base_dir = ""
    local sugg = nil
    if type(data.dir_preview) == "table" then
      base_dir = data.dir_preview.base_dir or ""
      sugg = data.dir_preview.suggested or (data.dir_preview.entries and data.dir_preview.entries[1])
    elseif type(data.dir_preview) == "string" then
      sugg = data.dir_preview
    end
    local at = data.active_target or {}
    local raw_target = at.path or sugg or "new_file"
    local target_path = ui.resolve_suggested_path(base_dir, raw_target)
    local target_content = (type(at.content) == "string" and at.content) or (type(data.content) == "string" and data.content) or nil
    primary_target = {
      path = target_path,
      line = 1,
      col = 1,
      content = target_content,
      action = "create",
      is_new_file = true,
      description = at.description or data.description or ("Create new file " .. target_path),
    }
  elseif data.active_target or data.path then
    local at = data.active_target or {}
    local path = at.path or data.path
    local root = ui.get_root_dir()
    local fullpath = path:match("^/") and path or (root .. "/" .. path)
    local file_exists = (vim.fn.filereadable(fullpath) == 1)
    local is_nav = (data.action == "navigate" or at.action == "navigate")
    local is_new = not is_nav and (not file_exists or (data.action == "create_and_jump" or data.action == "create" or at.action == "create"))
    local final_action = is_nav and "navigate" or (is_new and "create" or (at.action or data.action or "replace"))
    primary_target = {
      path = path,
      line = tonumber(at.line) or tonumber(data.line) or 1,
      col = tonumber(at.col) or tonumber(data.col) or 1,
      content = (type(at.content) == "string" and at.content) or (type(data.content) == "string" and data.content) or nil,
      action = final_action,
      old_lines_count = (is_new or is_nav) and 0 or (tonumber(at.old_lines_count) or tonumber(data.old_lines_count) or (at.action == "replace" and 1 or 0)),
      is_new_file = is_new,
      description = at.description or data.description or (is_nav and ("Jump to " .. path) or (is_new and ("Create " .. path) or ("Modify " .. path))),
    }
  end

  -- 2. Build unified queue for bottom task pane, filtering out directory paths
  local root = ui.get_root_dir()
  local function is_dir(p)
    if not p or p == "" or p == "." or p == "./" then return true end
    local full = p:match("^/") and p or (root .. "/" .. p)
    return vim.fn.isdirectory(full) == 1
  end

  local queue = {}
  if primary_target and not is_dir(primary_target.path) then
    table.insert(queue, primary_target)
  end
  if data.queue and #data.queue > 0 then
    for _, q_item in ipairs(data.queue) do
      if not is_dir(q_item.path) then
        local q_path = q_item.path
        local q_full = q_path:match("^/") and q_path or (root .. "/" .. q_path)
        local q_exists = (vim.fn.filereadable(q_full) == 1)
        local q_is_nav = (data.action == "navigate" or q_item.action == "navigate")
        local q_is_new = not q_is_nav and (not q_exists or (q_item.action == "create"))
        q_item.is_new_file = q_is_new
        if q_is_nav then q_item.action = "navigate" end
        if not primary_target or q_item.path ~= primary_target.path or q_item.line ~= primary_target.line then
          table.insert(queue, q_item)
        end
      end
    end
  end

  if on_done then
    state.is_busy = false
    vim.cmd("redraw")
    on_done(data)
    return
  end

  if #queue > 0 then
    state.queue = queue
    state.queue_index = 1
    local cur = queue[1]
    state.last_target = cur
    tasks_mod.jump_to_target(cur, origin_win)
    if #queue > 1 then
      tasks_mod.update_queue_display(true)
    else
      tasks_mod.update_queue_display(false)
    end
  else
    vim.notify("Agent: Found no specific file matches to open", vim.log.levels.WARN)
  end

  state.is_busy = false
  vim.cmd("redraw")
end

--- Execute prompt against LLM and process silent structured response
function M.run(prompt, is_rejection, on_done)
  if not prompt or prompt == "" then
    if on_done then on_done(nil) end
    return
  end
  local state = state_mod.state
  state.origin_win = ui.get_primary_editor_win()
  state.last_prompt = prompt
  state.is_busy = true

  local root = ui.get_root_dir()
  pcall(vim.fn.chdir, root)

  local ctx = M.collect_context(prompt)
  local file_list_str = table.concat(ctx.files, "\n")

  local rejection_context = ""
  if is_rejection and state.last_target then
    rejection_context = string.format(
      "\nREJECTION FEEDBACK: The user rejected previous target file '%s' at line %d. Reason: '%s'. Propose an alternative suitable location or file.",
      state.last_target.path or "",
      state.last_target.line or 1,
      state.last_rejection or prompt
    )
  end

  local search_section = ""
  if ctx.search_matches and #ctx.search_matches > 0 then
    search_section = "\nSearch matches in repository for query terms:\n" .. table.concat(ctx.search_matches, "\n") .. "\n"
  end

  local system_prompt = [[
You are an autonomous Neovim code navigation agent.
CRITICAL INSTRUCTION: Do NOT call any tools or commands (do NOT run bash, grep, find, view_file, or any tools). All context is provided directly in this prompt.
NEVER reply with conversational chat, apologies, or natural language prose.
Output your verdict IMMEDIATELY in this turn as a single STRICT JSON object.

Repository context:
Project Root: ]] .. root .. [[

Current file: ]] .. ctx.current_file .. [[ (line ]] .. ctx.current_line .. [[)
Available repository files:
]] .. file_list_str .. [[
]] .. search_section .. [[

Snippet around cursor:
]] .. ctx.snippet .. rejection_context .. [[

User Instruction:
]] .. prompt .. [[

Navigation rules:
- For navigation and general code questions ("where did we implement X", "where is X", "find X", "show X", "how does X work", "why is Y done"):
  - Set "action": "navigate"
  - RELEVANCE GUARD: DO NOT place "active_target" in "Current file" unless "Current file" genuinely contains the code answering the user's question! If the question refers to concepts implemented elsewhere in the repository (inspect Available repository files and Search matches), you MUST set "active_target.path" to that relevant file and line. NEVER blindly comment on the opened file if it is not relevant!
  - Pinpoint the exact implementation file and line as "active_target"
  - In "active_target.content", if the code benefits from clarification, provide a crisp, professional in-line comment (using the language's native comment syntax: // or -- or #) to be inserted directly above the target line that indirectly answers the question by making the code self-documenting.
  - NEVER output conversational text or answers in chat. The code and in-line comment ARE the answer.
  - Populate "queue" with ALL other relevant matching files and lines from the search matches or file list
  - active_target.path MUST point to an actual file (NEVER a directory, NEVER ".")
- For new file requests: set "action": "create_and_jump" or "propose_dir"
- NEVER suggest a directory as active_target.path. Always choose a specific file.

Output STRICT JSON matching this schema:
{
  "action": "navigate" | "create_and_jump" | "propose_dir",
  "active_target": {
    "path": "relative/path/to/file",
    "line": 1,
    "col": 1,
    "description": "Brief description of this match",
    "content": "optional code snippet or implementation to suggest in-line"
  },
  "queue": [
    {"path": "file1", "line": 10, "col": 1, "description": "Match 1"},
    {"path": "file2", "line": 40, "col": 1, "description": "Match 2"}
  ],
  "dir_preview": {
    "base_dir": "path/to/directory",
    "entries": ["file1", "file2", "file3"],
    "suggested": "file3"
  }
}
Emit ONLY raw JSON. No markdown code blocks, no text before or after.
]]

  if state.active_job then
    pcall(function() state.active_job:kill(9) end)
    state.active_job = nil
  end

  local agy_bin = vim.fn.exepath("agy")
  local opencode_bin = vim.fn.exepath("opencode")
  local cmd = {}
  if agy_bin ~= "" then
    cmd = { agy_bin, "-p", system_prompt, "--model", "Gemini 3.8 Flash (Low)", "--print-timeout", "30s", "--dangerously-skip-permissions", "--disable-slash-commands" }
  elseif opencode_bin ~= "" then
    cmd = { opencode_bin, "run", "--format", "json", system_prompt }
  else
    state.is_busy = false
    vim.notify("Agent: Neither 'agy' nor 'opencode' found in PATH", vim.log.levels.ERROR)
    if on_done then on_done(nil) end
    return
  end

  vim.api.nvim_echo({ { "● [Agent] Analyzing codebase...", "ModeMsg" } }, false, {})
  vim.cmd("redraw")

  local job_timeout = vim.uv.new_timer()
  job_timeout:start(30000, 0, vim.schedule_wrap(function()
    if state.active_job then
      vim.notify("Agent: Request timed out after 30s. Cancelled.", vim.log.levels.WARN)
      pcall(function() state.active_job:kill(9) end)
      state.active_job = nil
      state.is_busy = false
      if on_done then on_done(nil) end
    end
    if job_timeout then
      pcall(function() job_timeout:stop(); job_timeout:close() end)
      job_timeout = nil
    end
  end))

  local stdout_chunks = {}
  state.active_job = vim.system(cmd, {
    text = true,
    stdout = function(_, data)
      if data then table.insert(stdout_chunks, data) end
    end,
  }, vim.schedule_wrap(function(res)
    state.active_job = nil
    if job_timeout then
      pcall(function() job_timeout:stop(); job_timeout:close() end)
      job_timeout = nil
    end
    local raw = table.concat(stdout_chunks, "")
    local data = nil

    -- 1. Direct parse of json output ({ "status": "SUCCESS", "response": "..." })
    local ok, res_obj = pcall(vim.fn.json_decode, raw)
    if ok and type(res_obj) == "table" then
      if res_obj.response and type(res_obj.response) == "string" then
        local rok, rdata = pcall(vim.fn.json_decode, res_obj.response)
        if rok and type(rdata) == "table" then
          data = rdata
        else
          local sub = res_obj.response:match("(%b{})")
          if sub then
            local sok, sdata = pcall(vim.fn.json_decode, sub)
            if sok and type(sdata) == "table" then
              data = sdata
            end
          end
        end
      elseif res_obj.action or res_obj.active_target or res_obj.queue or res_obj.dir_preview then
        data = res_obj
      end
    end

    -- 2. OpenCode format json stream (lines with type == "text" and part.text)
    if not data then
      for line in raw:gmatch("[^\r\n]+") do
        local lok, lobj = pcall(vim.fn.json_decode, line)
        if lok and type(lobj) == "table" and lobj.type == "text" and lobj.part and lobj.part.text then
          local ptext = lobj.part.text
          local pok, pdata = pcall(vim.fn.json_decode, ptext)
          if pok and type(pdata) == "table" and (pdata.action or pdata.active_target or pdata.content) then
            data = pdata
            break
          end
          local sub = ptext:match("(%b{})")
          if sub then
            local sok, sdata = pcall(vim.fn.json_decode, sub)
            if sok and type(sdata) == "table" and (sdata.action or sdata.active_target or sdata.content) then
              data = sdata
              break
            end
          end
        end
      end
    end

    -- 2. Try finding stream-json result event if stream format was used
    if not data then
      for line in raw:gmatch("[^\r\n]+") do
        if line:find('"event"%s*:%s*"result"') then
          local rok, robj = pcall(vim.fn.json_decode, line)
          if rok and robj and robj.result and robj.result.response then
            local resp_str = robj.result.response
            local sok, sdata = pcall(vim.fn.json_decode, resp_str)
            if sok and type(sdata) == "table" then
              data = sdata
              break
            end
            local sub = resp_str:match("(%b{})")
            if sub then
              local tok, tdata = pcall(vim.fn.json_decode, sub)
              if tok and type(tdata) == "table" then
                data = tdata
                break
              end
            end
          end
        end
      end
    end

    -- 3. Fallback: search for balanced JSON in full raw output
    if not data then
      for candidate in raw:gmatch("(%b{})") do
        local cok, cand_obj = pcall(vim.fn.json_decode, candidate)
        if cok and type(cand_obj) == "table" then
          if cand_obj.action or cand_obj.active_target or cand_obj.queue or cand_obj.dir_preview then
            data = cand_obj
            break
          end
        end
      end
    end

    M.process_agent_response(data, on_done)
  end))
end

--- Stop any active background agent job and clear all previews/diffs
function M.stop()
  local state = state_mod.state
  if state.active_job then
    pcall(function() state.active_job:kill(9) end)
    state.active_job = nil
  end
  state.is_busy = false
  local diff_mod = require("agent.diff")
  diff_mod.clear_diff()
  ui.close_dir_preview()
  vim.notify("Agent: Stopped active job and cleared state", vim.log.levels.INFO)
end

return M
