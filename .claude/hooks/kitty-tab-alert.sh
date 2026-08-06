#!/usr/bin/env zsh
# kitty-tab-alert.sh — visual indicator in kitty tab bar when Claude needs attention.
#
# Wired into Claude Code hooks:
#   Notification  → set prefix when notification_type is permission_prompt or idle_prompt
#   Stop          → clear prefix when Claude finishes a turn
#   UserPromptSubmit → clear prefix when user submits a reply
#
# Approach: prefix the tab title with an alert symbol inside the existing LCARS
# pill. No color changes — set-tab-color breaks the half-circle cap rendering.
#
# Requires: kitty with allow_remote_control, KITTY_LISTEN_ON env var set.
# Reads hook JSON from stdin.
#
# ALTERNATIVE: if you switch to a custom draw-tab-title kitten (Python), this
# script becomes unnecessary — the kitten can read a flag file or env var and
# draw its own indicator glyph without the remote-control round-trip.
# See: https://sw.kovidgoyal.net/kitty/tab_bar/

set -euo pipefail

[[ -z "${KITTY_LISTEN_ON:-}" ]] && exit 0
[[ -z "${KITTY_WINDOW_ID:-}" ]] && exit 0

# Read stdin (hook JSON payload)
input=$(cat)

event=$(printf '%s' "$input" | jq -r '.hook_event_name // ""' 2>/dev/null)
ntype=$(printf '%s' "$input" | jq -r '.notification_type // ""' 2>/dev/null)

# Resolve the tab ID that owns this window
tab_id=$(kitty @ --to "$KITTY_LISTEN_ON" ls 2>/dev/null \
  | jq --argjson wid "$KITTY_WINDOW_ID" -r \
    '.[].tabs[] | select(any(.windows[]; .id == $wid)) | .id | tostring' \
  | head -1)

[[ -z "$tab_id" ]] && exit 0

# Current tab title (reflects what the process last set via OSC 0/2)
current_title=$(kitty @ --to "$KITTY_LISTEN_ON" ls 2>/dev/null \
  | jq --argjson tid "$tab_id" -r \
    '.[].tabs[] | select(.id == ($tid | tonumber)) | .title' \
  | head -1)

_set_alert() {
  local symbol="$1"
  # Only prefix if not already prefixed
  if [[ "$current_title" != "$symbol "* ]]; then
    kitty @ --to "$KITTY_LISTEN_ON" set-tab-title \
      --match "id:$tab_id" "$symbol ${current_title}"
  fi
}

_clear_alert() {
  # Strip any leading alert symbol (any single non-space char followed by space)
  local stripped
  stripped="${current_title}"
  if [[ "$stripped" =~ $'^[^ ] (.*)$' ]]; then
    kitty @ --to "$KITTY_LISTEN_ON" set-tab-title \
      --match "id:$tab_id" "${match[1]}"
    # Yield control back to the process title after a moment
    sleep 0.3
    kitty @ --to "$KITTY_LISTEN_ON" set-tab-title \
      --match "id:$tab_id" ""
  else
    kitty @ --to "$KITTY_LISTEN_ON" set-tab-title \
      --match "id:$tab_id" ""
  fi
}

case "$event" in
  Notification)
    case "$ntype" in
      permission_prompt)   _set_alert "◉" ;;
      idle_prompt)         _set_alert "▸" ;;
      agent_needs_input)   _set_alert "▸" ;;
    esac
    ;;
  Stop|UserPromptSubmit)
    _clear_alert
    ;;
esac

exit 0
