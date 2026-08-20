-- Shared asset helpers used by block_demo, chrome, terminal_frame, and others.
-- Single source of truth for cell size, cache path, asset filename format, and
-- the canonical chrome color (sourced from palette so it stays in sync).

local p = require("lcars.palette")

local M = {}

M.color     = p.periwinkle:sub(2)            -- "9999ff" — strip "#" for asset filenames
M.cache_dir = vim.fn.stdpath("cache") .. "/lcars"

function M.cell_px()
  local ok_t, term = pcall(require, "image.utils.term")
  if ok_t and term.get_size then
    local sz = term.get_size()
    if sz and sz.cell_width and sz.cell_width > 0 then
      return math.ceil(sz.cell_width), math.ceil(sz.cell_height)
    end
  end
  return 19, 38
end

-- Probe dimensions match the canonical block-frame asset sizes.
local ELBOW_W, ELBOW_H = 5, 3
local CORNER_W, CORNER_H = 6, 2

-- Return the best-matching asset directory for the given cell pixel size.
-- Prefers dirs that have both elbow and corner probes; falls back to elbow-only,
-- then to a synthetic "<cw>x<ch>-4" path.
function M.find_asset_dir(cw, ch)
  local dirs = vim.fn.glob(M.cache_dir .. "/" .. cw .. "x" .. ch .. "-*", false, true)
  local ep = "/elbow-top-left-" .. M.color .. "-" .. ELBOW_W .. "x" .. ELBOW_H
             .. "cells-" .. cw .. "x" .. ch .. "pixels.png"
  local cp = "/corner-top-left-" .. M.color .. "-background000000-"
             .. CORNER_W .. "x" .. CORNER_H .. "cells-" .. cw .. "x" .. ch .. "pixels.png"
  local fallback = nil
  for _, d in ipairs(dirs) do
    if vim.fn.filereadable(d .. ep) == 1 then
      if vim.fn.filereadable(d .. cp) == 1 then return d end
      fallback = fallback or d
    end
  end
  return fallback or (M.cache_dir .. "/" .. cw .. "x" .. ch .. "-4")
end

-- Mirror of gen_swoops.py's asset_name(): rebuild the exact descriptive filename
-- the generator writes. Keep in lock-step with the Python version.
-- Returns the base name WITHOUT ".png".
function M.asset_name(kind, color, cols, rows, cellw, cellh, orient, facing, gap, bg)
  orient = orient or "round"
  facing = facing or "left"
  local parts = { kind, orient, facing, color }
  if bg then parts[#parts + 1] = "background" .. bg end
  parts[#parts + 1] = cols .. "x" .. rows .. "cells"
  parts[#parts + 1] = cellw .. "x" .. cellh .. "pixels"
  if gap ~= nil then parts[#parts + 1] = "gap" .. gap end
  return table.concat(parts, "-")
end

return M
