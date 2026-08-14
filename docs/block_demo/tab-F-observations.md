# Tab F observations — F-bottom-prompt

> Expected geometry: [docs/block_demo/spec.md#tab-f--f-bottom-prompt](spec.md#tab-f--f-bottom-prompt)

## Observed (2026-08-13, corrected grid)

Grid: 181 cols × 57 rows.

- **Block 1**: scrollback rows 1–3 (`Previous output line 1/2/3`). Header rows 4–6. Stub row 7. Block ends.
- **Block 2**: scrollback rows 9–11. Header rows 12–14. Stub row 15. Block ends.
- 3-row header confirmed per block (rows 4–6, 12–14). Top two rows are full bar, row 6/14 is chips row with `main ~/code AWS`.
- Left elbow at cols 0–4. Bar spans cols 4–180.
- **Stub row** (rows 7 and 15): single black row immediately below chips row. Barely distinguishable from the black background — no cursor glyph visible at this scale.
- No footer — correct for bottom-pinned prompt.
- Note: only 1 bar row visible on rows 4 and 12 (should be 2 plain bar rows before the chips row). **May be 2-row header only, or the first bar row is being cropped.**

## Known open issues

- Same header geometry issues as Tab A.
- Whether the stub row has correct cursor glyph placement needs close inspection.

## User feedback

_(to be filled in)_

## Fix instructions

_(to be filled in after user feedback)_
