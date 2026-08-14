# Tab A observations — A-left-stem-3row

> Expected geometry: [docs/block_demo/spec.md#tab-a--a-left-stem-3row](spec.md#tab-a--a-left-stem-3row)

## Observed (2026-08-13, corrected grid --term-top 0)

Grid: 181 cols × 57 rows. Kitty tab bar occupies row 0. nvim content starts at row 1.

- **Block 1**: header rows 1–3 (h0=1, h0+1=2, h0+2=3 chips row). Content rows 4–16. Footer rows 17–18. Gap rows 19.
- **Block 2**: header rows 20–22. Content rows 23–31. Footer rows 32–33. Gap rows 34–35.
- **Block 3**: header rows 36–38. Content rows 39–44. Footer rows 45–46.
- 3 periwinkle header rows per block clearly visible and aligned with grid.
- Elbow image at cols 0–4 (ELBOW_W=5 confirmed). Grid lines show the elbow occupies exactly 5 cols.
- Stem col 0 is periwinkle through all content rows; the grid confirms a single-cell-wide periwinkle strip at col 0.
- Bar: starts at col 4 (bar_x0 = lp+ELBOW_W−1 = 4 confirmed), spans to right.
- Chips on h0+2: `main` (block 1), `feat/auth ~/code/myproject` (block 2), `main /etc` (block 3). Gap cells between chips — **cannot confirm at this scale**; use `get_cell_grid.py --dump-grid` to check col colors in the gap.
- Right vcap: bar terminates at the right edge with a rounded 2-cell cap. Visually present; sharp-corner issue from open issues cannot be confirmed/denied from screenshot scale.
- Inner fillet (cols 1–4 on h0+2, concave arc against black): **not discernible at screenshot scale**.
- Footer bars present on all 3 blocks, right vcap present.

## Known open issues (from bead lcarcat-2m7.10, as of 2026-08-12)

1. **Chip gap cols bleed** — gaps between chips should be black but LcarsBlockBar highlight bleeds through making them periwinkle. Fix: in `chips_block()`, place `{ " ", "LcarsBlockBg" }` virt_text on both r_top and r_text for each gap col.
2. **Inner fillet not visible** — elbow arc on h0+2 at cols lp+1..lp+4 not showing. Possible cause: bar highlight at bar_x0=lp+4 extends into fillet area, or image z-order/placement offset.
3. **Right-end caps sharp corners** — bar_w stops short of vcap; transparent corner pixels on vcap show wrong color. Original suggested fix (`bar_w = (lp + bw) - bar_x0`) was wrong.
   - Resolved 2026-08-14 (lcarcat-2m7.10.1): correct formula is `bar_w = cap_x - bar_x0`. The bar extmark at HL_PRI=200 renders above the image in nvim+image.nvim+kitty; any cap cell it covers becomes a solid rectangle and the arc is lost. Leaving both cap cells with the default LcarsBlockBg (black) lets the vcap PNG render intact — 2-row-tall periwinkle semicircle with transparent outer corners falling through to terminal void. The "sharp corner" concern from the original note does not materialize with this asset: the vcap's inner (flat) edge is fully opaque periwinkle, so it butts against the bar cleanly with no anti-aliased gap at the col boundary.
   - Trap for future work: `~/.config/nvim/lua/lcars/block_demo.lua` is a COPY of the repo file, not a symlink. Every edit needs `./deploy.sh` before the running nvim reflects it. Verifications done against an undeployed edit will look identical to the pre-fix state.
4. **Stem alignment unconfirmed** — whether col lp (stem cell) visually aligns with left edge of elbow image needs grid overlay verification.

## User feedback

_(to be filled in)_

## Fix instructions

_(to be filled in after user feedback)_
