# Tab B observations — B-right-stem-3row

> Expected geometry: [docs/block_demo/spec.md#tab-b--b-right-stem-3row](spec.md#tab-b--b-right-stem-3row)

## Observed (2026-08-17, fixed geometry)

Grid: 181 cols × 57 rows. LEFT_PAD=6, bw=171.

- **Block 1**: header rows 1–3. Content rows 4–15 (TREE1, 9 lines + blank separator). Footer rows 16–18.
- **Block 2**: header rows 20–22. Content rows 23–28 (TREE2, 7 lines). Footer rows 29–31.
- Right elbow image at cols 171–175 (ELBOW_W=5). Stem col is 176 (rx = lp + bw - 1 = 6 + 171 - 1 = 176).
- Left cap: 2-col vcap (`cap-round-left`) at cols 6–7 on bar rows. No bar highlight covers these cols — bar starts at col 8 (lp + CAP_W).
- Bar spans cols 8–170 on header/footer bar rows. Chips on h0+1 starting at col 10 (lp + CAP_W + 2).
- Stem (col 176) is present on every content row and on the stub rows (h0+2, f0).
- Content text left-aligned from col 6, padded with spaces to fill to col 175, stem space at col 176.

## Bugs fixed (2026-08-17)

### 1 — Stem highlight offset (multibyte chars)
`stem_right_rows` was using `hl()` (byte column) to place the stem highlight. Tree content
lines contain multibyte box-drawing chars (`├` `─` `│` `└` = 3 bytes, 1 display col each),
so the byte offset of the trailing stem cell differed per row, landing 2–8 cols left of `rx`.

**Fix:** switched `stem_right_rows` to `virt_text_win_col = x - GUTTER_W` (display column),
which is immune to multibyte byte-offset drift.

Also fixed content row padding: `#l` (byte count) → `vim.fn.strdisplaywidth(l)` so the
trailing stem space lands at the correct display column.

### 2 — Two separate 1×1 hcaps instead of one 2×2 vcap
make_B was placing four `hcap-round-left` 1×1-cell images (two per bar section). The left
end cap is supposed to be a single 2-row arc, same asset type as make_A's right cap.

**Fix:** replaced four `hcap(..."left"...)` specs with two `vcap(..."left"...)` specs
(`cap-round-left-9999ff-2x2cells`), placed at `dy=h0` and `dy=f0+1`.

### 3 — Bar highlight visible behind left cap
`bar_x0 = lp + HCAP_W` (1 col) left the bar extmark covering the second col of the vcap,
making the transparent arc corners show purple instead of black.

**Fix:** `bar_x0 = lp + CAP_W` (2 cols), matching the pattern make_A uses for its right vcap.
Also updated `bar_w = bw - CAP_W - ELBOW_W` accordingly.

## User feedback

Geometry confirmed correct by user on 2026-08-17.

## Fix instructions

All fixes applied in `nvim/lua/lcars/block_demo.lua`. See bugs section above.
