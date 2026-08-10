#!/usr/bin/env bash
# Scenario: visual validation of zsh prompt left-cell / elbow-stem alignment.
# Prints one PNG path per line; a subagent should Read each to evaluate.
#
# Evaluation criteria:
#   01-shell-baseline        — initial shell prompt, check elbow-to-first-cell alignment
#   02-multiline-entry       — PS2 continuation prompt visible during multi-line input
#   03-after-nop-execution   — prompt redrawn after executing a multi-line NOP command

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
H="$REPO/test/screenshot_harness.sh"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/$(basename "${BASH_SOURCE[0]}" .sh)}"
export LCARCAT_SHOT_DIR="$SHOT_DIR"

mkdir -p "$SHOT_DIR"

trap '"$H" teardown >/dev/null 2>&1 || true' EXIT INT TERM

"$H" launch
sleep 1.5

"$H" snapshot "01-shell-baseline"

# Type a multi-line NOP: `: \` then continuation lines, then execute
"$H" send-text ": \\"$'\n'
sleep 0.5
"$H" snapshot "02-multiline-entry"

"$H" send-text "  nothing \\"$'\n'
sleep 0.3
"$H" send-text "  nothing"$'\n'
sleep 0.8

"$H" snapshot "03-after-nop-execution"

# Teardown runs via the EXIT trap above.
