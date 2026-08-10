#!/usr/bin/env bash
# Integration test: gutter stays periwinkle after scrolling to end-of-file.
#
# Open a long file (60 lines, taller than the test window) in nvim.
# Navigate to the last line with G, then scroll it to the viewport top with zt.
# The EOB float must resize to cover exactly the visible EOB rows — all gutter
# cells (col 0, rows 1..N-2) must still be periwinkle.
#
# This is the minimal reproducer for the resize path of gutter_eob_fill.lua:
# initial open creates a full-window float; after G+zt, botline reaches the
# last buffer line and the float must shrink accordingly.
#
# Pass/fail: exits 0 if all gutter cells are periwinkle, 1 otherwise.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/test/nvim_harness_helpers.sh"

H="$REPO/test/screenshot_harness.sh"
FIXTURE="$REPO/test/fixtures/long_file.py"
SOCK="${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/nvim_eob_gutter_scrolled}"
export LCARCAT_SHOT_DIR="$SHOT_DIR"

nvim_harness_setup "$H" "$SOCK" "$SHOT_DIR"

"$H" launch
sleep 1.5
WIN="$(_nvim_focused_window_id "$SOCK")"

nvim_open "$SOCK" "$WIN" "$FIXTURE"
kitty @ --to "$SOCK" send-text --match "id:$WIN" "Gzt"
sleep 1.0

"$H" snapshot "01-eob-gutter-scrolled"

echo "=== semantic check: column 0 must be periwinkle after G+zt ==="
python3 "$REPO/test/get_cell_grid.py" \
  --socket "$SOCK" --window "$WIN" \
  --col 0 --skip-rows 1 --skip-bottom 1 \
  --expect-bg periwinkle --verbose
