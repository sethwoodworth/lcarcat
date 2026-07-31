#!/usr/bin/env bash
# Scenario: visual validation of command buffer LCARS theming.
# Prints one PNG path per line; a subagent should Read each to evaluate.
#
# Evaluation criteria:
#   01-shell-baseline        — periwinkle gutter, no split
#   02-cmd-buffer-open       — orange gutter in command buffer, periwinkle above
#   03-cmd-buffer-with-text  — same, with text in buffer
#   04-shell-focused-cmd-inactive — focus on shell; command buffer border goes muted

set -euo pipefail

H="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/screenshot_harness.sh"

mkdir -p /tmp/lcarcat-screenshots

# Always tear down the test kitty (and its nvim/shell children) when this
# scenario exits — normal, error, or interrupt. Screenshots on disk survive.
trap '"$H" teardown >/dev/null 2>&1 || true' EXIT INT TERM

"$H" launch
sleep 1.5

"$H" snapshot "01-shell-baseline"

"$H" launch-cmd-buffer
sleep 1.5

"$H" snapshot "02-cmd-buffer-open"

"$H" send-text "git log --oneline -5"
sleep 0.4
"$H" snapshot "03-cmd-buffer-with-text"

"$H" send-text $'\x1b'
sleep 0.2
"$H" focus-shell
sleep 0.3
"$H" snapshot "04-shell-focused-cmd-inactive"

# Teardown runs via the EXIT trap above.
