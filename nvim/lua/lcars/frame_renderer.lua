-- frame_renderer.lua — pure buffer render: header / content / footer
--
-- Entry point:
--   M.render_block(buf, start_row, rec, opts) → rows_consumed
--
-- `rec` is a block_record (see block_record.lua).
-- `opts.ns`, `.lp`, `.bw`, `.win`, `.cw`, `.ch`, `.image_key_prefix`.
--
-- Geometry mirrors block_demo.lua make_A exactly:
--   Header (3 rows):  h0=bar, h0+1=bar+chips+cwd, h0+2=stem-stub+cmd
--   Content (N rows): one per rec.lines, left stem
--   Footer (1 row):   f0=bar with left+right round caps (omitted for live)
--
-- Highlight groups (state → color):
--   live   → LcarsTermFrameLive  (sage)  / LcarsTermStemLive  (sage)
--   done   → LcarsTermBar        (peri)  / LcarsTermBar       (peri)
--   failed → same as done; the red ERR chip on the footer carries the signal
--
-- Coordinate conventions (mirror block_demo.lua):
--   lp, bar_x0, cap_x etc. are window cols from window-left (0-indexed, incl. gutter).
--   Byte-based hl extmarks subtract GUTTER_W once to convert to buffer byte col.
--   virt_text_win_col is already a window col — NO GUTTER_W subtraction.

local M = {}

local assets      = require("lcars.assets")
local registry    = require("lcars.image_registry")
local block_chips = require("lcars.block_chips")

local ELBOW_W, ELBOW_H = 5, 3
local CAP_W             = 2   -- vcap: 2-wide × 2-tall, spans both header bar rows
local STEM_W            = 1
local GUTTER_W          = 1
local HL_PRI            = 200

local ns_default = vim.api.nvim_create_namespace("lcars_frame_renderer")

-- ── highlight group selection ─────────────────────────────────────────────

-- "failed" deliberately renders the same chrome as "done": a nonzero exit is
-- reported by the red ERR chip on the footer, not by repainting the whole
-- frame. A wall of red for `grep` finding nothing drowns out the blocks that
-- actually went wrong. LcarsTermFrameFailed/LcarsTermStemFailed still exist in
-- the colorscheme for anything that wants the loud treatment back.
local function frame_hl(state)
  if state == "live" then return "LcarsTermFrameLive" end
  return "LcarsTermBar"
end

local function stem_hl(state)
  if state == "live" then return "LcarsTermStemLive" end
  return "LcarsTermBar"
end

-- ── asset color per state ─────────────────────────────────────────────────

-- Elbow/cap image color per state. "failed" matches "done" for the same reason
-- frame_hl does — see the note there.
local STATE_COLOR = {
  done   = "9999ff",  -- periwinkle
  live   = "99cc99",  -- sage
  failed = "9999ff",  -- periwinkle: failure shows as a footer chip, not red chrome
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

-- Drop priority when the chips don't fit, lowest-value first. Mirrors the
-- swoop bar's drop order in zsh/prompt_lcars.zsh ("aws, py, git-state, venv,
-- branch"). Chips tagged with a drop_group not listed here go after these;
-- untagged chips (block_demo's fixed lists) shed last.
local DROP_ORDER = { "aws", "awsdep", "py", "gitstate", "venv", "git" }

-- chips_width: columns header_chips will consume for this colored-chip list.
-- Layout is zsh's: one leading black gap, then each chip followed by its own
-- black gap (adjacent chips comb — N chips draw N+1 gaps). Mirrors the
-- placement arithmetic in header_chips exactly; keep the two in sync.
function M.chips_width(chip_list)
  local n = chip_list and #chip_list or 0
  if n == 0 then return 0 end
  local w = 1                                    -- leading black gap
  for i = 1, n do
    w = w + #chip_list[i][1] + 2 + 1             -- label + cushion + trailing gap
  end
  return w
end

-- chips_avail: columns left for colored chips on the header bar, once the
-- elbow overlap, the pre-cap buffer and the right-aligned cwd hole chip have
-- taken their share. The hole chip is never dropped — it is the block's
-- address — so it is charged against the budget rather than competing for it.
function M.chips_avail(bw, cwd)
  local avail = (bw - CAP_W) - (ELBOW_W - 1)     -- cap_x - bar_x0
  avail = avail - 1                              -- bar_x0 sits under the elbow's last col
  avail = avail - 2                              -- pre-cap buffer: 2 bare bar cols
  if cwd and cwd ~= "" then
    avail = avail - (#cwd + 2) - 1               -- hole chip + 1 bar-col separator
  end
  return avail
end

-- fit_chips: drop whole chip groups, lowest priority first, until the list
-- fits `avail` columns. Returns a new list; the input is left untouched.
function M.fit_chips(chip_list, avail)
  local list = {}
  for i, c in ipairs(chip_list or {}) do list[i] = c end
  if M.chips_width(list) <= avail then return list end

  -- Kinds present but unranked (e.g. emitted by a newer shell) shed after
  -- everything known, so an unrecognized chip degrades rather than wedging.
  local order, ranked = {}, {}
  for _, k in ipairs(DROP_ORDER) do order[#order + 1] = k; ranked[k] = true end
  for _, c in ipairs(list) do
    local g = c[3]
    if g and not ranked[g] then order[#order + 1] = g; ranked[g] = true end
  end
  order[#order + 1] = false                      -- untagged chips shed last

  for _, group in ipairs(order) do
    for i = #list, 1, -1 do
      if (list[i][3] or false) == group then table.remove(list, i) end
    end
    if M.chips_width(list) <= avail then return list end
  end
  return list
end

-- overlay_at: a virt_text overlay at an absolute window column.
local function overlay_at(buf, ns, row, pos, text, group)
  vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
    virt_text         = {{ text, group }},
    virt_text_pos     = "overlay",
    virt_text_win_col = pos,
    priority          = HL_PRI,
  })
end

-- chip_run: a left-to-right run of chips starting at column x0.
--
-- Chips ride on a 1-col black gap on either side, and each chip's trailing gap
-- combs with the next one's leading gap — so N chips draw N+1 gaps, the same
-- rule as _lcars_chips in zsh/prompt_lcars.zsh. The run always closes with its
-- own trailing gap, so a chip never butts straight into the bar fill.
--
-- r_text carries the label. r_blank, when given, is a second row painted in the
-- chip's own color (header chips span both bar rows; the 1-row footer passes
-- nil). Returns the column just past the trailing gap.
local function chip_run(buf, ns, r_text, r_blank, x0, chip_list)
  local function black(pos)
    overlay_at(buf, ns, r_text, pos, " ", "Normal")
    if r_blank then overlay_at(buf, ns, r_blank, pos, " ", "Normal") end
  end
  if #chip_list == 0 then return x0 end

  local c = x0
  black(c)                                       -- leading gap
  c = c + 1
  for i = 1, #chip_list do
    local chip  = chip_list[i]
    local label = " " .. chip[1] .. " "
    overlay_at(buf, ns, r_text, c, label, chip[2])
    if r_blank then
      overlay_at(buf, ns, r_blank, c, string.rep(" ", #label), chip[2])
    end
    c = c + #label
    black(c)                                     -- trailing gap (combs with the next chip's leading)
    c = c + 1
  end
  return c
end

-- header_chips: colored chips LEFT-aligned from the elbow, cwd hole chip
-- RIGHT-aligned before the cap — the same arrangement as the zsh swoop bar
-- ("chips + fill + path notch"), so a block header and the standalone prompt
-- read as one system.
--
--   [elbow][black][chip_1][black][chip_2][black] ...fill... [hole][2 bar cols][cap]
--
-- chip_list entries: { label, hl_group, drop_group? }. The hole chip is a hole
-- punched in the bar: black on both rows with Normal-colored text, hence no
-- color of its own.
local function header_chips(buf, ns, r_top, r_text, bar_x0, cap_x, chip_list, cwd)
  chip_run(buf, ns, r_text, r_top, bar_x0 + 1, chip_list)

  if cwd and cwd ~= "" then
    local label = " " .. cwd .. " "
    local h = cap_x - 2 - #label                 -- pre-cap buffer: 2 bare bar cols
    overlay_at(buf, ns, r_top,  h, string.rep(" ", #label), "Normal")
    overlay_at(buf, ns, r_text, h, label, "Normal")
  end
end

-- footer_chips: single-row chips LEFT-aligned from the footer elbow, matching
-- the header.
--
--   [felbow][black][chip_1][black][chip_2][black] ...bar fill... [cap]
--
-- This is where a block reports on itself — duration, exit code — as opposed to
-- the header, which describes the environment the command ran in.
local function footer_chips(buf, ns, row, bar_x0, chip_list)
  chip_run(buf, ns, row, nil, bar_x0 + 1, chip_list)
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
--   row+1: bar fill + chips (left) + cwd hole chip (right); vcap spans rows 0-1
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
    local shown = M.fit_chips(rec.chips, M.chips_avail(bw, rec.cwd))
    header_chips(buf, ns, row, row + 1, bar_x0, cap_x, shown, rec.cwd)
  end

  -- Stem stub on row+2
  hl(buf, ns, shl, row + 2, lp, lp + STEM_W)

  -- Duration is shown as a chip on the bar rows (block_chips.append_duration),
  -- not appended to the command text — the command line stays the command.
  mark_at(buf, ns, row + 2, lp + ELBOW_W, rec.command or "", "Normal")

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

-- render_footer: 1 row — bottom-left elbow image + bar fill + outcome chips +
-- right round cap.
--   f0: [elbow image at lp..lp+FELBOW_W-1][chips][bar fill][right cap at bw-FCAP_W]
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

  footer_chips(buf, ns, row, bar_x0, block_chips.outcome(rec))

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
