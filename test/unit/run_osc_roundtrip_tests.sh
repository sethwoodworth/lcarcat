#!/usr/bin/env bash
# Cross-language round-trip: the real zsh emitter's bytes, through the real lua
# parser.
#
# run_prompt_data_tests.sh proves the emitter produces the bytes IT thinks are
# right; run_parser_tests.sh proves the parser reads the bytes IT thinks are
# right. Both can pass while the two disagree — which is precisely the failure
# this whole split exists to make visible, since the emitter runs where nobody
# can see the payload and the parser runs where nobody can see the shell.
#
# So: emit from zsh, parse in nvim, compare. No hand-written wire strings on
# either side.
#
# Usage: bash test/unit/run_osc_roundtrip_tests.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if ! command -v zsh >/dev/null 2>&1; then
  echo "SKIP: zsh not found"
  exit 0
fi

WIRE=$(mktemp)
trap 'rm -f "$WIRE"' EXIT

# Labels chosen to exercise the escaping rules: a literal ";" (legal in a branch
# name), a literal "%", the "%3B" sequence that must survive as itself rather
# than decoding to ";", a space, and an empty label.
zsh -c '
  emulate -L zsh
  HOST=roundtrip
  source "'"$REPO"'/zsh/lcars_prompt_data.zsh"
  _lcars_emit_chips \
    venv     "lcarcat" \
    py       "py 3.12" \
    awsdep   "AWS|dep" \
    git      "feat;semi" \
    gitstate "02-MODIFIED" \
    err      "" \
    git      "100%done" \
    git      "%3B"
' >|"$WIRE"

# -c "qa!" as a trailing safety net: if the lua chunk errors before reaching its
# own qa!, headless nvim would otherwise sit there forever.
output=$(nvim --clean --headless \
  -c "lua package.path=package.path..';$REPO/nvim/lua/?.lua'" \
  -c "lua vim.g.lcars_wire_file='$WIRE'" \
  -c "luafile $REPO/test/unit/osc_roundtrip_test.lua" \
  -c "qa!" 2>&1) || code=$?

echo "$output"

if [[ "${code:-0}" -ne 0 ]]; then
  echo "FAIL: nvim exited with code ${code:-0}"
  exit 1
fi

echo "PASS"
