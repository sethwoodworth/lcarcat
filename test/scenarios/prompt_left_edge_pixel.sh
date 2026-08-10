#!/usr/bin/env bash
# Scenario: capture left-edge pixel data for prompt alignment diagnosis.
# Executes a NOP command so the STARDATE line appears, then screenshots.
# Prints the PNG path; a pixel analysis script reads it.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
H="$REPO/test/screenshot_harness.sh"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/$(basename "${BASH_SOURCE[0]}" .sh)}"
export LCARCAT_SHOT_DIR="$SHOT_DIR"

mkdir -p "$SHOT_DIR"
trap '"$H" teardown >/dev/null 2>&1 || true' EXIT INT TERM

"$H" launch
sleep 2.0

# Execute a NOP so preexec fires and the STARDATE line appears.
"$H" send-text $':\n'
sleep 1.0

"$H" snapshot "prompt-left-edge"
