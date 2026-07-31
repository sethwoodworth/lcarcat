# Asset Pipeline

How LCARS PNG assets are generated, named, cached, and regenerated at runtime.

---

## gen_swoops.py

`generate/gen_swoops.py` (deployed to `~/.config/kitty/lcars/gen_swoops.py`) generates all LCARS curve images using Pillow. Run via:

```bash
uv run --with pillow generate/gen_swoops.py [options]
```

### Shape types produced

| Shape | Description |
|-------|-------------|
| `swoop` | Legacy wide swoop — the full bar + elbow baked into one PNG (kept for backward compatibility) |
| `elbow` | Small left elbow cap: rounded outer corner + inner fillet + 1-row stem stub. The bar fill between elbow and cap is drawn as terminal cells. Left-facing and right-facing (mirrored) variants. |
| `cap` | Right half-round end cap for a vertical bar (2 rows). Left-facing mirror also generated. |
| `corner` | Short-bar elbow for nvim chrome: 1 bar row (tabline height) + 1 stem row, with `--corner-bg` baked black behind the outer curve. Width = `stem + 2` cols. |
| `hcap` | 1-row end cap for horizontal channel separators. Four variants: left/gap1 (off the left rail), right/gap0 (far-right terminus), left/gap0 (gutterless edge), right/gap1 (before a vsplit elbow). |

### Key flags

```
--color HEX      bar color hex (default ff9900)
--cellw PX       cell width  in device px (default 19) — MUST match kitty's CSI 16t reply
--cellh PX       cell height in device px (default 38) — MUST match kitty's CSI 16t reply
--cols N         total columns for legacy swoop (default 48)
--elbow-cols N   width of the small elbow cap (default 5)
--stem-rows N    rows the stem descends below the 2-row bar (default 1)
--bar-rows N     bar height for nvim corner elbows (default 2; nvim uses 1)
--stem-cols N    gutter width for nvim corner elbows (default 1; nvim passes textoff)
--corner-bg HEX  bake opaque fill behind the outer curve (use 000000 for nvim corners)
--outdir DIR     output directory
```

---

## Filename format (`asset_name()`)

Every PNG is named for the inputs that change its rendered shape, so distinct variants coexist instead of overwriting one fixed name:

```
{kind}-{orient}-{facing}-{color}[-background{hex}]-{cols}x{rows}cells-{cellw}x{cellh}pixels[-gap{n}].png
```

Examples:
```
elbow-top-left-9999ff-5x3cells-19x38pixels.png
cap-round-right-9999ff-2x2cells-19x38pixels.png
corner-top-left-9999ff-background000000-3x2cells-19x38pixels.png
hcap-round-left-9999ff-background000000-1x1cells-19x38pixels-gap1.png
```

**This format is a contract shared by three places:**
1. `generate/gen_swoops.py` — writes the files with this name
2. `zsh/prompt_lcars.zsh` (`_lcars_set_asset_paths`) — builds expected filenames for the prompt
3. `nvim/lua/lcars/chrome.lua` (`asset_name()`) — Lua mirror of the Python function

If you change the format in one place, change it in all three.

---

## The `--cellw`/`--cellh` contract

`--cellw` and `--cellh` **MUST** match kitty's actual `cell.width × cell.height` reported by CSI 16t (device pixels on HiDPI). Any mismatch causes kitty to aspect-fit the PNG into the cell box and center on the constraining axis, producing a 1–2 device-pixel inset between the image and the plain background cell at the same column.

Default values (19×38) are correct for font_size 18 Fantasque Sans Mono. They change with font size, font face, or display DPI. Do not hard-code a single cell-size filename anywhere.

See `docs/kitty-graphics.md` for the full aspect-fit math and why this matters.

---

## Runtime cell-probe and on-demand regen (zsh)

The zsh prompt probes kitty's actual cell dimensions at enable time and after every `SIGWINCH` (font zoom, display change, split resize). Key functions in `zsh/prompt_lcars.zsh`:

**`_lcars_probe_cell_size`** — sends CSI 16t, reads the reply, updates `_LCARS_CW`/`_LCARS_CH`, rebuilds filename constants via `_lcars_set_asset_paths`, clears `_LCARS_IMAGES_SENT` if dims changed.

**`_lcars_set_asset_paths`** — rebuilds `_LCARS_ELBOW_LEFT`, `_LCARS_ELBOW_RIGHT`, `_LCARS_CAP_LEFT`, `_LCARS_CAP_RIGHT` from the current `_LCARS_CW`/`_LCARS_CH` and color.

**`_lcars_ensure_assets`** — checks if the four prompt-used PNGs exist for the current dims. If any are missing, invokes:

```bash
uv run --with pillow $_LCARS_GEN_PY \
  --color "$_LCARS_COLOR" --outdir "$_LCARS_DIR" \
  --cellw "$_LCARS_CW" --cellh "$_LCARS_CH"
```

This is cheap when assets already exist. It only runs `gen_swoops.py` on a cache miss.

---

## Runtime regen in nvim chrome

`nvim/lua/lcars/chrome.lua` does the same via `image.nvim`'s `term.get_size()`:

```lua
local sz = require('image.utils.term').get_size()
local cw = math.ceil(sz.cell_width)
local ch = math.ceil(sz.cell_height)
```

Assets are cached per `(cellw, cellh, gutter_width)` in `stdpath('cache')/lcars/<cw>x<ch>-<stem>/`. A cell-size change invalidates `state.gen` (the generated-widths set), triggering a fresh regen.

---

## Supersampling

`gen_swoops.py` draws at 4x supersample (`SS = 4`) then downscales with `Image.LANCZOS` to the final pixel dimensions. This makes the outer corner and inner fillet smooth despite being small shapes. The supersample factor cancels out of the `round_cap_cols` formula, so the declared column width always matches the image actually drawn.

---

## Baked negative space (`--corner-bg`)

For nvim corner elbows and hcaps, pass `--corner-bg 000000`. This bakes an opaque black rectangle into the outer-curve sliver (the transparent area above/left of the outer arc). The inner fillet and buffer side stay transparent.

This lets the elbow show its curved edge over anything — periwinkle window separators, other windows' cells — that we can't paint via highlight groups. Without baked negative space, the transparent corner reveals whatever is behind it (often periwinkle, which blends the curve away).

---

## Verification after (re)generating

Before deploying a new asset set:

```bash
sips -g pixelWidth -g pixelHeight path/to/elbow.png
```

Verify that `pixelWidth == cols * cellw` and `pixelHeight == rows * cellh` exactly. A wrong-sized asset is the classic regression.
