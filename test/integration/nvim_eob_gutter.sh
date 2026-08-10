#!/usr/bin/env bash
# Integration test: periwinkle gutter stem continues past end-of-buffer.
# Open a short file (~11 lines) in a tall nvim window; the gutter (line-number
# column) must remain periwinkle below line 11 all the way to the statusline.
#
# Pass/fail: exits 0 if all gutter cells are periwinkle, 1 otherwise.
# The semantic check uses kitty's terminal model — no screenshot timing risk.
#
# Skips:
#   row 0  — kitty tab bar (outside nvim)
#   row N-1 — nvim statusline (--skip-bottom 1)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/test/nvim_harness_helpers.sh"

H="$REPO/test/screenshot_harness.sh"
FIXTURE="$REPO/test/fixtures/short_file.py"
SOCK="${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/nvim_eob_gutter}"
export LCARCAT_SHOT_DIR="$SHOT_DIR"

nvim_harness_setup "$H" "$SOCK" "$SHOT_DIR"

"$H" launch
sleep 1.5
WIN="$(_nvim_focused_window_id "$SOCK")"

nvim_open "$SOCK" "$WIN" "$FIXTURE"

"$H" snapshot "01-eob-gutter"

echo "=== semantic check: column 0 must be periwinkle ==="
python3 "$REPO/test/get_cell_grid.py" \
  --socket "$SOCK" --window "$WIN" \
  --col 0 --skip-rows 1 --skip-bottom 1 \
  --expect-bg periwinkle --verbose
