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
