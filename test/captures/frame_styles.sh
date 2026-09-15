#!/usr/bin/env bash
# Capture: frame styles the segment library can express.
#
# A left-facing bracket panel beside a right-facing one, plus a column of pills.
# Reference shot for the question "can we build the LCARS panel arrangements from
# the show" — the answer is visual, so this is a capture rather than an assertion.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
H="$REPO/test/screenshot_harness.sh"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/frame_styles}"
export LCARCAT_SHOT_DIR="$SHOT_DIR"

mkdir -p "$SHOT_DIR"
if [ -z "${LCARCAT_KEEP_ALIVE:-}" ]; then
  trap '"$H" teardown >/dev/null 2>&1 || true' EXIT INT TERM
fi

"$H" launch
sleep 1.5
"$H" send-text "cd $REPO && uv run --quiet --with pillow python -m dashboard.tools.frame_styles_demo --hold"$'\n'
sleep 4
"$H" snapshot "frame-styles"
"$H" send-text $'\x03'
