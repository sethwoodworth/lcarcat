#!/usr/bin/env bash
# Integration test: alternate-screen passthrough (lcarcat-biv)
#
# Pass/fail: running a full-screen program inside :LcarsTerm puts a terminal
# emulator float on top of the frame, shows the program's real screen, hands it
# keystrokes, and returns cleanly to the frame when it restores the primary
# screen — leaving an empty block (header + footer, no content lines) behind.
# The escape hatch, :LcarsTermExitAlternateScreen, gets the frame back from a
# program that never restores it.
#
# Whether the frame's elbow/cap PNGs stop painting over the program is a
# rendering question, not a state question — that is a screenshot check,
# evaluated by the visual-inspector subagent, not asserted here.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/test/nvim_harness_helpers.sh"

H="$REPO/test/screenshot_harness.sh"
SOCK="${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/$(basename "${BASH_SOURCE[0]}" .sh)}"
export LCARCAT_SHOT_DIR="$SHOT_DIR"

CHECK_DIR="/tmp/lcarcat-alternate-screen-checks"
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
nvim_check_messages "$SOCK" "$WIN" "alternate-screen-baseline"

# dump_state LABEL — writes {active, floats, display_shows_frame, blocks:[...]}
# to $CHECK_DIR/LABEL.json.
#   active             lcars.alternate_screen.active() — is the emulator float up
#   floats             count of floating windows in the current tab
#   display_shows_frame is some window still showing frame_buffer.buf (the float
#                      must cover the frame, never replace it)
dump_state() {
  local label="$1"
  local lua="lua local fb=require(\"lcars.frame_buffer\"); local a=require(\"lcars.alternate_screen\"); local floats=0; for _,w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do if vim.api.nvim_win_get_config(w).relative~=\"\" then floats=floats+1 end end; local d={active=a.active(),floats=floats,display_shows_frame=vim.fn.bufwinid(fb.buf)~=-1,blocks={}}; for i,b in ipairs(fb.blocks) do d.blocks[i]={state=b.state,command=b.command,exit_code=b.exit_code,line_count=b.line_count} end; vim.fn.writefile({vim.fn.json_encode(d)}, \"$CHECK_DIR/${label}.json\")"
  kitty @ --to "$SOCK" send-text --match "id:$WIN" ":$lua"$'\r'
  sleep 0.4
}

# submit_line TEXT — Esc, i, TEXT, Esc, <CR>. Explicit mode changes per the
# scripted-nvim gotchas in docs/test-harness.md — never rely on startinsert
# timing.
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

# While the alternate-screen float is focused, every keystroke goes to the
# full-screen program — including ":". Drop to normal mode before driving nvim
# with an Ex command, and go back to terminal mode before typing at the program.
# Leaving terminal mode does not close the float; it only changes nvim's mode.
leave_terminal_mode() {
  kitty @ --to "$SOCK" send-text --match "id:$WIN" $'\x1c\x0e'  # <C-\><C-n>
  sleep 0.3
}

enter_terminal_mode() {
  kitty @ --to "$SOCK" send-text --match "id:$WIN" "i"
  sleep 0.3
}

# ── open :LcarsTerm ──────────────────────────────────────────────────────────

nvim_run_cmd "$SOCK" "$WIN" "LcarsTerm"
# Cold start: the nested shell's first prompt draw is slow — see
# docs/test-harness.md pty cold-start gotcha.
sleep 5.0
nvim_check_messages "$SOCK" "$WIN" "alternate-screen-opened"
dump_state "00-opened"

# ── a pager takes the screen ────────────────────────────────────────────────

submit_line "LESS= less README.md"
sleep 3.0
kitty @ --to "$SOCK" get-text --match "id:$WIN" > "$CHECK_DIR/01-in-pager.txt"
leave_terminal_mode
dump_state "01-in-pager"
if [[ "${LCARCAT_SKIP_SCREENSHOTS:-0}" != "1" ]]; then
  "$H" snapshot "01-in-pager"
fi

# ── quitting it returns to the frame ────────────────────────────────────────
# "q" goes straight to the program, not to nvim — that round-trip through
# on_input → chansend is exactly what is under test.

enter_terminal_mode
kitty @ --to "$SOCK" send-text --match "id:$WIN" "q"
sleep 3.0
dump_state "02-after-pager"
kitty @ --to "$SOCK" get-text --match "id:$WIN" > "$CHECK_DIR/02-after-pager.txt"
nvim_check_messages "$SOCK" "$WIN" "alternate-screen-after-pager"
if [[ "${LCARCAT_SKIP_SCREENSHOTS:-0}" != "1" ]]; then
  "$H" snapshot "02-after-pager"
fi

# ── an ordinary command still works afterwards ──────────────────────────────
# The parser has to be back in text mode, not stuck swallowing bytes.

submit_line "echo back-in-the-frame"
sleep 4.0
dump_state "03-after-echo"

# ── exit codes survive a passthrough round-trip ─────────────────────────────
# A synthetic program instead of a real one: the exit code is chosen rather
# than hoped for, and no keystroke is needed to make it quit.

FIXTURE="$REPO/test/fixtures/alternate_screen_program.sh"

submit_line "$FIXTURE 0"
sleep 7
dump_state "04-fixture-exit-0"

submit_line "$FIXTURE 3"
sleep 7
dump_state "05-fixture-exit-3"

# ── escape hatch: leave a program running, force the frame back ─────────────

submit_line "LESS= less README.md"
sleep 3.0
leave_terminal_mode
dump_state "06-in-pager-again"
nvim_run_cmd "$SOCK" "$WIN" "LcarsTermExitAlternateScreen"
sleep 1.0
dump_state "07-after-escape-hatch"

# ── assertions ──────────────────────────────────────────────────────────────

set +e
python3 - "$CHECK_DIR" <<'PYEOF'
import json, sys, os

d = sys.argv[1]

def load(name):
    with open(os.path.join(d, f"{name}.json")) as f:
        return json.load(f)

def text(name):
    with open(os.path.join(d, f"{name}.txt")) as f:
        return f.read()

failures = []

def check(cond, msg):
    if not cond:
        failures.append(msg)

opened = load("00-opened")
check(not opened["active"], "00-opened: no program has run, expected no alternate screen")
# LCARS chrome (gutter_eob_fill) already owns floats of its own, so every float
# assertion below is relative to this baseline, never an absolute count.
baseline_floats = opened["floats"]

in_pager = load("01-in-pager")
check(in_pager["active"], "01-in-pager: expected the alternate-screen float to be up")
check(in_pager["floats"] == baseline_floats + 1,
      f"01-in-pager: expected one float above the {baseline_floats} chrome floats, got {in_pager['floats']}")
# The float covers the frame; it must not have replaced it. The frame buffer
# stays in its own window underneath, ready to come back untouched.
check(in_pager["display_shows_frame"],
      "01-in-pager: the frame buffer must stay in its window under the float")

# Content question → kitty get-text, not a screenshot (docs/test-harness.md).
pager_text = text("01-in-pager")
check("LCARS" in pager_text or "lcarcat" in pager_text,
      "01-in-pager: expected README content on screen, got something else")

after_pager = load("02-after-pager")
check(not after_pager["active"], "02-after-pager: expected the float to be gone after 'q'")
check(after_pager["floats"] == baseline_floats,
      f"02-after-pager: expected floats back to the {baseline_floats} chrome floats, got {after_pager['floats']}")
check(len(after_pager["blocks"]) >= 1, "02-after-pager: expected the pager's block")
pager_block = after_pager["blocks"][0]
check("less" in pager_block["command"],
      f"02-after-pager: expected a 'less' block, got {pager_block['command']!r}")
check(pager_block["state"] == "done",
      f"02-after-pager: expected state=done, got {pager_block['state']}")
check(pager_block["exit_code"] == 0,
      f"02-after-pager: expected exit_code=0, got {pager_block['exit_code']}")
# The decision on lcarcat-biv: a full-screen program's block is header + footer
# and nothing else. Nothing was ever emitted to the frame, so nothing is shown —
# and crucially none of the program's escape sequences leaked in as lines.
check(pager_block["line_count"] == 0,
      f"02-after-pager: expected an empty block, got {pager_block['line_count']} content lines")

after_echo = load("03-after-echo")
check(len(after_echo["blocks"]) >= 2, "03-after-echo: expected a second block")
echo_block = after_echo["blocks"][1]
check(echo_block["command"] == "echo back-in-the-frame",
      f"03-after-echo: expected the echo block, got {echo_block['command']!r}")
check(echo_block["exit_code"] == 0,
      f"03-after-echo: expected exit_code=0, got {echo_block['exit_code']}")
check(echo_block["line_count"] >= 1,
      "03-after-echo: the parser must be back in text mode and appending lines")

# Two full passthrough round-trips, each leaving an empty block carrying the
# program's real exit status. Nothing about entering or leaving the alternate
# screen may alter the exit code the shell reported.
zero = load("04-fixture-exit-0")["blocks"][-1]
check(zero["exit_code"] == 0, f"04-fixture-exit-0: expected exit_code=0, got {zero['exit_code']}")
check(zero["state"] == "done", f"04-fixture-exit-0: expected state=done, got {zero['state']}")
check(zero["line_count"] == 0,
      f"04-fixture-exit-0: expected an empty block, got {zero['line_count']} content lines")

three = load("05-fixture-exit-3")["blocks"][-1]
check(three["exit_code"] == 3, f"05-fixture-exit-3: expected exit_code=3, got {three['exit_code']}")
check(three["state"] == "failed", f"05-fixture-exit-3: expected state=failed, got {three['state']}")
check(three["line_count"] == 0,
      f"05-fixture-exit-3: expected an empty block, got {three['line_count']} content lines")

again = load("06-in-pager-again")
check(again["active"], "06-in-pager-again: expected the float to be up again")

escaped = load("07-after-escape-hatch")
check(not escaped["active"],
      "07-after-escape-hatch: :LcarsTermExitAlternateScreen must close the float")
check(escaped["floats"] == baseline_floats,
      f"07-after-escape-hatch: expected floats back to the {baseline_floats} chrome floats, got {escaped['floats']}")
check(escaped["display_shows_frame"],
      "07-after-escape-hatch: expected the frame back on screen")

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
