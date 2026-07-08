#!/usr/bin/env bash
# LCARS cell-bar prototype v3: full-width, both text styles, 2-row segmentation.
DIR="$(cd "$(dirname "$0")/../assets" && pwd)"
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
placeC1() { local p; p=$(b64 "$1"); printf '\033_Ga=T,f=100,t=f,c=%s,r=%s,C=1;%s\033\\' "$2" "$3" "$p"; }

COLS=${COLUMNS:-120}
ELBOW=5; PILL=2
O='255;153;0'; L='204;153;204'; G='136;187;136'; B='153;204;255'; W='255;255;198'; DIM='120;120;140'
bg()  { printf '\033[48;2;%sm' "$1"; }
fg()  { printf '\033[38;2;%sm' "$1"; }
blk() { printf '\033[48;2;0;0;0m'; }
rst() { printf '\033[0m'; }
sp()  { printf '%*s' "$1" ''; }
reserve() { local i; for ((i=0;i<$1;i++)); do printf '\n'; done; printf '\033[%dA' "$1"; }
pill_at() { printf '\033[%dG' $((COLS-PILL+1)); placeC1 "$DIR/pill-right.png" "$PILL" 2; }
mid=$((COLS - ELBOW - PILL))
# right-justify string $2 within a field of $1 cells (pad on the left)
rjust() { local w=$1 s=$2 pad; pad=$((w - ${#s})); (( pad > 0 )) && sp "$pad"; printf '%s' "$s"; }

# Style A bar row: right-anchored label motif = [black 1-col][1-col color][black notch words].
# The label lives only at the far right; black spans both rows (text only on the top row).
# $1 = "text" for the labelled row, anything else = the blank second row.
rowA() {
  local motif=14               # blk(1) + color(1) + notch(" SESSION 01 "=12)
  bg "$O"; sp $((mid - motif))  # orange fill
  blk;     sp 1                 # black vertical line
  bg "$O"; sp 1                 # single color column
  if [[ $1 == text ]]; then blk; fg "$O"; printf ' SESSION 01 '; else blk; sp 12; fi
  rst
}

# Style B bar row: dark text on a colored (lilac) label segment, no black separator.
# The label text sits on the 2nd (bottom) bar row, right-justified within the segment.
rowB() {
  local segW=20
  bg "$O"; sp 2
  bg "$L"
  if [[ $1 == text ]]; then fg '0;0;0'; rjust "$segW" '~/proj  git:main '; else sp "$segW"; fi
  bg "$O"; sp $((mid - 2 - segW)); rst
}

# ---- STYLE A ----
printf '\nStyle A — colored words on black notch (2 rows), with segmentation:\n'
reserve 4
placeC1 "$DIR/elbow-top.png" "$ELBOW" 4
printf '\033[%dG' $((ELBOW+1)); rowA text; pill_at
printf '\033[1B\033[%dG' $((ELBOW+1)); rowA blank
printf '\033[1B\033[3G'; fg "$B"; printf '~/proj'; rst; printf '  '; fg "$L"; printf 'git:main'; rst
printf '\033[1B\033[3G'; fg "$W"; printf '17:15'; rst; printf ' '; fg "$O"; printf '%%'; rst; printf ' '
printf '\033[1B\033[1G'
printf '   '; fg "$G"; printf 'build/'; rst; printf '  README.md  main.py\n'

# ---- STYLE B ----
printf '\nStyle B — dark text on a colored label segment (2 rows):\n'
reserve 4
placeC1 "$DIR/elbow-top.png" "$ELBOW" 4
printf '\033[%dG' $((ELBOW+1)); rowB blank; pill_at
printf '\033[1B\033[%dG' $((ELBOW+1)); rowB text
printf '\033[1B\033[3G'; fg "$W"; printf '17:15'; rst; printf ' '; fg "$O"; printf '%%'; rst; printf ' '
printf '\033[1B\033[3G'
printf '\033[1B\033[1G'

# ---- FOOTER ----
reserve 4
placeC1 "$DIR/elbow-bottom.png" "$ELBOW" 4
printf '\033[3G'; fg "$DIM"; printf 'end 17:16  4ms'; rst
printf '\033[2B\033[%dG' $((ELBOW+1)); bg "$O"; sp "$mid"; rst; pill_at
printf '\033[1B\033[%dG' $((ELBOW+1)); bg "$O"; sp "$mid"; rst
printf '\033[1B\033[1G\n'
