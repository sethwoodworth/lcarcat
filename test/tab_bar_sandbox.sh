#!/usr/bin/env bash
# Sandbox: open the working-tree tab bar in a separate, throwaway kitty — a
# normal window with a few tabs, no screenshots — so tab_bar.py can be tried by
# hand without deploying it or restarting the kitty being worked in.
#
# A running kitty caches the tab_bar module, so an edit only shows up in a fresh
# kitty. Running this again kills the previous sandbox and opens a new one from
# the current working tree; that is the edit loop.
#
#   bash test/tab_bar_sandbox.sh         # open (or reopen) with 3 tabs
#   bash test/tab_bar_sandbox.sh 10      # open with 10 tabs
#   bash test/tab_bar_sandbox.sh stop    # close the sandbox
#
# Everything lives under its own state directory, so it does not collide with
# the screenshot harness or test/captures/tab_bar.sh.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${LCARCAT_TAB_BAR_SANDBOX_DIR:-/tmp/lcarcat-tab-bar-sandbox}"
CONFIG_DIR="$STATE_DIR/config"
INSTANCE_FILE="$STATE_DIR/instance"

# Every launch listens on a socket of its own. With one fixed socket, an old
# instance that survived its close still owns the path and the new kitty cannot
# listen on it.
SOCKET_PREFIX="unix:$STATE_DIR/kitty-"

sandbox_pids() {
  pgrep -f "kitty.*--listen-on=$SOCKET_PREFIX" 2>/dev/null || true
}

# Kill by pid rather than asking kitty to close its windows: on macOS kitty
# stays running after its last window closes. Waits until the process is gone,
# so a relaunch never races the old instance. Also sweeps up any sandbox kitty
# whose pid was never recorded.
stop_sandbox() {
  local pids pid
  pids="$(sandbox_pids)"
  [ -n "$pids" ] || { rm -f "$STATE_DIR"/kitty-*.sock "$INSTANCE_FILE"; return 0; }
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null || true
  for _ in $(seq 1 30); do
    [ -n "$(sandbox_pids)" ] || break
    sleep 0.1
  done
  for pid in $(sandbox_pids); do
    kill -KILL "$pid" 2>/dev/null || true
  done
  for _ in $(seq 1 20); do
    [ -n "$(sandbox_pids)" ] || break
    sleep 0.1
  done
  if [ -n "$(sandbox_pids)" ]; then
    echo "ERROR: sandbox kitty still running: $(sandbox_pids | tr '\n' ' ')" >&2
    return 1
  fi
  rm -f "$STATE_DIR"/kitty-*.sock "$INSTANCE_FILE"
}

argument="${1:-3}"

if [ "$argument" = "stop" ]; then
  stop_sandbox
  exit 0
fi

if ! [[ "$argument" =~ ^[1-9][0-9]*$ ]]; then
  echo "Usage: $0 [TAB_COUNT|stop]" >&2
  exit 1
fi
tab_count="$argument"

stop_sandbox

mkdir -p "$STATE_DIR"
# shellcheck source=test/tab_bar_config.sh
source "$REPO/test/tab_bar_config.sh"
build_tab_bar_config_directory "$CONFIG_DIR"

socket="${SOCKET_PREFIX}$$.sock"
socket_path="${socket#unix:}"

# --listen-on=VALUE (not a separate argument): sandbox_pids matches exactly that
# form on the command line.
KITTY_CONFIG_DIRECTORY="$CONFIG_DIR" kitty \
  --title=LCARCAT-TAB-BAR-SANDBOX \
  --listen-on="$socket" \
  --config="$CONFIG_DIR/kitty.conf" \
  --directory="$REPO" \
  --detach

for _ in $(seq 1 20); do
  [ -S "$socket_path" ] && break
  sleep 0.25
done
if [ ! -S "$socket_path" ]; then
  echo "ERROR: sandbox kitty socket never appeared at $socket_path" >&2
  exit 1
fi

echo "$(sandbox_pids | head -n1) $socket" > "$INSTANCE_FILE"

# Extra tabs cycle through real directories rather than fixed --tab-title
# values, so the titles go through the tab bar's own rewriting.
directories=("$REPO/kitty" "$REPO/test" "$REPO/docs" "/tmp" "$HOME")
for ((index = 1; index < tab_count; index++)); do
  directory="${directories[$(((index - 1) % ${#directories[@]}))]}"
  kitty @ --to "$socket" launch --type=tab --cwd="$directory" >/dev/null
done

echo "tab bar sandbox up with $tab_count tab(s) on $socket"
echo "re-run to reload after editing kitty/tab_bar.py; '$0 stop' to close"
