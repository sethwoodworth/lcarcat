# Tab A2 observations — A2-left-stem-2row

> Expected geometry: [docs/block_demo/spec.md#tab-a2--a2-left-stem-2row](spec.md#tab-a2--a2-left-stem-2row)

## Observed (2026-08-13, corrected grid)

Grid: 181 cols × 57 rows.

- **Block 1**: header rows 1–2 (2-row confirmed). Content rows 3–14. Footer rows 15–16.
- **Block 2**: header rows 18–19. Content rows 20–28. Footer rows 29–30.
- **Block 3**: header rows 32–33. Content rows 34–38. Footer rows 39–40.
- Corner images at cols 0–1 (2 wide, CORNER_W=2 confirmed). The corner is a sharp 90° bracket shape — no curved fillet, matching spec.
- Chips appear on h0 (row 1), the top header row, with h0+1 being a plain bar row below. This is a **difference from Tab A** where chips are on the bottom row (h0+2). For A2 the 2-row corner means the chips/cmd are on the top row.
- Stem col 0 periwinkle through content rows.
- Footer bars and right vcap present.
- The third block (block 3) has only one chip (`main`, no cwd or env) — fits single-chip demo content.

## Known open issues

Same chip gap / right cap issues as Tab A (shared `chips_block()` and bar_w logic).

## User feedback

_(to be filled in)_

## Fix instructions

_(to be filled in after user feedback)_
