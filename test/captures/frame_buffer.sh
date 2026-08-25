#!/usr/bin/env bash
# Scenario: frame_buffer — display buffer lifecycle test (lcarcat-tq2)
#
# Exercises open_block / append_line / close_block across three states:
#   done (with duration), live (no footer), failed (re-rendered header + duration)
#
#   bash test/captures/frame_buffer.sh
#
# Evaluation criteria:
#   no_errors       — nvim messages clean before screenshot
#   header_rerender — done/failed blocks show duration in the header chip area
#   live_no_footer  — live block has no footer bar
#   ansi_colors     — colored content lines visible via baleia
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

# ── launch ────────────────────────────────────────────────────────────────────
"$H" launch
WIN="$(_nvim_focused_window_id "$SOCK")"
nvim_open "$SOCK" "$WIN"

# Dismiss intro splash
nvim_run_cmd "$SOCK" "$WIN" "enew"
sleep 0.5

# Run the test fixture
TEST_LUA="$REPO/test/captures/frame_buffer_test.lua"
nvim_run_cmd "$SOCK" "$WIN" "luafile $TEST_LUA"
sleep 2.0

# Dismiss any autocomplete/cmdline residue
kitty @ --to "$SOCK" send-text --match "id:$WIN" $'\x1b'
sleep 0.3

# ── message check ─────────────────────────────────────────────────────────────
nvim_check_messages "$SOCK" "$WIN" "frame-buffer"

# ── screenshot: top of buffer ─────────────────────────────────────────────────
"$H" snapshot "frame-buffer-top"
RAW="$SHOT_DIR/frame-buffer-top.png"
GRID="$SHOT_DIR/frame-buffer-top-grid.png"
python3 "$REPO/test/overlay_grid.py" "$RAW" "$GRID" >/dev/null
echo "Captured: $RAW"
echo "Captured: $GRID"

# ── scroll to show all blocks, screenshot bottom ──────────────────────────────
kitty @ --to "$SOCK" send-text --match "id:$WIN" "G"
sleep 0.3
"$H" snapshot "frame-buffer-bottom"
RAW2="$SHOT_DIR/frame-buffer-bottom.png"
GRID2="$SHOT_DIR/frame-buffer-bottom-grid.png"
python3 "$REPO/test/overlay_grid.py" "$RAW2" "$GRID2" >/dev/null
echo "Captured: $RAW2"
echo "Captured: $GRID2"

echo ""
echo "Screenshots in: $SHOT_DIR/"

if [ "${LCARCAT_KEEP_ALIVE:-1}" = "1" ]; then
    echo ""
    echo "Test kitty running. '$H teardown' to clean up."
fi
