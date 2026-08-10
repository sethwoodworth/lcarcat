#!/usr/bin/env bash
# Scenario: validate periwinkle gutter stem continues past end-of-buffer.
# Open a short file (~11 lines) in a tall nvim window; the gutter (line-number
# column) should remain periwinkle below line 11 all the way to the statusline.
#
# Evaluation:
#   semantic check — get_cell_grid.py reads kitty's terminal model to confirm
#                    nvim set the right bg color on gutter cells.
#   Row 0 (kitty tab bar) is outside the nvim window and is skipped.
#   Row N-1 (nvim statusline) is skipped via --skip-bottom 1.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
H="$REPO/test/screenshot_harness.sh"
FIXTURE="$REPO/test/fixtures/short_file.py"
SOCK="${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/$(basename "${BASH_SOURCE[0]}" .sh)}"
export LCARCAT_SHOT_DIR="$SHOT_DIR"

mkdir -p "$SHOT_DIR"
trap '"$H" teardown >/dev/null 2>&1 || true' EXIT INT TERM

"$H" launch
sleep 1.5

"$H" send-text "nvim $FIXTURE"$'\n'
sleep 2.0

"$H" snapshot "01-eob-gutter"

echo ""
echo "=== semantic check (kitty cell grid color) ==="
WIN_ID=$(kitty @ --to "$SOCK" ls 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
wins = []
for osw in d:
  for t in osw.get("tabs", []):
    for w in t.get("windows", []):
      wins.append(w["id"])
print(wins[-1]) if wins else sys.exit(1)
')
python3 "$REPO/test/get_cell_grid.py" \
  --socket "$SOCK" --window "$WIN_ID" \
  --col 0 --skip-rows 1 --skip-bottom 1 \
  --expect-bg periwinkle --verbose
