#!/usr/bin/env bash
# Headless unit tests for the zsh prompt data layer.
# Usage: bash test/unit/run_prompt_data_tests.sh
#
# Unlike the other unit suites this one needs no nvim: the data layer is plain
# zsh that emits bytes, which is the property the split was made to get.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if ! command -v zsh >/dev/null 2>&1; then
  echo "SKIP: zsh not found"
  exit 0
fi

output=$(zsh "$REPO/test/unit/prompt_data_test.zsh" 2>&1) || code=$?

echo "$output"

if [[ "${code:-0}" -ne 0 ]]; then
  echo "FAIL: zsh exited with code ${code:-0}"
  exit 1
fi

echo "PASS"
