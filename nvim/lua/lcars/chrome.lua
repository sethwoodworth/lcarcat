-- EXPERIMENTAL: kitty-image corner elbows for the nvim chrome.
--
-- Draws an LCARS elbow into the top-left corner of every window (the horizontal
-- tabline/separator bar rounding down into that window's number-gutter stem) and
-- one bottom-left elbow rounding up from the leftmost gutter into the global
-- statusline. Delivery is image.nvim (kitty backend); each elbow is a WINDOWLESS
-- image pinned to an absolute screen cell, so it sits on row 0 / the separator row
-- (the float code path's `+1` offset is avoided) and stays fixed as buffers scroll.
--
-- The negative space of the outer curve is BAKED into the PNG (`--corner-bg`), so a
-- split window's elbow shows its curve over the periwinkle separators / neighbour
-- panes we can't paint. Assets are generated per (cell size, gutter width) and cached.
--
-- On by default: auto-enabled on VimEnter (once the UI is attached so image.nvim can
-- read the cell size). `:LcarsCorner` toggles it off/on.

local p = require("lcars.palette")
local ok_image, image = pcall(require, "image")

local M = { enabled = false, ready = false }

local BAR_ROWS, STEM_ROWS = 1, 1
local H = BAR_ROWS + STEM_ROWS -- image rows (2): bar + stem/fillet

local cache_dir = vim.fn.stdpath("cache") .. "/lcars"
local gen_py = vim.fn.expand("~/.config/kitty/lcars/gen_swoops.py")

-- imgs: live image.nvim objects. gen: set of gutter widths already generated for the
-- current cell size (invalidated when the cell size changes). main_W: the top-left
-- window's corner column span, so lcars.tabline pads its first pill past the elbow.
local state = { cw = nil, ch = nil, main_W = nil, imgs = {}, gen = {} }

-- ---------------------------------------------------------------------------
-- assets
-- ---------------------------------------------------------------------------
-- Reuse image.nvim's physical cell size so the PNG matches exactly what it renders
-- against (avoids Retina half-scale). ceil so we slightly overshoot and downscale.
local function cell_px()
  local ok_term, term = pcall(require, "image.utils.term")
  if ok_term and term.get_size then
    local sz = term.get_size()
    if sz and sz.cell_width and sz.cell_width > 0 then
      return math.ceil(sz.cell_width), math.ceil(sz.cell_height)
    end
  end
  return 19, 38 -- fallback
end

-- One directory per (cell size, gutter width) so font/zoom changes never reuse a
-- stale-sized PNG. gen_swoops writes descriptive per-variant PNG names (see asset_name)
-- into it; the channel caps are gutter-independent but land in every dir.
local function asset_dir(stem) return cache_dir .. "/" .. state.cw .. "x" .. state.ch .. "-" .. stem end
local function asset_path(name, stem) return asset_dir(stem) .. "/" .. name .. ".png" end

-- Mirror of gen_swoops.py's asset_name(): rebuild the exact descriptive filename the
-- generator writes for a variant so we read back the right one. Keep in lock-step with
-- the Python version. Returns the base name WITHOUT ".png" (asset_path appends it).
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

-- The corner elbows always render periwinkle over a baked-black backdrop; capture that
-- so both the readiness check and the placements name the same file.
local CHROME_COLOR, CHROME_BG = "9999ff", "000000"

local function regenerate(stem, cb)
  local dir = asset_dir(stem)
  vim.fn.mkdir(dir, "p")
  if vim.fn.filereadable(gen_py) == 0 then
    vim.notify("lcars.chrome: generator not found at " .. gen_py, vim.log.levels.ERROR)
    cb(false)
    return
  end
  if vim.fn.executable("uv") == 0 then
    vim.notify("lcars.chrome: 'uv' not found in PATH — skipping asset generation", vim.log.levels.WARN)
    cb(false)
    return
  end
  vim.fn.jobstart({
    "uv", "run", "--with", "pillow", gen_py, "--color", "9999ff",
    "--outdir", dir, "--stem-rows", tostring(STEM_ROWS),
    "--cellw", tostring(state.cw), "--cellh", tostring(state.ch),
    "--bar-rows", tostring(BAR_ROWS), "--stem-cols", tostring(stem),
    "--corner-bg", "000000", -- bake black behind the outer curve
  }, {
    on_exit = function(_, code)
      vim.schedule(function()
        local corner_tl = asset_name("corner", CHROME_COLOR, stem + 2, H,
          state.cw, state.ch, "top", "left", nil, CHROME_BG)
        if code == 0 and vim.fn.filereadable(asset_path(corner_tl, stem)) == 1 then
          state.gen[stem] = true
          cb(true)
        else
          vim.notify("lcars.chrome: corner generation failed (code " .. code .. ")",
            vim.log.levels.ERROR)
          cb(false)
        end
      end)
    end,
  })
end

-- Generate every gutter width in `widths` that isn't cached yet, then call `done`.
local function ensure_assets(widths, done)
  local pending = {}
  for stem in pairs(widths) do
    if not state.gen[stem] then pending[#pending + 1] = stem end
  end
  if #pending == 0 then
    done()
    return
  end
  local remaining = #pending
  local failed = false
  for _, stem in ipairs(pending) do
    regenerate(stem, function(ok)
      if not ok then failed = true end
      remaining = remaining - 1
      if remaining == 0 and not failed then done() end
    end)
  end
end

-- ---------------------------------------------------------------------------
-- placement
-- ---------------------------------------------------------------------------
local function is_normal_win(win)
  local cfg = vim.api.nvim_win_get_config(win)
  return cfg.relative == nil or cfg.relative == "" -- skip floating windows
end

local function win_infos()
  local out = {}
  -- current tabpage only: nvim_list_wins() spans every tab, so another tab's window
  -- can otherwise steal the top-left slot and mask this tab's gutterless buffer.
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_normal_win(win) then
      local sp = vim.fn.win_screenpos(win) -- [row, col], 1-indexed
      local wi = vim.fn.getwininfo(win)[1]
      out[#out + 1] = {
        row = sp[1], col = sp[2],
        w = (wi and wi.width) or 0, h = (wi and wi.height) or 0,
        stem = (wi and wi.textoff) or 4,
      }
    end
  end
  return out
end

-- Placements (0-indexed screen cells): a top-left elbow per window, a bottom-left
-- elbow into the global statusline, and capped channel ends on horizontal split
-- separators. win_screenpos is the 1-indexed top-left content cell (gutter included);
-- y = row-2 puts an elbow's bar on the tabline/separator row above the window.
local function compute_placements()
  local pls = {}
  local infos = win_infos()
  local capcols = math.max(1, math.floor(state.ch / 2 / state.cw + 0.5))

  -- Descriptive filenames matching gen_swoops.py. corner_name: the N-column elbow that
  -- curves into a `stem`-wide gutter (2 image rows). channel_name: the 1-row round
  -- separator caps, keyed by which edge rounds and the leading black gap width.
  local function corner_name(stem, orient)
    return asset_name("corner", CHROME_COLOR, stem + 2, H, state.cw, state.ch,
      orient, "left", nil, CHROME_BG)
  end
  local function channel_name(facing, gap)
    return asset_name("hcap", CHROME_COLOR, capcols, 1, state.cw, state.ch,
      "round", facing, gap, CHROME_BG)
  end

  -- Outer frame only: a single top-left corner (the editor's top-left window) and a
  -- single bottom-left corner (into the statusline). A gutterless window (netrw:
  -- textoff 0) has no stem to curve into, so its corner is a rounded left CAP on the
  -- bar instead of an elbow. Interior split edges are capped channels below, NOT
  -- per-window elbows (which would be T-junctions).
  local main_stem, main_row, bl_stem, bl_row = nil, 1, 4, -1
  for _, a in ipairs(infos) do
    if a.col == 1 then
      if a.row <= 2 and not main_stem then main_stem, main_row = a.stem, a.row end -- top-left
      if a.row > bl_row then bl_row, bl_stem = a.row, a.stem end                    -- bottom-left
    end
  end
  main_stem = main_stem or 4

  -- An elbow at the top of the stem is only valid when a horizontal tabline bar is
  -- present to connect to. Without it the elbow is a fillet mid-stem with no bar.
  local tabline_visible = vim.o.showtabline == 2
    or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)

  -- Suppress the top-left corner when the primary window is a terminal buffer:
  -- the zsh LCARS prompt renders its own bar there, and the chrome image overpaints it.
  local main_win_is_terminal = false
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local sp = vim.fn.win_screenpos(win)
    if sp[1] <= 2 and sp[2] == 1 then
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].buftype == "terminal" then
        main_win_is_terminal = true
      end
      break
    end
  end

  if main_stem == 0 then -- gutterless top-left window -> cap the tabline bar
    state.main_W = capcols
    if tabline_visible and not main_win_is_terminal then
      pls[#pls + 1] = { name = channel_name("left", 0), stem = main_stem, x = 0, y = main_row - 2, w = capcols, h = 1 }
    end
  else
    state.main_W = main_stem + 2
    if tabline_visible and not main_win_is_terminal then
      pls[#pls + 1] = { name = corner_name(main_stem, "top"), stem = main_stem, x = 0, y = main_row - 2, w = main_stem + 2, h = H }
    end
  end
  local rail_width = main_stem -- leftmost gutter; kept continuous through separators

  if vim.o.laststatus == 3 then
    local sl_row = vim.o.lines - vim.o.cmdheight - 1 -- 0-indexed statusline row
    if bl_stem == 0 then -- gutterless bottom-left window -> cap the statusline bar
      pls[#pls + 1] = { name = channel_name("left", 0), stem = bl_stem, x = 0, y = sl_row, w = capcols, h = 1 }
    elseif sl_row - 1 >= 0 then
      pls[#pls + 1] = { name = corner_name(bl_stem, "bottom"), stem = bl_stem, x = 0, y = sl_row - 1, w = bl_stem + 2, h = H }
    end
  end

  -- Horizontal separators (between vertically-stacked windows): keep the flat bar as
  -- periwinkle cells (WinSeparator) and cap the ends. Left cap has a 1-col black gap so
  -- the segment sits off the left rail (which stays continuous); right cap rounds the end.
  for _, a in ipairs(infos) do
    local sep_row = a.row + a.h -- 1-indexed row just below window A
    for _, b in ipairs(infos) do
      if b.row == sep_row + 1 and b.col <= a.col + a.w - 1 and b.col + b.w - 1 >= a.col then
        local y = sep_row - 1
        local c0, c1 = a.col - 1, a.col + a.w - 2
        local lx = (c0 == 0) and rail_width or c0
        pls[#pls + 1] = { name = channel_name("left", 1), stem = main_stem, x = lx, y = y, w = 1 + capcols, h = 1 }
        pls[#pls + 1] = { name = channel_name("right", 0), stem = main_stem, x = c1 - capcols + 1, y = y, w = capcols, h = 1 }
        break
      end
    end
  end

  -- Vertical splits (side-by-side windows). The tabline (top) and global statusline
  -- (bottom) are each a SINGLE bar across the whole width; the window separator lives
  -- only in the window rows, not the frame rows. So we break each frame into per-pane
  -- pieces with image overlays: a pane that has another pane to its LEFT gets its own
  -- top-left / bottom-left elbow curving into ITS gutter, and the pane to its left has
  -- its bar terminated with a rounded right cap + 1-col black gap (`cap-r-gap`) so the
  -- break reads instead of the old T-junction. The rightmost pane's bar rounds off at
  -- the screen edge with a plain right cap (`hcap-r`).
  local top_row = math.huge
  for _, a in ipairs(infos) do if a.row < top_row then top_row = a.row end end

  -- Right cap for a pane's own far-right end (rounds off at `last0`, its last column).
  local function far_right_cap(a, y)
    local last0 = a.col + a.w - 2
    return { name = channel_name("right", 0), stem = main_stem, x = last0 - capcols + 1, y = y, w = capcols, h = 1 }
  end
  -- Cap + gap terminating the pane to the LEFT of `a`: a's elbow sits on the window
  -- separator at a.col-2, so the cap tip lands on that pane's last column (a.col-4)
  -- and the 1-col black gap over a.col-3, ending just left of the elbow.
  local function left_cap_gap(a, y)
    return { name = channel_name("right", 1), stem = main_stem, x = a.col - 3 - capcols, y = y, w = capcols + 1, h = 1 }
  end
  -- Top-left elbow (or a plain left cap for a gutterless pane) at pane `a`'s left edge.
  -- A right pane sits against a 1-col window separator that is ALSO periwinkle, so the
  -- separator + gutter read as one rail; widen the stem by that column and place the
  -- elbow on the separator (a.col-2) so it curves into the whole rail instead of
  -- landing one cell to the right of it.
  local function pane_corner(a, orient, y)
    if a.stem == 0 then
      return { name = channel_name("left", 0), stem = main_stem, x = a.col - 2, y = y, w = capcols, h = 1 }
    end
    local stem = a.stem + 1
    return { name = corner_name(stem, orient), stem = stem, x = a.col - 2, y = y, w = stem + 2, h = H }
  end

  local function frame_panes(is_row, y)
    local wins = {}
    for _, a in ipairs(infos) do if is_row(a) then wins[#wins + 1] = a end end
    table.sort(wins, function(x, z) return x.col < z.col end)
    local capped = false
    for _, a in ipairs(wins) do
      if a.col > 1 then
        pls[#pls + 1] = pane_corner(a, (y == top_row - 2) and "top" or "bottom", y)
        pls[#pls + 1] = left_cap_gap(a, y)
      end
    end
    if #wins > 0 and wins[#wins].col > 1 then
      pls[#pls + 1] = far_right_cap(wins[#wins], y)
      capped = true
    end
    return capped
  end

  -- TOP frame: elbows are 2 rows tall (bar + stem) so their bar sits on top_row-2.
  -- Skip when there is no tabline bar; an elbow with nothing extending horizontally
  -- from it is a broken fillet.
  if tabline_visible then
    frame_panes(function(a) return a.row == top_row end, top_row - 2)
  end

  -- BOTTOM frame: only with a global statusline. Elbows curve up from each pane's
  -- gutter into the statusline row; caps sit on the statusline row itself.
  state.right_pad = 0
  if vim.o.laststatus == 3 then
    local sl_row = vim.o.lines - vim.o.cmdheight - 1
    local bottom = -1
    for _, a in ipairs(infos) do local b = a.row + a.h - 1; if b > bottom then bottom = b end end
    -- pane elbows land at sl_row-1 (bar+stem reaches the statusline); caps at sl_row.
    local wins = {}
    for _, a in ipairs(infos) do if a.row + a.h - 1 == bottom then wins[#wins + 1] = a end end
    table.sort(wins, function(x, z) return x.col < z.col end)
    for _, a in ipairs(wins) do
      if a.col > 1 and sl_row - 1 >= 0 then
        pls[#pls + 1] = pane_corner(a, "bottom", (a.stem == 0) and sl_row or (sl_row - 1))
        pls[#pls + 1] = left_cap_gap(a, sl_row)
      end
    end
    if #wins > 0 and wins[#wins].col > 1 then
      pls[#pls + 1] = far_right_cap(wins[#wins], sl_row)
      state.right_pad = capcols -- statusline reserves this so its far-right cap clears the position text
    end
  end
  return pls
end

-- ---------------------------------------------------------------------------
-- rendering (delivery via image.nvim)
-- ---------------------------------------------------------------------------
local function clear_all()
  for _, img in pairs(state.imgs) do
    pcall(function() img:clear() end)
  end
  state.imgs = {}
end

-- Stable key for a placement: asset name encodes shape/dims/color; x,y is screen pos.
local function placement_key(pl) return pl.name .. "@" .. pl.x .. "," .. pl.y end

-- Windowless, absolutely-positioned images. With no `window`/`buffer`, image.nvim's
-- renderer places at absolute screen (geometry.x, geometry.y) and skips the float
-- offset / per-window clamps. state.imgs is keyed by placement_key so we only
-- create/render images that are new or changed; stale keys are cleared in place.
local function render_all(pls)
  if not ok_image then
    vim.notify("lcars.chrome: image.nvim not available", vim.log.levels.ERROR)
    return
  end

  local desired = {}
  for _, pl in ipairs(pls) do desired[placement_key(pl)] = pl end

  -- Clear placements no longer needed.
  for key, img in pairs(state.imgs) do
    if not desired[key] then
      pcall(function() img:clear() end)
      state.imgs[key] = nil
    end
  end

  -- Create and render only new placements.
  for key, pl in pairs(desired) do
    if not state.imgs[key] then
      local img = image.from_file(asset_path(pl.name, pl.stem), {
        x = pl.x, y = pl.y, width = pl.w, height = pl.h,
      })
      if img then
        img.ignore_global_max_size = true
        img:render()
        state.imgs[key] = img
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- lifecycle
-- ---------------------------------------------------------------------------
function M.active()
  return M.enabled and M.ready and state.main_W ~= nil
end

-- Column span of the top-left window's corner, so lcars.tabline blacks it out and
-- starts the first pill past it.
function M.width()
  return state.main_W
end

-- Columns the statusline must reserve on its RIGHT so a vertical-split's far-right
-- rounded cap doesn't overlay the position text. 0 when there's no such cap.
function M.right_pad()
  return state.right_pad or 0
end

function M.refresh()
  if not M.enabled then return end
  local cw, ch = cell_px()
  if cw ~= state.cw or ch ~= state.ch then state.gen = {} end -- cell size changed
  state.cw, state.ch = cw, ch
  local pls = compute_placements()
  local widths = {}
  for _, pl in ipairs(pls) do widths[pl.stem] = true end
  ensure_assets(widths, function()
    M.ready = true
    render_all(pls)
    vim.cmd("redrawtabline | redrawstatus")
  end)
end

-- Debounce layout churn (splits/resizes fire many events) so we regenerate/redraw once.
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
  M.refresh()
end

function M.disable()
  M.enabled = false
  M.ready = false
  clear_all()
  vim.cmd("redrawtabline | redrawstatus")
end

function M.toggle()
  if M.enabled then M.disable() else M.enable() end
end

vim.api.nvim_create_user_command("LcarsCorner", function() M.toggle() end,
  { desc = "Toggle the LCARS corner elbows" })

-- Enabled by default. Wait for VimEnter so the terminal is attached and image.nvim
-- has finished setup; defer once more so the first layout has settled before we read
-- cell size / window geometry. `:LcarsCorner` still toggles it off.
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    vim.schedule(function() M.enable() end)
  end,
})

-- BufWinEnter/WinEnter catch a window switching to a gutterless buffer (e.g. netrw),
-- which changes elbow-vs-cap without firing a resize/layout event.
vim.api.nvim_create_autocmd(
  { "VimResized", "WinResized", "WinNew", "WinClosed", "TabEnter", "BufWinEnter", "WinEnter" },
  { callback = schedule_refresh }
)
vim.api.nvim_create_autocmd({ "OptionSet" }, {
  pattern = { "number", "numberwidth", "signcolumn" },
  callback = schedule_refresh,
})

return M
