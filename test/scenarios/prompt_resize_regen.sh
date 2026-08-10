#!/usr/bin/env bash
# Scenario: verify the prompt regenerates and retransmits elbow PNGs when the cell
# size changes mid-session (e.g. font zoom). Sequence:
#   1. Baseline snapshot at default font_size — expect 0 device-px inset
#   2. Bump font_size via `kitty @ set-font-size` (fires SIGWINCH inside the shell)
#   3. Execute a NOP so precmd runs the WINCH-triggered probe+regen
#   4. Snapshot — expect 0 device-px inset at the new cell size
#   5. Restore font_size and re-snapshot for completeness

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
H="$REPO/test/screenshot_harness.sh"
SOCK="${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/$(basename "${BASH_SOURCE[0]}" .sh)}"
export LCARCAT_SHOT_DIR="$SHOT_DIR"

mkdir -p "$SHOT_DIR"
trap '"$H" teardown >/dev/null 2>&1 || true' EXIT INT TERM

"$H" launch
sleep 2.0

# baseline
"$H" send-text $':\n'
sleep 0.8
"$H" snapshot "01-resize-baseline"

# bump font size (kitty @ change-font-size supports relative +/- adjustments).
kitty @ --to "$SOCK" set-font-size 24 >/dev/null 2>&1 || true
sleep 0.6

# execute NOP to run precmd (which reprobes on WINCH)
"$H" send-text $':\n'
sleep 1.0
"$H" snapshot "02-resize-larger"

# restore
kitty @ --to "$SOCK" set-font-size 18 >/dev/null 2>&1 || true
sleep 0.6
"$H" send-text $':\n'
sleep 1.0
"$H" snapshot "03-resize-restored"
