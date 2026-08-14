# Tab E observations — E-folded

> Expected geometry: [docs/block_demo/spec.md#tab-e--e-folded](spec.md#tab-e--e-folded)

## Observed (2026-08-13, corrected grid)

Grid: 181 cols × 57 rows.

- **Folded rows**: rows 1, 3, 5 (single rows, one per folded block, separated by blank rows 2 and 4).
  - Row 1: `◀ ▶  git log --oneline -20  [✓ 0]  [0.4s]  [20 lines]  ▶`
  - Row 3: `◀ ▶  ping 8.8.8.8  [✓ 0]  [0.4s]  [47 lines]  ▶`
  - Row 5: `◀ ▶  tree ~/code/lcarcat  [✓ 0]  [0.4s]  [9 lines]  ▶`
  - Left end cap (◀ piece) at col 0. Right end cap (▶ piece) at col 180. Fold arrow ▶ and collapse arrow ◀ visible.
  - Background is very dark — nearly black. The LcarsBlockFoldDim color is either very subtle or these rows may be rendering as plain terminal default bg. **Needs `get_cell_grid.py --dump-grid` on row 1 to confirm actual bg color.**
- **Expanded block**: rows 7–9 header (`main ~/code AWS`), rows 10–19 content, rows 20–21 footer.
- One expanded block only (3 folded + 1 expanded), matching the 4-block E demo spec.

## Known open issues

- Folded row color/brightness: needs verification that LcarsBlockFoldDim is actually rendering vs. defaulting to black/terminal default.

## User feedback

_(to be filled in)_

## Fix instructions

_(to be filled in after user feedback)_
