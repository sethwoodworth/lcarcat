#!/usr/bin/env bash
# Scenario: gutter stays periwinkle after scrolling to end-of-file.
#
# Open a long file (60 lines, taller than the test window) in nvim.
# Navigate to the last line with G, then scroll that line to the top of the
# viewport with zt. Now only a few EOB rows are visible below the last line —
# the float must resize to cover exactly those rows.
#
# This is the minimal reproducer for the resize path of gutter_eob_fill.lua:
# the initial open creates a full-window float; after scrolling, botline
# advances to the last buffer line and the float must shrink to match.
#
# Evaluation:
#   semantic check — get_cell_grid.py reads kitty's terminal model.
#   Row 0 (kitty tab bar) is outside the nvim window and is skipped.
#   Row N-1 (nvim statusline) is skipped via --skip-bottom 1.
#   Only EOB rows (below the last line of the file) are tested; content rows
#   above are also periwinkle by virtue of the normal statuscolumn setting, so
#   the whole visible gutter column must be periwinkle.
#
# Future unit-test intent:
#   This scenario is designed to translate directly into a headless nvim unit
#   test once the harness supports programmatic cell-grid assertions without a
#   running kitty. The assertions here (col 0, skip-rows 1, skip-bottom 1,
#   expect-bg periwinkle) are the spec.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
H="$REPO/test/screenshot_harness.sh"
FIXTURE="$REPO/test/fixtures/long_file.py"
SOCK="${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}"
SHOT_DIR="${LCARCAT_SHOT_DIR:-/tmp/lcarcat-screenshots}"

mkdir -p "$SHOT_DIR"
trap '"$H" teardown >/dev/null 2>&1 || true' EXIT INT TERM

"$H" launch
sleep 1.5

# Open file, go to last line (G), scroll it to viewport top (zt)
"$H" send-text "nvim $FIXTURE"$'\n'
sleep 2.0
"$H" send-text "Gzt"
sleep 1.0

"$H" snapshot "02-eob-gutter-scrolled"

echo ""
echo "=== semantic check: gutter periwinkle after G+zt ==="
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
