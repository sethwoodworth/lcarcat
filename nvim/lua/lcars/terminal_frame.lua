-- LCARS terminal window integration.
--
-- Two responsibilities:
--   1. Stem column: set signcolumn=yes:1 on every :terminal window so the
--      existing periwinkle SignColumn highlight gives a 1-col stem that
--      indents terminal content one cell right, matching the zsh LCARS prompt.
--   2. Chrome suppression: chrome.lua watches buftype and skips its top-left
--      corner image when the primary window is a terminal (the zsh prompt
--      renders its own bar there). This module just handles the stem.
--
-- :LcarsTermFrame toggles the outer hcap bar (currently unused; kept for later).

local M = { enabled = false }

local ok_image, image = pcall(require, "image")
local p = require("lcars.palette")

local CHROME_COLOR, CHROME_BG = "9999ff", "000000"
local cache_dir = vim.fn.stdpath("cache") .. "/lcars"

local state = { cw = nil, ch = nil, imgs = {}, floats = {} }

-- ── asset helpers (mirrors chrome.lua) ────────────────────────────────────

local function cell_px()
  local ok_term, term = pcall(require, "image.utils.term")
  if ok_term and term.get_size then
    local sz = term.get_size()
    if sz and sz.cell_width and sz.cell_width > 0 then
      return math.ceil(sz.cell_width), math.ceil(sz.cell_height)
    end
  end
  return 19, 38
end

local function capcols(cw, ch)
  return math.max(1, math.floor(ch / 2 / cw + 0.5))
end

local function asset_name(kind, color, cols, rows, cellw, cellh, orient, facing, gap, bg)
  orient = orient or "round"
  facing = facing or "left"
  local parts = { kind, orient, facing, color }
  if bg then parts[#parts + 1] = "background" .. bg end
  parts[#parts + 1] = cols .. "x" .. rows .. "cells"
  parts[#parts + 1] = cellw .. "x" .. cellh .. "pixels"
  if gap ~= nil then parts[#parts + 1] = "gap" .. gap end
  return table.concat(parts, "-")
end

-- chrome.lua writes hcap assets into whichever main_stem dir it uses (e.g. "17x34-4").
-- Glob to find any existing dir for the current cell size rather than assuming a stem.
local function find_hcap(cw, ch, caps, facing)
  local name = asset_name("hcap", CHROME_COLOR, caps, 1, cw, ch, "round", facing, 0, CHROME_BG)
  local pattern = cache_dir .. "/" .. cw .. "x" .. ch .. "-*/" .. name .. ".png"
  local matches = vim.fn.glob(pattern, false, true)
  if #matches > 0 then return matches[1] end
  -- Fallback to stem=0 dir (may not exist until chrome.lua runs once)
  return cache_dir .. "/" .. cw .. "x" .. ch .. "-0/" .. name .. ".png"
end

-- ── rendering ─────────────────────────────────────────────────────────────

local function clear_all()
  for _, img in pairs(state.imgs) do
    pcall(function() img:clear() end)
  end
  state.imgs = {}
  for _, win in ipairs(state.floats) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  state.floats = {}
end

local function place_cap(path, x, y, w, key)
  if state.imgs[key] then return end
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("lcars.terminal_frame: asset missing: " .. path, vim.log.levels.WARN)
    return
  end
  local img = image.from_file(path, { x = x, y = y, width = w, height = 1 })
  if img then
    img.ignore_global_max_size = true
    img:render()
    state.imgs[key] = img
  end
end

-- 1-row floating window painted periwinkle: fills the bar between the two hcaps.
-- relative='editor' uses 0-indexed screen rows/cols (row 0 = tabline when visible).
local function place_fill(x, y, width)
  if width <= 0 then return end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, false, {
    relative  = "editor",
    row       = y,
    col       = x,
    width     = width,
    height    = 1,
    style     = "minimal",
    focusable = false,
    noautocmd = true,
    zindex    = 1,
  })
  vim.api.nvim_set_option_value(
    "winhighlight", "Normal:LcarsTermBar,NormalNC:LcarsTermBar", { win = win })
  table.insert(state.floats, win)
end

function M.refresh()
  if not M.enabled or not ok_image then return end
  clear_all()

  local cw, ch = cell_px()
  state.cw, state.ch = cw, ch
  local caps = capcols(cw, ch)
  local lpath = find_hcap(cw, ch, caps, "left")
  local rpath = find_hcap(cw, ch, caps, "right")

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative ~= nil and cfg.relative ~= "" then goto continue end

    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype ~= "terminal" then goto continue end

    local wi = vim.fn.getwininfo(win)
    if not wi or not wi[1] then goto continue end
    wi = wi[1]

    -- win_screenpos is 1-indexed. y_bar: the separator/tabline row above this window,
    -- 0-indexed for image.nvim and nvim_open_win(relative='editor').
    local y_bar = wi.winrow - 2
    local x0    = wi.wincol - 1
    local width = wi.width

    -- chrome.lua already owns the top-left primary slot (row≤2, col=1).
    if wi.winrow <= 2 and wi.wincol == 1 then goto continue end
    if y_bar < 0 then goto continue end

    place_cap(lpath, x0,                  y_bar, caps, "l@" .. x0 .. "," .. y_bar)
    place_cap(rpath, x0 + width - caps,   y_bar, caps, "r@" .. (x0 + width - caps) .. "," .. y_bar)
    place_fill(x0 + caps, y_bar, width - 2 * caps)

    ::continue::
  end
end

-- ── lifecycle ─────────────────────────────────────────────────────────────

local refresh_token = 0
local function schedule_refresh()
  if not M.enabled then return end
  refresh_token = refresh_token + 1
  local mine = refresh_token
  vim.defer_fn(function()
    if mine == refresh_token and M.enabled then M.refresh() end
  end, 80)
end

function M.enable()
  M.enabled = true
  if vim.fn.hlexists("LcarsTermBar") == 0 then
    vim.api.nvim_set_hl(0, "LcarsTermBar", { bg = p.periwinkle, fg = p.periwinkle })
  end
  M.refresh()
end

function M.disable()
  M.enabled = false
  clear_all()
end

function M.toggle()
  if M.enabled then M.disable() else M.enable() end
end

-- Set up the 1-col periwinkle stem on every terminal window.
-- signcolumn=yes:1 forces exactly 1 sign column even with no signs present,
-- which indents terminal content by 1 cell and is painted by SignColumn HL.
local function apply_stem(win)
  if not vim.api.nvim_win_is_valid(win) then return end
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= "terminal" then return end
  vim.api.nvim_set_option_value("signcolumn", "yes:1", { win = win })
  vim.api.nvim_set_option_value("number", false, { win = win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = win })
end

function M.setup()
  local grp = vim.api.nvim_create_augroup("LcarsTermFrame", { clear = true })

  -- Stem column on every new terminal buffer
  vim.api.nvim_create_autocmd("TermOpen", {
    group    = grp,
    callback = function() apply_stem(vim.api.nvim_get_current_win()) end,
  })

  -- Outer hcap bar refresh (for secondary splits; currently suppressed when
  -- the terminal is the primary window via chrome.lua's guard)
  vim.api.nvim_create_autocmd(
    { "VimResized", "WinResized", "WinNew", "WinClosed",
      "TabEnter", "BufWinEnter", "WinEnter" },
    { group = grp, callback = schedule_refresh }
  )
end

vim.api.nvim_create_user_command("LcarsTermFrame", function() M.toggle() end,
  { desc = "Toggle LCARS hcap bar above secondary :terminal windows" })

M.setup()

vim.api.nvim_create_autocmd("VimEnter", {
  once     = true,
  callback = function() vim.schedule(function() M.enable() end) end,
})

return M
