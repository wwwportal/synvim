local M = {}

local py = vim.fn.expand("~/myenv/bin/python")
local stream_file = "/tmp/syntra_voice_stream.out"
local stream_pid = nil
local timer = nil
local last_line = 0

--- Check if voice stream process is actively running
function M.is_active()
    if stream_pid and vim.fn.jobwait({ stream_pid }, 0)[1] == -1 then
        return true
    end
    -- Check system process in case process was started outside or before reload
    local check = vim.fn.system("pgrep -f '[s]yntra_voice_stream.py' 2>/dev/null")
    return vim.v.shell_error == 0 and check:match("%d+") ~= nil
end

--- Stop active transcription stream and polling timer
function M.stop()
    if timer then
        pcall(function() timer:stop(); timer:close() end)
        timer = nil
    end

    if stream_pid then
        pcall(vim.fn.jobstop, stream_pid)
        stream_pid = nil
    end

    -- Kill any lingering python stream processes
    vim.fn.system("pkill -9 -f syntra_voice_stream.py 2>/dev/null || true")

    vim.notify("✓ :Listen voice transcription stopped", vim.log.levels.INFO)
end

--- Start continuous transcription stream into active buffer
function M.start()
    if M.is_active() then
        M.stop()
    end

    -- Clear stream output file
    vim.fn.system("> " .. stream_file)
    last_line = 0

    stream_pid = vim.fn.jobstart({ py, "/tmp/syntra_voice_stream.py" })
    if stream_pid <= 0 then
        vim.notify("Failed to start voice stream", vim.log.levels.ERROR)
        stream_pid = nil
        return
    end

    vim.notify("● :Listen voice transcription active (run :Listen or :Listen stop to disable)", vim.log.levels.INFO)

    timer = vim.uv.new_timer()
    timer:start(500, 500, vim.schedule_wrap(function()
        if not vim.api.nvim_buf_is_valid(0) then return end
        if vim.fn.filereadable(stream_file) ~= 1 then return end

        local lines = vim.fn.readfile(stream_file)
        if #lines <= last_line then return end

        local cur_buf = vim.api.nvim_get_current_buf()
        local cur_win = vim.api.nvim_get_current_win()
        local row, col = unpack(vim.api.nvim_win_get_cursor(cur_win))
        local inserted = false

        for i = last_line + 1, #lines do
            local text = lines[i]:gsub("\r", ""):gsub("\n", "")
            if text ~= "" then
                local line_text = vim.api.nvim_buf_get_lines(cur_buf, row - 1, row, false)[1] or ""
                local before = line_text:sub(1, col)
                local after = line_text:sub(col + 1)
                local was_mod = vim.bo[cur_buf].modifiable
                vim.bo[cur_buf].modifiable = true
                local sep = " "
                vim.api.nvim_buf_set_lines(cur_buf, row - 1, row, false, { before .. text .. sep .. after })
                vim.bo[cur_buf].modifiable = was_mod
                col = #before + #text + #sep
                inserted = true
            end
        end

        if inserted then
            vim.api.nvim_win_set_cursor(cur_win, { row, col })
        end
        last_line = #lines
    end))
end

--- Record a single utterance via arecord and transcribe using faster-whisper
function M.record_once(callback)
    local arecord_bin = vim.fn.exepath("arecord")
    if arecord_bin == "" then
        vim.notify("Voice: 'arecord' audio utility not found", vim.log.levels.ERROR)
        return
    end

    local wav_file = "/tmp/voice_input_" .. tostring(os.time()) .. ".wav"
    pcall(vim.fn.delete, wav_file)

    local job = vim.fn.jobstart({ arecord_bin, "-q", "-r", "16000", "-c", "1", "-f", "S16_LE", "-t", "wav", wav_file })
    if job <= 0 then
        vim.notify("Voice: Failed to start audio recording", vim.log.levels.ERROR)
        return
    end

    vim.cmd("redraw")
    local input = vim.fn.input({
        prompt = "● [Voice Recording] Speak your request, then press <Enter> to send: ",
        cancelreturn = "__CANCEL__",
    })

    pcall(vim.fn.jobstop, job)

    if input == "__CANCEL__" then
        pcall(vim.fn.delete, wav_file)
        vim.notify("Voice: Recording cancelled", vim.log.levels.INFO)
        return
    end

    vim.api.nvim_echo({ { "● Transcribing audio with faster-whisper...", "ModeMsg" } }, false, {})
    vim.cmd("redraw")

    local text = ""
    local scribe_bin = vim.fn.exepath("scribe")
    if scribe_bin ~= "" then
        local out = vim.fn.system({ scribe_bin, "-q", "-f", wav_file })
        text = vim.trim(out or "")
    else
        local py_bin = vim.fn.expand("~/myenv/bin/python")
        local root = vim.fs.root(0, { ".git" }) or vim.fn.getcwd()
        local transcribe_script = root .. "/bin/agent_transcribe.py"
        if vim.fn.filereadable(transcribe_script) ~= 1 then
            transcribe_script = vim.fn.expand("~/.local/bin/agent_transcribe.py")
        end

        local cmd = { py_bin, transcribe_script, wav_file }
        local out = vim.fn.system(cmd)
        text = vim.trim(out or "")
    end
    pcall(vim.fn.delete, wav_file)

    if text == "" then
        vim.notify("Voice: No speech detected", vim.log.levels.WARN)
        return
    end

    vim.api.nvim_echo({
        { "● [Voice Input] ", "Directory" },
        { '"' .. text .. '"', "Normal" },
    }, false, {})

    if callback then
        callback(text)
    end
end

--- Toggle transcription state
function M.toggle()
    if M.is_active() then
        M.stop()
    else
        M.start()
    end
end

function M.setup()
    vim.api.nvim_create_user_command("Listen", function(ctx)
        local arg = vim.trim(ctx.args or ""):lower()
        if arg == "stop" or arg == "off" then
            M.stop()
        elseif arg == "start" or arg == "on" then
            M.start()
        elseif arg == "status" then
            local active = M.is_active()
            vim.notify("Voice transcription is currently " .. (active and "ACTIVE (listening)" or "INACTIVE"), vim.log.levels.INFO)
        else
            M.toggle()
        end
    end, {
        nargs = "?",
        complete = function(arglead)
            local subcmds = { "start", "stop", "toggle", "status" }
            return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, subcmds)
        end,
        desc = "Toggle or manage voice transcription (:Listen [start|stop|status])",
    })

    vim.keymap.set("n", "<leader>v", function()
        M.toggle()
    end, { desc = "Toggle voice transcription" })
end

return M
