#!/usr/bin/env bash
# Scenario: frame_renderer visual test — render all three states in a scratch buffer.
#
# Writes a scratch buffer with three render_block calls (live, done, failed) and
# screenshots the result for visual inspection.
#
#   bash test/captures/frame_renderer.sh
#
# Set LCARCAT_KEEP_ALIVE=1 to leave the test kitty running.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/test/nvim_harness_helpers.sh"

H="$REPO/test/screenshot_harness.sh"
SOCK="${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/$(basename "${BASH_SOURCE[0]}" .sh)}"
export LCARCAT_SHOT_DIR="$SHOT_DIR"

nvim_harness_setup "$H" "$SOCK" "$SHOT_DIR"

"$H" launch
sleep 1.5
WIN="$(_nvim_focused_window_id "$SOCK")"
nvim_open "$SOCK" "$WIN"

# Escape the lua path for the ex command line
TEST_LUA="$REPO/test/captures/frame_renderer_test.lua"
nvim_run_cmd "$SOCK" "$WIN" "luafile $TEST_LUA"
sleep 2.0
# Hit Escape in case autocomplete or anything else grabbed focus
kitty @ --to "$SOCK" send-text --match "id:$WIN" $'\x1b'
sleep 0.5
nvim_check_messages "$SOCK" "$WIN" "frame-renderer"

"$H" snapshot "frame-renderer-all"
RAW="$SHOT_DIR/frame-renderer-all.png"
GRID="$SHOT_DIR/frame-renderer-all-grid.png"
python3 "$REPO/test/overlay_grid.py" "$RAW" "$GRID" >/dev/null
echo "Captured: $RAW"
echo "Captured: $GRID"

if [ "${LCARCAT_KEEP_ALIVE:-0}" = "1" ]; then
    echo "LCARCAT_KEEP_ALIVE=1 — test kitty running. '$H teardown' to clean up."
fi
