#!/usr/bin/env bash
# Integration test: :LcarsTerm sizes the PTY to the frame's content width (lcarcat-wve)
#
# Pass/fail:
#   1. `tput cols` inside the session reports the frame's content width
#      (bw - 2), not the raw window width — so COLUMNS-aware tools format to
#      the space that is actually visible.
#   2. A ruler line of exactly $COLUMNS chars renders flush with the bar's
#      right edge — proving the full content width is usable, and guarding the
#      opposite failure of a too-conservative width wasting horizontal space.
#   3. Wide multi-column output (`ls /usr/bin`) never renders past the bar's
#      right edge. The display window has wrap=false, so an over-wide line is
#      clipped invisibly — the regression this guards.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/test/nvim_harness_helpers.sh"

H="$REPO/test/screenshot_harness.sh"
SOCK="${LCARCAT_TEST_SOCK:-unix:/tmp/lcarcat-test.sock}"
SHOT_DIR="${LCARCAT_SHOT_DIR:-$REPO/test/screenshots/$(basename "${BASH_SOURCE[0]}" .sh)}"
export LCARCAT_SHOT_DIR="$SHOT_DIR"

CHECK_DIR="/tmp/lcarcat-terminal-win-width-checks"
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
nvim_check_messages "$SOCK" "$WIN" "term-width-baseline"

# dump_state LABEL — writes the display window's geometry plus every block's
# command and output lines, so the assertions can compare rendered line widths
# against the frame's bar.
dump_state() {
  local label="$1"
  local lua="lua local fb=require(\"lcars.frame_buffer\"); local win=vim.fn.bufwinid(fb.buf); local d={win_width=vim.api.nvim_win_get_width(win),max_line_width=0,blocks={}}; for _,l in ipairs(vim.api.nvim_buf_get_lines(fb.buf,0,-1,false)) do local n=vim.fn.strdisplaywidth(l); if n>d.max_line_width then d.max_line_width=n end end; for i,b in ipairs(fb.blocks) do d.blocks[i]={command=b.command,state=b.state,lines=b.lines} end; vim.fn.writefile({vim.fn.json_encode(d)}, \"$CHECK_DIR/${label}.json\")"
  kitty @ --to "$SOCK" send-text --match "id:$WIN" ":$lua"$'\r'
  sleep 0.5
}

# submit_line TEXT — same scripted-input dance as terminal_win.sh: explicit Esc
# before and after, never relying on startinsert timing.
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

nvim_run_cmd "$SOCK" "$WIN" "LcarsTerm"
# Cold start: the nested shell's first prompt draw is slow (kitty graphics +
# git segment probes on every precmd) — see docs/test-harness.md pty cold-start gotcha.
sleep 5.0
nvim_check_messages "$SOCK" "$WIN" "term-width-opened"

# ── what the PTY tells the shell ─────────────────────────────────────────────

submit_line "tput cols"
sleep 3.0
nvim_check_messages "$SOCK" "$WIN" "term-width-after-tput"

# ── a line of exactly $COLUMNS chars, to see where full width lands ──────────

submit_line "printf '%*s\\n' \$COLUMNS '' | tr ' ' '#'"
sleep 3.0
nvim_check_messages "$SOCK" "$WIN" "term-width-after-ruler"

# ── the widest real output we can produce ────────────────────────────────────

submit_line "ls /usr/bin"
sleep 6.0
nvim_check_messages "$SOCK" "$WIN" "term-width-after-ls"
dump_state "00-after-ls"

if [[ "${LCARCAT_SKIP_SCREENSHOTS:-0}" != "1" ]]; then
  "$H" snapshot "01-wide-ls"
fi

# ── assertions ───────────────────────────────────────────────────────────────

set +e
python3 - "$CHECK_DIR" <<'PYEOF'
import json, os, re, sys

LP, BAR_MARGIN, GUTTER_W = 6, 14, 1

# rec.lines hold the PTY's raw bytes — baleia strips the ANSI when rendering to
# the buffer, so measure stripped width to get real columns.
ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")

def cols(line):
    return len(ANSI.sub("", line))

d = sys.argv[1]
with open(os.path.join(d, "00-after-ls.json")) as f:
    state = json.load(f)

win_width     = state["win_width"]
bw            = win_width - BAR_MARGIN
content_width = bw - 2

# Buffer-col geometry (window col - GUTTER_W):
#   bar spans buffer cols LP-1 .. LP+bw-2; content text starts at LP+1.
# A full-width content line is therefore LP+1+content_width chars and ends
# flush with the bar's right edge. Header/footer rows are one char longer:
# their pad+bar string carries a trailing uncolored space past that edge.
content_line_max = LP + 1 + content_width
buffer_line_max  = LP + bw
visible_cols     = win_width - GUTTER_W

failures = []

def check(cond, msg):
    if not cond:
        failures.append(msg)

def block(pred):
    for b in state["blocks"]:
        if pred(b.get("command") or ""):
            return b
    return None

# 1. the PTY reports the frame's content width
tput = block(lambda c: c == "tput cols")
check(tput is not None, "no block found for `tput cols`")
reported = None
if tput:
    nums = [l.strip() for l in tput.get("lines") or [] if l.strip().isdigit()]
    check(bool(nums), f"`tput cols` produced no numeric output: {tput.get('lines')!r}")
    if nums:
        reported = int(nums[0])
        check(reported == content_width,
              f"PTY reports COLUMNS={reported}, expected content width {content_width} "
              f"(win_width={win_width}, bw={bw})")

# 2. a full-width line lands flush with the bar's right edge, unclipped
ruler = block(lambda c: c.startswith("printf"))
check(ruler is not None,
      f"no ruler block found; commands seen: {[b.get('command') for b in state['blocks']]!r}")
if ruler:
    lines = [l for l in ruler.get("lines") or [] if "#" in l]
    check(bool(lines), f"ruler produced no output: {ruler.get('lines')!r}")
    if lines:
        width = cols(lines[0])
        check(width == content_width,
              f"ruler line is {width} cols, expected {content_width}")
        check(LP + 1 + width <= visible_cols,
              f"a full-width line reaches col {LP + 1 + width} but only {visible_cols} "
              f"text cols are visible — it would be clipped (wrap=false)")

# 3. real wide output stays inside the frame
ls = block(lambda c: c == "ls /usr/bin")
check(ls is not None, "no block found for `ls /usr/bin`")
if ls:
    check(ls["state"] == "done", f"`ls /usr/bin` state={ls['state']}, expected done")
    widest = max((cols(l) for l in ls.get("lines") or []), default=0)
    check(widest > 0, "`ls /usr/bin` produced no output lines")
    check(widest <= content_width,
          f"widest `ls` line is {widest} cols, exceeds content width {content_width}")

check(state["max_line_width"] <= buffer_line_max,
      f"buffer has a {state['max_line_width']}-col line; the frame allows at most "
      f"{buffer_line_max} (win_width={win_width}, bw={bw})")

print(f"geometry: win_width={win_width} bw={bw} content_width={content_width} "
      f"tput_cols={reported} content_line_max={content_line_max} "
      f"max_buffer_line={state['max_line_width']} (allowed {buffer_line_max}, "
      f"visible {visible_cols})")

if failures:
    print("FAIL:")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
print("PASS: all checks passed")
PYEOF
RESULT=$?
set -e

exit $RESULT
