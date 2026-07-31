# nvim Chrome Engineering Notes

`nvim/lua/lcars/chrome.lua` — the hardest-won part of lcarcat. Draws LCARS frame elbows and caps with image.nvim (kitty backend). This document records the lessons that cost real debugging time.

---

## The outer-frame-only model

**No T/+ junctions** is LCARS design law. Interior windows make their gutters/edges cross the global tabline/statusline → T-junctions. The model is instead **outer frame only**:

- One **top-left elbow** at the editor's top-left window (the tabline bar curving down into the leftmost gutter = the left rail)
- One **bottom-left elbow** at the global statusline (the left rail curving up from the statusline)
- Interior split edges: **capped channels**, never per-window elbows

### Elbow vs cap: key on `textoff`, not filetype

An elbow needs a stem to curve into. A **gutterless** window (`textoff == 0` — netrw, `number` off, no gutter) has no stem, so its corner becomes a rounded **left cap** on the bar instead of an elbow. `textoff` is the gutter width from `getwininfo(win)[1].textoff`; keying on it generalizes to any future gutterless buffer type.

### Capped channel separators

Interior split separators are kept as flat periwinkle cells (`WinSeparator`). Only the ends are images: a left cap with a 1-col black gap (so the segment sits *off* the continuous left rail), and a right cap rounding the far end. This upholds the flat=cells rule while giving the separator LCARS termination points.

---

## The `+1` float trap — use windowless images

image.nvim's **floating-window** path computes:
```
screen_pos.row = window.rect.top + original_y + 1
```
That `+1` pushes a float anchored at editor row 0 down to row 1. A float at row 0 bails outright. **You cannot put an image on the tabline row via a float.**

**Use windowless images instead:**
```lua
image.from_file(path, { x = col, y = row, width = w, height = h })
-- no `window` or `buffer` field
```
The windowless path uses `absolute_x = geometry.x`, `absolute_y = geometry.y`, lands on the true screen cell (including row 0), and stays fixed as the buffer scrolls. Per-window `max_*_window_percentage` clamps are skipped automatically.

Also set `img.ignore_global_max_size = true` (a field on the image object, not a `from_file` option) or the global `max_width/height` clamp can shrink the image.

---

## Geometry APIs (0-indexed screen math)

All geometry is done in 0-indexed screen coordinates, but the nvim APIs are 1-indexed. The arithmetic:

| API | Returns | Notes |
|-----|---------|-------|
| `nvim_tabpage_list_wins(0)` | Windows on current tab | **Use this, not `nvim_list_wins()`** — `nvim_list_wins()` spans all tabpages; another tab's window can steal the top-left slot and mask the current tab's gutterless buffer |
| `win_screenpos(win)` | `[row, col]` 1-indexed | Top-left **content** cell of the window (gutter included). To place an elbow on the row above: `y = row - 2` (0-indexed) |
| `getwininfo(win)[1].textoff` | Integer | Gutter width (number + sign + fold). `0` = gutterless |
| `vim.o.lines - vim.o.cmdheight - 1` | Integer (0-indexed) | Global statusline row when `laststatus == 3` |

### `win_screenpos` example

A window at `win_screenpos` `[3, 1]` (1-indexed) has its content at screen row 2, col 0 (0-indexed). The tabline/separator row above it is at screen row 1 (0-indexed). An elbow `H=2` tall with its top on row 1 occupies rows 1 and 2 — the separator + the window's first content row. Correct.

### `WinSeparator` limitation

`WinSeparator` is a single uniform highlight — no per-cell control. You can't gap or cap it directly using highlight groups. Use small cap images (or a winbar) overlaid on the separator row instead.

---

## Transparency and baked negative space

- Transparent PNG areas reveal nvim's cells behind the image; opaque areas cover them.
- You can paint a black backdrop on cells you own (the tabline pad). You cannot paint the `WinSeparator` row or another pane's cells.
- **Bake the outer-curve negative space as opaque black into the PNG** (`gen_swoops.py --corner-bg 000000`). This makes the elbow show its curved edge over anything — periwinkle separators, other panes — that we can't control via highlight groups.
- Keep the inner fillet and buffer side of the PNG **transparent** so real content (gutter numbers, tab pills) shows through there.

---

## Asset naming and chrome.lua's Lua mirror

`chrome.lua` contains `asset_name()` — an exact Lua mirror of `gen_swoops.py`'s Python `asset_name()`. Both build the same descriptive filename from the same inputs. If you change the format in one, change it in the other.

Corner assets are keyed by `(cellw, cellh, gutter_width)` and cached in `stdpath('cache')/lcars/<cw>x<ch>-<stem>/`. Cell size changes invalidate the cache (`state.gen = {}`).

The corner is `stem + 2` cols wide (2 extra for the inner fillet). Anything sharing its row must offset by `chrome.width()` (= `stem + 2`), **not** the raw `textoff`. The tabline pad and the statusline `gutter_pad` both use `chrome.width()`.

---

## Debounced refresh

Splits fire many layout events simultaneously (WinResized, WinNew, WinClosed, TabEnter, etc.). Responding to each would regenerate/redraw several times. The refresh is debounced with an incrementing token + `vim.defer_fn`:

```lua
local refresh_token = 0
local function schedule_refresh()
  refresh_token = refresh_token + 1
  local mine = refresh_token
  vim.defer_fn(function()
    if mine == refresh_token and M.enabled then M.refresh() end
  end, 80)
end
```

Only the last scheduled refresh within 80ms fires. `redrawtabline` alone won't refresh the statusline pad; always call both `redrawtabline` and `redrawstatus`.

---

## Events subscribed

```lua
{ "VimResized", "WinResized", "WinNew", "WinClosed", "TabEnter",
  "BufWinEnter", "WinEnter" }   -- layout changes
{ "OptionSet", pattern = { "number", "numberwidth", "signcolumn" } }  -- gutter width changes
```

`BufWinEnter`/`WinEnter` catch a window switching to a gutterless buffer (e.g. netrw), which changes elbow-vs-cap without a resize.

---

## `tabline_visible` gate

A top-left elbow is only valid when a horizontal tabline bar is present to connect to. Without it, the elbow is a fillet mid-stem with no bar — a visual glitch. Gate all top elbows on:

```lua
local tabline_visible = vim.o.showtabline == 2
  or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)
```

---

## `chrome.width()` and `chrome.right_pad()`

Two exported values that other modules consume:

- `chrome.width()` — column span of the top-left corner (= `stem + 2`). The tabline blacks out this area and starts its first pill past it.
- `chrome.right_pad()` — columns the statusline must reserve on its right so a vertical-split's far-right rounded cap doesn't overlay the position text. 0 when there's no such cap.
