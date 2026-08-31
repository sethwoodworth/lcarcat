# Test Harness Mechanics

<!-- Read this doc when: you are writing or debugging a scenario script — driving the detached kitty,
     capturing screenshots, or hitting a timing/scripted-input gotcha. -->

How the kitty screenshot harness works and how to write a scenario against it.
For which tests exist and how to run them see [`docs/testing.md`](testing.md);
for the analysis tools see [`docs/test-tools.md`](test-tools.md); for nvim
interaction patterns specifically see [`docs/nvim-harness.md`](nvim-harness.md).

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
| `LCARCAT_SKIP_SCREENSHOTS` | (unset) | Set to `1` to skip every `snapshot` call. Honored by the `test/integration/` scripts that capture (`term_input.sh`, `terminal_win.sh`, `terminal_win_pty_width.sh`, `alternate_screen.sh`) |
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

### `enabled_layouts splits` is mandatory in `kitty_test.conf`

Without it, `kitty @ launch --location=vsplit` (and `hsplit`) silently falls
back to the stacked layout: the new window is created, every command that
targets it succeeds, and the scenario passes its own plumbing checks — but the
panes are on top of one another rather than side by side, so any geometry or
adjacency assertion is measuring a layout that isn't there. `test/kitty_test.conf`
sets it; keep it there, and set it in any new test config.

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

The first four were found while building `test/integration/term_input.sh`
(lcarcat-lyz), the fifth and sixth while building
`test/integration/alternate_screen.sh` (lcarcat-biv). All apply to any future
test that drives nvim via `kitty @ send-text` and/or submits to a
`pty_session`-backed shell.

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

**A full-screen program eats your Ex commands.** Once alternate-screen
passthrough is active, nvim is in terminal mode inside the emulator float, so
every keystroke — including the leading `:` — goes to the program, not to nvim.
A `:lua ...` state dump sent while a pager is up simply never runs, and the
symptom is a missing output file rather than an error. Send `<C-\><C-n>`
(`$'\x1c\x0e'`) to drop to normal mode before driving nvim, and `i` to go back
to terminal mode before typing at the program. Leaving terminal mode does not
close the float, so `active()` assertions still hold either side of it.

**`less -X` and a `-X` in `$LESS` disable the alternate screen outright.** A
test that runs a pager to exercise passthrough will silently exercise the plain
line path instead, and pass its unrelated assertions while proving nothing.
`alternate_screen.sh` runs `LESS= less …` to neutralize the inherited setting.

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

