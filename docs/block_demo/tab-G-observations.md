# Tab G observations — G-header-stem-prompt

> Expected geometry: [docs/block_demo/spec.md#tab-g--g-header-stem-prompt](spec.md#tab-g--g-header-stem-prompt)

## Observed (2026-08-13, corrected grid)

Grid: 181 cols × 57 rows.

- **Block 1**: header rows 1–3. Stub row 4. Block ends at row 4.
- **Block 2**: header rows 6–8. Stub row 9. Block ends at row 9.
- 3-row header confirmed per block. Chips row (h0+2) visible with `main ~/code AWS`.
- Left elbow at cols 0–4. Bar spans to right vcap.
- Stub row (rows 4 and 9): single very thin row immediately below the chips row. No cursor glyph visible at screenshot scale.
- No output, no footer — correct.
- The two blocks are very compact (4 rows each including stub), cleanly separated by a single blank row (row 5).
- **Issue noted**: only 2 periwinkle rows visible per header (not 3). Rows 1 and 3 are periwinkle; row 2 appears to be a black/content row between them. This may indicate the middle bar row (h0+1) is missing or black instead of periwinkle. **Needs `get_cell_grid.py --scan-bg periwinkle` on this tab to confirm row count.**

## Known open issues

Same as Tab A for header geometry. No G-specific issues identified.

## User feedback

_(to be filled in)_

## Fix instructions

_(to be filled in after user feedback)_
