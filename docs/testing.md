# Visual Testing

lcarcat has no unit tests. All testing is visual/screenshot-based. This document covers the harness, scenarios, pixel analysis tools, and cell-grid color readers.

---

## Quick reference: which tool for which question

| Question | Tool |
|----------|------|
| Did nvim actually *set* periwinkle on those cells? | `get_cell_grid.py --expect-bg periwinkle` ← **prefer this for assertions** |
| Did the gutter render as periwinkle on screen? | `analyze_gutter_cells.py --expect-bg periwinkle` |
| Is the elbow image flush with the stem bg cell? | `analyze_left_edge.py` |
| Where is a color in the PNG, exactly? | `analyze_left_edge.py` (raw row scan) |
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

### How it works

1. `launch` starts kitty with `--detach`, waits up to 5s for the socket to appear, writes the PID.
2. `snapshot` reads the CGWindowID from `kitty @ ls` (the `platform_window_id` field), then calls `screencapture -l<id> -x <outfile>`. Waits 0.4s for the window to settle before capturing.
3. `teardown` is idempotent — safe to run when no test kitty is up. Politely closes windows first; force-kills if kitty is still alive after 2s.

### `id:N` vs `recent:N` lesson

Use stable `id:N` window addressing rather than `recent:N`. The `recent:N` index shifts when windows are opened or closed, causing commands to target the wrong window. Get window IDs once via `kitty @ ls` and reuse them throughout a scenario.

### Retina capture

`screencapture -l` captures at 2x on Retina displays — 1 logical point = 2 device pixels in the output PNG. The pixel tools use `--scale 2` to account for this.

---

## test/kitty_test.conf

Minimal kitty config for test runs. Loads the LCARS theme and uses Fantasque Sans Mono at font_size 18, which produces 19×38px cells (device pixels). Kept minimal to reduce variables.

The `rich_demo.sh` scenario uses `test/kitty_demo.conf` instead — 1600×900 with tab bar enabled.

---

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

**When to use:** When you want to confirm the terminal *model* has the right color — i.e., that the highlight group chain in nvim actually emitted the right SGR. Use this alongside a pixel check when debugging a gutter color regression.

**When not to use:**
- When kitty is no longer running (snapshot-only workflows). The tool needs a live socket.
- When testing zsh prompt colors. The prompt outputs raw escape sequences and the cells may change on the next prompt redraw. Capture a snapshot instead, then use `analyze_gutter_cells.py`.
- When the cell content is a kitty graphics placeholder (U+10EEEE). The `get-text` output for those cells is the raw placeholder codepoint with the image-id foreground color, not the visible rendered color.

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

Run all integration tests:
```bash
for f in test/integration/*.sh; do echo "--- $f ---"; bash "$f" && echo PASS || echo FAIL; done
```

### test/captures/ — reference screenshots, human-evaluated

These produce PNGs in `test/screenshots/<name>/` but have no programmatic assertion. Run them when you want a reference capture or are evaluating a visual change.

| Script | What it captures |
|--------|-----------------|
| `block_demo.sh` | LCARS block frame styles in a scratch buffer |
| `cmd_buffer_theme.sh` | Orange gutter in command buffer; periwinkle above |
| `prompt_elbow_alignment.sh` | Elbow image aligned with stem bg cell |
| `prompt_left_edge_pixel.sh` | Sub-pixel left edge (feed to `analyze_left_edge.py`) |
| `prompt_resize_regen.sh` | Alignment at baseline, larger, and restored font size |
| `rich_demo.sh` | Full 3-pane README hero layout |
| `terminal_frame.sh` | LCARS swoop prompt inside a full-window nvim `:terminal` |
| `trivial_image_alignment.sh` | 1-cell image vs plain bg cell (uses `test/fixtures/trivial_align_test.py`) |
| `vsplit_nvim_command_buffer.sh` | Side-by-side nvim + command buffer layout |

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
