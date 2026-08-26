#!/usr/bin/env bash
# Integration test: term_input.lua submits to a real PTY (lcarcat-lyz)
# Pass/fail: the command typed into the input buffer must actually execute
# in the PTY — proved by a marker file the shell writes on submit.
#
# terminal_win.lua (lcarcat-2z9) doesn't exist yet, so the fixture
# (term_input_test.lua) stands in for it: creates the split/buffer itself
# and wires on_submit = pty_session.send directly.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/test/nvim_harness_helpers.sh"

H="$REPO/test/screenshot_harness.sh"
SOCK="${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/$(basename "${BASH_SOURCE[0]}" .sh)}"
export LCARCAT_SHOT_DIR="$SHOT_DIR"

MARKER="/tmp/lcarcat-term-input-marker.txt"
rm -f "$MARKER"

nvim_harness_setup "$H" "$SOCK" "$SHOT_DIR"

"$H" launch && sleep 1.5
# Resolve the window by id, not focus: a detached kitty launched from a
# background/non-interactive context never receives real OS focus, so
# _nvim_focused_window_id (is_focused-based) returns nothing here. This test
# only ever has one window, so grabbing it directly is unambiguous.
WIN="$(kitty @ --to "$SOCK" ls | python3 -c '
import sys, json
d = json.load(sys.stdin)
for osw in d:
    for t in osw["tabs"]:
        for w in t["windows"]:
            print(w["id"])
' | tail -1)"

nvim_open "$SOCK" "$WIN"
nvim_run_cmd "$SOCK" "$WIN" "enew"

TEST_LUA="$REPO/test/integration/term_input_test.lua"
kitty @ --to "$SOCK" send-text --match "id:$WIN" ":luafile $TEST_LUA"$'\r'
sleep 1.5

nvim_check_messages "$SOCK" "$WIN" "term-input"

if [[ "${LCARCAT_SKIP_SCREENSHOTS:-0}" != "1" ]]; then
  "$H" snapshot "term-input-panel"
  RAW="$SHOT_DIR/term-input-panel.png"
  GRID="$SHOT_DIR/term-input-panel-grid.png"
  python3 "$REPO/test/overlay_grid.py" "$RAW" "$GRID" >/dev/null
  echo "Captured: $RAW"
  echo "Captured: $GRID"
fi

# Force Normal mode then explicitly enter Insert mode ourselves — don't rely
# on the fixture's own startinsert timing having landed by now.
kitty @ --to "$SOCK" send-text --match "id:$WIN" $'\x1b'   # Esc -> normal mode
sleep 0.2
kitty @ --to "$SOCK" send-text --match "id:$WIN" "i"        # enter insert mode
sleep 0.2
kitty @ --to "$SOCK" send-text --match "id:$WIN" "echo term-input-ok > $MARKER"
sleep 0.2
kitty @ --to "$SOCK" send-text --match "id:$WIN" $'\x1b'   # Esc -> normal mode
sleep 0.2
kitty @ --to "$SOCK" send-text --match "id:$WIN" $'\r'      # normal-mode <CR> -> submit
# The PTY's shell has a heavy custom LCARS prompt (kitty graphics per
# prompt draw) — cold start needs several seconds before it's draining
# PTY input, even though jobstart/chansend both return success immediately.
sleep 4.0

nvim_check_messages "$SOCK" "$WIN" "term-input-after-submit"
if [[ "${LCARCAT_SKIP_SCREENSHOTS:-0}" != "1" ]]; then
  "$H" snapshot "term-input-after-submit"
fi

set +e
[[ -f "$MARKER" ]] && grep -q "term-input-ok" "$MARKER"
RESULT=$?
set -e

if [[ $RESULT -eq 0 ]]; then
  echo "PASS: submitted command executed in the PTY (marker file written)"
else
  echo "FAIL: marker file $MARKER not found or content mismatch" >&2
  exit 1
fi
