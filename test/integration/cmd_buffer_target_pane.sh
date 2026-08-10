#!/usr/bin/env bash
# Regression test: command buffer sends text to the correct pane (lcarcat-08g.1).
#
# Layout:
#   LEFT      — zsh shell, stays idle throughout
#   RIGHT     — zsh shell, spawns the command buffer
#   RIGHT-CMD — command buffer strip (hsplit at bottom of RIGHT)
#
# The bug: submit() used target_window_id() which returned the first sibling
# (LEFT), not the pane above the split (RIGHT). Fix uses neighbors.top.
#
# Pass/fail assertions (no human evaluation required):
#   PASS  — RIGHT pane text contains "MARKER_RIGHT" after submit
#   PASS  — LEFT pane text does NOT contain "MARKER_RIGHT" after submit
#   Screenshots are captured as supporting evidence but do not gate the result.
#
# Exit 0 = both assertions pass. Exit 1 = regression detected.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/test/nvim_harness_helpers.sh"

H="$REPO/test/screenshot_harness.sh"
SOCK="${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/cmd_buffer_target_pane}"
export LCARCAT_SHOT_DIR="$SHOT_DIR"

nvim_harness_setup "$H" "$SOCK" "$SHOT_DIR"

"$H" launch
sleep 1.5

WIN_LEFT="$(_nvim_focused_window_id "$SOCK")"

kitty @ --to "$SOCK" launch --location=vsplit --bias=50 --cwd=current zsh
sleep 1.0
WIN_RIGHT="$(_nvim_focused_window_id "$SOCK")"

"$H" snapshot "01-vsplit-baseline"

sleep 1.0
kitty @ --to "$SOCK" launch \
  --location=hsplit --bias=6 --cwd=current \
  --env LCARCAT_COMMAND_BUFFER=1 \
  nvim \
    -c "set buftype=nofile bufhidden=hide noswapfile showtabline=0 laststatus=0" \
    -c "lua require('lcars.command_buffer')" \
    -c "startinsert"
sleep 3.0
WIN_CMD="$(_nvim_focused_window_id "$SOCK")"

"$H" snapshot "02-cmd-buffer-from-right"

kitty @ --to "$SOCK" send-text --match "id:$WIN_CMD" "echo MARKER_RIGHT"
sleep 0.4
"$H" snapshot "03-cmd-buffer-with-text"

kitty @ --to "$SOCK" send-text --match "id:$WIN_CMD" $'\x1b'
sleep 0.3
kitty @ --to "$SOCK" send-text --match "id:$WIN_CMD" $'\r'
sleep 1.2
"$H" snapshot "04-after-submit"

# ── assertions ────────────────────────────────────────────────────────────────

RIGHT_TEXT=$(kitty @ --to "$SOCK" get-text --match "id:$WIN_RIGHT" 2>/dev/null || true)
LEFT_TEXT=$(kitty @ --to "$SOCK" get-text --match "id:$WIN_LEFT" 2>/dev/null || true)

PASS=1

if echo "$RIGHT_TEXT" | grep -q "MARKER_RIGHT"; then
    echo "PASS: MARKER_RIGHT found in RIGHT pane"
else
    echo "FAIL: MARKER_RIGHT not found in RIGHT pane" >&2
    echo "RIGHT pane content:" >&2
    echo "$RIGHT_TEXT" | tail -5 >&2
    PASS=0
fi

if echo "$LEFT_TEXT" | grep -q "MARKER_RIGHT"; then
    echo "FAIL: MARKER_RIGHT appeared in LEFT pane (routing bug)" >&2
    echo "LEFT pane content:" >&2
    echo "$LEFT_TEXT" | tail -5 >&2
    PASS=0
else
    echo "PASS: LEFT pane clean (no MARKER_RIGHT)"
fi

if [ "$PASS" -eq 0 ]; then
    echo "Screenshots in $SHOT_DIR" >&2
    exit 1
fi

echo "Screenshots in $SHOT_DIR"
