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
The half-round end of a bar — punctuation, like a period. Only at bar termination points, never mid-bar. There must always be at least 2 bar-color cells immediately before the cap — a visual breathing gap that lets the round end read as a natural continuation of the bar rather than a blob stuck to the last chip. Chips and text must never run up to the cap's edge.

#### notch — the vertical highlight before a cap
A **notch** is not a kind of chip. It is a *one-column vertical accent stripe*
standing in the bar just before the cap, held apart from its neighbours by
black:

```
[ … bar … ][black][accent][black][accent accent][cap]
                    ↑notch              ↑pre-cap buffer
```

One column of bar color, a black column on each side of it, then the pre-cap
buffer and the cap. It reads as a tick mark closing the bar — the same role a
tally stroke plays at the end of a run — and it is the only place a single
isolated column of accent is allowed.

### rail block (vertical chip)
A stacked segment in a vertical rail — a chip stood on end. Labeled in black,
sized by proportional weight rather than by content, and clickable where a rail
carries navigation.

- **Spaced like chips**: a black gap between neighbours, *and the same gap at
  both ends*. Without the end gaps the first and last blocks fuse with the
  elbows above and below, and the rail reads as a stem that changes colour
  instead of as a stack of segments.
- **Coloured by position**, from `palette.ACCENT_SEQUENCE`, so every rail in
  every layout runs the same progression instead of each one picking its own.
- A block that carries **meaning** — the active tab, an alert — departs from the
  sequence and takes its own colour. What marks it is the break in the
  progression, not the particular hue.
- A rail with **no** blocks is a plain stem: one solid run, continuous with the
  elbows, and no gaps.

### chip
Two kinds, and the difference is what the label sits on.

**Color chip**: a solid segment in its own accent, different from the bar's,
carrying a dark label. Chips of different accents sit side by side separated by
combed 1-col black gaps. Each is preceded and followed by a 1-col black gap —
explicit black cells, not bar fill.

**Label chip**: the bar's own accent color as *text*, cut into black. The chip's
cells are the LCARS void and the letters are the accent, so the label reads as
cut **into** the bar rather than printed on it. It is reserved for a frame or
panel's **own title** — the most assertive thing in the bar, not ambient
decoration. A reading, a count or a state is a color chip, never this. Layout
rules:

- **Cap-side, always.** It takes the end of the bar *away from the elbow*: the
  right of a left-elbow bar, the left of a right-elbow (mirrored) one. The elbow
  is where the bar turns into the rest of the frame, and a label against it
  reads as part of the corner instead of as the panel's name.
- Separated from the chip beside it by `[1 black][1 bar-color]` — two columns,
  of which only the one nearer the chip is explicitly black.
- No gap between it and the pre-cap buffer: the chip is already black, and the
  2-col buffer follows it directly.
- At least one column of black padding inside the chip on each side of the
  label, so the letters never touch the bar color.
- Spans the full height of the bar.

A label chip may be set in **cell text** on its bottom row, or in
**bar-height block letters** as an image — see `docs/dashboard.md`, "Block-letter
titles". Same slot, same colors, same rules; the image form costs about two
columns per character against one and abbreviates rather than truncates when the
bar is narrow.

Text alignment: chips are laid out as a group ending at the bar's cap side;
generally cell-text labels sit on the bottom row of the 2-row bar.

---

## Structural design rules

### 1. Flat vector only
No gradients, no emboss, no drop shadows. Shapes are solid-fill geometric on black.

### 2. Thick-to-thin rule
A frame always changes thickness at each turn. Never the same thickness on two consecutive turns. Bars meeting stems must visibly change width at the elbow. Two panels sharing a split have independent parallel stems — they never merge into one spine.

### 3. The swoop is sacred
The LCARS elbow shape is identity-defining. Do not distort, flatten, or deform it. Large-radius outer corner; perpendicular inner corner.

**Radius measured 2026-09-17 from the reference props; the per-elbow numbers are
in `lcarcat-2cc.7`, and the method and its traps in
`docs/elbow-measurement.md`.** Five elbows across four references were fitted
(both arcs, sub-pixel residuals), and they support bounds rather than a formula. Name the arms by width, not by
direction: every elbow has a **thick arm** and a **thin arm**.

| Property | Measured across the references |
|----------|-------------------------------|
| `R_outer` | between the two arm widths, always: 1.0–2.9× the thin arm, 0.37–0.91× the thick arm |
| `R_inner` | 0.48–0.85× `R_outer`, and never below ~0.8× the thin arm |
| Both arcs | circles tangent to their own two edges (one outer corner is an ellipse at 1.5:1) |
| The turn | never pinches: the narrowest colour across the corner equals the thin arm (0.91–1.02×) |

Two rules previously recorded here are **disproved** and must not be reinstated:

- `R_inner = R_outer − W` fails on four of the five elbows, by up to 18px. It
  came from a single elbow whose bar thickness was never measured but *inferred
  from the rule*; measured directly, that bar is 9.9px, not 16px.
- **Centres share a height** fails too: the vertical offsets measured −15, +4,
  −5, +25 and +26px. The arcs are independent, so `R_outer` need not exceed
  either arm, and nothing forces a negative inner radius.

**Settled 2026-09-22 — this is what `gen_swoops.py` draws.** Seth's call, after
comparing the range in the elbow tuner:

```
R_outer = 1.0 × the THICK arm's width      ELBOW_OUTER_RADIUS_OVER_THICK_ARM
R_inner = 0.48 × R_outer                   ELBOW_INNER_OVER_OUTER_RADIUS
outer sweep is always a circle             (no ellipse; msd-1 is the only elliptical reference)
```

For our elbow (thin arm = 1-column stem = 19px, thick arm = 2-row bar = 76px)
that is `R_outer` 76px and `R_inner` 36.5px, against 34px and 17px before. The
fillet ends 112.5px down a 114px-tall image, so the 5×3-cell asset still holds.

Both constants live at the top of `gen_swoops.py` and are meant to be tuned.
Note where the choice sits against the references: `R_outer` at 1.0× the thick
arm is a shade past the measured maximum (0.91×), and `R_inner` at 0.48× is the
bottom of the measured band — a deliberate look, not a measurement.

### 4. No T/+ junctions
**This is the design law.** Bars meet stems only via 2-sided elbows. Free ends get caps. T (3-way) and + (4-way) junctions do not exist in LCARS. Where a stem would cross a bar, one must terminate in a cap or turn in an elbow.

Consequence: "an elbow at every window corner" is wrong for nvim — interior windows make their gutters cross the global tabline/statusline → T-junctions. Use the outer-frame-only model instead. See `docs/nvim-chrome.md`.

### 5. Caps are termination points
A rounded cap marks the end of a bar — punctuation, like a period. Caps belong only at bar termination points, never mid-bar.

### 6. Pre-cap buffer columns
At least 2 bar-color columns must precede every cap. Chips and text must stop no closer than 3 cols from the cap's edge (2 bar cols + the cap itself). This applies to header bars, footer bars, and split-separator bars, and it is symmetric: a mirrored bar whose cap is on the *left* keeps the same clearance on that side.

### 7. Two spacing constants
All elements align to one of two grid values: Main Frame Spacing and Frame Spacing. Breaking the grid produces the "disjointed amateur LCARS" look.

### 8. Three font sizes only
Main Title, Sub Header, Normal Data. No mixing beyond these three. All chrome text is ALL-CAPS (this is flexible on implementation).

### 9. Color discipline
Maximum ~5 colors, each semantically assigned. Every color means something specific — no decorative variation. See `docs/palette.md`.

### 10. Input vs display panel semantics
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
