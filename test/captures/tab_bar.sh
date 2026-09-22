#!/usr/bin/env bash
# Capture: the LCARS custom tab bar, with several tabs open.
#
# Runs against an ISOLATED kitty config directory built from the repo, not the
# deployed one. kitty resolves `tab_bar.py` relative to its config directory, so
# testing the strip against ~/.config would mean deploying an untested tab_bar.py
# into the live setup first — and a tab_bar.py that raises takes the tab bar down
# in every kitty window, including the one being worked in.
#
#   bash test/captures/tab_bar.sh
#   LCARCAT_KEEP_ALIVE=1 bash test/captures/tab_bar.sh   # leave kitty up
#
# To try the tab bar by hand, without screenshots: test/tab_bar_sandbox.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
H="$REPO/test/screenshot_harness.sh"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/tab_bar}"
CONFIG_DIR="${LCARCAT_TAB_BAR_CONFIG_DIR:-/tmp/lcarcat-tab-bar-config}"

export LCARCAT_SHOT_DIR="$SHOT_DIR"
mkdir -p "$SHOT_DIR"

# shellcheck source=test/tab_bar_config.sh
source "$REPO/test/tab_bar_config.sh"
build_tab_bar_config_directory "$CONFIG_DIR"

export KITTY_CONFIG_DIRECTORY="$CONFIG_DIR"
export LCARCAT_TEST_CONF="$CONFIG_DIR/kitty.conf"

if [ -z "${LCARCAT_KEEP_ALIVE:-}" ]; then
  trap '"$H" teardown >/dev/null 2>&1 || true' EXIT INT TERM
fi

"$H" launch
sleep 1.5

"$H" snapshot "tab-bar-01-single"

# A second and third tab, so inactive pills, the separators between them, and the
# right-aligned status readout are all exercised at once.
kitty @ --to "${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}" \
  launch --type=tab --tab-title=NEPTUNE >/dev/null
sleep 1.2
"$H" snapshot "tab-bar-02-two-tabs"

kitty @ --to "${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}" \
  launch --type=tab --tab-title=LONG-RUNNING-PROCESS-NAME >/dev/null
sleep 1.2
"$H" snapshot "tab-bar-03-three-tabs"

echo "tab bar shots in $SHOT_DIR"
