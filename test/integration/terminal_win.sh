#!/usr/bin/env bash
# Integration test: :LcarsTerm wires frame_buffer + pty_session + term_input (lcarcat-2z9)
# Pass/fail: real shell commands round-trip through the PTY and land in
# frame_buffer.blocks with the right state/command/exit_code; a second
# :LcarsTerm reuses the session instead of opening a new tab; closing a
# window tears down the PTY and lets a later :LcarsTerm open a fresh one.
#
# Acceptance criteria 3 (live ping + ^C) and 4 (scroll through multiple
# blocks) are visual/timing-heavy and are covered by screenshots only
# (human-evaluated), not hard assertions here.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/test/nvim_harness_helpers.sh"

H="$REPO/test/screenshot_harness.sh"
SOCK="${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/$(basename "${BASH_SOURCE[0]}" .sh)}"
export LCARCAT_SHOT_DIR="$SHOT_DIR"

CHECK_DIR="/tmp/lcarcat-terminal-win-checks"
rm -rf "$CHECK_DIR"
mkdir -p "$CHECK_DIR"

nvim_harness_setup "$H" "$SOCK" "$SHOT_DIR"

"$H" launch && sleep 1.5
WIN="$(kitty @ --to "$SOCK" ls | python3 -c '
import sys, json
d = json.load(sys.stdin)
for osw in d:
    for t in osw["tabs"]:
        for w in t["windows"]:
            print(w["id"])
' | tail -1)"

nvim_open "$SOCK" "$WIN"
nvim_check_messages "$SOCK" "$WIN" "term-win-baseline"

# dump_state LABEL — writes {tabs, cursor_at_end,
#   blocks:[{state,command,exit_code,line_count,cwd,chips:[kind...]}...]}
# to $CHECK_DIR/LABEL.json via lcars.frame_buffer's module-level block list.
# cursor_at_end checks the auto-scroll-to-bottom behavior: whatever window is
# currently showing frame_buffer.buf should have its cursor on the last line.
dump_state() {
  local label="$1"
  local lua="lua local fb=require(\"lcars.frame_buffer\"); local last=vim.api.nvim_buf_line_count(fb.buf); local win=vim.fn.bufwinid(fb.buf); local cursor_at_end=win~=-1 and vim.api.nvim_win_get_cursor(win)[1]==last; local d={tabs=#vim.api.nvim_list_tabpages(),cursor_at_end=cursor_at_end,blocks={}}; for i,b in ipairs(fb.blocks) do local ck={}; for j,c in ipairs(b.chips or {}) do ck[j]=c[3] or \"\" end; d.blocks[i]={state=b.state,command=b.command,exit_code=b.exit_code,line_count=b.line_count,cwd=b.cwd,chips=ck} end; vim.fn.writefile({vim.fn.json_encode(d)}, \"$CHECK_DIR/${label}.json\")"
  kitty @ --to "$SOCK" send-text --match "id:$WIN" ":$lua"$'\r'
  sleep 0.4
}

# submit_line TEXT — Esc (deterministic mode), i, TEXT, Esc, <CR> (term_input's
# normal-mode submit keymap). Explicit Esc before/after per the scripted-nvim
# gotchas in docs/test-harness.md — never rely on startinsert timing.
submit_line() {
  local text="$1"
  kitty @ --to "$SOCK" send-text --match "id:$WIN" $'\x1b'
  sleep 0.2
  kitty @ --to "$SOCK" send-text --match "id:$WIN" "i"
  sleep 0.2
  kitty @ --to "$SOCK" send-text --match "id:$WIN" "$text"
  sleep 0.2
  kitty @ --to "$SOCK" send-text --match "id:$WIN" $'\x1b'
  sleep 0.2
  kitty @ --to "$SOCK" send-text --match "id:$WIN" $'\r'
}

# ── open :LcarsTerm ──────────────────────────────────────────────────────────

nvim_run_cmd "$SOCK" "$WIN" "LcarsTerm"
# Cold start: the nested shell's first prompt draw is slow (kitty graphics +
# git segment probes on every precmd) — see docs/test-harness.md pty cold-start gotcha.
sleep 5.0
nvim_check_messages "$SOCK" "$WIN" "term-win-opened"

dump_state "00-opened"
if [[ "${LCARCAT_SKIP_SCREENSHOTS:-0}" != "1" ]]; then
  "$H" snapshot "01-opened"
fi

# ── success path: ls ─────────────────────────────────────────────────────────

submit_line "ls"
sleep 4.0
nvim_check_messages "$SOCK" "$WIN" "term-win-after-ls"
dump_state "01-after-ls"

# ── failure path: false ──────────────────────────────────────────────────────

submit_line "false"
sleep 4.0
nvim_check_messages "$SOCK" "$WIN" "term-win-after-false"
dump_state "02-after-false"
if [[ "${LCARCAT_SKIP_SCREENSHOTS:-0}" != "1" ]]; then
  "$H" snapshot "02-after-false"
fi

# ── reuse: second :LcarsTerm must not open a new tab ────────────────────────

nvim_run_cmd "$SOCK" "$WIN" "LcarsTerm"
sleep 0.5
nvim_check_messages "$SOCK" "$WIN" "term-win-reused"
dump_state "03-reused"

# ── cleanup: closing the current (input) window tears down the whole session ─

nvim_run_cmd "$SOCK" "$WIN" "close"
sleep 1.5
nvim_check_messages "$SOCK" "$WIN" "term-win-closed"
dump_state "04-after-close"

# ── reopen after cleanup: a fresh session must be possible, not stuck ───────

nvim_run_cmd "$SOCK" "$WIN" "LcarsTerm"
sleep 5.0
nvim_check_messages "$SOCK" "$WIN" "term-win-reopened"
dump_state "05-reopened"

# ── assertions ────────────────────────────────────────────────────────────────

set +e
python3 - "$CHECK_DIR" <<'PYEOF'
import json, sys, os

d = sys.argv[1]

def load(name):
    with open(os.path.join(d, f"{name}.json")) as f:
        return json.load(f)

failures = []

def check(cond, msg):
    if not cond:
        failures.append(msg)

opened = load("00-opened")
check(opened["tabs"] == 2, f"00-opened: expected 2 tabs, got {opened['tabs']}")
# Blocks open at OSC 133;C, not 133;A (lcarcat-ba0): sitting at a fresh prompt
# with nothing run yet must leave no frame on screen at all.
check(len(opened["blocks"]) == 0, f"00-opened: expected no blocks before any command runs, got {len(opened['blocks'])}")

after_ls = load("01-after-ls")
check(len(after_ls["blocks"]) >= 1, "01-after-ls: expected at least 1 block")
b1 = after_ls["blocks"][0]
check(b1["state"] == "done", f"01-after-ls: expected block 1 state=done, got {b1['state']}")
check(b1["command"] == "ls", f"01-after-ls: expected block 1 command='ls', got {b1['command']!r}")
check(b1["exit_code"] == 0, f"01-after-ls: expected block 1 exit_code=0, got {b1['exit_code']}")
check(b1["line_count"] >= 1, f"01-after-ls: expected block 1 line_count>=1, got {b1['line_count']}")
check(after_ls["cursor_at_end"], "01-after-ls: expected display window to auto-scroll to the last line")

# cwd hole chip: $HOME collapsed to "~" dynamically, never an absolute /Users path.
check(b1["cwd"], f"01-after-ls: expected a cwd on block 1, got {b1['cwd']!r}")
if b1["cwd"]:
    check(not b1["cwd"].startswith("/Users/"),
          f"01-after-ls: cwd should collapse $HOME to ~, got {b1['cwd']!r}")
    check(b1["cwd"].startswith("~") or not b1["cwd"].startswith("/home/"),
          f"01-after-ls: cwd should collapse $HOME to ~, got {b1['cwd']!r}")

# Chips arrive over OSC 7337 and are tagged with their kind. "err" must never be
# among them: precmd's exit code belongs to the previous command, so exit status
# is reported on the footer of its own block instead.
KNOWN = {"venv", "py", "aws", "awsdep", "git", "gitstate"}
check("err" not in b1["chips"], f"01-after-ls: header chips must not carry 'err', got {b1['chips']}")
check(all(k in KNOWN for k in b1["chips"]),
      f"01-after-ls: unexpected chip kind in {b1['chips']}")

after_false = load("02-after-false")
check(len(after_false["blocks"]) >= 2, "02-after-false: expected at least 2 blocks")
b2 = after_false["blocks"][1]
check(b2["state"] == "failed", f"02-after-false: expected block 2 state=failed, got {b2['state']}")
check(b2["command"] == "false", f"02-after-false: expected block 2 command='false', got {b2['command']!r}")
check(b2["exit_code"] == 1, f"02-after-false: expected block 2 exit_code=1, got {b2['exit_code']}")
# A failed block keeps normal chrome; the ERR chip on its footer is the signal.
check("err" not in b2["chips"], f"02-after-false: header chips must not carry 'err', got {b2['chips']}")

reused = load("03-reused")
check(reused["tabs"] == 2, f"03-reused: expected tabs to stay at 2 (session reused), got {reused['tabs']}")

after_close = load("04-after-close")
check(after_close["tabs"] == 1, f"04-after-close: expected tabs back to 1 (session torn down), got {after_close['tabs']}")

reopened = load("05-reopened")
check(reopened["tabs"] == 2, f"05-reopened: expected a fresh session to open (2 tabs), got {reopened['tabs']}")

if failures:
    print("FAIL:")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
else:
    print("PASS: all checks passed")
PYEOF
RESULT=$?
set -e

exit $RESULT
