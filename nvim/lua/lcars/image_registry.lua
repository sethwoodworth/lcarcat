-- Centralized image handle cache for all lcars image.nvim placements.
-- Supersedes the inline state.imgs tables in terminal_frame and block_demo.
--
-- spike-1 (lcarcat-zi1) ruled out custom APC/kitty-ID transmit; image.nvim
-- from_file() is the correct transport. This module centralizes deduplication,
-- clearing, and cell-dimension state in one place so frame_renderer,
-- terminal_frame, and chrome all share a single ownership model.
--
-- API:
--   M.place(path, x, y, w, h, key) → handle | nil
--   M.clear_key(key)
--   M.clear_all()
--   M.reset()              -- clear_all + nil out current_cw/current_ch
--   M.current_cw           -- set by callers after probing; nil until first set
--   M.current_ch

local ok_image, image = pcall(require, "image")

local M = {}

M.current_cw = nil
M.current_ch = nil

local cache = {}

-- Place a PNG at (x, y) with size (w × 1 rows) and cache by key.
-- Returns the image handle, or nil if the file is missing or image.nvim absent.
-- Idempotent: returns the cached handle on subsequent calls for the same key.
function M.place(path, x, y, w, h, key)
  if not ok_image then return nil end
  if cache[key] then return cache[key] end
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("lcars.image_registry: asset missing: " .. path, vim.log.levels.WARN)
    return nil
  end
  local img = image.from_file(path, { x = x, y = y, width = w, height = h })
  if img then
    img.ignore_global_max_size = true
    img:render()
    cache[key] = img
  end
  return cache[key]
end

-- Clear a single placement by key.
function M.clear_key(key)
  if cache[key] then
    pcall(function() cache[key]:clear() end)
    cache[key] = nil
  end
end

-- Clear all tracked image handles.
function M.clear_all()
  for _, img in pairs(cache) do
    pcall(function() img:clear() end)
  end
  cache = {}
end

-- Clear all images and reset stored cell dimensions.
-- Call this when cell pixel size changes so the next place() picks up new dims.
function M.reset()
  M.clear_all()
  M.current_cw = nil
  M.current_ch = nil
end

return M
