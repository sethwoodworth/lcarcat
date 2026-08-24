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
--   Footer (3 rows):  f0=stub, f0+1=bar, f0+2=bar  (omitted for live)
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

-- chips_block mirrors block_demo exactly. col is a window col.
local function chips_block(buf, ns, r_top, r_text, col, chip_list)
  local function gap_at(row, pos)
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      virt_text         = {{ " ", "Normal" }},
      virt_text_pos     = "overlay",
      virt_text_win_col = pos,
      priority          = HL_PRI,
    })
  end
  gap_at(r_top, col); gap_at(r_text, col)
  local c = col + 1
  for _, chip in ipairs(chip_list) do
    local label = " " .. chip[1] .. " "
    local blank = string.rep(" ", #label)
    vim.api.nvim_buf_set_extmark(buf, ns, r_top, 0, {
      virt_text         = {{ blank, chip[2] }},
      virt_text_pos     = "overlay",
      virt_text_win_col = c,
      priority          = HL_PRI,
    })
    vim.api.nvim_buf_set_extmark(buf, ns, r_text, 0, {
      virt_text         = {{ label, chip[2] }},
      virt_text_pos     = "overlay",
      virt_text_win_col = c,
      priority          = HL_PRI,
    })
    c = c + #label
    gap_at(r_top, c); gap_at(r_text, c)
    c = c + 1
  end
end

-- ── line builders ─────────────────────────────────────────────────────────

local function pad(n) return string.rep(" ", n) end
local function bar(w) return string.rep(" ", w) end

-- ── image placement ───────────────────────────────────────────────────────

local function place(key, path, win_col, win_row, topline, buf_row, buf_col, w, h)
  local sy = win_row + buf_row - topline
  local sx = win_col + buf_col
  registry.place(path, sx, sy, w, h, key)
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

  if rec.chips and #rec.chips > 0 then
    chips_block(buf, ns, row, row + 1, bar_x0, rec.chips)
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

-- render_footer: 3 rows (mirrors make_A footer geometry).
--   f0+0: stem stub (elbow image row 0)
--   f0+1: bar fill  (elbow image row 1)
--   f0+2: bar fill  (elbow image row 2)
function M.render_footer(buf, row, rec, opts)
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

  hl(buf, ns, shl, row, lp, lp + STEM_W)  -- stub on f0

  local bar_x0 = lp + ELBOW_W - 1
  local cap_x  = lp + bw - CAP_W
  local bar_w  = cap_x - bar_x0
  barrow(buf, ns, row + 1, bar_x0, bar_w, fhl)
  barrow(buf, ns, row + 2, bar_x0, bar_w, fhl)

  return 3
end

-- render_block: header(3) + content(N) + footer(3 or 0 for live) = N+6 or N+3 rows.
function M.render_block(buf, start_row, rec, opts)
  opts = opts or {}
  local row = start_row

  row = row + M.render_header(buf, row, rec, opts)
  row = row + M.render_content(buf, row, rec, opts)

  if rec.state ~= "live" then
    row = row + M.render_footer(buf, row, rec, opts)
  end

  -- Place elbow + vcap images when cell dimensions are known.
  local cw = opts.cw or registry.current_cw
  local ch = opts.ch or registry.current_ch
  if cw and ch then
    local win = opts.win or vim.api.nvim_get_current_win()
    local wi  = vim.fn.getwininfo(win)[1]
    if wi then
      local win_row = wi.winrow - 1
      local win_col = wi.wincol - 1
      local topline = vim.fn.line("w0", win) - 1
      local lp      = opts.lp or 6
      local bw      = opts.bw or 60
      local dir     = assets.find_asset_dir(cw, ch)
      local pfx     = (opts.image_key_prefix or tostring(buf) .. "_" .. tostring(start_row)) .. "_"
      local color   = STATE_COLOR[rec.state] or STATE_COLOR.done

      -- Top elbow + vcap (all states — colored assets now exist for sage/red)
      place(pfx .. "elbow_top",
        elbow_path(dir, cw, ch, "top", "left", color),
        win_col, win_row, topline, start_row, lp, ELBOW_W, ELBOW_H)
      place(pfx .. "vcap_top",
        vcap_path(dir, cw, ch, "right", color),
        win_col, win_row, topline, start_row, lp + bw - CAP_W, CAP_W, 2)

      if rec.state ~= "live" then
        local footer_row = row - 3
        place(pfx .. "elbow_bot",
          elbow_path(dir, cw, ch, "bottom", "left", color),
          win_col, win_row, topline, footer_row, lp, ELBOW_W, ELBOW_H)
        place(pfx .. "vcap_bot",
          vcap_path(dir, cw, ch, "right", color),
          win_col, win_row, topline, footer_row + 1, lp + bw - CAP_W, CAP_W, 2)
      end
    end
  end

  return row - start_row
end

return M
