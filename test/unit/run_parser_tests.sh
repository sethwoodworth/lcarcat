#!/usr/bin/env bash
# Headless unit tests for lcars.pty_session._parse_chunk
# Usage: bash test/unit/run_parser_tests.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

output=$(nvim --headless -u NONE \
  -c "lua package.path=package.path..';$REPO/nvim/lua/?.lua'" \
  -c "luafile $REPO/test/unit/pty_parser_test.lua" 2>&1) || code=$?

echo "$output"

if [[ "${code:-0}" -ne 0 ]]; then
  echo "FAIL: nvim exited with code ${code:-0}"
  exit 1
fi

echo "PASS"
