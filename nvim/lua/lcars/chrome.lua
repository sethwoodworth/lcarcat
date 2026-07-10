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
-- Opt-in: `:LcarsCorner` toggles it. Off by default; the base theme is untouched.

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
-- stale-sized PNG. gen_swoops writes fixed PNG names (corner-tl, corner-bl, hcap-l,
-- hcap-r) into it; the channel caps are gutter-independent but land in every dir.
local function asset_dir(stem) return cache_dir .. "/" .. state.cw .. "x" .. state.ch .. "-" .. stem end
local function asset_path(name, stem) return asset_dir(stem) .. "/" .. name .. ".png" end

local function regenerate(stem, cb)
  local dir = asset_dir(stem)
  vim.fn.mkdir(dir, "p")
  if vim.fn.filereadable(gen_py) == 0 then
    vim.notify("lcars.chrome: generator not found at " .. gen_py, vim.log.levels.ERROR)
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
        if code == 0 and vim.fn.filereadable(asset_path("corner-tl", stem)) == 1 then
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

  if main_stem == 0 then -- gutterless top-left window -> cap the tabline bar
    state.main_W = capcols
    pls[#pls + 1] = { name = "cap-left1", stem = main_stem, x = 0, y = main_row - 2, w = capcols, h = 1 }
  else
    state.main_W = main_stem + 2
    pls[#pls + 1] = { name = "corner-tl", stem = main_stem, x = 0, y = main_row - 2, w = main_stem + 2, h = H }
  end
  local rail_width = main_stem -- leftmost gutter; kept continuous through separators

  if vim.o.laststatus == 3 then
    local sl_row = vim.o.lines - vim.o.cmdheight - 1 -- 0-indexed statusline row
    if bl_stem == 0 then -- gutterless bottom-left window -> cap the statusline bar
      pls[#pls + 1] = { name = "cap-left1", stem = bl_stem, x = 0, y = sl_row, w = capcols, h = 1 }
    elseif sl_row - 1 >= 0 then
      pls[#pls + 1] = { name = "corner-bl", stem = bl_stem, x = 0, y = sl_row - 1, w = bl_stem + 2, h = H }
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
        pls[#pls + 1] = { name = "hcap-l", stem = main_stem, x = lx, y = y, w = 1 + capcols, h = 1 }
        pls[#pls + 1] = { name = "hcap-r", stem = main_stem, x = c1 - capcols + 1, y = y, w = capcols, h = 1 }
        break
      end
    end
  end
  return pls
end

-- ---------------------------------------------------------------------------
-- rendering (delivery via image.nvim)
-- ---------------------------------------------------------------------------
local function clear_all()
  for _, img in ipairs(state.imgs) do
    pcall(function() img:clear() end)
  end
  state.imgs = {}
end

-- Windowless, absolutely-positioned images. With no `window`/`buffer`, image.nvim's
-- renderer places at absolute screen (geometry.x, geometry.y) and skips the float
-- offset / per-window clamps. Each from_file gets a fresh random id, so reusing one
-- PNG across several windows does not collide.
local function render_all(pls)
  clear_all()
  if not ok_image then
    vim.notify("lcars.chrome: image.nvim not available", vim.log.levels.ERROR)
    return
  end
  for _, pl in ipairs(pls) do
    local img = image.from_file(asset_path(pl.name, pl.stem), {
      x = pl.x, y = pl.y, width = pl.w, height = pl.h,
    })
    if img then
      img.ignore_global_max_size = true
      img:render()
      state.imgs[#state.imgs + 1] = img
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
  { desc = "Toggle the experimental LCARS corner elbows" })

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
