#!/usr/bin/env bash
# Scenario: command buffer sends text to the correct pane when launched from
# a non-leftmost kitty window (regression test for lcarcat-08g.1).
#
# Layout:
#   LEFT  — zsh shell, stays idle
#   RIGHT — zsh shell → launch command buffer (hsplit at bottom)
#   RIGHT-CMD — command buffer strip (focused)
#
# The bug was that submit() called target_window_id() which returned the first
# sibling in the tab (LEFT), not the pane directly above the split (RIGHT).
# The fix uses neighbors.top so the text always goes to the spawning pane.
#
# Evaluation criteria:
#   01-vsplit-baseline        — two full-height shells side by side
#   02-cmd-buffer-from-right  — RIGHT shell has command buffer strip at bottom;
#                               LEFT shell is untouched
#   03-cmd-buffer-with-text   — text staged in command buffer
#   04-after-submit           — RIGHT shell received the text; LEFT shell is blank
#
# The critical check is 04: "echo MARKER_RIGHT" should appear in the RIGHT shell
# and the LEFT shell should show no output.
#
# Output: one PNG path per line.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
H="$REPO/test/screenshot_harness.sh"
SOCK="${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/$(basename "${BASH_SOURCE[0]}" .sh)}"
export LCARCAT_SHOT_DIR="$SHOT_DIR"

if [ "${LCARCAT_KEEP_ALIVE:-0}" != "1" ]; then
    trap '"$H" teardown >/dev/null 2>&1 || true' EXIT INT TERM
fi

_focused_window_id() {
    kitty @ --to "$SOCK" ls 2>/dev/null | python3 -c "
import sys, json
tabs = json.load(sys.stdin)[0]['tabs']
for t in tabs:
    for w in t['windows']:
        if w.get('is_focused'):
            print(w['id']); sys.exit(0)
sys.exit(1)
"
}

"$H" launch
sleep 1.5

# Capture the initial left shell window id before any splits
WIN_LEFT="$(_focused_window_id)"

# Create a right shell via vsplit; kitty focuses it automatically
kitty @ --to "$SOCK" launch --location=vsplit --bias=50 --cwd=current zsh
sleep 1.0
WIN_RIGHT="$(_focused_window_id)"

"$H" snapshot "01-vsplit-baseline"

# Launch command buffer from the RIGHT pane (it is currently focused)
sleep 1.0
kitty @ --to "$SOCK" launch \
  --location=hsplit --bias=6 --cwd=current \
  --env LCARCAT_COMMAND_BUFFER=1 \
  nvim \
    -c "set buftype=nofile bufhidden=hide noswapfile showtabline=0 laststatus=0" \
    -c "lua require('lcars.command_buffer')" \
    -c "startinsert"
sleep 3.0
WIN_CMD="$(_focused_window_id)"

"$H" snapshot "02-cmd-buffer-from-right"

# Type a distinctive marker command into the command buffer
kitty @ --to "$SOCK" send-text --match "id:$WIN_CMD" "echo MARKER_RIGHT"
sleep 0.4
"$H" snapshot "03-cmd-buffer-with-text"

# Submit by pressing Escape (to enter normal mode) then Enter
kitty @ --to "$SOCK" send-text --match "id:$WIN_CMD" $'\x1b'
sleep 0.3
kitty @ --to "$SOCK" send-text --match "id:$WIN_CMD" $'\r'
sleep 1.2
"$H" snapshot "04-after-submit"

echo "Screenshots preserved in $SHOT_DIR"
if [ "${LCARCAT_KEEP_ALIVE:-0}" = "1" ]; then
    echo "LCARCAT_KEEP_ALIVE=1 — test kitty left running for manual inspection." >&2
    echo "Run '$H teardown' to clean up." >&2
fi
