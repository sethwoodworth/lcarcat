#!/usr/bin/env bash
# Scenario: LCARS block frame style demos in a static scratch buffer.
#
# Opens nvim and runs :LcarsBlockDemo to render fake terminal output with
# LCARS header/stem/footer chrome. All blocks are visual-only — no live shell.
#
# Captures one screenshot per tab (A, A2, B, C, D, E, F, G).
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

# Tab names match the TABS table order in block_demo.lua
TAB_NAMES=(A A2 B C D E F G)

# ── launch ────────────────────────────────────────────────────────────────

"$H" launch
sleep 1.5
WIN="$(_nvim_focused_window_id "$SOCK")"

# Open nvim with no file — just the welcome screen / empty buffer.
nvim_open "$SOCK" "$WIN"

# Run the block demo renderer.
nvim_run_cmd "$SOCK" "$WIN" "lua require('lcars.block_demo').render_all()"
sleep 1.0

# ── nvim message check (abort if errors) ─────────────────────────────────

nvim_check_messages "$SOCK" "$WIN" "block-demo"

# ── screenshot each tab ───────────────────────────────────────────────────

TAB_COUNT=${#TAB_NAMES[@]}
# Demo tabs start at nvim tab index 2 — tab 1 is the initial [No Name] buffer.
for i in $(seq 1 "$TAB_COUNT"); do
    name="${TAB_NAMES[$((i-1))]}"
    nvim_goto_tab "$SOCK" "$WIN" "$((i+1))"
    sleep 1.0
    "$H" snapshot "tab-${i}-${name}"
    echo "Captured: $SHOT_DIR/tab-${i}-${name}.png"
done

# ── semantic check on tab A: look for periwinkle rows ────────────────────

echo ""
echo "=== scan tab A for periwinkle rows (LCARS header bars) ==="
nvim_goto_tab "$SOCK" "$WIN" 2
sleep 0.5
set +e
python3 "$REPO/test/get_cell_grid.py" \
    --socket "$SOCK" --window "$WIN" \
    --scan-bg periwinkle
SCAN_EXIT=$?
set -e

echo ""
echo "Screenshots in: $SHOT_DIR/"

if [ $SCAN_EXIT -ne 0 ]; then
    echo "WARNING: no periwinkle rows found on tab A — images may not be rendering or highlights missing"
fi

if [ "${LCARCAT_KEEP_ALIVE:-0}" = "1" ]; then
    echo ""
    echo "LCARCAT_KEEP_ALIVE=1 — test kitty running. '$H teardown' to clean up."
fi
