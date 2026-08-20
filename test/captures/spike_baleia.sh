#!/usr/bin/env bash
# Scenario: spike-2 — baleia.nvim + modifiable=false buffer pattern (lcarcat-dk5)
#
# Opens nvim and runs :LcarsSpikeBaleia to confirm:
#   1. baleia.buf_set_lines() writes ANSI-colored text through the
#      modifiable=false toggle (flip on → write → flip off)
#   2. Pre-existing extmarks survive the modifiable toggle
#   3. A burst of 100 ANSI lines completes without blocking the main loop
#
#   bash test/captures/spike_baleia.sh
#
# Evaluation criteria:
#   no_errors    — nvim messages clean before screenshot
#   ansi_colors  — colored lines visible in the buffer (visual-inspector)
#   pass_summary — PASS lines visible at the bottom of the buffer
#
# Set LCARCAT_KEEP_ALIVE=1 to leave the test kitty running for inspection.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/test/nvim_harness_helpers.sh"

H="$REPO/test/screenshot_harness.sh"
SOCK="${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/$(basename "${BASH_SOURCE[0]}" .sh)}"
export LCARCAT_SHOT_DIR="$SHOT_DIR"

export LCARCAT_KEEP_ALIVE="${LCARCAT_KEEP_ALIVE:-1}"

nvim_harness_setup "$H" "$SOCK" "$SHOT_DIR"

# ── launch ────────────────────────────────────────────────────────────────

"$H" launch
WIN="$(_nvim_focused_window_id "$SOCK")"

nvim_open "$SOCK" "$WIN"

# Dismiss intro splash
nvim_run_cmd "$SOCK" "$WIN" "enew"
sleep 0.5

# Run the spike — opens a scratch tab with colored output and summary rows
nvim_run_cmd "$SOCK" "$WIN" "lua require('lcars.spike_baleia').run()"
sleep 1.5

# ── nvim message check ────────────────────────────────────────────────────

nvim_check_messages "$SOCK" "$WIN" "spike-baleia"

# ── screenshot 1: top of buffer — ANSI-colored lines ─────────────────────

raw1="$SHOT_DIR/ansi_colors.png"
grid1="$SHOT_DIR/ansi_colors-grid.png"
"$H" snapshot "ansi_colors"
echo "Captured: $raw1"
python3 "$REPO/test/overlay_grid.py" "$raw1" "$grid1" >/dev/null
echo "Captured: $grid1"

# ── scroll to summary rows — PASS/FAIL lines ──────────────────────────────

"$H" send-text "G"
sleep 0.3

raw2="$SHOT_DIR/summary.png"
grid2="$SHOT_DIR/summary-grid.png"
"$H" snapshot "summary"
echo "Captured: $raw2"
python3 "$REPO/test/overlay_grid.py" "$raw2" "$grid2" >/dev/null
echo "Captured: $grid2"

echo ""
echo "Screenshots in: $SHOT_DIR/"

if [ "${LCARCAT_KEEP_ALIVE:-1}" = "1" ]; then
    echo ""
    echo "Test kitty running. '$H teardown' to clean up."
fi
