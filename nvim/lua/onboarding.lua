local M = {}

local config_file = vim.fn.stdpath("config") .. "/syntra_config.json"
local sentinel_file = vim.fn.stdpath("state") .. "/syntra_onboarded"

-- Default features
local features = {
    {
        id = "whisper",
        name = "Faster-Whisper Voice Transcription (:v)",
        desc = "Voice-to-text dictation into active buffer via faster-whisper",
        enabled = true,
        check_dep = function()
            local py = vim.fn.expand("~/myenv/bin/python")
            if vim.fn.filereadable(py) == 1 then
                local out = vim.fn.system(py .. " -c 'import faster_whisper' 2>&1")
                return vim.v.shell_error == 0
            end
            return false
        end,
        dep_hint = "requires: faster-whisper in ~/myenv or python environment",
    },
    {
        id = "voice_assistant",
        name = "Speech-to-Speech Assistant",
        desc = "Full audio assistant loop: Faster-Whisper -> OpenCode/OpenRouter -> Piper TTS",
        enabled = true,
        check_dep = function()
            local agent_script = vim.fn.expand("~/code/agent/scripts/start.sh")
            return vim.fn.filereadable(agent_script) == 1 and vim.fn.executable("opencode") == 1
        end,
        dep_hint = "requires: ~/code/agent + opencode + piper",
    },
}

function M.load_config()
    if vim.fn.filereadable(config_file) == 1 then
        local raw = vim.fn.readfile(config_file)
        local ok, data = pcall(vim.json.decode, table.concat(raw, "\n"))
        if ok and type(data) == "table" then
            for _, f in ipairs(features) do
                if data[f.id] ~= nil then
                    f.enabled = data[f.id]
                end
            end
        end
    end
end

function M.save_config()
    local data = {}
    for _, f in ipairs(features) do
        data[f.id] = f.enabled
    end
    local raw = vim.json.encode(data)
    vim.fn.writefile({ raw }, config_file)
    -- Mark sentinel so it doesn't pop up automatically again
    vim.fn.mkdir(vim.fn.fnamemodify(sentinel_file, ":h"), "p")
    vim.fn.writefile({ os.date("!%Y-%m-%dT%TZ") }, sentinel_file)
end

function M.is_feature_enabled(id)
    for _, f in ipairs(features) do
        if f.id == id then
            return f.enabled
        end
    end
    return false
end

function M.open_checklist()
    M.load_config()

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "syntra-checklist"

    local width = math.min(76, vim.o.columns - 4)
    local height = (#features * 3) + 7
    local row = math.max(1, math.floor((vim.o.lines - height) / 2))
    local col = math.max(1, math.floor((vim.o.columns - width) / 2))

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = " Syntra Neovim OS — Feature Checklist ",
        title_pos = "center",
    })

    local line_to_feature = {}

    local function render()
        local lines = {
            "  Configure optional Syntra features for this environment:",
            "  ─────────────────────────────────────────────────────────────",
            "",
        }
        line_to_feature = {}

        for idx, f in ipairs(features) do
            local mark = f.enabled and "[x]" or "[ ]"
            local dep_ok = f.check_dep()
            local status_tag = dep_ok and "✓ ready" or "! dep missing"
            local header = string.format("  %s %s  (%s)", mark, f.name, status_tag)
            table.insert(lines, header)
            line_to_feature[#lines] = idx
            table.insert(lines, string.format("      %s", f.desc))
            if not dep_ok then
                table.insert(lines, string.format("      Hint: %s", f.dep_hint))
            else
                table.insert(lines, "")
            end
        end

        table.insert(lines, "  ─────────────────────────────────────────────────────────────")
        table.insert(lines, "  <Space>: Toggle | <Enter>: Save & Apply | <q>/<Esc>: Close")

        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
    end

    render()

    -- Set initial cursor on first feature line
    vim.api.nvim_win_set_cursor(win, { 4, 2 })

    local function toggle_current()
        local cursor = vim.api.nvim_win_get_cursor(win)
        local cur_line = cursor[1]
        local feat_idx = line_to_feature[cur_line]
        if not feat_idx then
            -- Check if cursor is on description/hint line belonging to a feature
            for l = cur_line, math.max(1, cur_line - 2), -1 do
                if line_to_feature[l] then
                    feat_idx = line_to_feature[l]
                    break
                end
            end
        end
        if feat_idx then
            features[feat_idx].enabled = not features[feat_idx].enabled
            render()
            vim.api.nvim_win_set_cursor(win, cursor)
        end
    end

    local function save_and_close()
        M.save_config()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
        vim.notify("Syntra features saved successfully!", vim.log.levels.INFO)
    end

    local function close_without_saving()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end

    -- Keymaps
    local opts = { buffer = buf, silent = true, nowait = true }
    vim.keymap.set("n", "<Space>", toggle_current, opts)
    vim.keymap.set("n", "<CR>", save_and_close, opts)
    vim.keymap.set("n", "q", close_without_saving, opts)
    vim.keymap.set("n", "<Esc>", close_without_saving, opts)
end

function M.setup()
    M.load_config()

    -- Register user commands
    vim.api.nvim_create_user_command("SyntraFeatures", function()
        M.open_checklist()
    end, { desc = "Configure Syntra optional features checklist" })

    vim.api.nvim_create_user_command("SyntraSetup", function()
        M.open_checklist()
    end, { desc = "Open Syntra setup wizard" })

    -- Check first-time run
    if vim.fn.filereadable(sentinel_file) == 0 and vim.fn.filereadable(config_file) == 0 then
        -- Trigger on first VimEnter if started interactively with no specific file
        vim.api.nvim_create_autocmd("VimEnter", {
            once = true,
            callback = function()
                if vim.fn.has("ttyin") == 1 and #vim.api.nvim_list_uis() > 0 then
                    vim.defer_fn(function()
                        M.open_checklist()
                    end, 100)
                end
            end,
        })
    end
end

return M
