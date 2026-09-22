#!/usr/bin/env bash
# Sourced, not run. Builds an ISOLATED kitty config directory for the custom tab
# bar: the repo's tab_bar.py, the repo's theme, and a test kitty.conf that
# includes the theme from that directory rather than the deployed one.
#
# kitty resolves `tab_bar.py` relative to its config directory, so pointing
# KITTY_CONFIG_DIRECTORY here runs the working-tree tab bar without deploying
# it — a tab_bar.py that raises takes the strip down in every kitty window that
# loaded it, including the one being worked in.
#
#   build_tab_bar_config_directory DIRECTORY

build_tab_bar_config_directory() {
  local directory="$1"
  local repo
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  rm -rf "$directory"
  mkdir -p "$directory"
  cp "$repo/kitty/tab_bar.py" "$directory/tab_bar.py"
  cp "$repo/kitty/lcars.conf" "$directory/lcars.conf"
  sed 's|^include .*/lcars\.conf$|include lcars.conf|' \
    "$repo/test/kitty_test.conf" > "$directory/kitty.conf"
}
