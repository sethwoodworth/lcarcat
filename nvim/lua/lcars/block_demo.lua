-- block_demo.lua — LCARS block frame style demos, one tab per block type.
--
-- Each tab contains 2-3 instances of the same frame style with different fake
-- content. Images are placed at absolute screen coords within the viewport;
-- LEFT_PAD/TOP_PAD keep everything inside the outer LCARS chrome.
--
-- :LcarsBlockDemo   open / refresh all demo tabs
-- :LcarsBlockDemoA  open only block-A tab (etc.)

local M = {}

local ok_image, image = pcall(require, "image")
local p = require("lcars.palette")

local ELBOW_W, ELBOW_H = 5, 3
local CORNER_W, CORNER_H = 6, 2
local COLOR = "9999ff"
local cache_dir = vim.fn.stdpath("cache") .. "/lcars"

-- Margin to stay inside outer LCARS chrome (gutter + top bar rows)
local LEFT_PAD = 6   -- cols from window left edge to block left edge
local TOP_PAD  = 2   -- rows from window top  edge to first block row

local DEBUG_BG = false  -- set true (or toggle via :LcarsBlockDemoDebugBg) to reveal transparent image regions

-- ── asset helpers ─────────────────────────────────────────────────────────

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

local function find_asset_dir(cw, ch)
  local dirs = vim.fn.glob(cache_dir .. "/" .. cw .. "x" .. ch .. "-*", false, true)
  local ep = "/elbow-top-left-" .. COLOR .. "-" .. ELBOW_W .. "x" .. ELBOW_H
             .. "cells-" .. cw .. "x" .. ch .. "pixels.png"
  local cp = "/corner-top-left-" .. COLOR .. "-background000000-"
             .. CORNER_W .. "x" .. CORNER_H .. "cells-" .. cw .. "x" .. ch .. "pixels.png"
  local fallback = nil
  for _, d in ipairs(dirs) do
    if vim.fn.filereadable(d .. ep) == 1 then
      if vim.fn.filereadable(d .. cp) == 1 then return d end
      fallback = fallback or d
    end
  end
  return fallback or (cache_dir .. "/" .. cw .. "x" .. ch .. "-4")
end

local function elbow(dir, cw, ch, orient, facing)
  return dir .. "/elbow-" .. orient .. "-" .. facing .. "-" .. COLOR
         .. "-" .. ELBOW_W .. "x" .. ELBOW_H .. "cells-" .. cw .. "x" .. ch .. "pixels.png"
end

local function corner(dir, cw, ch, orient)
  return dir .. "/corner-" .. orient .. "-left-" .. COLOR
         .. "-background000000-" .. CORNER_W .. "x" .. CORNER_H .. "cells-"
         .. cw .. "x" .. ch .. "pixels.png"
end

local function hcap(dir, cw, ch, facing, w_cells)
  return dir .. "/hcap-round-" .. facing .. "-" .. COLOR
         .. "-background000000-" .. w_cells .. "x1cells-"
         .. cw .. "x" .. ch .. "pixels-gap0.png"
end

-- 2-row tall round cap spanning both bar rows (no -background000000, no -gap0)
local CAP_W = 2
local function vcap(dir, cw, ch, facing)
  return dir .. "/cap-round-" .. facing .. "-" .. COLOR
         .. "-" .. CAP_W .. "x2cells-" .. cw .. "x" .. ch .. "pixels.png"
end

-- ── highlight groups ───────────────────────────────────────────────────────

local function setup_hls()
  local bar_bg   = DEBUG_BG and "#330033" or p.periwinkle
  local bg_color = DEBUG_BG and "#003333" or p.bg
  vim.api.nvim_set_hl(0, "LcarsBlockBar",     { bg = bar_bg,   fg = bar_bg })
  vim.api.nvim_set_hl(0, "LcarsBlockStem",    { bg = bar_bg,   fg = bar_bg })
  vim.api.nvim_set_hl(0, "LcarsBlockBg",      { bg = bg_color, fg = p.fg })
  vim.api.nvim_set_hl(0, "LcarsBlockCmd",     { bg = bg_color, fg = p.fg,  bold = true })
  vim.api.nvim_set_hl(0, "LcarsBlockChipOr",  { bg = p.orange, fg = p.bg,  bold = true })
  vim.api.nvim_set_hl(0, "LcarsBlockChipGo",  { bg = p.gold,   fg = p.bg })
  vim.api.nvim_set_hl(0, "LcarsBlockChipSk",  { bg = p.sky,    fg = p.bg })
  vim.api.nvim_set_hl(0, "LcarsBlockLive",    { bg = bg_color, fg = p.sage, bold = true })
  vim.api.nvim_set_hl(0, "LcarsBlockFold",    { bg = p.bg_dim, fg = p.orange })
  vim.api.nvim_set_hl(0, "LcarsBlockFoldDim", { bg = p.bg_dim, fg = p.dim })
  vim.api.nvim_set_hl(0, "LcarsBlockInput",   { bg = bg_color, fg = p.fg })
  vim.api.nvim_set_hl(0, "LcarsBlockCursor",  { bg = p.cursor, fg = p.bg })
  vim.api.nvim_set_hl(0, "Normal",            { bg = p.bg,     fg = p.fg })
end

-- ── image state ────────────────────────────────────────────────────────────

local tab_imgs = {}  -- keyed by tabnr

local function clear_tab_images(tabnr)
  for _, img in ipairs(tab_imgs[tabnr] or {}) do
    pcall(function() img:clear() end)
  end
  tab_imgs[tabnr] = {}
end

local function clear_all_images()
  for t, _ in pairs(tab_imgs) do clear_tab_images(t) end
  -- Evict orphaned images from a prior module load (tab_imgs handles were lost
  -- on package.loaded reload). Filtered by cache_dir so we don't touch images
  -- placed by other plugins.
  if ok_image then
    pcall(function()
      for _, img in ipairs(image.get_images() or {}) do
        if img.path and img.path:find(cache_dir, 1, true) then
          img:clear()
        end
      end
    end)
  end
end

local function place_image(tabnr, path, x, y, w, h)
  if not ok_image then return end
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("block_demo: missing: " .. vim.fn.fnamemodify(path, ":t"), vim.log.levels.WARN)
    return
  end
  local img = image.from_file(path, { x = x, y = y, width = w, height = h })
  if img then
    img.ignore_global_max_size = true
    img:render()
    tab_imgs[tabnr] = tab_imgs[tabnr] or {}
    table.insert(tab_imgs[tabnr], img)
  end
end

-- ── buffer helpers ─────────────────────────────────────────────────────────

local ns = vim.api.nvim_create_namespace("lcars_block_demo")

-- Append rows to shared `lines` table; return 0-indexed start row.
local function append(lines, new_lines)
  local start = #lines
  for _, l in ipairs(new_lines) do lines[#lines + 1] = l end
  return start
end

local function pad(n) return string.rep(" ", n) end
local function bar(w)  return string.rep(" ", w) end

-- ── annotation helpers (called after buf_set_lines) ────────────────────────

-- Priority 200 beats treesitter (100) and default highlights so stem/bar bg
-- covers content characters that would otherwise inherit Normal bg.
local HL_PRI = 200

-- The global statuscolumn ("%#LineNr#%=%l%#LineNr# ") in nvim/colors/lcars.lua
-- always renders one gutter cell before content col 0 (textoff = 1). Images use
-- raw screen coords; extmarks use buffer coords. Subtracting GUTTER_W once, here,
-- lands every extmark at the same screen column as the image col it should cover.
local GUTTER_W = 1

local function hl(buf, group, r, c0, c1)
  vim.api.nvim_buf_set_extmark(buf, ns, r, c0 - GUTTER_W, {
    end_col   = c1 - GUTTER_W,
    hl_group  = group,
    priority  = HL_PRI,
    strict    = false,   -- clamp instead of error when end_col > line length
  })
end

local function barrow(buf, r, x0, w, group)
  hl(buf, group, r, x0, x0 + w)
end

-- Stem is 1 cell wide: the elbow image's stem segment is STEM_COLS=1 in gen_swoops.py.
local STEM_W = 1

-- Right-end cap width in cells (hcap-round-left/right-...-1x1cells-...)
local HCAP_W = 1

local function stem_left_rows(buf, r0, r1, x)
  for r = r0, r1 - 1 do hl(buf, "LcarsBlockStem", r, x, x + STEM_W) end
end

local function stem_right_rows(buf, r0, r1, x)
  for r = r0, r1 - 1 do hl(buf, "LcarsBlockStem", r, x - STEM_W + 1, x + 1) end
end

-- Place chips spanning two rows (r_top = bar row 0, r_text = bar row 1).
-- Each chip: 1-col black gap | colored bg full height | 1-col trailing black gap.
-- Adjacent chips share (comb) a single gap column per the zsh _lcars_chips rule.
local function chips_block(buf, r_top, r_text, col, chip_list)
  local function gap_at(row, pos)
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      virt_text         = {{ " ", "LcarsBlockBg" }},
      virt_text_pos     = "overlay",
      virt_text_win_col = pos,
    })
  end
  -- leading gap before first chip
  gap_at(r_top, col); gap_at(r_text, col)
  local c = col + 1
  for _, chip in ipairs(chip_list) do
    local label = " " .. chip[1] .. " "
    local blank = string.rep(" ", #label)
    vim.api.nvim_buf_set_extmark(buf, ns, r_top, 0, {
      virt_text         = {{ blank, chip[2] }},
      virt_text_pos     = "overlay",
      virt_text_win_col = c,
    })
    vim.api.nvim_buf_set_extmark(buf, ns, r_text, 0, {
      virt_text         = {{ label, chip[2] }},
      virt_text_pos     = "overlay",
      virt_text_win_col = c,
    })
    c = c + #label
    -- trailing gap (combs with next chip's leading gap)
    gap_at(r_top, c); gap_at(r_text, c)
    c = c + 1
  end
end

-- Single-row chip placement (used by make_A2/B/C/D/F/G where chips sit on one row).
local function chips_at(buf, r, col, chip_list)
  local c = col
  for _, chip in ipairs(chip_list) do
    local text = " " .. chip[1] .. " "
    vim.api.nvim_buf_set_extmark(buf, ns, r, 0, {
      virt_text         = {{ text, chip[2] }},
      virt_text_pos     = "overlay",
      virt_text_win_col = c,
    })
    c = c + #text
  end
end

local function mark_at(buf, r, col, text, group)
  vim.api.nvim_buf_set_extmark(buf, ns, r, 0, {
    virt_text         = {{ text, group }},
    virt_text_pos     = "overlay",
    virt_text_win_col = col,
  })
end

-- ── shared fake content ────────────────────────────────────────────────────

local CHIPS = {
  { "main",   "LcarsBlockChipGo" },
  { "~/code", "LcarsBlockChipSk" },
  { "AWS",    "LcarsBlockChipOr" },
}

local TREE1 = {
  ".", "├── nvim/", "│   └── lua/lcars/",
  "│       ├── chrome.lua", "│       └── palette.lua",
  "├── zsh/", "│   └── prompt_lcars.zsh",
  "└── docs/", "3 directories, 4 files",
}

local TREE2 = {
  ".", "├── src/", "│   ├── main.rs", "│   └── lib.rs",
  "├── Cargo.toml", "└── README.md",
  "2 directories, 4 files",
}

local PING = {
  "PING 8.8.8.8: 56 data bytes",
  "64 bytes icmp_seq=0 ttl=118 time=12.4 ms",
  "64 bytes icmp_seq=1 ttl=118 time=11.9 ms",
  "64 bytes icmp_seq=2 ttl=118 time=12.2 ms",
}

-- ── block constructors ─────────────────────────────────────────────────────
--
-- Each takes (lines, lp, bw, dir, cw, ch) where:
--   lines = shared all_lines table (appended to directly)
--   lp    = left padding (LEFT_PAD cols of spaces before block)
--   bw    = block width in cols
--   dir, cw, ch = asset parameters
--
-- Returns (annotate_fn, image_specs[])
-- annotate_fn(buf) is called AFTER buf_set_lines.
-- image_specs[].dy is the global buffer row.

-- 3-row header, left stem
-- Header layout (elbow-top-left, 3 rows):
--   h0+0: [bar][bar]   full periwinkle bar
--   h0+1: [bar][bar]   full periwinkle bar + chips overlaid
--   h0+2: [stub]...    1-col stem stub + cmd text
-- Footer layout (elbow-bottom-left, 3 rows):
--   f0+0: [stub]...    1-col stem stub (image row 0)
--   f0+1: [bar][bar]   full bar (image row 1)
--   f0+2: [bar][bar]   full bar (image row 2)
local function make_A(lines, lp, bw, dir, cw, ch, cmd, content, chips)
  chips = chips or CHIPS
  append(lines, { "" })
  local h0 = append(lines, {
    pad(lp) .. bar(bw),   -- bar
    pad(lp) .. bar(bw),   -- bar + chips
    pad(lp) .. bar(bw),   -- stem stub + cmd
  })
  local out = {}
  for _, l in ipairs(content) do out[#out+1] = pad(lp) .. " " .. l end
  local o0 = append(lines, out)
  local f0 = append(lines, {
    pad(lp) .. bar(bw),   -- stem stub (image row 0)
    pad(lp) .. bar(bw),   -- bar (image row 1)
    pad(lp) .. bar(bw),   -- bar (image row 2)
  })
  append(lines, { "" })

  -- bar_x0 overlaps the elbow by 1 col to close the antialiased-edge gap
  local bar_x0 = lp + ELBOW_W - 1
  local cap_x  = lp + bw - CAP_W
  -- Bar stops BEFORE the 2-cell vcap. The bar extmark at HL_PRI=200 renders above
  -- the image in nvim+image.nvim+kitty, so any cap cell it covers becomes a solid
  -- rectangle (arc lost). Leaving both cap cells with the default black bg lets the
  -- vcap image's full 2-cell semicircle show — periwinkle interior curving to
  -- transparent outer corners over black.
  local bar_w  = cap_x - bar_x0

  local function annotate(buf)
    barrow(buf, h0,     bar_x0, bar_w, "LcarsBlockBar")
    barrow(buf, h0 + 1, bar_x0, bar_w, "LcarsBlockBar")
    chips_block(buf, h0, h0 + 1, bar_x0, chips)
    mark_at(buf, h0 + 2, lp + ELBOW_W, cmd, "LcarsBlockBg")
    stem_left_rows(buf, o0, o0 + #out, lp)
    barrow(buf, f0 + 1, bar_x0, bar_w, "LcarsBlockBar")
    barrow(buf, f0 + 2, bar_x0, bar_w, "LcarsBlockBar")
  end

  return annotate, {
    { path = elbow(dir,cw,ch,"top",   "left"), dx=lp,   dy=h0, w=ELBOW_W, h=ELBOW_H },
    { path = elbow(dir,cw,ch,"bottom","left"), dx=lp,   dy=f0, w=ELBOW_W, h=ELBOW_H },
    { path = vcap(dir,cw,ch,"right"), dx=cap_x, dy=h0,     w=CAP_W, h=2 },
    { path = vcap(dir,cw,ch,"right"), dx=cap_x, dy=f0 + 1, w=CAP_W, h=2 },
  }
end

-- 2-row header (chrome weight), left stem
-- corner-top-left:    row0=full bar, row1=partial (gap at cols 4-5)
-- corner-bottom-left: row0=partial (gap at cols 4-5), row1=full bar
-- Header: [bar+chips][stub+cmd]; Footer: [stub][bar]
local function make_A2(lines, lp, bw, dir, cw, ch, cmd, content, chips)
  chips = chips or CHIPS
  append(lines, { "" })
  local h0 = append(lines, {
    pad(lp) .. bar(bw),   -- bar + chips (image row 0)
    pad(lp) .. bar(bw),   -- stem stub + cmd (image row 1)
  })
  local out = {}
  for _, l in ipairs(content) do out[#out+1] = pad(lp) .. " " .. l end
  local o0 = append(lines, out)
  local f0 = append(lines, {
    pad(lp) .. bar(bw),   -- partial/stub row (image row 0)
    pad(lp) .. bar(bw),   -- full bar (image row 1)
  })
  append(lines, { "" })

  local bar_x0 = lp + CORNER_W
  local bar_w  = bw - CORNER_W - HCAP_W
  local cap_x  = lp + bw - HCAP_W

  local function annotate(buf)
    barrow(buf, h0,     bar_x0, bar_w, "LcarsBlockBar")
    barrow(buf, h0 + 1, bar_x0, bar_w, "LcarsBlockBar")
    hl(buf, "LcarsBlockStem", h0 + 1, lp, lp + STEM_W)
    chips_at(buf, h0, lp + CORNER_W + 1, chips)
    mark_at(buf, h0 + 1, lp + 1, cmd, "LcarsBlockBg")
    stem_left_rows(buf, o0, o0 + #out, lp)
    hl(buf, "LcarsBlockStem", f0,     lp, lp + STEM_W)
    barrow(buf, f0 + 1, bar_x0, bar_w, "LcarsBlockBar")
  end

  return annotate, {
    { path = corner(dir,cw,ch,"top"),     dx=lp,   dy=h0,     w=CORNER_W, h=CORNER_H },
    { path = corner(dir,cw,ch,"bottom"),  dx=lp,   dy=f0,     w=CORNER_W, h=CORNER_H },
    { path = hcap(dir,cw,ch,"right", HCAP_W), dx=cap_x, dy=h0,     w=HCAP_W, h=1 },
    { path = hcap(dir,cw,ch,"right", HCAP_W), dx=cap_x, dy=f0 + 1, w=HCAP_W, h=1 },
  }
end

-- 3-row header, right stem
local function make_B(lines, lp, bw, dir, cw, ch, cmd, content, chips)
  chips = chips or CHIPS
  append(lines, { "" })
  local h0 = append(lines, {
    pad(lp) .. bar(bw),
    pad(lp) .. bar(bw),
    pad(lp) .. bar(bw),
  })
  local out = {}
  for _, l in ipairs(content) do
    local pad_n = math.max(0, bw - 1 - #l)
    out[#out+1] = pad(lp) .. l .. string.rep(" ", pad_n) .. " "
  end
  local o0 = append(lines, out)
  local f0 = append(lines, {
    pad(lp) .. bar(bw),   -- stub (col-1 only, image row 0)
    pad(lp) .. bar(bw),   -- full bar (image row 1)
    pad(lp) .. bar(bw),   -- full bar (image row 2)
  })
  append(lines, { "" })

  local rx     = lp + bw - 1          -- right stem col (rightmost cell)
  local elbow_x = lp + bw - ELBOW_W   -- right elbow starts here
  local bar_x0  = lp + HCAP_W         -- bar starts after left cap
  local bar_w   = bw - HCAP_W - ELBOW_W  -- bar ends before right elbow

  local function annotate(buf)
    barrow(buf, h0,     bar_x0, bar_w, "LcarsBlockBar")
    barrow(buf, h0 + 1, bar_x0, bar_w, "LcarsBlockBar")
    hl(buf, "LcarsBlockStem", h0 + 2, rx - STEM_W + 1, rx + 1)
    chips_at(buf, h0 + 1, lp + HCAP_W + 2, chips)
    mark_at(buf, h0 + 2, lp + HCAP_W + 1, cmd, "LcarsBlockBg")
    stem_right_rows(buf, o0, o0 + #out, rx)
    hl(buf, "LcarsBlockStem", f0,     rx - STEM_W + 1, rx + 1)
    barrow(buf, f0 + 1, bar_x0, bar_w, "LcarsBlockBar")
    barrow(buf, f0 + 2, bar_x0, bar_w, "LcarsBlockBar")
  end

  return annotate, {
    { path = elbow(dir,cw,ch,"top",   "right"), dx=elbow_x, dy=h0, w=ELBOW_W, h=ELBOW_H },
    { path = elbow(dir,cw,ch,"bottom","right"), dx=elbow_x, dy=f0, w=ELBOW_W, h=ELBOW_H },
    { path = hcap(dir,cw,ch,"left", HCAP_W), dx=lp, dy=h0,     w=HCAP_W, h=1 },
    { path = hcap(dir,cw,ch,"left", HCAP_W), dx=lp, dy=h0 + 1, w=HCAP_W, h=1 },
    { path = hcap(dir,cw,ch,"left", HCAP_W), dx=lp, dy=f0 + 1, w=HCAP_W, h=1 },
    { path = hcap(dir,cw,ch,"left", HCAP_W), dx=lp, dy=f0 + 2, w=HCAP_W, h=1 },
  }
end

-- Command text as a black notch in the header bar (like zsh cwd gap).
-- Chip(s) on the left, then a black-bg notch containing the command text.
local function make_C(lines, lp, bw, dir, cw, ch, cmd, content, chips)
  chips = chips or {{ "main", "LcarsBlockChipGo" }}
  append(lines, { "" })
  local h0 = append(lines, {
    pad(lp) .. bar(bw),   -- bar (image row 0)
    pad(lp) .. bar(bw),   -- bar + chips + cmd notch (image row 1)
    pad(lp) .. bar(bw),   -- stem stub (image row 2)
  })
  local out = {}
  for _, l in ipairs(content) do out[#out+1] = pad(lp) .. " " .. l end
  local o0 = append(lines, out)
  local f0 = append(lines, {
    pad(lp) .. bar(bw),   -- stub (image row 0)
    pad(lp) .. bar(bw),   -- bar (image row 1)
    pad(lp) .. bar(bw),   -- bar (image row 2)
  })
  append(lines, { "" })

  -- chip total width: compute to place notch after them
  local chip_w = 0
  for _, ch_ in ipairs(chips) do chip_w = chip_w + #ch_[1] + 2 end
  local notch_col = lp + ELBOW_W + 1 + chip_w + 1

  local bar_x0 = lp + ELBOW_W
  local bar_w  = bw - ELBOW_W - HCAP_W
  local cap_x  = lp + bw - HCAP_W

  local function annotate(buf)
    barrow(buf, h0,     bar_x0, bar_w, "LcarsBlockBar")
    barrow(buf, h0 + 1, bar_x0, bar_w, "LcarsBlockBar")
    hl(buf, "LcarsBlockStem", h0 + 2, lp, lp + STEM_W)
    chips_at(buf, h0 + 1, lp + ELBOW_W + 1, chips)
    mark_at(buf, h0 + 1, notch_col, " " .. cmd .. " ", "LcarsBlockCmd")
    stem_left_rows(buf, o0, o0 + #out, lp)
    hl(buf, "LcarsBlockStem", f0,     lp, lp + STEM_W)
    barrow(buf, f0 + 1, bar_x0, bar_w, "LcarsBlockBar")
    barrow(buf, f0 + 2, bar_x0, bar_w, "LcarsBlockBar")
  end

  return annotate, {
    { path = elbow(dir,cw,ch,"top",   "left"), dx=lp,   dy=h0,     w=ELBOW_W, h=ELBOW_H },
    { path = elbow(dir,cw,ch,"bottom","left"), dx=lp,   dy=f0,     w=ELBOW_W, h=ELBOW_H },
    { path = hcap(dir,cw,ch,"right",  HCAP_W), dx=cap_x, dy=h0,     w=HCAP_W, h=1 },
    { path = hcap(dir,cw,ch,"right",  HCAP_W), dx=cap_x, dy=h0 + 1, w=HCAP_W, h=1 },
    { path = hcap(dir,cw,ch,"right",  HCAP_W), dx=cap_x, dy=f0 + 1, w=HCAP_W, h=1 },
    { path = hcap(dir,cw,ch,"right",  HCAP_W), dx=cap_x, dy=f0 + 2, w=HCAP_W, h=1 },
  }
end

-- Live block: header + stem, no footer
local function make_D(lines, lp, bw, dir, cw, ch, cmd, content)
  append(lines, { "" })
  local h0 = append(lines, {
    pad(lp) .. bar(bw),
    pad(lp) .. bar(bw),
    pad(lp) .. bar(bw),
  })
  local out = {}
  for i, l in ipairs(content) do
    out[#out+1] = pad(lp) .. " " .. l .. (i == #content and " ▌" or "")
  end
  local o0 = append(lines, out)
  append(lines, { "" })

  local bar_x0 = lp + ELBOW_W
  local bar_w  = bw - ELBOW_W - HCAP_W
  local cap_x  = lp + bw - HCAP_W

  local function annotate(buf)
    barrow(buf, h0,     bar_x0, bar_w, "LcarsBlockBar")
    barrow(buf, h0 + 1, bar_x0, bar_w, "LcarsBlockBar")
    hl(buf, "LcarsBlockStem", h0 + 2, lp, lp + STEM_W)
    chips_at(buf, h0 + 1, lp + ELBOW_W + 1, CHIPS)
    mark_at(buf, h0 + 2, lp + 1, cmd, "LcarsBlockBg")
    stem_left_rows(buf, o0, o0 + #out, lp)
    local last_text = out[#out]
    local cursor_col = #last_text - 2
    hl(buf, "LcarsBlockLive", o0 + #out - 1, cursor_col, cursor_col + 3)
  end

  return annotate, {
    { path = elbow(dir,cw,ch,"top","left"), dx=lp,   dy=h0,     w=ELBOW_W, h=ELBOW_H },
    { path = hcap(dir,cw,ch,"right", HCAP_W), dx=cap_x, dy=h0,     w=HCAP_W, h=1 },
    { path = hcap(dir,cw,ch,"right", HCAP_W), dx=cap_x, dy=h0 + 1, w=HCAP_W, h=1 },
  }
end

-- Folded block: single summary row with hcap end-caps
local function make_E(lines, lp, bw, dir, cw, ch, cmd, line_count)
  local hcap_w = math.max(1, math.floor(ch / 2 / cw + 0.5))
  append(lines, { "" })
  local fold_row = append(lines, { pad(lp) .. bar(bw) })
  append(lines, { "" })

  local function annotate(buf)
    hl(buf, "LcarsBlockFoldDim", fold_row, lp, lp + bw)
    mark_at(buf, fold_row, lp + hcap_w + 1,  "▶ ",   "LcarsBlockFold")
    mark_at(buf, fold_row, lp + hcap_w + 3,  " " .. cmd .. " ", "LcarsBlockBg")
    local meta = "[✓ 0]  [0.4s]  [" .. line_count .. " lines]"
    mark_at(buf, fold_row, lp + hcap_w + 5 + #cmd, meta, "LcarsBlockFoldDim")
  end

  return annotate, {
    { path = hcap(dir,cw,ch,"left",  hcap_w), dx=lp,          dy=fold_row, w=hcap_w, h=1 },
    { path = hcap(dir,cw,ch,"right", hcap_w), dx=lp+bw-hcap_w,dy=fold_row, w=hcap_w, h=1 },
  }
end

-- Bottom-pinned prompt (command-buffer style)
local function make_F(lines, lp, bw, dir, cw, ch)
  local scroll = {
    "  Previous output line 1",
    "  Previous output line 2",
    "  Previous output line 3",
  }
  append(lines, { "" })
  local s0 = append(lines, (function()
    local r = {}
    for _, l in ipairs(scroll) do r[#r+1] = pad(lp) .. l end
    return r
  end)())
  local h0 = append(lines, {
    pad(lp) .. bar(bw),
    pad(lp) .. bar(bw),
    pad(lp) .. bar(bw),
  })
  append(lines, { "" })

  local bar_x0 = lp + ELBOW_W
  local bar_w  = bw - ELBOW_W - HCAP_W
  local cap_x  = lp + bw - HCAP_W

  local function annotate(buf)
    for r = s0, s0 + #scroll - 1 do hl(buf, "LcarsBlockFoldDim", r, lp, lp + bw) end
    barrow(buf, h0,     bar_x0, bar_w, "LcarsBlockBar")
    barrow(buf, h0 + 1, bar_x0, bar_w, "LcarsBlockBar")
    chips_at(buf, h0 + 1, lp + ELBOW_W + 1, CHIPS)
    hl(buf, "LcarsBlockInput", h0 + 2, lp, lp + bw)
    hl(buf, "LcarsBlockStem",  h0 + 2, lp, lp + STEM_W)
    mark_at(buf, h0 + 2, lp + 1, "█", "LcarsBlockCursor")
  end

  return annotate, {
    { path = elbow(dir,cw,ch,"top","left"), dx=lp,   dy=h0,     w=ELBOW_W, h=ELBOW_H },
    { path = hcap(dir,cw,ch,"right", HCAP_W), dx=cap_x, dy=h0,     w=HCAP_W, h=1 },
    { path = hcap(dir,cw,ch,"right", HCAP_W), dx=cap_x, dy=h0 + 1, w=HCAP_W, h=1 },
  }
end

-- Header + stem prompt (zsh-style, nvim-native)
local function make_G(lines, lp, bw, dir, cw, ch)
  append(lines, { "" })
  local h0 = append(lines, {
    pad(lp) .. bar(bw),
    pad(lp) .. bar(bw),
    pad(lp) .. bar(bw),
  })
  append(lines, { "" })

  local bar_x0 = lp + ELBOW_W
  local bar_w  = bw - ELBOW_W - HCAP_W
  local cap_x  = lp + bw - HCAP_W

  local function annotate(buf)
    barrow(buf, h0,     bar_x0, bar_w, "LcarsBlockBar")
    barrow(buf, h0 + 1, bar_x0, bar_w, "LcarsBlockBar")
    hl(buf, "LcarsBlockStem", h0 + 2, lp, lp + STEM_W)
    chips_at(buf, h0 + 1, lp + ELBOW_W + 1, CHIPS)
    mark_at(buf, h0 + 2, lp + 1, "█", "LcarsBlockCursor")
  end

  return annotate, {
    { path = elbow(dir,cw,ch,"top","left"), dx=lp,   dy=h0,     w=ELBOW_W, h=ELBOW_H },
    { path = hcap(dir,cw,ch,"right", HCAP_W), dx=cap_x, dy=h0,     w=HCAP_W, h=1 },
    { path = hcap(dir,cw,ch,"right", HCAP_W), dx=cap_x, dy=h0 + 1, w=HCAP_W, h=1 },
  }
end

-- ── tab renderer ───────────────────────────────────────────────────────────

-- Find or create a tab with the given name; return (tabnr, win, buf).
local function get_or_create_tab(name)
  -- Search existing tabs
  for _, t in ipairs(vim.api.nvim_list_tabpages()) do
    local wins = vim.api.nvim_tabpage_list_wins(t)
    if #wins > 0 then
      local b = vim.api.nvim_win_get_buf(wins[1])
      if vim.api.nvim_buf_get_name(b):find(name, 1, true) then
        return vim.api.nvim_tabpage_get_number(t),
               wins[1],
               b
      end
    end
  end
  -- Create new tab
  vim.cmd("tabnew")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_buf_set_name(buf, "lcars://demo/" .. name)
  return vim.api.nvim_tabpage_get_number(vim.api.nvim_get_current_tabpage()),
         win, buf
end

local function setup_win(win)
  vim.wo[win].number         = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn     = "no"
  vim.wo[win].foldcolumn     = "0"
  vim.wo[win].wrap           = false
  vim.wo[win].cursorline     = false
  vim.wo[win].list           = false
  vim.wo[win].winhighlight   = "Normal:LcarsBlockBg,NormalNC:LcarsBlockBg"
end

local function render_tab(name, build_fn)
  if not ok_image then
    vim.notify("block_demo: image.nvim not available", vim.log.levels.ERROR)
    return
  end
  setup_hls()

  local cw, ch = cell_px()
  local dir    = find_asset_dir(cw, ch)
  local tabnr, win, buf = get_or_create_tab(name)

  clear_tab_images(tabnr)
  setup_win(win)

  local win_w = vim.api.nvim_win_get_width(win)
  -- Block width: full window minus left pad and a right margin
  local bw = win_w - LEFT_PAD - 4

  -- ── Phase 1: build lines + collect deferred annotations ────────────────
  local all_lines  = {}
  for _ = 1, TOP_PAD do all_lines[#all_lines + 1] = "" end

  local all_annots = {}
  local all_specs  = {}

  local function add(annot, specs)
    all_annots[#all_annots + 1] = annot
    for _, s in ipairs(specs) do all_specs[#all_specs + 1] = s end
  end

  build_fn(all_lines, bw, dir, cw, ch, add)

  -- ── Phase 2: write buffer ───────────────────────────────────────────────
  vim.bo[buf].modifiable = true
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].swapfile   = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
  vim.bo[buf].modifiable = false

  -- ── Phase 3: annotations ───────────────────────────────────────────────
  -- hl() subtracts GUTTER_W to compensate for the global statuscolumn (1 col
  -- gutter, textoff=1) between screen col 0 and buffer col 0. No dynamic
  -- textoff read is needed: statuscolumn is set once in nvim/colors/lcars.lua
  -- and doesn't vary per window.
  for _, annot in ipairs(all_annots) do annot(buf) end

  vim.api.nvim_win_set_cursor(win, { 1, 0 })

  -- Return the tabpage handle, specs, and win so the caller can place images.
  local tp = nil
  for _, t in ipairs(vim.api.nvim_list_tabpages()) do
    if vim.api.nvim_tabpage_get_number(t) == tabnr then tp = t; break end
  end
  return all_specs, win, tp, tabnr
end

-- ── tab definitions ────────────────────────────────────────────────────────

local TABS = {

  { name = "A-left-stem-3row", fn = function(lines, bw, dir, cw, ch, add)
    local a, s = make_A(lines, LEFT_PAD, bw, dir, cw, ch,
      "tree ~/code/lcarcat", TREE1, CHIPS)
    add(a, s)
    local a2, s2 = make_A(lines, LEFT_PAD, bw, dir, cw, ch,
      "tree ~/code/myproject", TREE2,
      {{ "feat/auth", "LcarsBlockChipSk" }, { "~/code/myproject", "LcarsBlockChipGo" }})
    add(a2, s2)
    local a3, s3 = make_A(lines, LEFT_PAD, bw, dir, cw, ch,
      "ls -la /etc", {
        "total 96", "-rw-r--r-- hosts", "-rw-r--r-- passwd",
        "-rw-r--r-- sudoers", "-rw-r--r-- resolv.conf",
      }, {{ "main", "LcarsBlockChipGo" }, { "/etc", "LcarsBlockChipOr" }})
    add(a3, s3)
  end},

  { name = "A2-left-stem-2row", fn = function(lines, bw, dir, cw, ch, add)
    local a, s = make_A2(lines, LEFT_PAD, bw, dir, cw, ch,
      "tree ~/code/lcarcat", TREE1, CHIPS)
    add(a, s)
    local a2, s2 = make_A2(lines, LEFT_PAD, bw, dir, cw, ch,
      "tree ~/code/myproject", TREE2,
      {{ "feat/auth", "LcarsBlockChipSk" }, { "~/code/myproject", "LcarsBlockChipGo" }})
    add(a2, s2)
    local a3, s3 = make_A2(lines, LEFT_PAD, bw, dir, cw, ch,
      "git log --oneline -5",
      { "a3f2b1c fix: prompt elbow alignment",
        "d9e0123 feat: add block_demo",
        "8c4f991 docs: terminology",
        "1a2b3c4 chore: deploy terminal_frame" },
      {{ "main", "LcarsBlockChipGo" }})
    add(a3, s3)
  end},

  { name = "B-right-stem-3row", fn = function(lines, bw, dir, cw, ch, add)
    local a, s = make_B(lines, LEFT_PAD, bw, dir, cw, ch,
      "tree ~/code/lcarcat", TREE1, CHIPS)
    add(a, s)
    local a2, s2 = make_B(lines, LEFT_PAD, bw, dir, cw, ch,
      "tree ~/code/myproject", TREE2,
      {{ "AWS", "LcarsBlockChipOr" }, { "feat/auth", "LcarsBlockChipSk" }})
    add(a2, s2)
  end},

  { name = "C-cmd-in-header", fn = function(lines, bw, dir, cw, ch, add)
    local a, s = make_C(lines, LEFT_PAD, bw, dir, cw, ch,
      "ls -la /etc/hosts",
      { "-rw-r--r-- 1 root wheel 213 /etc/hosts" },
      {{ "main", "LcarsBlockChipGo" }})
    add(a, s)
    local a2, s2 = make_C(lines, LEFT_PAD, bw, dir, cw, ch,
      "echo $PATH",
      { "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" },
      {{ "main", "LcarsBlockChipGo" }, { "~", "LcarsBlockChipSk" }})
    add(a2, s2)
    local a3, s3 = make_C(lines, LEFT_PAD, bw, dir, cw, ch,
      "git status",
      { "On branch main", "Changes not staged for commit:",
        "  modified: nvim/lua/lcars/block_demo.lua" },
      {{ "main", "LcarsBlockChipGo" }, { "AWS", "LcarsBlockChipOr" }})
    add(a3, s3)
  end},

  { name = "D-live-block", fn = function(lines, bw, dir, cw, ch, add)
    local a, s = make_D(lines, LEFT_PAD, bw, dir, cw, ch, "ping 8.8.8.8", PING)
    add(a, s)
    local a2, s2 = make_D(lines, LEFT_PAD, bw, dir, cw, ch, "tail -f /var/log/system.log", {
      "Aug 10 13:01:23 mac kernel: AppleKeyStore",
      "Aug 10 13:01:24 mac WindowServer: CGXSetLayerPosition",
      "Aug 10 13:01:25 mac bluetoothd: Bluetooth: device connected",
    })
    add(a2, s2)
  end},

  { name = "E-folded", fn = function(lines, bw, dir, cw, ch, add)
    local a, s = make_E(lines, LEFT_PAD, bw, dir, cw, ch, "git log --oneline -20", 20)
    add(a, s)
    local a2, s2 = make_E(lines, LEFT_PAD, bw, dir, cw, ch, "ping 8.8.8.8", 47)
    add(a2, s2)
    local a3, s3 = make_E(lines, LEFT_PAD, bw, dir, cw, ch, "tree ~/code/lcarcat", 9)
    add(a3, s3)
    -- Show an unfolded block for comparison
    local a4, s4 = make_A(lines, LEFT_PAD, bw, dir, cw, ch,
      "tree ~/code/lcarcat", TREE1, CHIPS)
    add(a4, s4)
  end},

  { name = "F-bottom-prompt", fn = function(lines, bw, dir, cw, ch, add)
    local a, s = make_F(lines, LEFT_PAD, bw, dir, cw, ch)
    add(a, s)
    local a2, s2 = make_F(lines, LEFT_PAD, bw, dir, cw, ch)
    add(a2, s2)
  end},

  { name = "G-header-stem-prompt", fn = function(lines, bw, dir, cw, ch, add)
    local a, s = make_G(lines, LEFT_PAD, bw, dir, cw, ch)
    add(a, s)
    local a2, s2 = make_G(lines, LEFT_PAD, bw, dir, cw, ch)
    add(a2, s2)
  end},
}

-- Place images for the given tab's win/specs at current screen coords.
-- Must be called when `tabnr` is the active (visible) tab.
-- Clears ALL tracked images first — kitty images are screen-absolute and
-- persist across nvim tab switches, so we must evict every other tab's images.
local function render_images_for_tab(tabnr, win, specs)
  clear_all_images()
  local wi      = vim.fn.getwininfo(win)[1]
  local win_top = wi.winrow - 1
  local win_col = wi.wincol - 1
  local topline = vim.fn.line("w0", win) - 1
  for _, spec in ipairs(specs) do
    local sy = win_top + spec.dy - topline
    local sx = win_col + spec.dx
    if sy >= win_top and sy < win_top + wi.height then
      place_image(tabnr, spec.path, sx, sy, spec.w, spec.h)
    end
  end
end

-- ── public API ─────────────────────────────────────────────────────────────

function M.render_all()
  -- Phase 1: render all tab buffers (text + highlights only, no images).
  -- render_tab may create tabs via tabnew (switching active tab); that's OK
  -- since we defer all image placement to phase 3.
  local tab_specs = {}  -- { tp, tabnr, win, specs }
  for _, t in ipairs(TABS) do
    local specs, win, tp, tabnr = render_tab(t.name, t.fn)
    tab_specs[#tab_specs + 1] = { tp = tp, tabnr = tabnr, win = win, specs = specs }
  end

  -- Phase 2: clear every kitty image (stale from prior renders).
  clear_all_images()

  -- Phase 3: navigate to tab A and place only its images.
  for _, ts in ipairs(tab_specs) do
    local b = vim.api.nvim_win_get_buf(ts.win)
    if vim.api.nvim_buf_get_name(b):find("demo/A-", 1, true) then
      vim.api.nvim_set_current_tabpage(ts.tp)
      render_images_for_tab(ts.tabnr, ts.win, ts.specs)
      break
    end
  end
end

function M.render_one(name)
  for _, t in ipairs(TABS) do
    if t.name == name or t.name:sub(1,1) == name then
      local specs, win, tp, tabnr = render_tab(t.name, t.fn)
      if tp then
        vim.api.nvim_set_current_tabpage(tp)
        render_images_for_tab(tabnr, win, specs)
      end
      return
    end
  end
  vim.notify("block_demo: unknown tab name: " .. name, vim.log.levels.WARN)
end

vim.api.nvim_create_user_command("LcarsBlockDemo", function()
  M.render_all()
end, { desc = "Open LCARS block frame demo tabs" })

vim.api.nvim_create_user_command("LcarsBlockDemoOne", function(opts)
  M.render_one(opts.args)
end, { nargs = 1, desc = "Open a single LCARS block demo tab (A-G)" })

vim.api.nvim_create_user_command("LcarsBlockDemoDebugBg", function()
  DEBUG_BG = not DEBUG_BG
  setup_hls()
  M.render_all()
end, { desc = "Toggle debug bg (#330033) to reveal transparent image regions" })

-- Re-render images when entering a demo tab (images are viewport-fixed;
-- they need to be redrawn at current screen coordinates on tab switch).
vim.api.nvim_create_autocmd("TabEnter", {
  group = vim.api.nvim_create_augroup("LcarsBlockDemoRefresh", { clear = true }),
  callback = function()
    local wins = vim.api.nvim_tabpage_list_wins(0)
    if #wins == 0 then return end
    local bufname = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(wins[1]))
    if not bufname:find("lcars://demo/", 1, true) then return end
    -- Find which tab definition matches and re-render images for the now-active tab.
    local demo_name = bufname:match("lcars://demo/(.+)$")
    for _, t in ipairs(TABS) do
      if t.name == demo_name then
        vim.schedule(function()
          local specs, win, tp, tabnr = render_tab(t.name, t.fn)
          if tp then render_images_for_tab(tabnr, win, specs) end
        end)
        return
      end
    end
  end,
})

return M
