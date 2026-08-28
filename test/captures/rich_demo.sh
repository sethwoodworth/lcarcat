#!/usr/bin/env bash
# Scenario: rich README demo — 3-pane layout showing all major LCARS chrome.
#
# Layout (1600×900 window):
#
#   ┌──────────────────────┬────────────────────────────────────────────┐
#   │  LEFT TOP (40%)      │  RIGHT (60%)                               │
#   │  zsh shell           │  nvim: lcars.lua colorscheme source        │
#   │  - LCARS prompt bar  │  - orange/periwinkle/gold/lilac syntax     │
#   │  - bash history      │  - corner elbow, tabline, statusline       │
#   │  - scrollback stamps │  - periwinkle stem / gutter                │
#   ├──────────────────────┤                                            │
#   │  LEFT BOTTOM (6%)    │                                            │
#   │  nvim command buffer │                                            │
#   │  - orange gutter     │                                            │
#   │  - sample command    │                                            │
#   └──────────────────────┴────────────────────────────────────────────┘
#
# Tab 2 ("edit") is created before the main layout so the tab bar pill
# contrast (orange-active vs periwinkle-inactive) is visible throughout.
#
# Named shots (in order):
#   01-overview       — two shells side-by-side, tab bar visible from the start
#   02-shell-history  — left shell with ls/git scrollback + LCARS timestamps
#   03-nvim-chrome    — right nvim focused; tabline pill, corner elbow, statusline
#   04-cmd-buffer     — command buffer open; orange gutter + typed text
#   05-full-layout    — all panes, nvim focused; full layout (see 08 for README use)
#   06-tab-bar        — tab 2 active; orange-active vs periwinkle-inactive contrast
#   07-cmd-submit     — after submit; command output in left shell scrollback
#   08-hero           — canonical README hero: pane cleared and scrollback
#                       rebuilt AFTER the final split, so no prompt carries a
#                       stale pre-resize swoop bar
#
# Run:
#   bash test/scenarios/rich_demo.sh
#   LCARCAT_KEEP_ALIVE=1 bash test/scenarios/rich_demo.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
H="$REPO/test/screenshot_harness.sh"
SOCK="${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}"
DEMO_CONF="${LCARCAT_TEST_CONF:-$REPO/test/kitty_demo.conf}"
DEMO_FILE="$REPO/nvim/colors/lcars.lua"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/$(basename "${BASH_SOURCE[0]}" .sh)}"
export LCARCAT_SHOT_DIR="$SHOT_DIR"

if [ "${LCARCAT_KEEP_ALIVE:-0}" != "1" ]; then
    trap '"$H" teardown >/dev/null 2>&1 || true' EXIT INT TERM
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_at() { kitty @ --to "$SOCK" "$@"; }

_first_window_id() {
    _at ls 2>/dev/null | python3 -c "
import sys, json
tabs = json.load(sys.stdin)[0]['tabs']
windows = [w for t in tabs for w in t['windows']]
print(min(w['id'] for w in windows))
"
}

_wait() { sleep "${1:-1.0}"; }

# ---------------------------------------------------------------------------
# Launch — use the wide demo config
# ---------------------------------------------------------------------------

export LCARCAT_TEST_CONF="$DEMO_CONF"
"$H" launch
_wait 1.5

# The first (and only) window at launch is the shell.
# We use min-id rather than is_focused to avoid the focus-race.
WIN_SHELL="$(_first_window_id)"

# ---------------------------------------------------------------------------
# Create tab 2 now so the tab bar renders throughout every shot.
# new-tab creates a separate tab; new-window inside it gives the shell.
# Then immediately refocus the original shell in tab 1.
# ---------------------------------------------------------------------------

WIN_TAB2="$(_at launch --type=tab --tab-title "edit" --cwd=current zsh)"
_wait 0.8

_at focus-window --match "id:$WIN_SHELL"
_wait 0.5

# ---------------------------------------------------------------------------
# Build the 3-pane layout in tab 1:
#   vsplit 40/60: left shell | right shell (will become nvim)
#   hsplit left at 6%: command buffer strip at bottom
# ---------------------------------------------------------------------------

WIN_NVIM="$(_at launch --location=vsplit --bias=60 --cwd=current zsh)"
_wait 2.5

# shot 01: two shells side by side, tab bar showing both pills
"$H" snapshot "01-overview"

# Open nvim in the right pane with the colorscheme source
# -n: no swap file. A demo capture must never be able to hit nvim's
# "Found a swap file ... [O]pen Read-Only, (E)dit anyway" recovery modal, which
# blocks the pane with a dialog instead of showing the source. That happens
# whenever a previous run's nvim did not exit cleanly.
_at send-text --match "id:$WIN_NVIM" "nvim -n \"$DEMO_FILE\"\r"
_wait 3.5

# ---------------------------------------------------------------------------
# Left shell: build up realistic bash scrollback while nvim loads
# ---------------------------------------------------------------------------

_at focus-window --match "id:$WIN_SHELL"
_wait 0.4

# No pager, anywhere in this pane. Shot 07 submits `git log --oneline -5` from
# the command buffer without --no-pager, which leaves `less` sitting on the
# pane; every later keystroke then goes to the pager instead of the shell.
# ("ls -lh demos/" contains an `h`, which opens less's help screen — that is
# how this pane ended up showing pager documentation in the hero shot.) It also
# removes the bare "(END)" marker that showed up at the bottom of shots 05/07.
_at send-text --match "id:$WIN_SHELL" "export GIT_PAGER=cat PAGER=cat && clear\r"
_wait 0.8

_at send-text --match "id:$WIN_SHELL" "ls -lh demos/\r"
_wait 1.2
_at send-text --match "id:$WIN_SHELL" "git --no-pager log --oneline -5\r"
_wait 1.2
_at send-text --match "id:$WIN_SHELL" "ls assets/*.png | head -8\r"
_wait 1.0

"$H" snapshot "02-shell-history"

# ---------------------------------------------------------------------------
# shot 03: focus nvim — syntax highlights, tabline pill, statusline
# ---------------------------------------------------------------------------

_at focus-window --match "id:$WIN_NVIM"
_wait 2.0
"$H" snapshot "03-nvim-chrome"

# ---------------------------------------------------------------------------
# Open command buffer below the LEFT shell
# ---------------------------------------------------------------------------

_at focus-window --match "id:$WIN_SHELL"
_wait 0.3
WIN_CMD="$(_at launch \
  --location=hsplit --bias=6 --cwd=current \
  --env LCARCAT_COMMAND_BUFFER=1 \
  nvim \
    -c "set buftype=nofile bufhidden=hide noswapfile showtabline=0 laststatus=0" \
    -c "lua require('lcars.command_buffer')" \
    -c "startinsert")"
_wait 3.0

# Type a realistic command into the command buffer (not submitted yet)
_at send-text --match "id:$WIN_CMD" "git log --oneline -5"
_wait 0.4
"$H" snapshot "04-cmd-buffer"

# ---------------------------------------------------------------------------
# shot 05: focus nvim — all 3 panes + tab bar visible; hero shot
# ---------------------------------------------------------------------------

_at focus-window --match "id:$WIN_NVIM"
_wait 0.3
"$H" snapshot "05-full-layout"

# ---------------------------------------------------------------------------
# shot 06: switch to tab 2 — orange-active vs periwinkle-inactive pill contrast
# ---------------------------------------------------------------------------

_at focus-window --match "id:$WIN_TAB2"
_wait 0.8
_at send-text --match "id:$WIN_TAB2" "git --no-pager log --oneline -8\r"
_wait 1.5
"$H" snapshot "06-tab-bar"

# ---------------------------------------------------------------------------
# shot 07: return to tab 1, submit the command buffer; output in left shell
# ---------------------------------------------------------------------------

_at focus-window --match "id:$WIN_CMD"
_wait 0.5

# Escape to normal mode, Enter submits to the shell pane above
_at send-text --match "id:$WIN_CMD" $'\033'
_wait 0.3
_at send-text --match "id:$WIN_CMD" $'\r'
_wait 1.5
_at focus-window --match "id:$WIN_SHELL"
_wait 0.5
"$H" snapshot "07-cmd-submit"

# ---------------------------------------------------------------------------
# shot 08: clean hero — every prompt drawn at the FINAL pane width
#
# Shots 01-07 all carry stale swoop bars in the left pane's scrollback: the
# shell drew its first prompt at full window width, then the vsplit and the
# hsplit each resized that pane, and the elbow/cap PNGs on already-drawn
# prompts do not reflow (the known split-resize issue in ROADMAP.md). The
# result is a mangled bar at the top of the left pane — fine for regression
# shots, wrong for a README, where it advertises a bug as a feature.
#
# So: clear the pane once the layout is final, rebuild the scrollback, and
# shoot again. Every bar in this one was drawn at the width it is displayed at.
# ---------------------------------------------------------------------------

_at focus-window --match "id:$WIN_SHELL"
_wait 0.4

_at send-text --match "id:$WIN_SHELL" "clear\r"
_wait 0.8
_at send-text --match "id:$WIN_SHELL" "ls -lh demos/\r"
_wait 1.2
_at send-text --match "id:$WIN_SHELL" "git --no-pager log --oneline -5\r"
_wait 1.2
_at send-text --match "id:$WIN_SHELL" "ls assets/*.png | head -8\r"
_wait 1.2
_at focus-window --match "id:$WIN_NVIM"
_wait 0.5
"$H" snapshot "08-hero"

# ---------------------------------------------------------------------------
echo "Screenshots saved to $SHOT_DIR"
if [ "${LCARCAT_KEEP_ALIVE:-0}" = "1" ]; then
    echo "LCARCAT_KEEP_ALIVE=1 — kitty left running. '$H teardown' to clean up." >&2
fi
