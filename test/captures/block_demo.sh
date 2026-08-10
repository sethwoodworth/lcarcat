#!/usr/bin/env bash
# Scenario: LCARS block frame style demos in a static scratch buffer.
#
# Opens nvim and runs :LcarsBlockDemo to render fake terminal output with
# LCARS header/stem/footer chrome. All blocks are visual-only — no live shell.
#
# Evaluation criteria:
#   header_bar  — periwinkle rows present (block A header should appear)
#   no_errors   — nvim messages clean before screenshot
#
# Set LCARCAT_KEEP_ALIVE=1 to leave the test kitty running for inspection.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/test/nvim_harness_helpers.sh"

H="$REPO/test/screenshot_harness.sh"
SOCK="${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/$(basename "${BASH_SOURCE[0]}" .sh)}"
export LCARCAT_SHOT_DIR="$SHOT_DIR"

nvim_harness_setup "$H" "$SOCK" "$SHOT_DIR"

# ── launch ────────────────────────────────────────────────────────────────

"$H" launch
sleep 1.5
WIN="$(_nvim_focused_window_id "$SOCK")"

# Open nvim with no file — just the welcome screen / empty buffer.
nvim_open "$SOCK" "$WIN"

# Run the block demo renderer.
nvim_run_cmd "$SOCK" "$WIN" "lua require('lcars.block_demo').render()"
sleep 0.5

# ── nvim message check (abort if errors) ─────────────────────────────────

nvim_check_messages "$SOCK" "$WIN" "block-demo"

# ── screenshot ────────────────────────────────────────────────────────────

"$H" snapshot "01-block-demo"

# ── semantic check: look for periwinkle rows ──────────────────────────────

echo ""
echo "=== scan for periwinkle rows (LCARS header bars) ==="
set +e
python3 "$REPO/test/get_cell_grid.py" \
    --socket "$SOCK" --window "$WIN" \
    --scan-bg periwinkle
SCAN_EXIT=$?
set -e

echo ""
echo "Screenshot: $SHOT_DIR/01-block-demo.png"

if [ $SCAN_EXIT -ne 0 ]; then
    echo "WARNING: no periwinkle rows found — images may not be rendering or highlights missing"
fi

if [ "${LCARCAT_KEEP_ALIVE:-0}" = "1" ]; then
    echo ""
    echo "LCARCAT_KEEP_ALIVE=1 — test kitty running. '$H teardown' to clean up."
fi
