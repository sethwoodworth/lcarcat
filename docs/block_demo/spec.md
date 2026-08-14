# Block Demo Visual Spec

Reference for screenshot regression of all block demo tabs (lcarcat-2m7.10).

Each section describes the **expected** geometry, what the agent **observes** from the current
grid-annotated screenshots, space for **user feedback**, and **fix instructions** derived from
that feedback. The goal is that an agent reading this file can self-correct without needing to
re-describe problems from scratch.

Grid screenshots live at `test/screenshots/block_demo/tab-N-<name>-grid.png`.  
Block implementations: `nvim/lua/lcars/block_demo.lua`, make_A–make_G (lines 215–481).

---

## Geometry constants (confirmed, all block types)

| Constant | Value | Notes |
|----------|-------|-------|
| ELBOW_W | 5 cols | left/right elbow image width |
| ELBOW_H | 3 rows | left/right elbow image height |
| CORNER_W | 2 cols | corner asset width (A2 only) |
| CORNER_H | 2 rows | corner asset height (A2 only) |
| STEM_COLS | 1 | stem width for elbow/swoop assets |
| bar_x0 | lp + ELBOW_W - 1 | 1-col overlap to close antialiasing seam |
| CAP_W | 2 | vcap width (right/left end caps) |
| bar_w | (lp + bw) - bar_x0 | bar highlight should reach full block width |

`lp` = left padding column of the block (first block typically lp=0).

---

## Tab A — A-left-stem-3row

**Screenshot:** `tab-1-A-grid.png`

### Expected

Three blocks, each with:
- **Header row 0** (h0): elbow-top-left image at cols lp..lp+4, periwinkle bar from bar_x0 to right vcap, right vcap image at rightmost 2 cols. No text on this row.
- **Header row 1** (h0+1): elbow-mid-left image at cols lp..lp+4, periwinkle bar same span.
- **Header row 2** (h0+2): elbow-bot-left image at cols lp..lp+4, periwinkle bar, chips (branch/cwd/env) on bar from bar_x0 rightward with black gap cells between chips.
- **Stem**: col lp, periwinkle (LcarsBlockStem), runs for all content/scrollback rows.
- **Content rows**: col lp = stem, col lp+1+ = black bg with output text.
- **Footer** (last row): full-width periwinkle bar, same span as header bars, with right vcap. No elbow — left end is the stem cell (periwinkle), bar starts at lp+1.
- **Inner fillet**: on row h0+2, cols lp+1 through lp+4 should show the elbow image's concave arc against black (image z-ordered above the bar highlight).

> Observations, open issues, and fix log: [docs/block_demo/tab-A-observations.md](tab-A-observations.md)

---

## Tab A2 — A2-left-stem-2row

**Screenshot:** `tab-2-A2-grid.png`

### Expected

Three blocks, each with:
- **Header row 0** (h0): corner-top-left image at cols lp..lp+1 (2 wide), periwinkle bar from ~lp+1 to right vcap, chips on bar.
- **Header row 1** (h0+1): corner-bot-left image at cols lp..lp+1, periwinkle bar same span. No chips on this row.
- **Stem**: col lp, periwinkle, runs for all content rows.
- **Content rows**: same as A.
- **Footer**: same as A.
- Corner assets are 90° joins (no curved fillet) — sharper corner than the elbow.

> Observations, open issues, and fix log: [docs/block_demo/tab-A2-observations.md](tab-A2-observations.md)

---

## Tab B — B-right-stem-3row

**Screenshot:** `tab-3-B-grid.png`

### Expected

Two blocks, each with:
- **Header row 0** (h0): periwinkle bar from left hcap (cols 0..1) to right side, elbow-top-right image at cols bw-ELBOW_W..bw-1 (rightmost 5 cols).
- **Header row 1** (h0+1): bar + elbow-mid-right image.
- **Header row 2** (h0+2): bar + elbow-bot-right image + chips on bar from the left.
- **Stem**: rightmost col (lp + bw - 1 = col ~180), periwinkle, runs down content rows.
- **Content rows**: text at left, stem at right edge.
- **Footer**: full-width bar with right hcap on left end, right end is stem cell.
- Left end cap: 2-cell-wide hcap (rounded left terminus) on rows 0-1; row 2 is chip row starting at col 0.

> Observations, open issues, and fix log: [docs/block_demo/tab-B-observations.md](tab-B-observations.md)

---

## Tab C — C-cmd-in-header

**Screenshot:** `tab-4-C-grid.png`

### Expected

Three blocks, each with:
- **Header row h0+2** (chips row): chips on far left, then a **black notch** (LcarsBlockCmd highlight) containing the command text, then periwinkle bar continues to right vcap. The black notch replaces the periwinkle bar in the cmd text column range.
- Rows h0 and h0+1: full-width periwinkle bar (same as A, no notch).
- **Left stem** (same as A): elbow-top-left, elbow-mid-left, elbow-bot-left.
- **Content rows**: like A. No special treatment.
- **Footer**: like A.

> Observations, open issues, and fix log: [docs/block_demo/tab-C-observations.md](tab-C-observations.md)

---

## Tab D — D-live-block

**Screenshot:** `tab-5-D-grid.png`

### Expected

Two blocks, each with:
- **Header** (3 rows): same as A (left elbow, bar, chips row).
- **Content rows**: output text with left stem.
- **No footer** — live/streaming block. The last content line has a cursor glyph (▌) at the end.
- The block visually "hangs open" — no bottom bar.

> Observations, open issues, and fix log: [docs/block_demo/tab-D-observations.md](tab-D-observations.md)

---

## Tab E — E-folded

**Screenshot:** `tab-6-E-grid.png`

### Expected

Three folded (collapsed) rows at top, then one expanded block:
- **Folded rows**: single row each. Left hcap at col 0 (small rounded left end, LcarsBlockFoldDim color), fold arrow ▶, command text, metadata (exit code, timing, line count), right hcap at far right. No stem, no bar height.
- **Expanded block**: normal 3-row header (left elbow + bar + chips row) + content rows + footer.
- Folded row color: `LcarsBlockFoldDim` — a dimmer/darker periwinkle-family color, distinct from the bright periwinkle of active bars.

> Observations, open issues, and fix log: [docs/block_demo/tab-E-observations.md](tab-E-observations.md)

---

## Tab F — F-bottom-prompt

**Screenshot:** `tab-7-F-grid.png`

### Expected

Two blocks, each with:
- **Scrollback output** above: several lines of previous command output.
- **3-row header at bottom** of the output section: rows h0, h0+1 are bar-only (no chips); row h0+2 is the chips row (with elbow image at left).
- **Input/cursor stub row** immediately below the chips row: a single black row with a cursor glyph (▌) at the prompt position. This is the active shell input line.
- No footer.

> Observations, open issues, and fix log: [docs/block_demo/tab-F-observations.md](tab-F-observations.md)

---

## Tab G — G-header-stem-prompt

**Screenshot:** `tab-8-G-grid.png`

### Expected

Two blocks, each with:
- **3-row header**: left elbow (h0..h0+2) + periwinkle bar + chips row at h0+2.
- **Cursor stub row** (h0+3): single row, black bg, cursor glyph (▌) at start of text area (col lp+1 or similar).
- No output, no footer. Just the header + immediate cursor.
- Block represents "waiting for first command" state — prompt freshly drawn, no output yet.

> Observations, open issues, and fix log: [docs/block_demo/tab-G-observations.md](tab-G-observations.md)

---

## Cross-cutting issues (affect multiple tabs)

These issues originate in shared helper functions and affect every block type that uses them.

| Issue | Affected tabs | Source location | Status |
|-------|--------------|-----------------|--------|
| Chip gap cols bleed periwinkle | A, A2, B, C, D, F, G | `chips_block()` | Open |
| Inner fillet not visible on stub row | A, A2, B, D, F, G | elbow image z-order / bar_x0 | Open |
| Right-end cap sharp corners (bar_w too short) | A, A2, B, C, D, F, G | `bar_w` calculation | Open |
| Stem col alignment with elbow image | A, A2, D, F, G | `STEM_W`/placement | Unconfirmed |
