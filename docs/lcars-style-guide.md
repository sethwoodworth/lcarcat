# LCARS Style Guide for lcarcat

Reference for screenshot evaluation subagents. Read this before critiquing any lcarcat screenshot.

Source: Bracer Jack's "Creating a Coherent LCARS Interface" tutorial; lcarcat palette from `nvim/lua/lcars/palette.lua` and `kitty/lcars.conf`.

---

## lcarcat Palette (Voyager-era, intentional — do not propose changes without user review)

| Role | Hex | Notes |
|------|-----|-------|
| Canvas | `#000000` | Universal background — never off-black |
| Primary text | `#ffffc6` | Pale canary — never pure white |
| Input / active accent | `#ff9900` | Orange — insert mode pill, active border, input panel stems |
| Structural stem / display | `#9999ff` | Periwinkle — gutter, tabline fill, elbow images |
| Gold / yellow-alert | `#ffcc66` | Branch chip, constants |
| Lilac accent | `#cc99cc` | Type chip, Voyager-era cooler purple |
| Sky / info | `#6699cc` | Info chip |
| Error / red-alert | `#ff3300` | |
| Success / diff-add | `#99cc99` | |
| Cursor | `#cc6699` | Magenta, matches kitty cursor |
| Comments | `#666699` | Dim violet |

---

## Structural Rules

### 1. Flat vector only
No gradients, no emboss, no drop shadows, no 3D. Shapes are solid-fill geometric on black.

### 2. Thick-to-thin rule
A frame **always** changes thickness at each turn. It is **never** the same thickness on two consecutive turns. This means:
- A bar meeting a stem must visibly change width at the elbow
- Two panels sharing a split must have **independent parallel stems** — they never merge into one shared spine, because that would produce equal-width bars at a shared junction, violating the rule

### 3. The swoop is sacred
The LCARS swoop/elbow shape is identity-defining. Do not distort, flatten, or deform it. The outer corner is a large radius curve; the inner corner is perpendicular.

### 4. Caps are termination points
A rounded cap marks the **end** of a bar — it is punctuation, like a period. Caps belong only at bar termination points, never mid-bar. They also naturally serve as buttons.

### 5. Two spacing constants
All elements align to one of two grid values: Main Frame Spacing and Frame Spacing. Elements that break the grid produce the characteristic "disjointed amateur LCARS" look.

### 6. Continuous frames
Frames are not arbitrarily segmented. The number of segments in a frame equals the number of options or data items being displayed.

### 7. Three font sizes only
Main Title, Sub Header, Normal Data. No mixing beyond these three. All chrome text is ALL-CAPS.

### 8. Color discipline
Maximum ~5 colors, each semantically assigned. Every color means something specific. No decorative color variation.

### 9. Input vs display panel semantics
- **Input panels** (where the user types): orange structural color
- **Display panels** (read-only, status, output): periwinkle/violet structural color
- Active split border: orange when that pane has focus
- Inactive split border: muted periwinkle

---

## How lcarcat Chrome Renders in the Terminal

Understanding this is essential for accurate evaluation. Chrome is *not* one big image —
it is a combination of terminal cells and small PNGs:

- **Flat parts (bars, fills, stems, chips)** are colored terminal background cells. They
  look like solid colored rectangles and render natively without any image protocol.
- **Curved parts (elbows, caps)** are small PNGs placed via the kitty graphics protocol.
  They appear as rounded corners and half-round bar ends.

### Elbows (swoops)
An elbow is the L-shaped corner where a horizontal **bar** turns into a vertical **stem**.
It appears as a large-radius rounded outer corner with a concave inner fillet. The elbow
image is ~5 cells wide × 3 cells tall (bar height 2 + stem row 1). The stem continues
below the elbow as a 1-cell-wide vertical strip of colored background cells.

**In screenshots:** look for a curved colored shape in the top-left area of the terminal,
connecting a horizontal band to a vertical column. The outer edge curves; the inner corner
is perpendicular. A single-pixel vertical colored column is NOT an elbow — it is a bare
stem without its elbow image (the image failed to render or is not present in this context).

### Caps
A cap is a half-round (semicircle) end placed at the right termination of a bar. It
appears as a rounded bump at the far right of a colored horizontal band.

**In screenshots:** caps appear at the rightmost extent of bars, nowhere else. A rounded
shape in the middle of a bar is a rendering error.

### Unicode placeholder rendering
nvim's tabline and statusline chrome uses the kitty **Unicode placeholder** protocol:
the image is transmitted once as a virtual placement, and then `U+10EEEE` codepoints with
row/column diacritics mark each cell. The image renders in those cells. This means:
- The tabline row at the top of nvim *can* contain an elbow/cap image
- The image is anchored to text cells so it survives nvim redraws
- If the protocol is not active or the terminal does not support it, that row will show
  placeholder characters or be blank — not a crash

### Prompt chrome (zsh, outside nvim)
The shell prompt uses cursor-anchored direct placement (`a=T,C=1`). The elbow and cap
images appear at the start and end of each prompt line. Between launches of kitty remote
control and the image placements there are sleeps in the harness — if the image placement
fires before the terminal is ready, the image may not appear.

---

## What to Check in Screenshots

**Geometry**
- [ ] Background is pure black everywhere — no off-black regions
- [ ] Each bar changes thickness at its elbow turn (thick-to-thin)
- [ ] Parallel stems are independent — never merged, never equal-width at a shared junction
- [ ] Swoops are clean and undeformed
- [ ] Rounded caps appear only at bar termination points, not mid-bar
- [ ] Elements appear to align to a consistent grid

**Color and semantic correctness**
- [ ] Input/active panes show orange structural elements
- [ ] Display/passive panes show periwinkle structural elements
- [ ] Active split border is orange; inactive is muted periwinkle
- [ ] Text is pale canary (`#ffffc6`), not white
- [ ] No color bleed — each pane's colors stay within that pane

**Typography**
- [ ] Chrome labels are ALL-CAPS
- [ ] No more than three distinct font sizes visible

**Anti-patterns to flag**
- Gradients, glows, or emboss effects
- Two swoops of identical size meeting symmetrically (merging stems)
- Rounded caps in the middle of a bar
- Pure white text
- More than ~5 distinct colors in the chrome
- An inner fillet (concave rounded corner) with only vertical structure above and below it and no horizontal bar extending from it — a fillet marks where a bar turns into a stem; a fillet mid-stem with no bar is a broken elbow
- A pane separator that is only 1 physical pixel wide — pane borders must carry enough visual weight to read as structural LCARS stems
- Pills whose top/bottom edges are flush with the bar they sit in — pills require clear space above and below; if the bar is too shallow for that clearance, use chips (flat rectangular segments) instead
