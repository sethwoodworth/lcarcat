#!/usr/bin/env bash
# Capture: single-cell image vs plain bg cell side by side.
# Transmits a 1x1 periwinkle PNG via kitty graphics protocol, then renders:
#   [image cell] [plain periwinkle bg cell] [plain periwinkle bg cell]
# If image placement is flush with cell column 0, all three should have the
# same left edge. If the image is inset, the plain cells will appear wider.
#
# Uses test/fixtures/trivial_align_test.py (committed).

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
H="$REPO/test/screenshot_harness.sh"
FIXTURE_PY="$REPO/test/fixtures/trivial_align_test.py"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/trivial_image_alignment}"
export LCARCAT_SHOT_DIR="$SHOT_DIR"

mkdir -p "$SHOT_DIR"
trap '"$H" teardown >/dev/null 2>&1 || true' EXIT INT TERM

"$H" launch
sleep 1.5

"$H" send-text "python3 $FIXTURE_PY"$'\n'
sleep 1.5
"$H" snapshot "trivial-image-alignment"
