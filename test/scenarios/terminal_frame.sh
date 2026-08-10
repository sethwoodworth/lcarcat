#!/usr/bin/env bash
# Scenario: LCARS swoop prompt inside a full-window nvim :terminal.
#
# Opens nvim, then switches the entire window to a :terminal buffer so the
# LCARS zsh prompt renders inside nvim without any splits.
# This exercises the _lcars_graphics_ok nvim-terminal arm:
#   [[ -n $KITTY_WINDOW_ID && -n $NVIM ]]
#
# Semantic check: scan the full grid for periwinkle rows to locate the
# LCARS swoop bar, then assert those rows are present.
#
# Set LCARCAT_KEEP_ALIVE=1 to leave the test kitty running.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/test/nvim_harness_helpers.sh"

H="$REPO/test/screenshot_harness.sh"
SOCK="${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}"
SHOT_DIR="${LCARCAT_SHOT_DIR:-/tmp/lcarcat-screenshots}"

nvim_harness_setup "$H" "$SOCK" "$SHOT_DIR"

# ── launch ────────────────────────────────────────────────────────────────

"$H" launch
sleep 1.5
WIN="$(_nvim_focused_window_id "$SOCK")"

# Open nvim and immediately enter a full-window terminal buffer.
nvim_open "$SOCK" "$WIN"

# :terminal opens a terminal buffer in the current window (full-window, no split).
nvim_run_cmd "$SOCK" "$WIN" "terminal"
sleep 2.0

"$H" snapshot "01-nvim-terminal-full"

# ── semantic checks ───────────────────────────────────────────────────────

echo ""
echo "=== scan for periwinkle rows (LCARS swoop bar location) ==="
python3 "$REPO/test/get_cell_grid.py" \
    --socket "$SOCK" --window "$WIN" \
    --scan-bg periwinkle

echo ""
echo "=== full grid dump of first 5 rows for diagnosis ==="
for ROW in 0 1 2 3 4; do
    echo "--- row $ROW ---"
    python3 "$REPO/test/get_cell_grid.py" \
        --socket "$SOCK" --window "$WIN" \
        --row "$ROW" --verbose 2>&1 | tail -8
done

echo ""
echo "Screenshot: $SHOT_DIR/01-nvim-terminal-full.png"

if [ "${LCARCAT_KEEP_ALIVE:-0}" = "1" ]; then
    echo ""
    echo "LCARCAT_KEEP_ALIVE=1 — test kitty running. '$H teardown' to clean up."
fi
