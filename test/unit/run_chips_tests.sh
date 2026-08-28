#!/usr/bin/env bash
# Headless unit tests for lcars.block_chips + frame_renderer chip fitting.
# Usage: bash test/unit/run_chips_tests.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --clean, not -u NONE: see the note in run_parser_tests.sh — -u NONE leaves
# ~/.config/nvim on 'runtimepath', which shadows the repo copy of lcars.*.
output=$(nvim --clean --headless \
  -c "lua package.path=package.path..';$REPO/nvim/lua/?.lua'" \
  -c "luafile $REPO/test/unit/block_chips_test.lua" 2>&1) || code=$?

echo "$output"

if [[ "${code:-0}" -ne 0 ]]; then
  echo "FAIL: nvim exited with code ${code:-0}"
  exit 1
fi

echo "PASS"
