#!/usr/bin/env bash
# Scenario: capture left-edge pixel data for prompt alignment diagnosis.
# Executes a NOP command so the STARDATE line appears, then screenshots.
# Prints the PNG path; a pixel analysis script reads it.

set -euo pipefail

H="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/screenshot_harness.sh"

mkdir -p /tmp/lcarcat-screenshots
trap '"$H" teardown >/dev/null 2>&1 || true' EXIT INT TERM

"$H" launch
sleep 2.0

# Execute a NOP so preexec fires and the STARDATE line appears.
"$H" send-text $':\n'
sleep 1.0

"$H" snapshot "prompt-left-edge"
