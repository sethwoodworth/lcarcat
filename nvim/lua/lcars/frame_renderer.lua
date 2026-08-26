-- frame_renderer.lua — pure buffer render: header / content / footer
--
-- Entry point:
--   M.render_block(buf, start_row, rec, opts) → rows_consumed
--
-- `rec` is a block_record (see block_record.lua).
-- `opts.ns`, `.lp`, `.bw`, `.win`, `.cw`, `.ch`, `.image_key_prefix`.
--
-- Geometry mirrors block_demo.lua make_A exactly:
--   Header (3 rows):  h0=bar, h0+1=bar+chips, h0+2=stem-stub+cmd
--   Content (N rows): one per rec.lines, left stem
--   Footer (1 row):   f0=bar with left+right round caps (omitted for live)
--
-- Highlight groups (state → color):
--   live   → LcarsTermFrameLive  (sage)  / LcarsTermStemLive  (sage)
--   done   → LcarsTermBar        (peri)  / LcarsTermBar       (peri)
--   failed → LcarsTermFrameFailed (red)  / LcarsTermStemFailed (red)
--
-- Coordinate conventions (mirror block_demo.lua):
--   lp, bar_x0, cap_x etc. are window cols from window-left (0-indexed, incl. gutter).
--   Byte-based hl extmarks subtract GUTTER_W once to convert to buffer byte col.
--   virt_text_win_col is already a window col — NO GUTTER_W subtraction.

local M = {}

local assets   = require("lcars.assets")
local registry = require("lcars.image_registry")

local ELBOW_W, ELBOW_H = 5, 3
local CAP_W             = 2   -- vcap: 2-wide × 2-tall, spans both header bar rows
local STEM_W            = 1
local GUTTER_W          = 1
local HL_PRI            = 200

local ns_default = vim.api.nvim_create_namespace("lcars_frame_renderer")

-- ── highlight group selection ─────────────────────────────────────────────

local function frame_hl(state)
  if state == "live"   then return "LcarsTermFrameLive"   end
  if state == "failed" then return "LcarsTermFrameFailed" end
  return "LcarsTermBar"
end

local function stem_hl(state)
  if state == "live"   then return "LcarsTermStemLive"   end
  if state == "failed" then return "LcarsTermStemFailed" end
  return "LcarsTermBar"
end

-- ── asset color per state ─────────────────────────────────────────────────

local STATE_COLOR = {
  done   = "9999ff",  -- periwinkle
  live   = "99cc99",  -- sage
  failed = "ff3300",  -- red
}

-- ── asset path helpers (mirror block_demo) ────────────────────────────────

local function elbow_path(dir, cw, ch, orient, facing, color)
  return dir .. "/elbow-" .. orient .. "-" .. facing .. "-" .. color
         .. "-" .. ELBOW_W .. "x" .. ELBOW_H .. "cells-" .. cw .. "x" .. ch .. "pixels.png"
end

local function vcap_path(dir, cw, ch, facing, color)
  return dir .. "/cap-round-" .. facing .. "-" .. color
         .. "-" .. CAP_W .. "x2cells-" .. cw .. "x" .. ch .. "pixels.png"
end

-- footer elbow: 5 wide × 2 tall (bar_rows=1 + stem_rows=1), placed 1 row up into content
-- so the inner fillet is visible, while only the bottom bar row is the footer row.
local FELBOW_W, FELBOW_H = 5, 2
local function felbow_path(dir, cw, ch, color)
  return dir .. "/elbow-bottom-left-" .. color
         .. "-" .. FELBOW_W .. "x" .. FELBOW_H .. "cells-" .. cw .. "x" .. ch .. "pixels.png"
end

-- footer right cap: 1 wide × 1 tall
local FCAP_W = 1
local function fcap_path(dir, cw, ch, color)
  return dir .. "/cap-round-right-" .. color
         .. "-" .. FCAP_W .. "x1cells-" .. cw .. "x" .. ch .. "pixels.png"
end

-- ── low-level extmark helpers ─────────────────────────────────────────────

-- Byte-based hl_group extmark. c0/c1 are window cols; subtract GUTTER_W for buffer byte cols.
local function hl(buf, ns, group, r, c0, c1)
  vim.api.nvim_buf_set_extmark(buf, ns, r, c0 - GUTTER_W, {
    end_col  = c1 - GUTTER_W,
    hl_group = group,
    priority = HL_PRI,
    strict   = false,
  })
end

local function barrow(buf, ns, r, x0, w, group)
  hl(buf, ns, group, r, x0, x0 + w)
end

-- virt_text overlay. col is a window col — no GUTTER_W subtraction.
local function mark_at(buf, ns, r, col, text, group)
  vim.api.nvim_buf_set_extmark(buf, ns, r, 0, {
    virt_text         = {{ text, group }},
    virt_text_pos     = "overlay",
    virt_text_win_col = col,
    priority          = HL_PRI,
  })
end

-- Stem: pure hl_group byte-range (solid color, no glyph → no texture).
local function stem_rows(buf, ns, r0, count, x, group)
  for r = r0, r0 + count - 1 do
    hl(buf, ns, group, r, x, x + STEM_W)
  end
end

-- chips_block: right-aligned chips placed from cap_x leftward.
-- chip_list entries: { label, hl_group }.
-- cwd (string|nil): rightmost "hole" chip — blank top row, Normal text bottom row.
--
-- Layout right-to-left from cap_x:
--   [2 bar cols][hole chip][1 bar col][1 black][chip_n][black]...[black][chip_1][black]
--
-- Colored chips have 1-col black gaps before, after, and between them.
-- The hole chip is separated from the colored chips by 1 black col + 1 bar-color col.
-- 2 bg columns are always reserved before the cap (pre-cap buffer rule).
local function chips_block(buf, ns, r_top, r_text, cap_x, chip_list, cwd, fhl)
  local function overlay(row, pos, text, group)
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      virt_text         = {{ text, group }},
      virt_text_pos     = "overlay",
      virt_text_win_col = pos,
      priority          = HL_PRI,
    })
  end
  local function black(row, pos)
    overlay(row, pos, " ", "Normal")
  end

  local c = cap_x - 2  -- pre-cap buffer: 2 bare bar cols

  -- Hole chip (rightmost)
  if cwd and cwd ~= "" then
    local label = " " .. cwd .. " "
    local blank  = string.rep(" ", #label)
    c = c - #label
    overlay(r_top,  c, blank, "Normal")
    overlay(r_text, c, label, "Normal")
    -- Separator: 1 bar-color col (implicit — barrow already colors it) + 1 black col
    if #chip_list > 0 then
      c = c - 1  -- bar-color col: no overlay needed, barrow provides it
      c = c - 1
      black(r_top, c); black(r_text, c)
    end
  end

  -- Colored chips right-to-left: [chip][black] ... [black][chip][black]
  -- The gap to the right of the rightmost colored chip was already placed above (or is the
  -- bar fill when there's no hole chip — handled by placing a black gap after each chip).
  for i = #chip_list, 1, -1 do
    local chip  = chip_list[i]
    local label = " " .. chip[1] .. " "
    local blank = string.rep(" ", #label)
    c = c - #label
    overlay(r_top,  c, blank, chip[2])
    overlay(r_text, c, label, chip[2])
    -- black gap to the left of this chip (before next chip, or trailing before bar fill)
    c = c - 1
    black(r_top, c); black(r_text, c)
  end
end

-- ── line builders ─────────────────────────────────────────────────────────

local function pad(n) return string.rep(" ", n) end
local function bar(w) return string.rep(" ", w) end

-- ── image placement ───────────────────────────────────────────────────────

local function place(key, path, win, buf, buf_row, buf_col, w, h)
  registry.place(path, win, buf, buf_col - GUTTER_W, buf_row, w, h, key)
end

-- ── public render functions ───────────────────────────────────────────────

-- render_header: 3 rows.
--   row+0: bar fill (elbow image placeholder + bar + vcap placeholder cols uncolored)
--   row+1: bar fill + chips (vcap spans rows 0-1)
--   row+2: stem stub (hl) + command text
function M.render_header(buf, row, rec, opts)
  local ns  = opts.ns or ns_default
  local lp  = opts.lp or 6
  local bw  = opts.bw or 60

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, row, row + 3, false, {
    pad(lp) .. bar(bw),
    pad(lp) .. bar(bw),
    pad(lp) .. bar(bw),
  })
  vim.bo[buf].modifiable = false

  local fhl = frame_hl(rec.state)
  local shl = stem_hl(rec.state)

  -- bar_x0 overlaps elbow by 1 col (mirrors block_demo); vcap cells left clear
  local bar_x0 = lp + ELBOW_W - 1
  local cap_x  = lp + bw - CAP_W
  local bar_w  = cap_x - bar_x0
  barrow(buf, ns, row,     bar_x0, bar_w, fhl)
  barrow(buf, ns, row + 1, bar_x0, bar_w, fhl)

  if (rec.chips and #rec.chips > 0) or (rec.cwd and rec.cwd ~= "") then
    chips_block(buf, ns, row, row + 1, cap_x, rec.chips, rec.cwd, fhl)
  end

  -- Stem stub on row+2
  hl(buf, ns, shl, row + 2, lp, lp + STEM_W)

  local cmd_text = rec.command or ""
  if rec.duration and (rec.state == "done" or rec.state == "failed") then
    cmd_text = cmd_text .. string.format("  [%.1fs]", rec.duration)
  end
  mark_at(buf, ns, row + 2, lp + ELBOW_W, cmd_text, "Normal")

  return 3
end

-- render_content: one line per rec.lines, solid stem on each row.
function M.render_content(buf, row, rec, opts)
  local ns  = opts.ns or ns_default
  local lp  = opts.lp or 6

  local out = {}
  for _, l in ipairs(rec.lines or {}) do
    out[#out + 1] = pad(lp) .. " " .. l
  end
  if #out == 0 then out[1] = pad(lp) .. " " end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, row, row + #out, false, out)
  vim.bo[buf].modifiable = false

  stem_rows(buf, ns, row, #out, lp, stem_hl(rec.state))

  return #out
end

-- render_footer: 1 row — bottom-left elbow image + bar fill + right round cap.
--   f0: [elbow image at lp..lp+FELBOW_W-1][bar fill][right cap at bw-FCAP_W]
function M.render_footer(buf, row, rec, opts)
  local ns  = opts.ns or ns_default
  local lp  = opts.lp or 6
  local bw  = opts.bw or 60

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, row, row + 1, false, {
    pad(lp) .. bar(bw),
  })
  vim.bo[buf].modifiable = false

  local fhl   = frame_hl(rec.state)
  local bar_x0 = lp + FELBOW_W - 1  -- overlap elbow by 1 col (mirrors header)
  local cap_x  = lp + bw - FCAP_W
  local bar_w  = cap_x - bar_x0
  barrow(buf, ns, row, bar_x0, bar_w, fhl)

  return 1
end

-- clear_images: clear cached image keys for a block so place_images can re-place
-- with a different state color (e.g. after transitioning from live → done/failed).
function M.clear_images(buf, start_row, opts)
  opts = opts or {}
  local pfx = (opts.image_key_prefix or tostring(buf) .. "_" .. tostring(start_row)) .. "_"
  registry.clear_key(pfx .. "elbow_top")
  registry.clear_key(pfx .. "vcap_top")
  registry.clear_key(pfx .. "felbow_bot")
  registry.clear_key(pfx .. "fcap_right")
end

-- place_images: place elbow/cap Kitty images for a block.
--   start_row: first row of the header.
--   footer_row: the footer row (ignored when rec.state == "live").
--   Requires opts.win (or falls back to current win) and cw/ch from opts or registry.
function M.place_images(buf, start_row, footer_row, rec, opts)
  opts = opts or {}
  local cw = opts.cw or registry.current_cw
  local ch = opts.ch or registry.current_ch
  if not (cw and ch) then return end

  local win = opts.win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then return end

  local lp      = opts.lp or 6
  local bw      = opts.bw or 60
  local dir     = assets.find_asset_dir(cw, ch)
  local pfx     = (opts.image_key_prefix or tostring(buf) .. "_" .. tostring(start_row)) .. "_"
  local color   = STATE_COLOR[rec.state] or STATE_COLOR.done

  place(pfx .. "elbow_top",
    elbow_path(dir, cw, ch, "top", "left", color),
    win, buf, start_row, lp, ELBOW_W, ELBOW_H)
  place(pfx .. "vcap_top",
    vcap_path(dir, cw, ch, "right", color),
    win, buf, start_row, lp + bw - CAP_W, CAP_W, 2)

  if rec.state ~= "live" then
    -- elbow placed 1 row above footer so fillet occupies last content row
    place(pfx .. "felbow_bot",
      felbow_path(dir, cw, ch, color),
      win, buf, footer_row - 1, lp, FELBOW_W, FELBOW_H)
    place(pfx .. "fcap_right",
      fcap_path(dir, cw, ch, color),
      win, buf, footer_row, lp + bw - FCAP_W, FCAP_W, 1)
  end
end

-- render_block: header(3) + content(N) + footer(1 or 0 for live) = N+4 or N+3 rows.
function M.render_block(buf, start_row, rec, opts)
  opts = opts or {}
  local row = start_row

  row = row + M.render_header(buf, row, rec, opts)
  row = row + M.render_content(buf, row, rec, opts)

  if rec.state ~= "live" then
    row = row + M.render_footer(buf, row, rec, opts)
  end

  local footer_row = rec.state ~= "live" and (row - 1) or nil
  M.place_images(buf, start_row, footer_row, rec, opts)

  return row - start_row
end

return M
