vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
-- vim.opt.scrolloff = 999
vim.opt.expandtab = true
vim.opt.smartindent = true
-- vim.opt.cursorcolumn = false
vim.opt.cursorline = true
vim.opt.number = true
vim.opt.mousescroll = "ver:1,hor:6"
vim.opt.clipboard = "unnamedplus"
vim.opt.splitright = true
vim.opt.splitbelow = true

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

-- Scroll by a fixed 10 lines instead of the default half-window jump
vim.keymap.set("n", "<C-d>", "10<C-d>")
vim.keymap.set("n", "<C-u>", "10<C-u>")
vim.keymap.set("v", "<C-d>", "10<C-d>")
vim.keymap.set("v", "<C-u>", "10<C-u>")

-- ── Monochrome colorscheme ──
vim.cmd("colorscheme mono")
vim.opt.signcolumn = "yes"

-- ── Terminal emulator: map the 16 ANSI colours to the monochrome palette ──
-- Without this, :terminal inherits the terminal's default (often low-contrast)
-- 16-colour palette. Map each slot to a black/white/grey value so terminal
-- programs look consistent with the rest of the config.
vim.api.nvim_create_autocmd("TermOpen", {
	pattern = "*",
	callback = function()
		vim.opt_local.background = "light"
		-- Terminal buffers are output, not files: no line numbers, no sign column
		-- (task: line numbers were showing up on the left of the terminal).
		vim.opt_local.number = false
		vim.opt_local.relativenumber = false
		vim.opt_local.signcolumn = "no"
		-- Force the terminal buffer to use the same Normal highlight as the rest
		-- of the config, so "special text" rendered in the terminal's default
		-- light-grey foreground becomes visible.
		vim.api.nvim_set_hl(0, "Normal", { fg = "#000000", bg = "#ffffff" })
		vim.api.nvim_set_hl(0, "NormalNC", { fg = "#666666", bg = "#ffffff" })
	end,
})

-- Map ANSI colour slots to greyscale hex values.
-- Slot 0-7: normal colours, slot 8-15: bright colours.
-- Dark enough to be readable on a white background (WCAG AA ≥ 4.5:1).
vim.g.terminal_color_0 = "#000000"  -- black
vim.g.terminal_color_1 = "#990000"  -- red (error) — dark enough to not wash out
vim.g.terminal_color_2 = "#006600"  -- green
vim.g.terminal_color_3 = "#b8860b"  -- yellow/amber (warning)
vim.g.terminal_color_4 = "#0000cc"  -- blue
vim.g.terminal_color_5 = "#660066"  -- magenta
vim.g.terminal_color_6 = "#006666"  -- cyan
vim.g.terminal_color_7 = "#555555"  -- white (was #888888 — too light)
vim.g.terminal_color_8 = "#444444"  -- bright black
vim.g.terminal_color_9 = "#990000"  -- bright red — dark enough to not wash out
vim.g.terminal_color_10 = "#006600" -- bright green
vim.g.terminal_color_11 = "#b8860b" -- bright yellow
vim.g.terminal_color_12 = "#0000cc" -- bright blue
vim.g.terminal_color_13 = "#660066" -- bright magenta
vim.g.terminal_color_14 = "#006666" -- bright cyan
vim.g.terminal_color_15 = "#ffffff" -- bright white

-- ── Window Tiling & Splits (Hyprland / Option A style) ──

-- Remember where the terminal we are in is `cd`-ed to, so a terminal opened
-- afterwards starts in that directory instead of the directory nvim itself was
-- launched from. (Task: after opening a file from a terminal, opening a new
-- terminal dropped you back in nvim's original cwd rather than the working
-- directory you were actually in.)
local last_term_cwd = nil
local function read_term_cwd()
	local pid = vim.b.terminal_job_pid
	if not pid then return nil end
	local ok, cwd = pcall(vim.uv.fs_readlink, "/proc/" .. pid .. "/cwd")
	if ok and cwd then return cwd end
	return nil
end
local function remember_term_cwd()
	local cwd = read_term_cwd()
	if cwd then last_term_cwd = cwd end
end

-- Track the cwd both on entering and on leaving a terminal, so a `cd` is picked
-- up even when the next terminal is opened from a file buffer. Focusing a
-- terminal split no longer auto-enters Terminal mode: that used to snap the
-- cursor to the command line at the bottom of the buffer on every switch, so
-- scrolling back through output and switching splits always jumped to the bottom.
-- Now the view (and Normal mode) stays put and you enter terminal mode by typing
-- (i/a/...), i.e. only when you actually start typing
-- (task: keep the cursor where the user was looking).
vim.api.nvim_create_autocmd({ "BufEnter", "TermEnter" }, {
	pattern = "term://*",
	callback = remember_term_cwd,
})
vim.api.nvim_create_autocmd("TermOpen", {
	pattern = "*",
	callback = remember_term_cwd,
})


-- <Esc> does both jobs a terminal needs it for: it leaves Terminal mode *when you
-- are at the shell prompt*, and is forwarded to the running program otherwise.
-- A bare <Esc> cannot unconditionally do both, so we tell the two situations
-- apart by looking at which process group owns the terminal's pty: while the
-- shell waits for input (nothing running) the foreground group is the shell's own
-- group, so we drop back to Normal mode; as soon as a child command is in the
-- foreground (a CLI app, a pager, ...) we pass <Esc> straight through. This is a
-- single-key mapping, so a lone <Esc> is handled immediately — unlike the old
-- <Esc><Esc> mapping, which made nvim hold every <Esc> for `timeoutlen` and thus
-- broke Esc inside CLI apps (task: esc key must work inside the terminal).
-- <C-\><C-n> still unconditionally leaves Terminal mode, even mid-command.
local function terminal_shell_is_foreground()
	local job = vim.b.terminal_job_id
	if not job then
		return true
	end
	local pid = vim.fn.jobpid(job)
	if type(pid) ~= "number" or pid <= 0 then
		return true
	end
	local fd = io.open("/proc/" .. pid .. "/stat")
	if not fd then
		return true
	end
	local stat = fd:read("*a")
	fd:close()
	-- After the last ')' the fields are: state ppid pgrp session tty_nr tpgid ...
	-- (the comm field between the first '(' and the last ')' may contain spaces).
	local rest = stat:match("%)%s*(.*)$")
	if not rest then
		return true
	end
	local fields = vim.split(rest, "%s+", { trimempty = true })
	local pgrp = tonumber(fields[3])
	local tpgid = tonumber(fields[6])
	return pgrp ~= nil and tpgid ~= nil and pgrp == tpgid
end

vim.keymap.set("t", "<Esc>", function()
	if terminal_shell_is_foreground() then
		vim.cmd("stopinsert") -- back to Normal mode, cursor stays put
	else
		vim.api.nvim_chan_send(vim.b.terminal_job_id, "\27")
	end
end, { desc = "Leave Terminal mode at the shell, else send <Esc> to the job" })

-- Scroll the focused terminal's scrollback with Ctrl+Shift+Up/Down (the keys used
-- for terminal scrolling elsewhere). Terminal mode forwards every key to the job,
-- so we first leave it (<C-\><C-n>) and then scroll the view with <C-y>/<C-e>.
-- Those move the *view* one line at a time while keeping the terminal's own cursor
-- pinned to the last line, so the job keeps running and new output still tails.
-- The Normal-mode twin keeps repeated presses scrolling after the first one; press
-- i/a to type again. Ghostty leaves these keys unbound so they reach nvim (see
-- ~/.config/ghostty/config); a full-screen job that wants them itself would need
-- to use different keys.
local function term_scroll(dir)
	if vim.bo.buftype == "terminal" then
		vim.cmd(dir == "up" and "normal! \25" or "normal! \5") -- C-y / C-e
	end
end
vim.keymap.set("t", "<C-S-Up>", "<C-\\><C-n><C-y>", { desc = "Scroll terminal scrollback up" })
vim.keymap.set("t", "<C-S-Down>", "<C-\\><C-n><C-e>", { desc = "Scroll terminal scrollback down" })
vim.keymap.set("n", "<C-S-Up>", function() term_scroll("up") end,
	{ desc = "Scroll terminal scrollback up" })
vim.keymap.set("n", "<C-S-Down>", function() term_scroll("down") end,
	{ desc = "Scroll terminal scrollback down" })

-- Helper function: determine the active path of the currently focused window/split.
-- If a file is open, use the file's parent directory.
-- If a terminal is open, use the terminal process's current working directory.
local function get_current_split_dir()
	local bufnr = vim.api.nvim_get_current_buf()

	-- 1. If currently in a terminal buffer, read the running shell's cwd from /proc
	if vim.bo[bufnr].buftype == "terminal" then
		local pid = vim.b[bufnr].terminal_job_pid
		if pid then
			local ok, cwd = pcall(vim.uv.fs_readlink, "/proc/" .. pid .. "/cwd")
			if ok and cwd and vim.fn.isdirectory(cwd) == 1 then
				return cwd
			end
		end
	end

	-- 2. If a file is open, use the directory containing the file
	local bufname = vim.api.nvim_buf_get_name(bufnr)
	if bufname ~= "" and not bufname:match("^term://") then
		local file_dir = vim.fn.fnamemodify(bufname, ":p:h")
		if file_dir and vim.fn.isdirectory(file_dir) == 1 then
			return file_dir
		end
	end

	-- 3. If window was opened from a terminal, check that origin terminal's cwd
	local term_origin = vim.w.terminal_origin
	if term_origin and vim.api.nvim_buf_is_valid(term_origin) then
		local pid = vim.b[term_origin].terminal_job_pid
		if pid then
			local ok, cwd = pcall(vim.uv.fs_readlink, "/proc/" .. pid .. "/cwd")
			if ok and cwd and vim.fn.isdirectory(cwd) == 1 then
				return cwd
			end
		end
	end

	-- 4. Fallback to last recorded terminal cwd or nvim global cwd
	if last_term_cwd and vim.fn.isdirectory(last_term_cwd) == 1 then
		return last_term_cwd
	end
	return vim.fn.getcwd()
end

local function open_terminal_split(split_cmd)
	local target_dir = get_current_split_dir()
	vim.cmd(split_cmd)
	if target_dir then
		vim.cmd("lcd " .. vim.fn.fnameescape(target_dir))
	end
	vim.cmd("terminal")
	vim.cmd("startinsert")
end

local function term_vsplit()
	open_terminal_split("vsplit")
end

local function term_split()
	open_terminal_split("split")
end

-- Split right / down with a new terminal (matches Hyprland Alt+Shift+= and Alt+Shift+-)
for _, mode in ipairs({ "n", "t", "i" }) do
	vim.keymap.set(mode, "<A-S-=>", term_vsplit, { desc = "Split right (terminal)" })
	vim.keymap.set(mode, "<A-+>", term_vsplit, { desc = "Split right (terminal)" })
	vim.keymap.set(mode, "<A-S-->", term_split, { desc = "Split down (terminal)" })
	vim.keymap.set(mode, "<A-_>", term_split, { desc = "Split down (terminal)" })
end

-- Seamless focus navigation across splits in Normal, Terminal, and Insert modes
for _, mode in ipairs({ "n", "t", "i" }) do
	vim.keymap.set(mode, "<A-Left>",  "<Cmd>wincmd h<CR>", { desc = "Focus left split" })
	vim.keymap.set(mode, "<A-Right>", "<Cmd>wincmd l<CR>", { desc = "Focus right split" })
	vim.keymap.set(mode, "<A-Up>",    "<Cmd>wincmd k<CR>", { desc = "Focus up split" })
	vim.keymap.set(mode, "<A-Down>",  "<Cmd>wincmd j<CR>", { desc = "Focus down split" })
end

-- Move the current split by swapping it with the adjacent split in the given
-- direction (like Hyprland's `movewindow`). It always trades places with the
-- *nearest* split, so if two splits sit to the left, one press only steps past
-- the first of them instead of jumping all the way to the edge.
--
-- Implemented by finding the neighbour with `wincmd h/j/k/l` and exchanging the
-- two windows' buffers. This works for row, column and grid layouts alike,
-- whereas `wincmd x` only exchanges windows adjacent in the internal list order.
local function swap_split(dir)
	local cur = vim.api.nvim_get_current_win()
	vim.cmd("wincmd " .. dir)
	local nb = vim.api.nvim_get_current_win()
	if nb == cur then
		return -- already at the edge in that direction
	end
	local bc = vim.api.nvim_win_get_buf(cur)
	local bn = vim.api.nvim_win_get_buf(nb)
	if bc == bn then
		return
	end
	local view_cur = vim.api.nvim_win_call(cur, vim.fn.winsaveview)
	local view_nb = vim.api.nvim_win_call(nb, vim.fn.winsaveview)
	vim.api.nvim_win_set_buf(cur, bn)
	vim.api.nvim_win_set_buf(nb, bc)
	vim.api.nvim_win_call(cur, function() pcall(vim.fn.winrestview, view_nb) end)
	vim.api.nvim_win_call(nb, function() pcall(vim.fn.winrestview, view_cur) end)
	vim.api.nvim_set_current_win(nb) -- focus follows the moved split
end

-- Move/swap split with neighbour using Alt+h/j/k/l (Normal, Terminal, Insert modes)
local swap_dirs = { h = "h", l = "l", k = "k", j = "j" }
for _, mode in ipairs({ "n", "t", "i" }) do
	for _, key in ipairs({ "h", "j", "k", "l" }) do
		vim.keymap.set(mode, "<A-" .. key .. ">", function() swap_split(swap_dirs[key]) end,
			{ desc = "Swap split " .. key .. " with neighbour" })
	end
end

-- ── Split Resizing: Static Trailing Edge Invariant ──────────────────────────
-- Each focused split owns exactly one vertical edge and one horizontal edge:
--   • Vertical axis: Trailing border (Right). If it's the right-most split,
--     it owns its inner border (Left).
--   • Horizontal axis: Trailing border (Bottom). If it's the bottom-most split,
--     it owns its inner border (Top).
-- Directional keys move that owned edge along the axis:
--   • Right ('l') / Left ('h') move the owned vertical edge Right (+) or Left (-).
--   • Down ('j') / Up ('k') move the owned horizontal edge Down (+) or Up (-).
local function resize_split(dir)
	local step = 2
	local cur = vim.api.nvim_get_current_win()

	local function neighbor(d)
		local n = vim.fn.winnr(d)
		if n == vim.fn.winnr() then
			return nil -- no window that way
		end
		return vim.fn.win_getid(n)
	end

	local function resize_win(win, delta, horizontal)
		vim.api.nvim_win_call(win, function()
			if horizontal then
				vim.cmd(string.format("vertical resize %+d", delta))
			else
				vim.cmd(string.format("resize %+d", delta))
			end
		end)
	end

	if dir == "h" or dir == "l" then
		-- Vertical edge (horizontal movement: left/right)
		local r_near = neighbor("l")
		local l_near = neighbor("h")
		local target = r_near and cur or l_near
		if not target then
			return
		end
		local delta = (dir == "l") and step or -step
		resize_win(target, delta, true)
	elseif dir == "j" or dir == "k" then
		-- Horizontal edge (vertical movement: down/up)
		local b_near = neighbor("j")
		local t_near = neighbor("k")
		local target = b_near and cur or t_near
		if not target then
			return
		end
		local delta = (dir == "j") and step or -step
		resize_win(target, delta, false)
	end
end

-- Ctrl+Alt+Arrows and Alt+Shift+Arrows, in Normal and Terminal modes.
for _, mode in ipairs({ "n", "t" }) do
	vim.keymap.set(mode, "<C-A-Left>", function() resize_split("h") end, { desc = "Move split border left" })
	vim.keymap.set(mode, "<C-A-Right>", function() resize_split("l") end, { desc = "Move split border right" })
	vim.keymap.set(mode, "<C-A-Up>", function() resize_split("k") end, { desc = "Move split border up" })
	vim.keymap.set(mode, "<C-A-Down>", function() resize_split("j") end, { desc = "Move split border down" })

	vim.keymap.set(mode, "<A-S-Left>", function() resize_split("h") end, { desc = "Move split border left" })
	vim.keymap.set(mode, "<A-S-Right>", function() resize_split("l") end, { desc = "Move split border right" })
	vim.keymap.set(mode, "<A-S-Up>", function() resize_split("k") end, { desc = "Move split border up" })
	vim.keymap.set(mode, "<A-S-Down>", function() resize_split("j") end, { desc = "Move split border down" })
end

-- Close active split/window
local function close_split()
	if #vim.api.nvim_tabpage_list_wins(0) > 1 then
		vim.cmd("close")
	else
		vim.notify("Only one window remaining", vim.log.levels.WARN)
	end
end

-- Alt+w and Alt+q work reliably across ALL terminal emulators (GNOME Terminal, Ghostty, etc.)
for _, mode in ipairs({ "n", "t", "i" }) do
	vim.keymap.set(mode, "<A-w>", close_split, { desc = "Close split" })
	vim.keymap.set(mode, "<A-q>", close_split, { desc = "Close split" })
	vim.keymap.set(mode, "<C-S-w>", close_split, { desc = "Close split" })
	vim.keymap.set(mode, "<C-S-W>", close_split, { desc = "Close split" })
end

-- Maximize ("zoom") the focused split: show it alone in a temporary tab, leaving
-- the real layout untouched in the tab behind it. The key again closes the tab
-- and restores everything exactly (same windows, buffers and sizes). `:tab split`
-- copies the window, so window-local options (number, wrap, ...) and the cursor
-- position carry over; parking the zoom in a tab avoids having to rebuild the
-- split layout by hand, and it keeps working the same in any terminal.
local function zoom_split()
	if vim.t.zoom_origin then
		local origin = vim.t.zoom_origin
		vim.t.zoom_origin = nil
		vim.cmd("tabclose")
		if vim.api.nvim_tabpage_is_valid(origin) then
			vim.api.nvim_set_current_tabpage(origin)
		end
		return
	end
	if #vim.api.nvim_tabpage_list_wins(0) < 2 then
		return -- single window: nothing to zoom
	end
	local origin = vim.api.nvim_get_current_tabpage()
	vim.cmd("tab split")
	vim.t.zoom_origin = origin
end

for _, mode in ipairs({ "n", "t", "i" }) do
	vim.keymap.set(mode, "<A-z>", zoom_split, { desc = "Zoom (maximize) split" })
end

-- ── Smart Quit: Return to Terminal Split on :q ──────────────────────────────
-- When a file is opened from a terminal split (e.g. via 'n file', 'nvim file',
-- $EDITOR, or :edit), quitting the file (:q, :wq, :x, :q!, ZZ, ZQ) returns to the
-- terminal split instead of closing the split/window.

local function is_buf_displayed_elsewhere(buf, exclude_win)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if w ~= exclude_win and vim.api.nvim_win_get_buf(w) == buf then
			return true
		end
	end
	return false
end

local function smart_quit(opts)
	opts = opts or {}
	local cur_win = vim.api.nvim_get_current_win()
	local cur_buf = vim.api.nvim_get_current_buf()

	-- Check if this window was previously showing a terminal buffer
	local term_buf = vim.w[cur_win].terminal_origin
	if term_buf and (not vim.api.nvim_buf_is_valid(term_buf) or vim.bo[term_buf].buftype ~= "terminal" or is_buf_displayed_elsewhere(term_buf, cur_win)) then
		term_buf = nil
	end

	-- Fallback to alternate buffer only if it's a valid terminal AND NOT displayed in another window
	if not term_buf then
		local alt = vim.fn.bufnr("#")
		if alt > 0 and vim.api.nvim_buf_is_valid(alt) and vim.bo[alt].buftype == "terminal" and not is_buf_displayed_elsewhere(alt, cur_win) then
			term_buf = alt
		end
	end

	-- If write requested (:wq, :x, ZZ)
	if opts.write then
		if vim.bo[cur_buf].modified then
			local ok, err = pcall(vim.cmd, "write")
			if not ok then
				vim.api.nvim_err_writeln(err or "Failed to write buffer")
				return
			end
		end
	elseif vim.bo[cur_buf].modified and not opts.force then
		vim.api.nvim_err_writeln("E37: No write since last change (add ! to override)")
		return
	end

	-- If this file was opened from a terminal in this window, return to the terminal
	if term_buf and vim.api.nvim_buf_is_valid(term_buf) and vim.bo[term_buf].buftype == "terminal" then
		vim.w[cur_win].terminal_origin = nil

		-- Switch window back to the terminal buffer
		vim.api.nvim_win_set_buf(cur_win, term_buf)

		-- Clean up the file buffer if it's not displayed anywhere else
		if not vim.bo[cur_buf].modified or opts.force then
			local shown_elsewhere = false
			for _, w in ipairs(vim.api.nvim_list_wins()) do
				if w ~= cur_win and vim.api.nvim_win_get_buf(w) == cur_buf then
					shown_elsewhere = true
					break
				end
			end
			if not shown_elsewhere and vim.bo[cur_buf].buftype == "" then
				pcall(vim.cmd, "bdelete! " .. cur_buf)
			end
		end

		-- Return directly to terminal input mode
		vim.cmd("startinsert")
		return
	end

	-- Fallback: standard quit behavior
	local cmd = "quit"
	if opts.write then cmd = "wq" end
	if opts.force then cmd = cmd .. "!" end
	pcall(vim.cmd, cmd)
end

vim.api.nvim_create_user_command("SmartQuit", function(ctx)
	smart_quit({ force = ctx.bang })
end, { bang = true, desc = "Quit file or return to terminal split" })

vim.api.nvim_create_user_command("SmartWriteQuit", function(ctx)
	smart_quit({ write = true, force = ctx.bang })
end, { bang = true, desc = "Save and quit file or return to terminal split" })

vim.api.nvim_create_user_command("TermEdit", function(ctx)
	local cur_win = vim.api.nvim_get_current_win()
	local cur_buf = vim.api.nvim_get_current_buf()
	if vim.bo[cur_buf].buftype == "terminal" then
		vim.w[cur_win].terminal_origin = cur_buf
	end
	vim.cmd("edit " .. vim.fn.fnameescape(ctx.args))
end, { nargs = 1, complete = "file", desc = "Edit file in place of terminal split" })

vim.api.nvim_create_autocmd("BufEnter", {
	pattern = "*",
	callback = function(ev)
		local cur_win = vim.api.nvim_get_current_win()
		local cur_buf = ev.buf
		local prev_win_buf = vim.w[cur_win].prev_window_buf

		-- If this window just switched away from a terminal buffer, record it as terminal_origin
		if prev_win_buf and prev_win_buf ~= cur_buf and vim.api.nvim_buf_is_valid(prev_win_buf) then
			if vim.bo[prev_win_buf].buftype == "terminal" and not is_buf_displayed_elsewhere(prev_win_buf, cur_win) then
				vim.w[cur_win].terminal_origin = prev_win_buf
			end
		end

		vim.w[cur_win].prev_window_buf = cur_buf
	end,
})

vim.cmd([[
  cnoreabbrev <expr> q (getcmdtype() ==# ':' && getcmdline() ==# 'q') ? 'SmartQuit' : 'q'
  cnoreabbrev <expr> q! (getcmdtype() ==# ':' && getcmdline() ==# 'q!') ? 'SmartQuit!' : 'q!'
  cnoreabbrev <expr> quit (getcmdtype() ==# ':' && getcmdline() ==# 'quit') ? 'SmartQuit' : 'quit'
  cnoreabbrev <expr> quit! (getcmdtype() ==# ':' && getcmdline() ==# 'quit!') ? 'SmartQuit!' : 'quit!'
  cnoreabbrev <expr> wq (getcmdtype() ==# ':' && getcmdline() ==# 'wq') ? 'SmartWriteQuit' : 'wq'
  cnoreabbrev <expr> wq! (getcmdtype() ==# ':' && getcmdline() ==# 'wq!') ? 'SmartWriteQuit!' : 'wq!'
  cnoreabbrev <expr> x (getcmdtype() ==# ':' && getcmdline() ==# 'x') ? 'SmartWriteQuit' : 'x'
  cnoreabbrev <expr> x! (getcmdtype() ==# ':' && getcmdline() ==# 'x!') ? 'SmartWriteQuit!' : 'x!'
]])

vim.keymap.set("n", "ZZ", function() smart_quit({ write = true }) end, { desc = "Save and quit or return to terminal" })
vim.keymap.set("n", "ZQ", function() smart_quit({ force = true }) end, { desc = "Quit without saving or return to terminal" })


-- ── LSP ──
require("lsp")

-- ── First-Time Feature Checklist & Onboarding ──
require("onboarding").setup()

-- ── Voice Transcription (:Listen) ──
require("voice").setup()

-- ── Autonomous Silent Code Agent ──
require("agent").setup()

vim.keymap.set("n", "<leader>q", "<Cmd>Tasks<CR>", { silent = true, desc = "Toggle tasks agenda (:Tasks)" })


-- ── Tab Navigation (Focused Full-Screen Tabs) ──
for i = 1, 9 do
	vim.keymap.set({ "n", "t", "i" }, string.format("<A-%d>", i), string.format("<Cmd>%dtabnext<CR>", i), { desc = string.format("Go to tab %d", i) })
end
vim.keymap.set({ "n", "t", "i" }, "<A-t>", "<Cmd>tabnew<CR>", { desc = "New tab" })
vim.keymap.set({ "n", "t", "i" }, "<A-]>", "<Cmd>tabnext<CR>", { desc = "Next tab" })
vim.keymap.set({ "n", "t", "i" }, "<A-[>", "<Cmd>tabprev<CR>", { desc = "Previous tab" })

-- Global statusline
vim.o.laststatus = 3
vim.opt.shortmess:append("cFWsAI")

-- ── Plugin manager (lazy.nvim) ──
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
	local lazyrepo = "https://github.com/folke/lazy.nvim.git"
	local out = vim.fn.system({
		"git",
		"clone",
		"--filter=blob:none",
		"--branch=stable",
		lazyrepo,
		lazypath,
	})
	if vim.v.shell_error ~= 0 then
		vim.api.nvim_echo({
			{ "Failed to clone lazy.nvim:\n", "ErrorMsg" },
			{ out, "WarningMsg" },
			{ "\nPress any key to exit..." },
		}, true, {})
		vim.fn.getchar()
		os.exit(1)
	end
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
	spec = {
		{ import = "plugins" },
	},
	checker = { enabled = false },
	change_detection = { notify = false },
})

-- ── Default to a terminal when started with no file ──
-- `nvim` with no arguments opens a shell in terminal mode, which suits using the
-- editor as a terminal multiplexer; `nvim <file>` still opens the file. Skipped
-- for headless/embedded runs, piped stdin (`echo x | nvim`), and when something
-- already populated the buffer (a plugin's start screen, for example).
vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		local untouched = vim.api.nvim_buf_get_name(0) == ""
			and vim.bo.buftype == ""
			and not vim.bo.modified
			and vim.api.nvim_buf_line_count(0) == 1
		if
			vim.fn.argc() == 0
			and vim.fn.has("ttyin") == 1
			and #vim.api.nvim_list_uis() > 0
			and untouched
		then
			-- Open the terminal on the next event-loop tick. Calling :terminal
			-- directly inside VimEnter creates the buffer but suppresses the
			-- buffer autocmds (BufNew/BufWinEnter/TermOpen/FileType never fire),
			-- so the TermOpen settings above (no line numbers, no sign column)
			-- would not be applied to this first terminal.
			vim.schedule(function()
				vim.cmd("terminal")
				-- :terminal enters Terminal-Job mode on its own, but be explicit
				-- so the very first shell is ready to type into.
				vim.cmd("startinsert")
			end)
		end
	end,
})
