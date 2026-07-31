# Visual Testing

lcarcat has no unit tests. All testing is visual/screenshot-based. This document covers the harness, scenarios, and pixel analysis tools.

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

### How it works

1. `launch` starts kitty with `--detach`, waits up to 5s for the socket to appear, writes the PID.
2. `snapshot` reads the CGWindowID from `kitty @ ls` (the `platform_window_id` field), then calls `screencapture -l<id> -x <outfile>`. Waits 0.4s for the window to settle before capturing.
3. `teardown` is idempotent — safe to run when no test kitty is up. Politely closes windows first; force-kills if kitty is still alive after 2s.

### `id:N` vs `recent:N` lesson

When addressing windows via `kitty @ focus-window` or `send-text`, use stable `id:N` addressing rather than `recent:N`. The `recent:N` index shifts when windows are opened or closed, causing commands to target the wrong window. Get window IDs once via `kitty @ ls` and use them throughout a scenario.

### Retina capture

`screencapture -l` captures at 2x on Retina displays — 1 logical point = 2 device pixels in the output PNG. Keep this in mind when measuring pixel offsets in screenshots.

---

## test/kitty_test.conf

Minimal kitty config for test runs. Loads the LCARS theme and uses Fantasque Sans Mono at font_size 18 (the configuration that produces 19×38px cells). Kept minimal to reduce variables.

---

## Scenarios

Scenario scripts live in `test/scenarios/`. Each is a standalone shell script that runs a self-contained test using the harness.

| Scenario | What it tests |
|----------|---------------|
| `prompt_elbow_alignment.sh` | Elbow image aligns with the plain stem bg cell at the same column |
| `prompt_left_edge_pixel.sh` | Measures device-pixel inset between elbow stem and LED cell at column 1 |
| `prompt_resize_regen.sh` | Bumps font size mid-session, confirms stem alignment survives the resize |
| `trivial_image_alignment.sh` | Minimal 1-cell image alignment check |
| `cmd_buffer_theme.sh` | nvim command buffer orange input-panel theming |
| `vsplit_nvim_command_buffer.sh` | Full nvim vsplit with command buffer open |

---

## test/analyze_left_edge.py

Pixel-level stem alignment analyzer. Reads a Retina screenshot and measures the horizontal offset between the elbow image's left edge and the adjacent plain background cell. Used to verify the aspect-fit inset is zero (or diagnose the source of a nonzero inset).

The expected result after the 2026-07-30 fix: 0-pixel horizontal inset between the elbow stem and the sky-blue LED cell at column 1.

---

## Verification after asset changes

When changing cell dimensions, font, or the `gen_swoops.py` output:

1. Run `prompt_left_edge_pixel.sh` to measure pixel-level stem alignment.
2. Run `prompt_resize_regen.sh` to confirm alignment survives a mid-session font zoom.
3. Inspect screenshots manually against the checklist in `docs/lcars-design.md`.

The `sips -g pixelWidth -g pixelHeight` command on a generated PNG is also useful to confirm the pixel dimensions are exactly `cols * cellw × rows * cellh` before deploying.
