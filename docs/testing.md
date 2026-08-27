# Testing

lcarcat has two complementary test layers:

- **Headless unit tests** (`test/unit/`) — pure-Lua logic tests, no nvim display, no kitty required. Fast, deterministic, CI-runnable. Currently cover `pty_session._parse_chunk`.
- **Visual / screenshot tests** — kitty-harness-driven capture scripts and integration tests. Required for anything involving nvim rendering, image placement, or terminal interaction.

This document covers both layers.

---

## Headless unit tests

### test/unit/run_parser_tests.sh

Tests `lcars.pty_session._parse_chunk` — the pure OSC 133 parser and carry-buffer logic.

```bash
bash test/unit/run_parser_tests.sh
```

Runs under `nvim --headless -u NONE`. No kitty, no display, no plugin dependencies. Exit 0 = all pass.

**Test convention** (pattern for future headless tests):
- Minimal pure-Lua runner in `test/unit/<module>_test.lua` — no busted or plenary.
- Call `vim.cmd("cq 1")` on any failure so nvim exits nonzero.
- Expose the function under test as `M._function_name` in the module (Lua convention for semi-private testable functions).

---

## Visual testing

---

## Quick reference: which tool for which question

| Question | Tool |
|----------|------|
| Did nvim actually *set* periwinkle on those cells? | `get_cell_grid.py --expect-bg periwinkle` ← **prefer this for assertions** |
| Did the gutter render as periwinkle on screen? | `analyze_gutter_cells.py --expect-bg periwinkle` |
| Is the elbow image flush with the stem bg cell? | `analyze_left_edge.py` |
| Where is a color in the PNG, exactly? | `analyze_left_edge.py` (raw row scan) |
| Which cell column/row does a rendered element occupy? | `overlay_grid.py` — annotate screenshot with cell boundary grid |
| Something renders wrong but cells look right | rendering bug — check CSI 16t / font size |
| Cells have the wrong color but nvim config looks right | logic bug — check highlight groups in `nvim/colors/lcars.lua` |

**Prefer the semantic check (`get_cell_grid.py`) for programmatic assertions.** It reads kitty's terminal model directly and does not depend on screenshot timing. The pixel check (`analyze_gutter_cells.py`) is useful for visual confirmation and diagnosing rendering bugs downstream of the terminal model, but screenshot timing makes it unreliable as a pass/fail gate — a screenshot taken a few milliseconds before nvim finishes painting will silently show the wrong color.

A pixel check passing with a semantic check failing means the right color reached the screen despite wrong SGR state (possible with compositor caching, but unlikely). Pixel failing with semantic passing is a rendering or anti-aliasing bug, not a logic bug.

---

## test/screenshot_harness.sh

Drives a detached kitty instance via `kitty @ --to SOCK` remote control. Captures screenshots via macOS `screencapture -l <CGWindowID>`.

### Subcommands

```bash
./test/screenshot_harness.sh launch             # start a detached test kitty
./test/screenshot_harness.sh snapshot LABEL     # capture to /tmp/lcarcat-screenshots/LABEL.png
./test/screenshot_harness.sh launch-nvim-vsplit [FILE]  # open nvim with vsplit
./test/screenshot_harness.sh launch-cmd-buffer  # open the nvim command buffer pane
./test/screenshot_harness.sh send-text TEXT     # send text to most recently focused window
./test/screenshot_harness.sh focus-shell        # focus the first (shell) window
./test/screenshot_harness.sh remote CMD...      # pass raw kitty @ commands
./test/screenshot_harness.sh teardown           # close all windows, remove socket
```

### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `LCARCAT_TEST_SOCK` | `unix:/tmp/lcarcat-test.sock` | kitty remote-control socket |
| `LCARCAT_TEST_PID_FILE` | `<sock_path>.pid` | PID for teardown |
| `LCARCAT_SHOT_DIR` | `/tmp/lcarcat-screenshots` | Screenshot output directory |
| `LCARCAT_TEST_DISPLAY` | (unset) | Set to `external` to move window to external display |
| `TEST_CONF` | `test/kitty_test.conf` | kitty config for the test instance |
| `LCARCAT_SKIP_SCREENSHOTS` | (unset) | Set to `1` to skip every `snapshot` call. Honored by the `test/integration/` scripts that capture (`term_input.sh`, `terminal_win.sh`, `terminal_win_pty_width.sh`) |
| `LCARCAT_KEEP_ALIVE` | (unset) | Set to `1` to suppress the teardown trap in `nvim_harness_setup`, leaving kitty up for post-run probing |

### How it works

1. `launch` starts kitty with `--detach`, waits up to 5s for the socket to appear, writes the PID.
2. `snapshot` reads the CGWindowID from `kitty @ ls` (the `platform_window_id` field), then calls `screencapture -l<id> -x <outfile>`. Waits 0.4s for the window to settle before capturing.
3. `teardown` is idempotent — safe to run when no test kitty is up. Politely closes windows first; force-kills if kitty is still alive after 2s.

### When `snapshot` fails: `could not create image from window`

That message is from macOS `screencapture`: the terminal hosting the test run
lacks **Screen Recording** permission (System Settings → Privacy & Security →
Screen Recording). It is not a harness or kitty bug, and it affects every
capture, including a bare `screenshot_harness.sh snapshot`.

It matters more than it looks: scenario scripts run under `set -euo pipefail`,
so a failed snapshot aborts the whole run before the assertions execute. Run
assertion-bearing tests with `LCARCAT_SKIP_SCREENSHOTS=1` when the host lacks
the permission — the pass/fail checks do not depend on the PNGs.

### `id:N` vs `recent:N` lesson

Use stable `id:N` window addressing rather than `recent:N`. The `recent:N` index shifts when windows are opened or closed, causing commands to target the wrong window. Get window IDs once via `kitty @ ls` and reuse them throughout a scenario.

### Fullscreen capture and pixel coordinates

The test kitty launches fullscreen (`--start-as=fullscreen`) with `window_padding_width 0` and `placement_strategy top-left`. This means:

- Cell (0,0) is at pixel (0,0) in every screenshot — no macOS title bar, no partial-cell leading gap.
- `screencapture -l` on Retina returns device pixels. At the standard test font (Fantasque Sans Mono 18pt), each cell is 19×38 device px.
- Any remainder pixels from display-size ÷ cell-size land at the right and bottom edges, not the top-left.
- Pass screenshots directly to `overlay_grid.py` with `--term-left 0 --term-top 0` (the defaults).

---

## test/kitty_test.conf

Minimal kitty config for test runs. Loads the LCARS theme and uses Fantasque Sans Mono at font_size 18, which produces 19×38px cells (device pixels). Kept minimal to reduce variables.

The `rich_demo.sh` scenario uses `test/kitty_demo.conf` instead — 1600×900 with tab bar enabled.

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

## Test hierarchy

Scripts are split into two directories based on whether they have machine-verifiable exit codes.

### test/integration/ — pass/fail, CI-runnable

Each script exits 0 on pass, 1 on failure. Safe to run in CI or as a pre-commit gate.

| Script | What it asserts |
|--------|-----------------|
| `nvim_eob_gutter.sh` | Column 0 is periwinkle for all rows (short file, no scroll) |
| `nvim_eob_gutter_scrolled.sh` | Column 0 stays periwinkle after `G`+`zt` scroll to EOF |
| `cmd_buffer_target_pane.sh` | Submitted text reaches RIGHT pane; LEFT pane is clean (regression: lcarcat-08g.1) |
| `terminal_win.sh` | `:LcarsTerm` round-trips real commands through the PTY; session reuse and teardown (lcarcat-2z9) |
| `terminal_win_pty_width.sh` | PTY `COLUMNS` equals the frame's content width; wide output stays inside the bar (regression: lcarcat-wve) |

Run all integration tests:
```bash
for f in test/integration/*.sh; do echo "--- $f ---"; bash "$f" && echo PASS || echo FAIL; done
```

### test/captures/ — reference screenshots, human-evaluated

These produce PNGs in `test/screenshots/<name>/` but have no programmatic assertion. Run them when you want a reference capture or are evaluating a visual change.

| Script | What it captures |
|--------|-----------------|
| `block_demo.sh` | LCARS block frame styles in a scratch buffer |
| `frame_buffer.sh` | frame_buffer lifecycle: done/live/failed blocks via open_block→append_line→close_block |
| `cmd_buffer_theme.sh` | Orange gutter in command buffer; periwinkle above |
| `prompt_elbow_alignment.sh` | Elbow image aligned with stem bg cell |
| `prompt_left_edge_pixel.sh` | Sub-pixel left edge (feed to `analyze_left_edge.py`) |
| `prompt_resize_regen.sh` | Alignment at baseline, larger, and restored font size |
| `rich_demo.sh` | Full 3-pane README hero layout |
| `terminal_frame.sh` | LCARS swoop prompt inside a full-window nvim `:terminal` |
| `trivial_image_alignment.sh` | 1-cell image vs plain bg cell (uses `test/fixtures/trivial_align_test.py`) |
| `vsplit_nvim_command_buffer.sh` | Side-by-side nvim + command buffer layout |

---

## DEBUG_BG diagnostic mode

`block_demo.lua` has a `DEBUG_BG` flag (toggled via `:LcarsBlockDemoDebugBg`) that swaps highlight group backgrounds to diagnostic colors, making transparent image regions and highlight geometry immediately visible.

### Color zones

| Zone color | Meaning |
|------------|---------|
| Deep purple `#330033` | `LcarsBlockBar` / `LcarsBlockStem` — bar/stem territory |
| Deep teal `#003333` | `LcarsBlockBg` / `LcarsBlockCmd` / `LcarsBlockLive` / `LcarsBlockInput` — frame interior territory |
| Black | Terminal background — no highlight (Normal bg is never changed) |

### When to use it

Use DEBUG_BG when diagnosing transparent image corners or inner fillets. Against a black background, transparent PNG regions are invisible. With diagnostic highlights, the boundary between "highlight covers this cell" and "image covers this cell" is immediately obvious.

### How to capture

```bash
# Single tab with debug highlights
LCARCAT_DEBUG_BG=1 bash test/captures/block_demo.sh A

# All tabs with debug highlights
LCARCAT_DEBUG_BG=1 bash test/captures/block_demo.sh
```

Output files get a `-debug` suffix: `tab-1-A-debug.png`, `tab-1-A-debug-grid.png`. Normal (non-debug) screenshots are unaffected.

### Diagnostic patterns

- **Teal in a stub row fillet area** → `LcarsBlockBg` extends there (correct bg assignment; check image z-order / placement)
- **Purple in a chip gap** → gap cells have `LcarsBlockBar` highlight bleed
- **Purple in cap cells** → `bar_w` extends into the cap region (extmark covers the image)
- **Black where teal expected** → highlight not set; extmark is missing for that row/cell range

### Inspecting debug screenshots

Delegate to the `visual-inspector` subagent. The inspection question shifts from "is the image present?" to "does each color zone's boundary match the expected highlight geometry?" — e.g., "On tab A, does the purple zone end exactly at col `lp` or does it bleed into the cap region?"

---

## Known gotchas for scripted nvim/PTY tests

Found while building `test/integration/term_input.sh` (lcarcat-lyz). All four
apply to any future test that drives nvim via `kitty @ send-text` and/or
submits to a `pty_session`-backed shell.

**`:startinsert` doesn't stick across a scripted Ex-command sequence.**
Calling `vim.cmd('startinsert')` at the end of a `:luafile`-executed fixture
— even deferred via `vim.schedule` — does not reliably leave the buffer in
Insert mode by the time a *later* command in the driving shell script sends
its own leading-`:` Ex command (e.g. `nvim_check_messages`'s
`:redir! > file | messages | redir END`). If the buffer is still in Insert
mode when that arrives, the `:` and the rest of the command get typed as
**literal text into the buffer** instead of executing — corrupting whatever
the fixture set up, with no error printed anywhere. Don't have a fixture put
itself into Insert mode and then rely on timing; instead, have the *driving
script* send its own explicit `<Esc>` before any Ex-command helper call, and
explicit `<Esc>` + `i` right before typing buffer content. This is fully
deterministic and doesn't depend on how long some prior step took.

**`_nvim_focused_window_id` (in `nvim_harness_helpers.sh`) requires real OS
focus, which a background/non-interactive job never gets.** A kitty window
launched via `screenshot_harness.sh launch` from a background Claude Code
job shows `is_focused: false` for both the OS window and its pane — nothing
in that context can click to focus it. Every helper built on
`is_focused` silently returns nothing. When a test only ever has one window
(true for most capture/integration scripts), resolve it by id instead:

```bash
WIN="$(kitty @ --to "$SOCK" ls | python3 -c '
import sys, json
d = json.load(sys.stdin)
for osw in d:
    for t in osw["tabs"]:
        for w in t["windows"]:
            print(w["id"])
' | tail -1)"
```

**Screenshot capture is unreliable from a background job, independent of
Screen Recording permission.** `screencapture -l<id>` fails with "could not
create image from window" for the unfocused window above, even after Screen
Recording permission is granted to the terminal app — most likely because
an unfocused fullscreen window isn't actually composited by macOS in that
context, not a TCC denial. There is no known workaround from a background
job. Guard screenshot calls behind a skippable flag (see
`LCARCAT_SKIP_SCREENSHOTS` in `term_input.sh`) so the hard pass/fail
assertion can still run standalone, and note in the handoff that visual
confirmation needs an interactive foreground session.

**A `pty_session`-backed shell needs several seconds of cold-start before it
drains PTY input, even though `jobstart`/`chansend` both return success
immediately.** This repo's zsh prompt renders LCARS elbow images via kitty
graphics on every prompt draw, which is slow on a cold first prompt.
Sending `pty_session.send(...)` right after `pty_session.start(...)`
appeared to silently do nothing (no error — `chansend` to a job whose shell
hasn't reached a read-loop yet just doesn't get processed in time). Wait at
least ~4 seconds between starting the PTY and depending on a command having
executed, or trigger off an actual event (e.g. the first OSC 133;A) instead
of a fixed sleep once `terminal_win.lua` wires that up.

---

## Writing a new test or capture

**Integration test** (`test/integration/`) — use when you have a machine-verifiable assertion. Exit 0/1 must reflect pass/fail. Use `get_cell_grid.py --expect-bg` or `get-text` + grep for assertions. See existing scripts for patterns.

**Capture script** (`test/captures/`) — use when the question is "does this look right" and there is no programmatic signal. Name the shots clearly; a subagent can evaluate the PNGs independently.

### Integration test template

```bash
#!/usr/bin/env bash
# Integration test: <one-line description>
# Pass/fail: <what exit 0 means>

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/test/nvim_harness_helpers.sh"

H="$REPO/test/screenshot_harness.sh"
SOCK="${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/$(basename "${BASH_SOURCE[0]}" .sh)}"
export LCARCAT_SHOT_DIR="$SHOT_DIR"

nvim_harness_setup "$H" "$SOCK" "$SHOT_DIR"
"$H" launch && sleep 1.5
WIN="$(_nvim_focused_window_id "$SOCK")"

nvim_open "$SOCK" "$WIN" "$FIXTURE"
nvim_check_messages "$SOCK" "$WIN" "my-test"
"$H" snapshot "01-label"

# Hard assertion — exits 1 on failure
python3 "$REPO/test/get_cell_grid.py" \
  --socket "$SOCK" --window "$WIN" \
  --col 0 --skip-rows 1 --skip-bottom 1 \
  --expect-bg periwinkle --verbose

[[ $EXIT -eq 0 ]] && echo "PASS" || { echo "FAIL"; exit 1; }
```

### Rules

- Always wrap `launch` and `teardown` with the `EXIT INT TERM` trap. Teardown is idempotent.
- Use `sleep` after `launch` (1.5s), after opening nvim (2.0s), and after interactions (0.2–0.4s). These are not negotiable — kitty and nvim need wall-clock time to settle.
- Use `set +e` / `set -e` around assertion commands that exit nonzero on failure, so the failure is captured in a variable rather than killing the script before the final verdict.
- Get window IDs via `kitty @ ls` once after `launch`, not inline at every command.
- Use `id:N` addressing for all `focus-window` and `send-text` calls. Never use `recent:N`.
- **Check nvim messages before every screenshot.** After any Lua command sent to nvim, query
  `:messages` via `kitty @ send-text` → `\r` and capture the output before taking the snapshot.
  An error printed to the nvim message area (e.g. E5108 Lua errors, E474 invalid argument)
  means the command failed silently from the harness's perspective. If messages contain "Error"
  or "E[0-9]", abort the test and print the message rather than capturing a misleading screenshot.
  Practical pattern:
  ```bash
  kitty @ --to "$SOCK" send-text --match "id:$WIN" ":lua require('lcars.block_demo').render()\r"
  sleep 0.5
  # Capture messages to a temp file; fail fast if nvim reported an error
  kitty @ --to "$SOCK" send-text --match "id:$WIN" ":redir! > /tmp/nvim_messages.txt | messages | redir END\r"
  sleep 0.3
  if grep -qiE '^E[0-9]+:|Error' /tmp/nvim_messages.txt 2>/dev/null; then
    echo "ABORT: nvim reported errors before screenshot:" >&2
    cat /tmp/nvim_messages.txt >&2
    exit 1
  fi
  "$H" snapshot "label"
  ```

### Adding a programmatic assertion to an existing scenario

Prefer the semantic check. The pixel check is optional and useful only for diagnosing rendering bugs.

1. After the `snapshot` call, add a semantic check (the test kitty must still be running — teardown happens via the EXIT trap):
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
   python3 "$REPO/test/get_cell_grid.py" \
     --socket "$SOCK" --window "$WIN_ID" \
     --col <N> --skip-rows 1 --skip-bottom 1 \
     --expect-bg <color> --verbose
   ```
   `--skip-rows 1` skips the kitty tab bar (row 0 of the terminal buffer is outside the nvim window). `--skip-bottom 1` skips the nvim statusline.

2. Optionally add a pixel check for rendered-color confirmation:
   ```bash
   python3 "$REPO/test/analyze_gutter_cells.py" "$SHOT_DIR/<label>.png" \
     --gutter-col <N> --expect-bg <color> --verbose
   ```

3. Exit the script nonzero on any failure.

### Which column to check

- **Column 0** — the nvim LineNr gutter. Background should be `periwinkle` (#9999ff) in normal buffers and `orange` (#ff9900) in command buffers.
- **Column 1+** — the text area. Background should be `black` (#000000).
- The gutter is always one cell wide (`signcolumn=number` merges signs into the LineNr column).

### Choosing `--skip-rows` and `--skip-bottom`

- `--skip-rows` defaults to 0. If the nvim window has a winbar (`WinBar` set), the first cell row is the winbar — pass `--skip-rows 1`.
- `--skip-bottom` defaults to 1 to skip the nvim statusline. For a shell-only window with no statusline, pass `--skip-bottom 0`.
- For `get_cell_grid.py`, the same parameters apply to the terminal buffer row count. The last row of a full-screen nvim window is the statusline — skip it.

---

## Verification after asset changes

When changing cell dimensions, font, or `gen_swoops.py` output:

1. Run `prompt_left_edge_pixel.sh` → feed the PNG to `analyze_left_edge.py` to verify zero sub-cell inset.
2. Run `prompt_resize_regen.sh` → confirm alignment survives a mid-session font zoom.
3. Run `nvim_eob_gutter.sh` → confirm the gutter assertion still passes at the new cell dims.
4. Inspect screenshots manually against the checklist in `docs/lcars-design.md`.

Pass `--cellw` and `--cellh` explicitly to `analyze_gutter_cells.py` if you've changed the test font size:

```bash
python3 test/analyze_gutter_cells.py /tmp/lcarcat-screenshots/01-eob-gutter.png \
  --cellw 20 --cellh 40 --expect-bg periwinkle --verbose
```

The defaults (19×38) match `test/kitty_test.conf` at font_size 18 Fantasque Sans Mono. Any other font or size requires explicit values from a CSI 16t probe.
