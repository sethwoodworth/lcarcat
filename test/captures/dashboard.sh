#!/usr/bin/env bash
# Capture: the LCARS dashboard, one screenshot per layout.
#
# Reference shots for human evaluation, not an assertion — the questions this
# answers are "do the elbows meet their bars", "is the chrome inside its panel",
# "does the orrery read as a solar system", and none of those have a pass/fail
# the harness could compute.
#
# Runs each layout with --frames 1 so the dashboard paints once and exits,
# leaving the frame on screen for the snapshot. Pass a layout name to capture
# just that one.
#
#   bash test/captures/dashboard.sh                 # every layout
#   bash test/captures/dashboard.sh bridge          # one layout
#   LCARCAT_KEEP_ALIVE=1 bash test/captures/dashboard.sh bridge   # leave kitty up

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
H="$REPO/test/screenshot_harness.sh"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/dashboard}"
export LCARCAT_SHOT_DIR="$SHOT_DIR"

LAYOUTS=("$@")
if [ ${#LAYOUTS[@]} -eq 0 ]; then
  LAYOUTS=(bridge operations astrometrics stellar-cartography viewscreen)
fi

mkdir -p "$SHOT_DIR"
if [ -z "${LCARCAT_KEEP_ALIVE:-}" ]; then
  trap '"$H" teardown >/dev/null 2>&1 || true' EXIT INT TERM
fi

"$H" launch
sleep 1.5

for layout in "${LAYOUTS[@]}"; do
  # --hold is load-bearing. A dashboard that EXITS cannot be screenshotted
  # honestly: on the alternate screen the frame is torn down on the way out, and
  # on the normal screen the shell prompt printed afterwards scrolls the top rows
  # — including the outer frame's header bar — into scrollback before the capture
  # runs. --hold paints once and then waits, so what is captured is what a
  # running dashboard actually looks like.
  "$H" send-text "$REPO/dashboard/run.sh --layout $layout --frames 1 --hold"$'\n'
  # The first run of a layout generates any curve PNGs it needs, which is slower
  # than the redraw; give it room before capturing.
  sleep 4
  "$H" snapshot "layout-$layout"
  # Ctrl-C leaves the alternate screen and restores the shell for the next layout.
  "$H" send-text $'\x03'
  sleep 1
done
