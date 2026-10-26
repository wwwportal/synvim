-- ==============================================================================
-- agent/image.lua: Native Kitty Graphics Protocol Image Viewer via LuaJIT FFI
-- Uses libsynvim_image.so (C++20 + libpng) for sub-millisecond in-memory RGBA
-- viewport cropping, PNG encoding, and base64 Kitty escape chunk generation.
-- ==============================================================================

local M = {}
local ffi = require("ffi")

ffi.cdef[[
  typedef struct {
    int x;
    int y;
    int w;
    int h;
  } SynvimCropRect;

  typedef struct {
    int ok;
    int width;
    int height;
    const char* error;
  } SynvimImageMeta;

  typedef struct {
    int ok;
    int img_w;
    int img_h;
    SynvimCropRect crop;
    const char* payload;
    size_t payload_len;
    const char* error;
  } SynvimKittyRenderResult;

  SynvimCropRect synvim_image_compute_crop(
    int img_w,
    int img_h,
    double scale,
    double pan_x,
    double pan_y
  );

  SynvimImageMeta synvim_image_inspect(const char* filepath);

  SynvimKittyRenderResult synvim_image_render_kitty(
    const char* filepath,
    int image_id,
    double scale,
    double pan_x,
    double pan_y,
    int term_row,
    int term_col,
    int win_cols,
    int win_rows
  );

  const char* synvim_image_build_kitty_payload(
    const unsigned char* png_bytes,
    size_t png_len,
    int image_id,
    int term_row,
    int term_col,
    int win_cols,
    int win_rows
  );

  const char* synvim_image_build_kitty_delete(int image_id);

  void synvim_image_invalidate_cache(const char* filepath);

  const char* synvim_image_version(void);
]]

local function find_image_library()
  local candidates = {
    vim.fn.getcwd() .. "/build/libsynvim_image.so",
    (function()
      local git_root = vim.fs.root(0, { ".git" })
      return git_root and (git_root .. "/build/libsynvim_image.so") or nil
    end)(),
    (function()
      local src = debug.getinfo(1, "S").source:sub(2)
      local repo = vim.fn.fnamemodify(src, ":p:h:h:h:h")
      return repo .. "/build/libsynvim_image.so"
    end)(),
    vim.fn.expand("~/.local/lib/libsynvim_image.so"),
    vim.fn.stdpath("config") .. "/build/libsynvim_image.so",
    "/usr/local/lib/libsynvim_image.so",
    "libsynvim_image.so",
  }

  for _, path in ipairs(candidates) do
    if path then
      local ok, lib = pcall(ffi.load, path)
      if ok and lib then
        return lib, path
      end
    end
  end
  return nil, nil
end

local image_lib, image_lib_path = find_image_library()

M.states = {}
local next_image_id = 100

function M.is_available()
  return image_lib ~= nil
end

function M.library_path()
  return image_lib_path
end

function M.version()
  if not image_lib then
    error("FATAL: Native Image library (libsynvim_image.so) is not loaded.")
  end
  return ffi.string(image_lib.synvim_image_version())
end

function M.compute_crop_rect(img_w, img_h, scale, pan_x, pan_y)
  if not image_lib then
    error("FATAL: Native Image library (libsynvim_image.so) is not loaded.")
  end
  local c = image_lib.synvim_image_compute_crop(
    tonumber(img_w) or 1,
    tonumber(img_h) or 1,
    tonumber(scale) or 1.0,
    tonumber(pan_x) or 0.5,
    tonumber(pan_y) or 0.5
  )
  return { x = c.x, y = c.y, w = c.w, h = c.h }
end

function M.build_kitty_payload(png_bytes, opts)
  opts = opts or {}
  if not image_lib then
    error("FATAL: Native Image library (libsynvim_image.so) is not loaded.")
  end
  local raw = tostring(png_bytes or "")
  local ptr = image_lib.synvim_image_build_kitty_payload(
    ffi.cast("const unsigned char*", raw),
    #raw,
    tonumber(opts.id) or 1,
    tonumber(opts.row) or 1,
    tonumber(opts.col) or 1,
    tonumber(opts.cols) or 80,
    tonumber(opts.rows) or 24
  )
  return ptr ~= nil and ffi.string(ptr) or ""
end

function M.build_kitty_delete(image_id)
  if not image_lib then
    error("FATAL: Native Image library (libsynvim_image.so) is not loaded.")
  end
  local ptr = image_lib.synvim_image_build_kitty_delete(tonumber(image_id) or 1)
  return ptr ~= nil and ffi.string(ptr) or ""
end

local function write_tty(payload)
  if not payload or payload == "" then return false end
  if #vim.api.nvim_list_uis() == 0 then return false end
  local tty = io.open("/dev/tty", "wb")
  if not tty then return false end
  tty:write(payload)
  tty:flush()
  tty:close()
  return true
end

local function resolve_png_path(filepath)
  local ext = vim.fn.fnamemodify(filepath, ":e"):lower()
  if ext == "png" then
    return filepath
  end
  -- Convert non-PNG formats (SVG, JPG, WEBP, GIF) once via ImageMagick to a cached PNG
  if vim.fn.executable("convert") == 1 then
    local cache_dir = vim.fn.stdpath("cache") .. "/synvim_images"
    vim.fn.mkdir(cache_dir, "p")
    local hash = vim.fn.sha256(filepath)
    local out_png = cache_dir .. "/" .. hash:sub(1, 16) .. ".png"
    vim.fn.system({ "convert", filepath .. "[0]", out_png })
    if vim.v.shell_error == 0 and vim.fn.filereadable(out_png) == 1 then
      return out_png
    end
  end
  return filepath
end

function M.render(bufnr)
  local st = M.states[bufnr]
  if not st or not vim.api.nvim_buf_is_valid(bufnr) then return nil end

  local win = st.win
  if not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == bufnr then
        win = w
        st.win = w
        break
      end
    end
  end

  local term_row, term_col = 2, 1
  local win_cols, win_rows = 80, 24
  if win and vim.api.nvim_win_is_valid(win) then
    local ok_pos, pos = pcall(vim.fn.win_screenpos, win)
    if ok_pos and type(pos) == "table" and pos[1] and pos[2] then
      term_row = math.max(1, pos[1] + 1) -- leave line 1 of buffer for status header
      term_col = math.max(1, pos[2])
    end
    win_cols = math.max(10, vim.api.nvim_win_get_width(win) - 2)
    win_rows = math.max(4, vim.api.nvim_win_get_height(win) - 2)
  end

  local png_path = resolve_png_path(st.filepath)
  local res = image_lib.synvim_image_render_kitty(
    png_path,
    st.image_id,
    st.scale,
    st.pan_x,
    st.pan_y,
    term_row,
    term_col,
    win_cols,
    win_rows
  )

  if res.ok == 1 then
    st.img_w = res.img_w
    st.img_h = res.img_h
    st.last_crop = { x = res.crop.x, y = res.crop.y, w = res.crop.w, h = res.crop.h }
    st.last_escape_payload = (res.payload ~= nil and res.payload_len > 0)
      and ffi.string(res.payload, res.payload_len)
      or ""
    write_tty(st.last_escape_payload)
  else
    st.last_error = res.error ~= nil and ffi.string(res.error) or "Failed to render image"
  end

  -- Update header line in buffer
  local fname = vim.fn.fnamemodify(st.filepath, ":t")
  local header = string.format(
    " 🖼  %s (%dx%d) │ Zoom: %.2fx │ Crop: %dx%d+%d+%d │ [+/=]:Zoom In [-]:Zoom Out [h/j/k/l]:Pan [0]:Reset [q]:Quit",
    fname,
    st.img_w or 0,
    st.img_h or 0,
    st.scale or 1.0,
    st.last_crop and st.last_crop.w or 0,
    st.last_crop and st.last_crop.h or 0,
    st.last_crop and st.last_crop.x or 0,
    st.last_crop and st.last_crop.y or 0
  )
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { header })
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false

  return st
end

function M.zoom(bufnr, new_scale, is_factor)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.states[bufnr]
  if not st then return nil end
  if is_factor then
    st.scale = math.max(1.0, math.min(16.0, st.scale * (tonumber(new_scale) or 1.25)))
  else
    st.scale = math.max(1.0, math.min(16.0, tonumber(new_scale) or 1.0))
  end
  if st.scale <= 1.0 then
    st.pan_x = 0.5
    st.pan_y = 0.5
  end
  return M.render(bufnr)
end

function M.pan(bufnr, dx, dy)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.states[bufnr]
  if not st then return nil end
  local scale = math.max(1.0, st.scale or 1.0)
  local step_x = (tonumber(dx) or 0) / scale
  local step_y = (tonumber(dy) or 0) / scale
  st.pan_x = math.max(0.0, math.min(1.0, (st.pan_x or 0.5) + step_x))
  st.pan_y = math.max(0.0, math.min(1.0, (st.pan_y or 0.5) + step_y))
  return M.render(bufnr)
end

function M.reset(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.states[bufnr]
  if not st then return nil end
  st.scale = 1.0
  st.pan_x = 0.5
  st.pan_y = 0.5
  return M.render(bufnr)
end

function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.states[bufnr]
  if not st then return nil end
  local png_path = resolve_png_path(st.filepath)
  if image_lib then
    image_lib.synvim_image_invalidate_cache(png_path)
  end
  return M.render(bufnr)
end

function M.clear(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.states[bufnr]
  if not st then return end
  local del_seq = M.build_kitty_delete(st.image_id)
  write_tty(del_seq)
end

function M.open_image_buffer(bufnr, filepath, win)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  win = win or vim.api.nvim_get_current_win()
  local abs_path = vim.fn.fnamemodify(filepath, ":p")

  local existing = M.states[bufnr]
  if not existing then
    next_image_id = next_image_id + 1
    existing = {
      bufnr = bufnr,
      win = win,
      filepath = abs_path,
      image_id = next_image_id,
      scale = 1.0,
      pan_x = 0.5,
      pan_y = 0.5,
      img_w = 0,
      img_h = 0,
      last_crop = { x = 0, y = 0, w = 0, h = 0 },
      last_escape_payload = "",
    }
    M.states[bufnr] = existing
  else
    existing.filepath = abs_path
    existing.win = win
  end

  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "synvim_image"

  -- Buffer-local interactive zoom & pan keymaps
  local kopts = { buffer = bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "+", function() M.zoom(bufnr, 1.25, true) end, vim.tbl_extend("force", kopts, { desc = "Zoom in image" }))
  vim.keymap.set("n", "=", function() M.zoom(bufnr, 1.25, true) end, vim.tbl_extend("force", kopts, { desc = "Zoom in image" }))
  vim.keymap.set("n", "-", function() M.zoom(bufnr, 0.8, true) end, vim.tbl_extend("force", kopts, { desc = "Zoom out image" }))
  vim.keymap.set("n", "h", function() M.pan(bufnr, -0.2, 0) end, vim.tbl_extend("force", kopts, { desc = "Pan image left" }))
  vim.keymap.set("n", "l", function() M.pan(bufnr, 0.2, 0) end, vim.tbl_extend("force", kopts, { desc = "Pan image right" }))
  vim.keymap.set("n", "k", function() M.pan(bufnr, 0, -0.2) end, vim.tbl_extend("force", kopts, { desc = "Pan image up" }))
  vim.keymap.set("n", "j", function() M.pan(bufnr, 0, 0.2) end, vim.tbl_extend("force", kopts, { desc = "Pan image down" }))
  vim.keymap.set("n", "<Left>", function() M.pan(bufnr, -0.2, 0) end, vim.tbl_extend("force", kopts, { desc = "Pan image left" }))
  vim.keymap.set("n", "<Right>", function() M.pan(bufnr, 0.2, 0) end, vim.tbl_extend("force", kopts, { desc = "Pan image right" }))
  vim.keymap.set("n", "<Up>", function() M.pan(bufnr, 0, -0.2) end, vim.tbl_extend("force", kopts, { desc = "Pan image up" }))
  vim.keymap.set("n", "<Down>", function() M.pan(bufnr, 0, 0.2) end, vim.tbl_extend("force", kopts, { desc = "Pan image down" }))
  vim.keymap.set("n", "0", function() M.reset(bufnr) end, vim.tbl_extend("force", kopts, { desc = "Reset image zoom & pan" }))
  vim.keymap.set("n", "r", function() M.refresh(bufnr) end, vim.tbl_extend("force", kopts, { desc = "Refresh image from disk" }))
  vim.keymap.set("n", "q", function()
    M.clear(bufnr)
    if vim.fn.exists(":SmartQuit") == 2 then
      vim.cmd("SmartQuit")
    elseif #vim.api.nvim_tabpage_list_wins(0) > 1 then
      vim.cmd("close")
    else
      vim.cmd("bprevious")
    end
  end, vim.tbl_extend("force", kopts, { desc = "Close image viewer" }))

  vim.api.nvim_create_autocmd({ "BufLeave", "BufWipeout", "WinClosed" }, {
    buffer = bufnr,
    callback = function()
      M.clear(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinResized" }, {
    buffer = bufnr,
    callback = function()
      M.render(bufnr)
    end,
  })

  return M.render(bufnr)
end

function M.setup()
  local group = vim.api.nvim_create_augroup("SynvimNativeImageViewer", { clear = true })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = { "*.png", "*.svg", "*.jpg", "*.jpeg", "*.webp", "*.gif", "*.bmp" },
    callback = function(ev)
      M.open_image_buffer(ev.buf, ev.match, vim.api.nvim_get_current_win())
    end,
    desc = "Render image files natively via Kitty graphics protocol + LuaJIT FFI libpng cropper",
  })
end

return M
