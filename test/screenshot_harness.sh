#!/usr/bin/env bash
# screenshot_harness.sh — launch and drive a test kitty instance for visual evaluation.
#
# Subcommands:
#   launch                  Start a detached test kitty instance
#   snapshot LABEL          Capture the kitty window to $SHOT_DIR/LABEL.png; prints path
#   launch-nvim-vsplit FILE Open nvim with FILE in a vsplit (left pane); focus goes to new window
#   launch-cmd-buffer       Open the nvim command buffer split (replicates ctrl+a>b)
#   send-text TEXT          Send text to the most recently focused window
#   focus-shell             Move focus to the first (shell) window
#   teardown                Close all windows and remove the socket

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCK="${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}"
SOCK_PATH="${SOCK#unix:}"
SHOT_DIR="${LCARCAT_SHOT_DIR:-/tmp/lcarcat-screenshots}"
TEST_CONF="$REPO/test/kitty_test.conf"

_kitty_at() { kitty @ --to "$SOCK" "$@"; }

_get_window_id() {
    _kitty_at ls 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data[0]['platform_window_id'])
"
}

cmd="${1:-}"

case "$cmd" in
  launch)
    kitty \
      --title=LCARCAT-TEST \
      --listen-on="$SOCK" \
      --config="$TEST_CONF" \
      --detach
    for i in $(seq 1 20); do
      [ -S "$SOCK_PATH" ] && break
      sleep 0.25
    done
    if [ ! -S "$SOCK_PATH" ]; then
      echo "ERROR: kitty socket never appeared at $SOCK_PATH" >&2
      exit 1
    fi
    mkdir -p "$SHOT_DIR"
    ;;

  snapshot)
    label="${2:-unlabeled}"
    win_id="$(_get_window_id)"
    if [ -z "$win_id" ]; then
      echo "ERROR: could not read platform_window_id from kitty @ ls" >&2
      exit 1
    fi
    sleep 0.4
    outfile="$SHOT_DIR/${label}.png"
    screencapture -l"$win_id" -x "$outfile"
    echo "$outfile"
    ;;

  launch-nvim-vsplit)
    file="${2:-}"
    _kitty_at launch \
      --location=vsplit --bias=50 --cwd=current \
      nvim "${file:+$file}"
    ;;

  launch-cmd-buffer)
    _kitty_at launch \
      --location=hsplit --bias=6 --cwd=current \
      --env LCARCAT_COMMAND_BUFFER=1 \
      nvim \
        -c "set buftype=nofile bufhidden=hide noswapfile showtabline=0 laststatus=0" \
        -c "lua require('lcars.command_buffer')" \
        -c "startinsert"
    ;;

  send-text)
    text="${2:-}"
    _kitty_at send-text --match "recent:0" "$text"
    ;;

  focus-shell)
    _kitty_at focus-window --match "recent:1"
    ;;

  remote)
    shift
    _kitty_at "$@"
    ;;

  teardown)
    _kitty_at close-window --all-windows 2>/dev/null || true
    rm -f "$SOCK_PATH"
    ;;

  *)
    echo "Usage: $0 {launch|snapshot LABEL|launch-nvim-vsplit [FILE]|launch-cmd-buffer|send-text TEXT|focus-shell|remote CMD...|teardown}" >&2
    exit 1
    ;;
esac
