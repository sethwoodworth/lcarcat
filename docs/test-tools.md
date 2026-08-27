# Test Analysis Tools

<!-- Read this doc when: you have a capture or a live session and need to answer a question about it —
     which cell a thing rendered in, what color a cell actually is, how wide a line is. -->

The tools that answer questions about rendered output: cell colors, cell
coordinates, and line widths. For running tests see [`docs/testing.md`](testing.md);
for driving the kitty/nvim harness see [`docs/test-harness.md`](test-harness.md).

---

## Measuring rendered output (width and content assertions)

**`block_record.lines` are raw PTY bytes, including ANSI.** baleia strips the
escape sequences only when writing into the buffer (`frame_buffer.append_line`
calls `baleia.buf_set_lines`). So `#line` / `len(line)` over `rec.lines` counts
escape bytes and wildly overstates the rendered width — a colorized `ls` line
that renders as 118 cols measures 203.

Pick the right source for what you are asserting:

| Asserting about | Read | Measure with |
|-----------------|------|--------------|
| what the PTY emitted | `rec.lines` | strip ANSI first |
| what is on screen | `nvim_buf_get_lines` | `vim.fn.strdisplaywidth` |
| what the terminal model holds | `get_cell_grid.py` | cell records |

A regex that works for the stripping case:

```python
ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
```

When comparing a max buffer line width against frame geometry, remember that
header/footer rows are one char wider than a full-width content line (the
trailing pad space past the bar). See "Frame geometry and coordinate systems"
in `docs/nvim-terminal-frame.md` for the exact numbers.

## Pixel and semantic color tools

### Coordinate systems

Three coordinate systems appear in the tools. Keep them straight:

- **Device pixels** — raw pixels in the PNG. `screencapture -l` on Retina = 2× logical pixels.
- **Terminal cells** — a logical grid of rows × cols. Cell `(row, col)` covers device pixels `(col * cellw * scale, row * cellh * scale)` to `((col+1) * cellw * scale - 1, (row+1) * cellh * scale - 1)`.
- **Semantic colors** — the SGR `\e[48;2;r;g;b;m` values nvim wrote, independent of pixels.

The pixel tool (`analyze_gutter_cells.py`) works in device pixels, anchored to the terminal content top. The semantic tool (`get_cell_grid.py`) works in cell rows, anchored to row 0 of the terminal buffer. Both skip the same number of rows at the bottom by default (1 for the nvim statusline).

---

### test/analyze_gutter_cells.py

**What it answers:** "Did this column of cells actually render as the expected color in the screenshot?"

Samples the **center pixel** of each cell in a named column. This avoids false positives from anti-aliasing and sub-pixel rendering at cell boundary edges — the root cause of the prior LineNo gutter false positives when scanning `x=0`.

```
analyze_gutter_cells.py <png>
    [--cellw 19]         device px per cell, width  (default: 19)
    [--cellh 38]         device px per cell, height (default: 38)
    [--scale 2]          Retina scale factor (default: 2)
    [--gutter-col 0]     which terminal column to check (default: 0)
    [--skip-rows 0]      skip N cell rows from the top (e.g. nvim winbar)
    [--skip-bottom 1]    skip N rows from the bottom (default: nvim statusline)
    [--expect-bg COLOR]  assert all sampled cells match this bg color
    [--verbose]          print per-cell color table

Exit 0 = pass, 1 = assertion failed.
```

**Color names understood:** `periwinkle` (#9999ff), `stem` (same), `orange` (#ff9900), `black`, `sky` / `sky-blue` (#6699cc), `gold`, `sage`, `red`, `lilac`, `stem-dim`. Also accepts `#rrggbb` hex.

**Cell center formula:**

```
cx = col * cellw * scale + (cellw * scale) // 2
cy = terminal_top + row * cellh * scale + (cellh * scale) // 2
```

`terminal_top` is detected by scanning for the first near-black pixel at `x=0` (terminal chrome is above; content starts at first black row).

**When to use:** Assertion after a snapshot. Use it when you want to confirm the final rendered color of a gutter, bar, or bg cell region.

**When not to use:** If you need to detect fine horizontal alignment (e.g. elbow flush with stem), use `analyze_left_edge.py` instead — it scans raw pixel rows and can detect sub-cell insets that cell-center sampling would miss.

---

### test/get_cell_grid.py

**What it answers:** "Did nvim (or the shell) actually write the expected color into kitty's terminal model for this column?"

Calls `kitty @ get-text --ansi --extent screen` and parses the full SGR state machine — including `38;2;r;g;b` 24-bit truecolor (what nvim emits with `termguicolors = true`). Outputs one record per cell: `(char, fg_rgb, bg_rgb)`.

```
get_cell_grid.py
    --socket unix:/tmp/lcarcat-test.sock  (required)
    [--window N]       kitty window id from `kitty @ ls .windows[].id`
    [--col 0]          terminal column to inspect (default: 0)
    [--skip-rows 0]    skip N rows from the top
    [--skip-bottom 1]  skip N rows from the bottom (default: nvim statusline)
    [--expect-bg COLOR] assert all sampled cells have this bg color
    [--verbose]        print per-row table of char, fg, bg

Exit 0 = pass, 1 = assertion failed, 2 = tool error (kitty unreachable).
```

**What it parses:** SGR sequences from `get-text --ansi`: reset (`0m`), 24-bit color (`38;2;r;g;b` / `48;2;r;g;b`), 256-color (`38;5;n` / `48;5;n`), classic 8-color (`30–37` / `40–47`), bright (`90–97` / `100–107`), default (`39`/`49`), bold/italic/underline (ignored for color purposes). Non-CSI sequences (APC kitty graphics, OSC) are skipped.

**Getting the window id:** `kitty @ ls` returns JSON. The window id for a specific pane:

```bash
WIN_ID=$(kitty @ --to "$SOCK" ls | python3 -c '
import sys, json
d = json.load(sys.stdin)
wins = []
for osw in d:
  for t in osw.get("tabs", []):
    for w in t.get("windows", []):
      wins.append(w["id"])
print(wins[-1])
')
```

For a scenario with multiple panes, parse by `is_self`, `is_focused`, or position in `t["windows"]` rather than assuming `wins[-1]`.

**Caveat — the `Grid: N rows x M cols` header.** `M` is
`max(len(row) for row in grid)`, the longest *parsed* row, not the terminal
width. Rows holding kitty graphics placeholders parse long, so a 181-col
terminal can report `362 cols`. This does not mean column indexing is skewed:
`--col N` still maps to terminal col `N` for ordinary text rows. Do not
"correct" for it.

**When to use:** When you want to confirm the terminal *model* has the right color — i.e., that the highlight group chain in nvim actually emitted the right SGR. Use this alongside a pixel check when debugging a gutter color regression.

**When not to use:**
- When kitty is no longer running (snapshot-only workflows). The tool needs a live socket.
- When testing zsh prompt colors. The prompt outputs raw escape sequences and the cells may change on the next prompt redraw. Capture a snapshot instead, then use `analyze_gutter_cells.py`.
- When the cell content is a kitty graphics placeholder (U+10EEEE). The `get-text` output for those cells is the raw placeholder codepoint with the image-id foreground color, not the visible rendered color.

---

### test/overlay_grid.py

**What it answers:** "Which cell column and row does this rendered element occupy?"

Annotates a screenshot PNG with semi-transparent cyan grid lines at every cell boundary, labelling every Nth column and row with its index. Creates a shared coordinate vocabulary between user and agent — feedback like "the cap arc starts at col 7, one cell too late" becomes unambiguous.

```
overlay_grid.py <input.png> <output.png>
    [--cellw 19]              device px per cell width  (default: 19)
    [--cellh 38]              device px per cell height (default: 38)
    [--term-left 0]           x of col 0 left edge (default: 0)
    [--term-top 0]            y of row 0 top edge (default: 0)
    [--label-every-n-cols 5]  label every Nth column  (default: 5)
    [--label-every-n-rows 3]  label every Nth row     (default: 3)
```

**Calibrated values for `test/kitty_test.conf`** (fullscreen, `placement_strategy top-left`, `window_padding_width 0`):

```bash
python3 test/overlay_grid.py input.png output.png \
  --term-left 0 --term-top 0 --cellw 19 --cellh 38
```

All defaults are set to these values. With fullscreen launch and `placement_strategy top-left`, cell (0,0) is always at pixel (0,0) — no partial-cell leading gap. The screenshot harness (`screenshot_harness.sh launch`) uses `--start-as=fullscreen` to ensure this.

**Cell dimensions are font-specific.** The defaults (19×38 device px) are calibrated for Fantasque Sans Mono at `font_size 18`. If the font family or size changes, recalibrate via CSI 16t (`ESC[16t` → reply `ESC[6;<height>;<width>t`) or use the `--socket` flag (tracked in `lcarcat-1la`). Pass `--cellw`/`--cellh` explicitly when running outside the test harness or after a font change.

**When to use:**
- When debugging geometry issues: which cell does the LCARS elbow image start at? Does the periwinkle bar span the expected columns?
- When reporting or diagnosing issues with LCARS block frame rendering — add a grid overlay to the screenshot before filing a bead so cell positions are unambiguous.
- After any image placement or highlight group change, overlay the grid on the before/after screenshots to confirm the change landed at the right cell.

**When not to use:**
- For programmatic pass/fail assertions — `get_cell_grid.py --expect-bg` is the right tool.
- When you need rendered pixel colors — `analyze_gutter_cells.py` samples the actual screenshot pixels.

**Screenshot harness integration:** The `snapshot` subcommand in `screenshot_harness.sh` captures at device pixel resolution with no OS chrome (fullscreen mode). Pass the captured PNG directly to `overlay_grid.py` — no scale factor needed.

```bash
./test/screenshot_harness.sh snapshot my-tab
python3 test/overlay_grid.py \
  "$SHOT_DIR/my-tab.png" \
  "$SHOT_DIR/my-tab-grid.png"
```

---

### test/analyze_left_edge.py

**What it answers:** "Is the elbow image visually flush with the plain stem bg cell to its right?"

Scans raw pixel rows at the leftmost 80 device pixels of a screenshot. Reports per-row: first non-black pixel x-offset, color at x=0, color at x=2. Identifies the STARDATE row (sky-blue at x=0) and periwinkle stem rows (elbow area).

No `--expect` mode — output is a diagnostic text table for human or agent evaluation.

**When to use:** Diagnosing horizontal alignment of the zsh prompt elbow. Not suited for cell-level gutter color assertions (use `analyze_gutter_cells.py` instead).

---

