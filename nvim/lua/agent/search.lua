local M = {}
local state_mod = require("agent.state")
local ui = require("agent.ui")

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
  for word in query:lower():gmatch("[%a%d_-]+") do
    if #word >= 3 and not stop_words[word] then
      table.insert(keywords, word)
    end
  end
  if #keywords == 0 then
    for word in query:gmatch("%S+") do
      table.insert(keywords, word:lower())
    end
  end
  return keywords
end

--- Search codebase and rank matches by definition confidence
function M.search_and_rank(query, root)
  root = root or ui.get_root_dir()
  local keywords = M.extract_search_keywords(query)
  if #keywords == 0 then return {} end

  local candidates = {}
  local seen_locs = {}

  -- 1. Check for filename matches across repository
  local find_cmd = { "git", "-C", root, "ls-files", "*" .. (keywords[1] or query) .. "*" }
  local find_out = vim.fn.system(find_cmd)
  if vim.v.shell_error == 0 and find_out ~= "" then
    for line in find_out:gmatch("[^\r\n]+") do
      if not line:match("%.olean$") and not line:match("%.jsonl$") and not line:match("%.log$") and not line:match("%.ipynb$") then
        local loc_key = line .. ":1"
        if not seen_locs[loc_key] then
          seen_locs[loc_key] = true
          table.insert(candidates, {
            path = line,
            line = 1,
            col = 1,
            action = "navigate",
            description = "[FILE] " .. line,
            score = 150,
          })
        end
      end
    end
  end

  local grep_matches = {}
  local pattern = table.concat(keywords, "|")
  local git_cmd = { "git", "-C", root, "grep", "--untracked", "-n", "-I", "-i", "-E", pattern, "--",
    ":!*.jsonl", ":!*.log", ":!*.json", ":!*.ipynb", ":!*.olean", ":!specs/.lexlean/*", ":!logs/*", ":!target/*" }
  local git_out = vim.fn.system(git_cmd)

  if vim.v.shell_error == 0 and git_out ~= "" then
    for line in git_out:gmatch("[^\r\n]+") do
      table.insert(grep_matches, line)
    end
  else
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
  end

  for _, line in ipairs(grep_matches) do
    local fpath, lnum, txt = line:match("^([^:]+):(%d+):(.*)$")
    if fpath and lnum and txt then
      local lnum_num = tonumber(lnum) or 1
      local loc_key = fpath .. ":" .. lnum_num
      if not seen_locs[loc_key] then
        seen_locs[loc_key] = true
        local txt_low = txt:lower()
        local fpath_low = fpath:lower()
        local query_low = query:lower()
        local score = 10

        -- Exact verbatim query match (+140)
        if txt:find(query, 1, true) then
          score = score + 140
        elseif txt_low:find(query_low, 1, true) then
          score = score + 90
        end

        -- Direct symbol definition match (+120)
        for _, kw in ipairs(keywords) do
          local pat1 = "fn%s+" .. kw
          local pat2 = "def%s+" .. kw
          local pat3 = "function%s+" .. kw
          local pat4 = "function%s+[%a0-9_]*[:%.]" .. kw
          local pat5 = "struct%s+" .. kw
          local pat6 = "class%s+" .. kw
          local pat7 = "theorem%s+" .. kw
          local pat8 = "type%s+" .. kw
          local pat9 = "let%s+" .. kw
          local pat10 = kw .. "%s*="
          if txt_low:find(pat1) or txt_low:find(pat2) or txt_low:find(pat3) or txt_low:find(pat4)
            or txt_low:find(pat5) or txt_low:find(pat6) or txt_low:find(pat7) or txt_low:find(pat8)
            or txt_low:find(pat9) or txt_low:find(pat10) then
            score = score + 120
            break
          end
        end

        -- Boost actual function/method implementation bodies (+60)
        if txt_low:find("=%s*function") or txt_low:find("function%s*[%a0-9_]*%s*%(") or txt_low:find("fn%s+[%a0-9_]+%s*%(") or txt_low:find("def%s+[%a0-9_]+%s*%(") then
          score = score + 60
        end

        -- Penalize forward stubs / nil initializations (-50)
        if txt_low:find("=%s*nil%s*$") or txt_low:find("=%s*none%s*$") or txt_low:find("=%s*null%s*$") then
          score = score - 50
        end

        -- Definition keywords (+50)
        if txt_low:find("%f[%a]struct%f[%A]")
          or txt_low:find("%f[%a]class%f[%A]")
          or txt_low:find("%f[%a]def%f[%A]")
          or txt_low:find("%f[%a]fn%f[%A]")
          or txt_low:find("%f[%a]theorem%f[%A]")
          or txt_low:find("%f[%a]lemma%f[%A]")
          or txt_low:find("%f[%a]axiom%f[%A]")
          or txt_low:find("%f[%a]type%f[%A]")
          or txt_low:find("%f[%a]typedef%f[%A]")
          or txt_low:find("%f[%a]enum%f[%A]")
          or txt_low:find("%f[%a]interface%f[%A]") then
          score = score + 50
        end

        -- Explanatory comment (+35)
        if txt_low:find("^%s*//") or txt_low:find("^%s*/%*") or txt_low:find("^%s*#") or txt_low:find("^%s*%-%-") then
          score = score + 35
        end

        -- Keyword match in filename (+40)
        for _, kw in ipairs(keywords) do
          if fpath_low:find(vim.pesc(kw)) then
            score = score + 40
            break
          end
        end

        -- Penalize generated tex / documentation files or huge lines (-50)
        if fpath_low:match("%.tex$") or fpath_low:match("%.md$") or fpath_low:match("%.txt$") or fpath_low:match("%.rst$") or #txt > 500 then
          score = score - 50
        end

        -- Boost code implementation files (+40)
        if fpath_low:match("%.hpp$") or fpath_low:match("%.cpp$") or fpath_low:match("%.rs$") or fpath_low:match("%.c$") or fpath_low:match("%.h$") or fpath_low:match("%.lean$") or fpath_low:match("%.py$") or fpath_low:match("%.lua$") or fpath_low:match("%.go$") then
          score = score + 40
        end

        -- Core source directories (+30)
        if fpath_low:find("^src/") or fpath_low:find("^lib/") or fpath_low:find("^include/") or fpath_low:find("^crates/") or fpath_low:find("^nvim/lua/") then
          score = score + 30
        end

        -- Penalize includes/imports (-25)
        if txt_low:find("^%s*#include") or txt_low:find("^%s*import%s") or txt_low:find("^%s*from%s.*import") then
          score = score - 25
        end

        -- Penalize tests if query is not asking for tests (-20)
        if (fpath_low:find("test") or fpath_low:find("tests/")) and not query:lower():find("test") then
          score = score - 20
        end

        table.insert(candidates, {
          path = fpath,
          line = lnum_num,
          col = 1,
          action = "navigate",
          description = vim.trim(txt),
          score = score,
        })
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

--- Semantic Code Search (:Find <concept|description>)
function M.find(query, root_override, callback)
  if type(root_override) == "function" then
    callback = root_override
    root_override = nil
  end
  query = vim.trim(query or "")
  if query == "" then
    vim.notify("Usage: :Find <concept or description of code>", vim.log.levels.INFO)
    if callback then callback(nil) end
    return
  end

  local root = root_override or ui.get_root_dir()
  local state = state_mod.state
  local llm_mod = require("agent.llm")
  local tasks_mod = require("agent.tasks")

  local cur_win = ui.get_primary_editor_win()
  local cur_buf = cur_win and vim.api.nvim_win_is_valid(cur_win) and vim.api.nvim_win_get_buf(cur_win)
  local cur_file = (cur_buf and vim.bo[cur_buf].buftype == "") and vim.api.nvim_buf_get_name(cur_buf) or ""
  local rel_cur_file = ""
  if cur_file ~= "" and not cur_file:match("^%a+://") then
    rel_cur_file = vim.fn.fnamemodify(cur_file, ":.")
  end

  local candidates = M.search_and_rank(query, root)
  local cur_file_is_relevant = false
  for idx = 1, math.min(3, #candidates) do
    if candidates[idx].path == rel_cur_file then
      cur_file_is_relevant = true
      break
    end
  end

  vim.api.nvim_echo({ { "● [Finding Code] ", "ModeMsg" }, { "Locating code with LLM...", "Comment" } }, false, {})
  local prompt = "where did we implement " .. query .. " (locate the exact source file and line implementing this logic)"
  llm_mod.run(prompt, false, function(res)
    local target = res and res.active_target
    local target_path = target and target.path and vim.trim(target.path) or ""
    if target_path:sub(1, #root) == root then
      target_path = target_path:sub(#root + 1):gsub("^/+", "")
    end
    target_path = target_path:gsub("^/+", ""):gsub("^%./", "")

    local full_target = target_path:match("^/") and target_path or (root .. "/" .. target_path)
    local full_cur = cur_file ~= "" and (cur_file:match("^/") and cur_file or (root .. "/" .. cur_file)) or ""

    local is_blind_open_file = (full_target == full_cur or target_path == rel_cur_file) and not cur_file_is_relevant
    local target_exists = (vim.fn.filereadable(full_target) == 1)

    if (not target or target_path == "" or not target_exists or is_blind_open_file) and #candidates > 0 then
      target = candidates[1]
    end

    if target and target.path and (vim.fn.filereadable(root .. "/" .. target.path) == 1 or target.path:match("^/")) then
      tasks_mod.jump_to_target(target, cur_win)
      tasks_mod.update_queue_display(state.queue and #state.queue > 1)
      vim.api.nvim_echo({
        { "● [Found] ", "ModeMsg" },
        { string.format("%s:%d", target.path, target.line or 1), "Directory" },
        { target.description and (" — " .. target.description) or "", "Normal" },
      }, false, {})
      if callback then callback(target) end
    else
      if #candidates > 0 then
        local best = candidates[1]
        state.queue = candidates
        state.queue_index = 1
        tasks_mod.jump_to_target(best, cur_win)
        tasks_mod.update_queue_display(#candidates > 1)
        vim.api.nvim_echo({
          { "● [Found (Local Fallback)] ", "ModeMsg" },
          { string.format("%s:%d", best.path, best.line), "Directory" },
          { string.format(" — %s (%d match%s)", best.description, #candidates, #candidates > 1 and "es" or ""), "Normal" },
        }, false, {})
        if callback then callback(best) end
      else
        vim.notify("No code found matching '" .. query .. "'", vim.log.levels.WARN)
        if callback then callback(nil) end
      end
    end
  end)
end

--- Ask a question about the code: navigates to the exact lines that answer it
function M.ask(question, root_override, callback)
  if type(root_override) == "function" then
    callback = root_override
    root_override = nil
  end
  question = vim.trim(question or "")
  if question == "" then
    vim.notify("Usage: :Ask <question about the code>", vim.log.levels.INFO)
    if callback then callback(nil) end
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

  local candidates = M.search_and_rank(question, root)
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
  local cand_str = #cand_lines > 0 and ("\nRanked repository code matches for this question:\n" .. table.concat(cand_lines, "\n")) or ""

  local anti_blind_comment_rule = ""
  if rel_cur_file ~= "" and not cur_file_is_relevant then
    anti_blind_comment_rule = string.format(
      "\nCRITICAL: Currently open file is '%s', which is UNRELATED to the question. Do NOT place active_target or comments in '%s'! Target the relevant file (e.g. '%s').\n",
      rel_cur_file, rel_cur_file, candidates[1] and candidates[1].path or "the matching file"
    )
  end

  local prompt = string.format(
    [[Code question: '%s'.%s%s

INSTRUCTIONS:
1. Pinpoint the exact source file and line answering this question.
2. In active_target.content, produce a concise, professional in-line comment (using the target language's native comment prefix, e.g. // NOTE: ... or # NOTE: ... or -- NOTE: ...) placed directly above the target line that makes the code self-documenting and clarifies the answer.
3. Output STRICT JSON with "action": "navigate", "active_target": {"path": "<file>", "line": <line>, "content": "<comment + target line>"}]],
    question, cand_str, anti_blind_comment_rule
  )

  vim.api.nvim_echo({ { "● [Navigating to Code] ", "ModeMsg" }, { "Locating line & preparing in-line clarification...", "Comment" } }, false, {})

  llm_mod.run(prompt, false, function(res)
    local target = res and res.active_target
    local target_path = target and target.path and vim.trim(target.path) or ""
    if target_path:sub(1, #root) == root then
      target_path = target_path:sub(#root + 1):gsub("^/+", "")
    end
    target_path = target_path:gsub("^/+", ""):gsub("^%./", "")

    local full_target = target_path:match("^/") and target_path or (root .. "/" .. target_path)
    local full_cur = cur_file ~= "" and (cur_file:match("^/") and cur_file or (root .. "/" .. cur_file)) or ""

    -- Guard against blindly targeting or commenting on an unrelated open buffer
    local is_blind_open_file = (full_target == full_cur or target_path == rel_cur_file) and not cur_file_is_relevant
    local target_exists = (vim.fn.filereadable(full_target) == 1)

    if (not target or target_path == "" or not target_exists or is_blind_open_file) and #candidates > 0 then
      local best = candidates[1]
      local clean_content = nil
      if target and type(target.content) == "string" and not is_blind_open_file then
        clean_content = target.content
      elseif target and type(target.content) == "string" and is_blind_open_file then
        local comment_text = target.content:match("NOTE:%s*(.*)") or target.content:match("[#/%-]+%s*(.*)") or target.content
        local leader = tasks_mod.get_comment_leader(best.path)
        clean_content = string.format("%s NOTE: %s", leader, vim.trim(comment_text))
      end

      target = {
        path = best.path,
        line = best.line,
        col = best.col or 1,
        action = "navigate",
        description = best.description,
        content = clean_content,
      }
    end

    if target and target.path and (vim.fn.filereadable(root .. "/" .. target.path) == 1 or target.path:match("^/")) then
      state.queue = (res and res.queue) or candidates
      state.queue_index = 1
      tasks_mod.jump_to_target(target, cur_win)
      tasks_mod.update_queue_display(state.queue and #state.queue > 1)
      vim.api.nvim_echo({
        { "● [Code Located] ", "ModeMsg" },
        { string.format("%s:%d", target.path, target.line or 1), "Directory" },
        { target.description and (" — " .. target.description) or " (clarification previewed in-line)", "Normal" },
      }, false, {})
      if callback then callback(target) end
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
      if callback then callback(best) end
    else
      vim.notify("Could not locate code answering: '" .. question .. "'", vim.log.levels.WARN)
      if callback then callback(nil) end
    end
  end)
end

return M
