#!/usr/bin/env bash
# Scenario: side-by-side layout — nvim with a demo file on the left, command buffer on the right.
#
# Launch order:
#   1. Launch test kitty (full terminal, zsh shell in first window)
#   2. vsplit — creates a second full-height column beside the first (side-by-side)
#   3. Left column: launch nvim with demos/swoop_preview.sh
#   4. Right column: launch the nvim command buffer as a small hsplit at the bottom
#
# This ensures both columns are full-height before the command buffer is opened,
# avoiding the bug where splitting from inside the command buffer strip gives a
# partial-height split (lcarcat-vvw.1).
#
# Window IDs are captured immediately after each launch so that subsequent focus
# and send-text calls use stable id: matches, not recency-based recent: indices
# (recency order shifts on every focus/send, making recent: fragile).
#
# Evaluation criteria:
#   01-shell-vsplit           — two full-height columns, zsh shell in both (LCARS prompt visible)
#   02-nvim-demo-left         — left column: nvim with swoop_preview.sh; LCARS tabline chrome
#   03-cmd-buffer-right       — right column: shell above, command buffer strip at bottom
#   04-cmd-buffer-with-text   — text in command buffer; orange gutter distinct from left pane
#   05-nvim-pane-focused      — focus back on nvim; command buffer border/gutter goes muted
#
# Output: one PNG path per line. Screenshots persist in /tmp/lcarcat-screenshots/;
# the live test kitty is torn down on exit so no processes leak. Set
# LCARCAT_KEEP_ALIVE=1 to preserve the live kitty for manual inspection.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
H="$REPO/test/screenshot_harness.sh"
SOCK="${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}"
DEMO_FILE="$REPO/demos/swoop_preview.sh"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/$(basename "${BASH_SOURCE[0]}" .sh)}"
export LCARCAT_SHOT_DIR="$SHOT_DIR"

# Ensure the test kitty and its nvim/shell children die on normal exit, error,
# or interrupt — unless the user opts into keeping it for manual inspection.
if [ "${LCARCAT_KEEP_ALIVE:-0}" != "1" ]; then
    trap '"$H" teardown >/dev/null 2>&1 || true' EXIT INT TERM
fi

# Returns the kitty window id of the most recently focused window.
_newest_window_id() {
    kitty @ --to "$SOCK" ls 2>/dev/null | python3 -c "
import sys, json
tabs = json.load(sys.stdin)[0]['tabs']
windows = [w for t in tabs for w in t['windows']]
# most recent window is last in the recency list
recency = [w for w in windows if w.get('is_focused')]
if recency:
    print(recency[0]['id'])
    sys.exit(0)
# fallback: highest id
print(max(w['id'] for w in windows))
"
}

# Returns the kitty window id of the focused window.
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

# Step 1: initial shell is the left window — capture its id
WIN_LEFT="$(_focused_window_id)"

# vsplit launches a new window to the right; kitty focuses it automatically
kitty @ --to "$SOCK" launch --location=vsplit --bias=50 --cwd=current zsh
sleep 1.0
WIN_RIGHT="$(_focused_window_id)"

"$H" snapshot "01-shell-vsplit"

# Step 2: send nvim to the LEFT window by stable id; wait for prompt to settle first
# (sending before zsh prompt finishes renders readline markers into the input)
sleep 1.5
kitty @ --to "$SOCK" send-text --match "id:$WIN_LEFT" "nvim \"$DEMO_FILE\"\r"
sleep 3.0
"$H" snapshot "02-nvim-demo-left"

# Step 3: focus the RIGHT shell and hsplit the command buffer at the bottom
kitty @ --to "$SOCK" focus-window --match "id:$WIN_RIGHT"
sleep 0.3
kitty @ --to "$SOCK" launch \
  --location=hsplit --bias=6 --cwd=current \
  --env LCARCAT_COMMAND_BUFFER=1 \
  nvim \
    -c "set buftype=nofile bufhidden=hide noswapfile showtabline=0 laststatus=0" \
    -c "lua require('lcars.command_buffer')" \
    -c "startinsert"
sleep 3.0
WIN_CMD="$(_focused_window_id)"
"$H" snapshot "03-cmd-buffer-right"

# Step 4: type into the command buffer (it is focused)
kitty @ --to "$SOCK" send-text --match "id:$WIN_CMD" "git log --oneline -5"
sleep 0.4
"$H" snapshot "04-cmd-buffer-with-text"

# Step 5: return focus to nvim (left column)
kitty @ --to "$SOCK" focus-window --match "id:$WIN_LEFT"
sleep 0.3
"$H" snapshot "05-nvim-pane-focused"

echo "Screenshots preserved in $SHOT_DIR"
if [ "${LCARCAT_KEEP_ALIVE:-0}" = "1" ]; then
    echo "LCARCAT_KEEP_ALIVE=1 — test kitty left running for manual inspection." >&2
    echo "Run '$H teardown' to clean up." >&2
fi
# Teardown runs via the EXIT trap above (unless LCARCAT_KEEP_ALIVE=1).
