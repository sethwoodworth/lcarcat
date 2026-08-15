#!/usr/bin/env bash
# Scenario: LCARS block frame style demos in a static scratch buffer.
#
# Opens nvim and runs :LcarsBlockDemo to render fake terminal output with
# LCARS header/stem/footer chrome. All blocks are visual-only — no live shell.
#
# Captures one screenshot per requested tab. With no args, captures all tabs
# (A A2 B C D E F G). With one arg, captures only that tab — useful when
# iterating on a single block type without regenerating unrelated screenshots.
#
#   bash test/captures/block_demo.sh          # all tabs
#   bash test/captures/block_demo.sh A        # only tab A
#
# Set LCARCAT_DEBUG_BG=1 to toggle DEBUG_BG mode before capturing. Highlights
# become: purple (#330033) = bar/stem territory, teal (#003333) = frame bg
# territory, black = terminal background (no highlight). Outputs -debug suffix
# screenshots alongside the normal set. Useful for diagnosing transparent image
# region geometry.
#
#   LCARCAT_DEBUG_BG=1 bash test/captures/block_demo.sh A
#
# Evaluation criteria:
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

# ── resolve requested tab set ────────────────────────────────────────────

REQUESTED_TAB="${1:-}"
if [ -n "$REQUESTED_TAB" ]; then
    tab_index=-1
    for i in "${!TAB_NAMES[@]}"; do
        if [ "${TAB_NAMES[$i]}" = "$REQUESTED_TAB" ]; then
            tab_index=$((i + 1))
            break
        fi
    done
    if [ $tab_index -lt 1 ]; then
        echo "ERROR: unknown tab '$REQUESTED_TAB'. Valid: ${TAB_NAMES[*]}" >&2
        exit 2
    fi
    TAB_INDICES=("$tab_index")
else
    TAB_INDICES=()
    for i in $(seq 1 "${#TAB_NAMES[@]}"); do
        TAB_INDICES+=("$i")
    done
fi

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

# ── optional: activate DEBUG_BG diagnostic mode ──────────────────────────

if [ "${LCARCAT_DEBUG_BG:-0}" = "1" ]; then
    echo "DEBUG_BG mode: purple=bar/stem, teal=frame-bg, black=no-highlight"
    nvim_run_cmd "$SOCK" "$WIN" "LcarsBlockDemoDebugBg"
    sleep 0.5
fi

# ── screenshot each requested tab ────────────────────────────────────────
#
# Demo tabs start at nvim tab index 2 — tab 1 is the initial [No Name] buffer.
for i in "${TAB_INDICES[@]}"; do
    name="${TAB_NAMES[$((i-1))]}"
    nvim_goto_tab "$SOCK" "$WIN" "$((i+1))"
    sleep 1.0
    if [ "${LCARCAT_DEBUG_BG:-0}" = "1" ]; then
        raw="$SHOT_DIR/tab-${i}-${name}-debug.png"
        grid="$SHOT_DIR/tab-${i}-${name}-debug-grid.png"
        "$H" snapshot "tab-${i}-${name}-debug"
    else
        raw="$SHOT_DIR/tab-${i}-${name}.png"
        grid="$SHOT_DIR/tab-${i}-${name}-grid.png"
        "$H" snapshot "tab-${i}-${name}"
    fi
    echo "Captured: $raw"
    # Regenerate the grid overlay so it can never lag the raw shot.
    python3 "$REPO/test/overlay_grid.py" "$raw" "$grid" >/dev/null
    echo "Captured: $grid"
done

echo ""
echo "Screenshots in: $SHOT_DIR/"

if [ "${LCARCAT_KEEP_ALIVE:-0}" = "1" ]; then
    echo ""
    echo "LCARCAT_KEEP_ALIVE=1 — test kitty running. '$H teardown' to clean up."
fi
