#!/usr/bin/env bash
# Scenario: validate periwinkle gutter stem continues past end-of-buffer.
# Open a short file (~10 lines) in a tall nvim window; the gutter (line-number
# column) should remain periwinkle below line 10 all the way to the statusline.
#
# Evaluation criteria:
#   01-eob-gutter  — gutter bg should be continuous periwinkle (#9999ff) from
#                    line 1 to the bottom of the window; text area below the last
#                    line should be black (#000000)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
H="$REPO/test/screenshot_harness.sh"
FIXTURE="$REPO/test/fixtures/short_file.py"

mkdir -p /tmp/lcarcat-screenshots
trap '"$H" teardown >/dev/null 2>&1 || true' EXIT INT TERM

"$H" launch
sleep 1.5

"$H" send-text "nvim $FIXTURE"$'\n'
sleep 2.0

"$H" snapshot "01-eob-gutter"
