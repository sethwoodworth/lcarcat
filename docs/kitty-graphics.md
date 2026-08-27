# Kitty Graphics Protocol Reference

Technical reference for the LCARS chrome that uses the kitty graphics protocol — elbows, caps, and corners. Written after the s2v elbow-stem alignment fix (2026-07-30) and expanded from the image sizing contract in AGENTS.md.

---

## Z-order: images vs. terminal cells

Kitty renders placed images **above** terminal cells in the compositor:

1. nvim renders all cells (SGR background colors, highlight groups, extmark virt_text) to the terminal layer.
2. Kitty images are composited on top. Opaque image pixels cover the cell content; transparent pixels reveal the cell bg/fg beneath them.

There is no `z_index` parameter for windowless image.nvim placements. Render order is strictly:
**cells (including all extmarks and virt_text) → placed images.**

**Practical consequences for LCARS block frames:**

- To show the bar color through a transparent image corner or fillet, paint that cell with the
  bar highlight group — the image's transparent pixels will reveal it.
- To show black through transparent pixels, leave the cell at `Normal` / `LcarsBlockBg` (black bg).
- `virt_text` overlays and `hl_group` extmarks are both below the image layer. If an image is
  placed at a column, its opaque pixels win regardless of extmark priority.
- The inner fillet arc is transparent in the elbow PNG. If the cells behind the fillet area
  have no bar highlight, the fillet will look correct against a black background. If a bar
  highlight extends into the fillet columns, the periwinkle bar color bleeds through the
  partial-alpha fillet pixels — which may be intentional (it matches the bar color).

---

## The central rule: pixel dimensions must match exactly

When kitty renders a Unicode-placeholder (`U=1`) image, it **aspect-fits** the source PNG into the cell box `cols * cell.width × rows * cell.height`. If the two aspect ratios differ, kitty centers on the constraining axis and stores a sub-cell offset (`cell_x_offset` or `cell_y_offset`). The final layer position is:

```
r.left = screen_left + start_column * dx + dx * cell_x_offset / cell.width
```

This produced the s2v "elbow-stem misaligned by 1 pixel" bug: PNGs generated at 19×**40** pixels per cell didn't match kitty's actual 19×**38** `cell.height` at font_size 18 Fantasque Sans Mono. The centering produced a 1–2 device-pixel left inset between the image and the plain bg cell at the same column.

**The only fix: make PNG pixel dimensions exactly `cols * cell.width × rows * cell.height`.** There is no client-side escape-sequence nudge — the `X=` parameter is stored but then discarded when `grman_put_cell_image` rebuilds the aspect-fit math.

Source refs (kitty v0.47.2):
- `kitty/graphics.c:grman_put_cell_image` (~lines 888–999) — the aspect-fit math
- `kitty/graphics.c:grman_update_layers` (~lines 1245–1246) — final placement formula
- `kitty/graphics.c:handle_put_command` (~lines 1063–1139) — X= is stored, then discarded
- `kitty/parse-graphics-command.h` (~lines 30–50) — APC key list
- `docs/graphics-protocol.rst` (~lines 555–680) — Unicode-placeholder spec

---

## CSI 16t: querying cell pixel dimensions

Send `ESC[16t`. Reply format: `ESC[6;<height>;<width>t`.

Kitty answers in **device pixels** on HiDPI (same unit the graphics renderer uses internally). No scaling needed to feed the numbers back to `gen_swoops.py` or any image transmit.

### Reading the reply in zsh

```zsh
print -n -- $'\e[16t'
IFS= read -s -d 't' -t 0.5 reply 2>/dev/null
```

Critical flags:
- **`-s`** — suppresses TTY echo. Without it, kitty's escape reply is painted on-screen as visible garbage.
- **`-d 't'`** — reads up to and strips the terminating `t`.
- **`-t 0.5`** — fails fast on non-kitty terminals or when a stray CSI response has already been swallowed.
- **`-r` does not exist in zsh's `read` builtin.** Passing it makes zsh treat `r` as a variable name, blocking on stdin forever. Do not copy bash idioms verbatim.

### Parsing the reply

```zsh
if [[ $reply =~ $'\e\\[6;([0-9]+);([0-9]+)$' ]]; then
  new_h=$match[1]; new_w=$match[2]
fi
```

Reject anything that doesn't match — a mixed-in keystroke can poison the parse. Keep old dims rather than jump to garbage.

---

## Unicode placeholder protocol

Each image is transmitted once with a fixed id and a virtual placement (`U=1`) sized in cells (`c×r`). Placeholder cells hold `U+10EEEE` plus row/column combining diacritics (kitty's fixed table: `U+0305 U+030D U+030E U+0310 U+0312`). The image id rides the cell's foreground color (`\e[38;5;<id>m`), so ids must stay < 256.

### Transmission

The zsh prompt sends PNG **bytes** inline (`t=d`, base64 of the file contents) rather than a file path (`t=f`). Two reasons, both of them real bugs rather than theory:

**Synchronous.** kitty has all the data in one read and processes it before the next write arrives, so placeholder cells drawn immediately after are guaranteed to find the image registered. `t=f` is async — kitty opens the file on its own schedule and can miss the first placeholder draw.

**Race-free.** With `t=f`, kitty holds the file mmap'd and reads it whenever it likes. Rewrite that file underneath a live mapping and kitty faults past a truncated EOF and takes **SIGBUS** — which is exactly the 2026-08-26 crash (lcarcat-46w): `deploy.sh`'s in-place copy opened the destination `O_TRUNC`, leaving it zero bytes mid-copy, while a prompt was drawing. With `t=d` kitty never opens the file at all, so the hazard cannot arise on this path.

That does **not** retire the atomic-write fix in `deploy.sh` and `gen_swoops.py` (see [asset-pipeline.md](asset-pipeline.md)): nvim's image.nvim consumer is still handed *paths*, so it retains the same exposure and still depends on writers using temp-file + `rename(2)`.

```zsh
printf '\e_Ga=T,U=1,i=%d,f=100,t=d,c=%d,r=%d,q=2;%s\e\\' "$id" "$cols" "$rows" "$base64data"
```

**Chunking.** kitty caps a graphics escape at 4096 bytes of base64 payload. Larger images must be split: control data rides the *first* escape with `m=1`, continuations carry only `m=1`, and the final escape carries `m=0`.

```zsh
\e_Ga=T,U=1,i=1,f=100,t=d,c=5,r=3,q=2,m=1;<chunk>\e\    # first: control + m=1
\e_Gm=1;<chunk>\e\                                       # middle
\e_Gm=0;<chunk>\e\                                       # last
```

Current assets are ~1.8–2.6KB of base64 and never reach this path, but a large font means larger cells, larger PNGs, and eventually multi-chunk. `_lc_transmit` handles both cases.

> Historical note: the code sent `t=f` from the initial commit while this document and the function's own comment described `t=d` and its benefits. The prose was right about what we wanted; the code had never done it. Resolved 2026-08-27 by implementing `t=d`.

### Cursor-anchored vs windowless placement

**Cursor-anchored** (`a=T,C=1`): the image is placed at the current cursor position. This is what the zsh prompt uses for the split-swoop feature (disabled). Images placed this way are anchored to the screen cell at draw time — they don't reflow on pane resize, leaving "dangling elbows" in scrollback.

**Windowless** (image.nvim): `image.from_file(path, { x=, y=, width=, height= })` with no `window`/`buffer`. Takes the absolute-screen path, lands on the true screen cell (including row 0), and stays fixed as the buffer scrolls. This is what nvim chrome uses.

The zsh prompt now uses **Unicode placeholder cells** (not cursor-anchored), which live in the text stream and reflow with their bar on pane resize — fixing the dangling-elbow problem without the windowless image.nvim path.

### Raw Unicode placeholders inside nvim

Raw Unicode placeholder codepoints (`U+10EEEE`) **do not render inside nvim's own tabline/statusline strings**. Nvim controls those SGR/codepoints. Windowless image.nvim is the only way to put images on those rows.

**The image ID color cannot be carried by an nvim highlight group.** Kitty reads the image ID from `\e[38;5;<id>m` (256-color foreground). Nvim with `termguicolors=true` always emits `\e[38;2;r;g;b;m` (24-bit) for any `fg` set via `nvim_set_hl` — there is no way to force 256-color output from the highlight system. The only paths that work:

1. **Direct `io.write` at cursor position** — move the cursor to the target screen cell and write `\e[38;5;<id>m<PH><row-diacritic><col-diacritic>` via `io.write()`, bypassing nvim's buffer renderer entirely. This is what image.nvim's `write_placeholder()` (`lua/image/backends/kitty/helpers.lua`) does.

2. **Disable `termguicolors` for the placeholder window** — `vim.wo[win].termguicolors = false` before rendering placeholder rows forces nvim to emit 256-color SGR codes. The rest of the buffer (filler lines) can have termguicolors re-enabled via `winhighlight` overrides, but this is fragile.

**Neither option works reliably from nvim Lua.** nvim's post-command `update_screen()` repaints the buffer cells after any `:lua` command returns, overwriting any bytes written via `io.write`. `vim.defer_fn` defers past that repaint, but any subsequent nvim redraw (cursor move, window focus, etc.) overwrites the placeholders again. There is no stable hook point from Lua that fires after nvim's screen writes are complete and before kitty composites the image.

**The correct path for images in nvim buffers is `image.nvim from_file()` with `window+buffer` binding** — not unicode placeholders. image.nvim registers its own `WinScrolled` autocmd and uses `vim.fn.screenpos()` to recompute placement on every scroll. Unicode placeholders in nvim are an opt-in experiment (`kitty_method = "unicode-placeholders"`) with known limitations (no crop support) and are not the default path.

---

## Image id management

Fixed ids in the zsh prompt: 1 = elbow-left, 2 = elbow-right, 3 = cap-left, 4 = cap-right. Ids must stay < 256 (the foreground color channel carries the id).

In nvim chrome, each `from_file()` gets a fresh random id via image.nvim — one PNG placed in many windows is fine.

---

## `_LCARS_IMAGES_SENT` invalidation

When `TRAPWINCH` fires (font zoom, display change, split resize):

1. Re-probe via CSI 16t.
2. If dims changed: update `_LCARS_CW`/`_LCARS_CH`, rebuild filename constants (`_lcars_set_asset_paths`), clear `_LCARS_IMAGES_SENT` so `_lcars_transmit_images` retransmits at the new dims.
3. Call `_lcars_ensure_assets` (cheap when PNGs already exist; runs `uv run gen_swoops.py …` on miss).

The image is still cached in kitty under its id, but a wrong-dim PNG will stretch/inset in the new cell box, so retransmit is required on any dim change.

---

## Ancillary notes

- macOS `screencapture -l <window_id>` captures at 2x on Retina — 1 logical point = 2 device pixels in output PNGs.
- Older comments describing cell dimensions as "logical px" were wrong; kitty reports device px directly via CSI 16t on HiDPI displays.
- kitty renders aspect-fit images with a GPU linear sampler. The sampler doesn't introduce edge gaps — only the geometry (dim mismatch) does.
