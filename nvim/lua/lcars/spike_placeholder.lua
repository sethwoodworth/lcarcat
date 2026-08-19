-- spike_placeholder.lua — spike-1 (lcarcat-zi1)
-- Verify that image.nvim from_file() places an elbow PNG in a scratch buffer
-- and that it stays correctly positioned as the buffer scrolls (via WinScrolled
-- re-render). This mirrors block_demo's approach exactly — no io.write, no
-- unicode placeholders.
--
-- :LcarsSpikeImg   run the spike

local M = {}

vim.opt.shortmess:append("I")

local ok_image, image = pcall(require, "image")

local cache_dir = vim.fn.stdpath("cache") .. "/lcars"
local COLOR     = "9999ff"
local ELBOW_W   = 5
local ELBOW_H   = 3
-- Place the elbow away from the outer LCARS frame so it's clearly distinct.
-- Row 10 / col 10 puts it well inside the content area for visual verification.
local TEST_DY   = 10
local TEST_DX   = 10

-- Same cell_px() pattern as block_demo / terminal_frame (no shared util exists).
local function cell_px()
  local ok_t, term = pcall(require, "image.utils.term")
  if ok_t and term.get_size then
    local sz = term.get_size()
    if sz and sz.cell_width and sz.cell_width > 0 then
      return math.ceil(sz.cell_width), math.ceil(sz.cell_height)
    end
  end
  return 19, 38
end

-- Same find_asset_dir() pattern as block_demo.
local function find_asset_dir(cw, ch)
  local dirs = vim.fn.glob(cache_dir .. "/" .. cw .. "x" .. ch .. "-*", false, true)
  local ep = "/elbow-top-left-" .. COLOR .. "-" .. ELBOW_W .. "x" .. ELBOW_H
             .. "cells-" .. cw .. "x" .. ch .. "pixels.png"
  local fallback = nil
  for _, d in ipairs(dirs) do
    if vim.fn.filereadable(d .. ep) == 1 then return d end
    fallback = fallback or d
  end
  return fallback or (cache_dir .. "/" .. cw .. "x" .. ch .. "-4")
end

local function elbow_path(dir, cw, ch)
  return dir .. "/elbow-top-left-" .. COLOR
         .. "-" .. ELBOW_W .. "x" .. ELBOW_H .. "cells-"
         .. cw .. "x" .. ch .. "pixels.png"
end

-- Placed image handle so we can clear on re-render.
local placed_img = nil

-- Place (or re-place) the elbow image bound to a buffer row/col.
-- Using window+buffer binding lets image.nvim handle all scroll math:
-- partial clipping at the top (topline logic), horizontal scroll, and
-- WinScrolled re-render via its own global autocmd — no manual math needed.
local function place_elbow(win, buf, path)
  if placed_img then
    pcall(function() placed_img:clear() end)
    placed_img = nil
  end
  if not ok_image then return end

  local img = image.from_file(path, {
    window = win,
    buffer = buf,
    x      = TEST_DX,   -- 0-indexed buffer col
    y      = TEST_DY,   -- 0-indexed buffer row
    width  = ELBOW_W,
    height = ELBOW_H,
  })
  if img then
    img:render()
    placed_img = img
  end
end

function M.render()
  if not ok_image then
    vim.notify("spike_placeholder: image.nvim not available", vim.log.levels.ERROR)
    return
  end

  local cw, ch = cell_px()
  local dir    = find_asset_dir(cw, ch)
  local path   = elbow_path(dir, cw, ch)

  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("spike_placeholder: asset missing: " .. path, vim.log.levels.WARN)
    return
  end

  -- Build buffer: 60 filler lines. Image is at buffer row TEST_DY (10) so we
  -- need enough lines below it to scroll and see it move with the text.
  local lines = {}
  for i = 1, 60 do
    lines[i] = string.format("line %02d — scroll to verify image tracks buffer", i)
  end

  -- get_or_create_tab pattern from block_demo.
  local spike_buf_name = "lcars://spike/placeholder"
  local win, buf
  for _, t in ipairs(vim.api.nvim_list_tabpages()) do
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(t)) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.api.nvim_buf_get_name(b) == spike_buf_name then
        vim.api.nvim_set_current_tabpage(t)
        win, buf = w, b
        break
      end
    end
    if win then break end
  end

  if not win then
    vim.cmd("tabnew")
    win = vim.api.nvim_get_current_win()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_buf_set_name(buf, spike_buf_name)
  end

  vim.wo[win].number         = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn     = "no"
  vim.wo[win].foldcolumn     = "0"
  vim.wo[win].wrap           = false
  vim.wo[win].cursorline     = false
  vim.wo[win].list           = false
  vim.wo[win].winhighlight   = "Normal:LcarsBlockBg,NormalNC:LcarsBlockBg"

  vim.bo[buf].modifiable = true
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].swapfile   = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_win_set_cursor(win, { 1, 0 })

  -- image.nvim's window+buffer binding handles WinScrolled re-render
  -- and partial-scroll clipping internally — no manual autocmd needed.
  place_elbow(win, buf, path)

  vim.notify(
    string.format("spike_placeholder: elbow at %s (cell %dx%d)",
      vim.fn.fnamemodify(path, ":t"), cw, ch),
    vim.log.levels.INFO
  )
end

vim.api.nvim_create_user_command("LcarsSpikeImg", function()
  M.render()
end, { desc = "spike-1: test image.nvim elbow placement in scratch buffer" })

return M
