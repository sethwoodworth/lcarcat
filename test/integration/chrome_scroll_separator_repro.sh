#!/usr/bin/env bash
# REPRO HARNESS — not yet a pass/fail test. See lcarcat-2fq for turning it into one.
#
# Reproduces and measures the bug fixed in 7701abc: chrome elbow/cap images on the
# separator row between :LcarsTerm's display and input windows were cleared when the
# display window scrolled, and never re-placed, because chrome.lua did not subscribe
# to WinScrolled.
#
# Why this needs its own harness. The defect lives ENTIRELY in the kitty image layer:
#   - every state-dump assertion in terminal_win.sh passed while it was live;
#   - `redraw!` does NOT fix it (it repaints nvim text cells, not image placements),
#     which is the diagnostic that tells you it is the image layer;
#   - it self-heals on WinEnter, so it reads as random flakiness.
#
# The technique that worked, and which generalises to any "image layer got clobbered"
# bug: derive the row of interest from nvim's OWN window geometry (win_screenpos +
# height) rather than eyeballing a screenshot, then pixel-diff that row's band against
# a known-good capture. Before the fix: 10874/131328 px differed. After: 0.
#
# Usage:  bash test/integration/chrome_scroll_separator_repro.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
source "$REPO/test/nvim_harness_helpers.sh"
H="$REPO/test/screenshot_harness.sh"

SOCK="unix:/tmp/lcarcat-sep.sock";  export LCARCAT_TEST_SOCK="$SOCK"
SHOT_DIR="${LCARCAT_SHOT_DIR:-/tmp/lcarcat-sep-shots}"; export LCARCAT_SHOT_DIR="$SHOT_DIR"
GEO="/tmp/lcarcat-sep-geo"
rm -rf "$SHOT_DIR" "$GEO"; mkdir -p "$SHOT_DIR" "$GEO"

nvim_harness_setup "$H" "$SOCK" "$SHOT_DIR"
"$H" launch && sleep 1.5
WIN="$(kitty @ --to "$SOCK" ls | python3 -c '
import sys, json
for osw in json.load(sys.stdin):
    for t in osw["tabs"]:
        for w in t["windows"]: print(w["id"])' | tail -1)"

nvim_open "$SOCK" "$WIN"
nvim_run_cmd "$SOCK" "$WIN" "LcarsTerm"
sleep 5.0   # cold-start: first prompt draw is slow (see docs/test-harness.md)

submit_line() {
  kitty @ --to "$SOCK" send-text --match "id:$WIN" $'\x1b'; sleep 0.2
  kitty @ --to "$SOCK" send-text --match "id:$WIN" "i";     sleep 0.2
  kitty @ --to "$SOCK" send-text --match "id:$WIN" "$1";    sleep 0.2
  kitty @ --to "$SOCK" send-text --match "id:$WIN" $'\x1b'; sleep 0.2
  kitty @ --to "$SOCK" send-text --match "id:$WIN" $'\r'
}

# Window geometry, so the separator row is DERIVED and not guessed.
geo() {
  local lua="lua local o={lines=vim.o.lines,wins={}} for _,w in ipairs(vim.api.nvim_list_wins()) do local p=vim.fn.win_screenpos(w) local b=vim.api.nvim_win_get_buf(w) o.wins[#o.wins+1]={name=vim.api.nvim_buf_get_name(b),row=p[1],h=vim.api.nvim_win_get_height(w)} end vim.fn.writefile({vim.fn.json_encode(o)},'$GEO/$1.json')"
  kitty @ --to "$SOCK" send-text --match "id:$WIN" ":$lua"$'\r'; sleep 0.5
}

for _ in 1 2 3 4 5; do submit_line "seq 1 20"; sleep 2.5; done
geo "layout"; sleep 1; "$H" snapshot "A-before"; sleep 1

nvim_run_cmd "$SOCK" "$WIN" "wincmd k"; sleep 0.8
for _ in 1 2 3 4; do kitty @ --to "$SOCK" send-text --match "id:$WIN" $'\x15'; sleep 0.7; done
sleep 1; "$H" snapshot "B-scrolled"; sleep 1

# `redraw!` deliberately included: if the separator does NOT come back here, the
# damage is in the image layer, not the highlight layer.
nvim_run_cmd "$SOCK" "$WIN" "redraw!"; sleep 1.2
"$H" snapshot "C-after-redraw"; sleep 1

python3 - "$GEO/layout.json" "$SHOT_DIR" <<'PYEOF'
import json, sys, os
from PIL import Image

geo = json.load(open(sys.argv[1])); shots = sys.argv[2]
wins = {w["name"].split("/")[-1]: w for w in geo["wins"] if "terminal_win" in w["name"]}
if "display" not in wins or "input" not in wins:
    sys.exit("could not identify display/input windows in geometry dump")

# Separator = the screen row between the two windows. 1-indexed -> 0-indexed.
disp = wins["display"]
sep0 = (disp["row"] + disp["h"]) - 1
print(f"display rows {disp['row']}..{disp['row']+disp['h']-1}, "
      f"input row {wins['input']['row']}  ->  separator cell row {sep0}")

def band(path, ch):
    im = Image.open(path).convert("RGB")
    return im.crop((0, sep0*ch, im.size[0], sep0*ch + ch))

# Derive cell height from the capture rather than assuming it (see the
# visual-inspector notes: capture geometry has been wrong in prose before).
im0 = Image.open(os.path.join(shots, "A-before.png"))
ch = im0.size[1] // geo["lines"]
print(f"derived cell height: {ch}px  ({im0.size[1]}px / {geo['lines']} rows)")

base = band(os.path.join(shots, "A-before.png"), ch)
for lab in ("B-scrolled", "C-after-redraw"):
    b = band(os.path.join(shots, f"{lab}.png"), ch)
    pa, pb = base.load(), b.load()
    W, H = base.size
    d = sum(1 for x in range(W) for y in range(H) if pa[x, y] != pb[x, y])
    verdict = "MATCHES baseline" if d == 0 else f"DIFFERS ({100*d//(W*H)}%)"
    print(f"  {lab:16s} {d:6d}/{W*H} px differ from pre-scroll separator  -> {verdict}")
print("\nExpected after 7701abc: both rows 0 px. Any nonzero value is a regression.")
PYEOF
