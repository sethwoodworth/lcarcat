#!/usr/bin/env bash
# Scenario: spike-1 — Unicode placeholder transmission from Lua (lcarcat-zi1)
#
# Opens nvim and runs :LcarsSpikeImg to transmit an elbow PNG via io.write(APC)
# and write U+10EEEE placeholder cells into a scratch buffer. Captures a
# screenshot before and after scrolling to verify the image scrolls with the
# buffer text.
#
#   bash test/captures/spike_placeholder.sh
#
# Evaluation criteria:
#   no_errors       — nvim messages clean before screenshot
#   image_renders   — elbow PNG visible in the header rows (visual-inspector)
#   image_scrolls   — after scrolling down, image has moved with the text
#
# Set LCARCAT_KEEP_ALIVE=1 to leave the test kitty running for inspection.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/test/nvim_harness_helpers.sh"

H="$REPO/test/screenshot_harness.sh"
SOCK="${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/$(basename "${BASH_SOURCE[0]}" .sh)}"
export LCARCAT_SHOT_DIR="$SHOT_DIR"

# Default keep-alive so the kitty window stays open for visual inspection.
# nvim_harness_setup reads LCARCAT_KEEP_ALIVE; set it here so both the setup
# trap and the end-of-script check agree on the same default.
export LCARCAT_KEEP_ALIVE="${LCARCAT_KEEP_ALIVE:-1}"

nvim_harness_setup "$H" "$SOCK" "$SHOT_DIR"

# ── launch ────────────────────────────────────────────────────────────────

"$H" launch
WIN="$(_nvim_focused_window_id "$SOCK")"

nvim_open "$SOCK" "$WIN"

# Dismiss the nvim intro splash before running the spike.
# The intro is a UI overlay, not a buffer — it dismisses on first command.
nvim_run_cmd "$SOCK" "$WIN" "enew"
sleep 0.5

# Run the spike — transmits PNG via io.write(APC), opens spike buffer in a
# new tab (tab 2). Call the Lua function directly (same pattern as block_demo).
nvim_run_cmd "$SOCK" "$WIN" "lua require('lcars.spike_placeholder').render()"
sleep 1.5

# ── nvim message check (abort if errors) ─────────────────────────────────

nvim_check_messages "$SOCK" "$WIN" "spike-placeholder"

# ── screenshot 1: initial render ─────────────────────────────────────────

raw1="$SHOT_DIR/initial.png"
grid1="$SHOT_DIR/initial-grid.png"
"$H" snapshot "initial"
echo "Captured: $raw1"
python3 "$REPO/test/overlay_grid.py" "$raw1" "$grid1" >/dev/null
echo "Captured: $grid1"

# ── scroll down ~10 lines, screenshot to verify image scrolls with buffer ─

"$H" send-text "10j"
sleep 0.5

raw2="$SHOT_DIR/scrolled.png"
grid2="$SHOT_DIR/scrolled-grid.png"
"$H" snapshot "scrolled"
echo "Captured: $raw2"
python3 "$REPO/test/overlay_grid.py" "$raw2" "$grid2" >/dev/null
echo "Captured: $grid2"

echo ""
echo "Screenshots in: $SHOT_DIR/"

# Default keep-alive so kitty stays up for inspection.
if [ "${LCARCAT_KEEP_ALIVE:-1}" = "1" ]; then
    echo ""
    echo "Test kitty running. '$H teardown' to clean up."
fi
