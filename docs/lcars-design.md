# LCARS Design Reference

Star Trek's Library Computer Access/Retrieval System UI for the terminal. This document covers terminology, rendering philosophy, visual rules, and the glyph kit.

---

## Rendering philosophy

LCARS chrome is split into two kinds of pieces:

- **Flat parts are terminal cells** — `\e[48;2;R;G;Bm` background-colored spaces. They cost nothing, flex to `$COLUMNS`, and scroll natively. This is the bulk of every panel.
- **Curved parts are images** — small PNGs placed with the kitty graphics protocol, used only where a corner or cap actually curves.

**Use the minimum viable image.** PNGs are drawn *only* where a shape actually curves — the elbow corner and the right round cap. Everything else is cells. When adding a visual element, ask "can this be a background cell?" first. It almost always can.

---

## Terminology

```
  swoop                       chip (B)      chip (B)          fill        chip (A)    cap
 ┌──╮ ┌──────────────────────────────────────────────────────────────────────────────╮
 │  │ │ ███ venv ███ py 3.11 ███ ······· orange bar ······· ███▏black▕ ~/PROJ ▕███    ◗│
 │  │ └──────────────────────────────────────────────────────────────────────────────╯
 │  │   ← stem                                                        notch ↑
 │  •  nested content (input line, timestamps) sits beside the stem
```

| Term | What it is | Rendered as |
|------|-----------|-------------|
| bar | Horizontal accent band, 2 rows tall | Terminal cells |
| swoop | Left elbow + stem | PNG (elbow) + cell (stem) |
| elbow | Rounded outer corner + inner fillet, 3 rows (bar 2 + stem 1) | PNG |
| stem | 1-cell-wide vertical drop from the elbow | Terminal cells |
| cap | Right half-round end cap | PNG |
| pill | Segment capped on both ends (not yet implemented in zsh) | Cells + 2 caps |
| chip | Labeled segment in a bar | Terminal cells |
| notch | Black inset holding accent text (Style-A chip) | Terminal cells |

### bar
Full-width, dynamic to `$COLUMNS`; 2 rows tall by convention. The bar is the canvas that chips, notches, and caps sit on.

### swoop / elbow
The L-corner where a horizontal bar turns into a vertical stem. Two variants: **top swoop** (bar on top, stem descends) and **bottom swoop** (vertical mirror).

The **elbow** image is 3 rows tall (bar 2 + stem 1) and contains the rounded outer corner plus the inner concave fillet. The stem continues below as a background cell (via `PROMPT2`).

### cap
The right half-round end of a bar — punctuation, like a period. Only at bar termination points, never mid-bar. The prompt places 2 bar-color cells before the cap so the round end reads as a continuation of the bar.

### chip (Style A vs Style B)

**Style A — notch chip**: label in the bar's own accent color, cut into a black notch. Only at the far right of a bar. Introduced by `[1-col black rule][1-col accent][black notch: words]`.

**Style B — color chip**: solid colored segment (different accent than the bar) with dark/black label. Chips of different accents sit side by side separated by combed 1-col black gaps.

Text alignment: right-aligned horizontally; generally on the bottom row of the 2-row bar.

---

## Structural design rules

### 1. Flat vector only
No gradients, no emboss, no drop shadows. Shapes are solid-fill geometric on black.

### 2. Thick-to-thin rule
A frame always changes thickness at each turn. Never the same thickness on two consecutive turns. Bars meeting stems must visibly change width at the elbow. Two panels sharing a split have independent parallel stems — they never merge into one spine.

### 3. The swoop is sacred
The LCARS elbow shape is identity-defining. Do not distort, flatten, or deform it. Large-radius outer corner; perpendicular inner corner.

### 4. No T/+ junctions
**This is the design law.** Bars meet stems only via 2-sided elbows. Free ends get caps. T (3-way) and + (4-way) junctions do not exist in LCARS. Where a stem would cross a bar, one must terminate in a cap or turn in an elbow.

Consequence: "an elbow at every window corner" is wrong for nvim — interior windows make their gutters cross the global tabline/statusline → T-junctions. Use the outer-frame-only model instead. See `docs/nvim-chrome.md`.

### 5. Caps are termination points
A rounded cap marks the end of a bar — punctuation, like a period. Caps belong only at bar termination points, never mid-bar.

### 6. Two spacing constants
All elements align to one of two grid values: Main Frame Spacing and Frame Spacing. Breaking the grid produces the "disjointed amateur LCARS" look.

### 7. Three font sizes only
Main Title, Sub Header, Normal Data. No mixing beyond these three. All chrome text is ALL-CAPS (this is flexible on implementation).

### 8. Color discipline
Maximum ~5 colors, each semantically assigned. Every color means something specific — no decorative variation. See `docs/palette.md`.

### 9. Input vs display panel semantics
- **Input panels** (user types): orange structural color
- **Display panels** (read-only, status, output): periwinkle structural color
- Active split border: orange; inactive: muted periwinkle

---

## Glyph kit

LCARS vocabulary is solid geometric shapes — filled triangles, blocks and bars, dots — not icon-font glyphs. Avoid `✘ ✓ ⚠ ⏱ →`. Use chip colors as the primary signal; glyphs sparingly.

| Purpose | Candidates |
|---------|-----------|
| Directional / flow | `▸ ▹ ▶ ◀ ◂ ▲ ▼` |
| Status dots | `● ○ ◉ ◍` |
| Blocks / bars / separators | `■ ▪ ▮ █ ▌ ▐ ▬ ▭` |
| Chevrons (lighter motion) | `» « › ‹` |
| Diamonds (accent points) | `◆ ◇ ◈` |
| Progress / segmented | `▰▱ ▮▯` |

Per-slot picks when a glyph is warranted:
- **command start / done** — `▸` / `◂` (mirrored filled triangles)
- **error** — no glyph; the red chip color is the signal
- **duration** — bare bracket label `[+142ms]` not `⏱`
- **git indicators** — ASCII `! ? +` are fine; geometric: modified `▲`, untracked `◇`, staged `◆`

---

## Screenshot evaluation checklist

**Geometry**
- [ ] Background is pure black everywhere
- [ ] Each bar changes thickness at its elbow turn (thick-to-thin)
- [ ] Parallel stems are independent — never merged
- [ ] Swoops are clean and undeformed
- [ ] Rounded caps appear only at bar termination points, not mid-bar
- [ ] Elements appear to align to a consistent grid

**Color and semantic correctness**
- [ ] Input/active panes show orange structural elements
- [ ] Display/passive panes show periwinkle structural elements
- [ ] Active split border is orange; inactive is muted periwinkle
- [ ] Text is pale canary (`#ffffc6`), not white
- [ ] No color bleed

**Typography**
- [ ] Chrome labels are ALL-CAPS
- [ ] No more than three distinct font sizes visible

**Anti-patterns to flag**
- Gradients, glows, or emboss effects
- Two swoops of identical size meeting symmetrically (merging stems)
- Rounded caps in the middle of a bar
- Pure white text
- More than ~5 distinct colors in the chrome
- Inner fillet with only vertical structure above and below it and no horizontal bar — a fillet marks where a bar turns into a stem; a fillet mid-stem with no bar is a broken elbow
- Pane separator only 1 physical pixel wide — borders must carry enough visual weight to read as structural LCARS stems
- Pills whose top/bottom edges are flush with the bar they sit in — pills need clear space above and below
