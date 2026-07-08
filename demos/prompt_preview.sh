#!/usr/bin/env bash
# Prototype: current prompt segments as an LCARS bar — Style B chips, path in Style A.
DIR="$(cd "$(dirname "$0")/../assets" && pwd)"
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
placeC1() { local p; p=$(b64 "$1"); printf '\033_Ga=T,f=100,t=f,c=%s,r=%s,C=1;%s\033\\' "$2" "$3" "$p"; }

COLS=${COLUMNS:-120}
ELBOW=5; PILL=2; mid=$((COLS - ELBOW - PILL))
O='255;153;0'; LIL='204;153;204'; PERI='153;204;255'; GOLD='255;204;102'
RED='204;102;102'; W='255;255;198'; DIM='120;120;140'
bg(){ printf '\033[48;2;%sm' "$1"; }; fg(){ printf '\033[38;2;%sm' "$1"; }
blk(){ printf '\033[48;2;0;0;0m'; }; rst(){ printf '\033[0m'; }; sp(){ printf '%*s' "$1" ''; }
reserve(){ local i; for ((i=0;i<$1;i++)); do printf '\n'; done; printf '\033[%dA' "$1"; }
pill_at(){ printf '\033[%dG' $((COLS-PILL+1)); placeC1 "$DIR/pill-right.png" "$PILL" 2; }

# --- example segment values (these become dynamic in zsh) ---
V_VENV=' uv ';        W_VENV=${#V_VENV}
V_PY=' py 3.11 ';     W_PY=${#V_PY}
V_GIT=' git:main !? ';W_GIT=${#V_GIT}
V_PATH=' ~/proj ';    W_PATH=${#V_PATH}
AMOTIF=$((1 + 1 + W_PATH))              # black line + color col + path notch
chipsW=$((W_VENV + W_PY + W_GIT))
fill=$((mid - chipsW - AMOTIF))

printf '\n'
reserve 4
placeC1 "$DIR/elbow-top.png" "$ELBOW" 4

# bar row 0 (top): chip colors blank + orange fill + Style-A PATH label (text on top) + pill
printf '\033[%dG' $((ELBOW+1))
bg "$LIL"; sp "$W_VENV"; bg "$PERI"; sp "$W_PY"; bg "$GOLD"; sp "$W_GIT"
bg "$O"; sp "$fill"
blk; sp 1; bg "$O"; sp 1; blk; fg "$O"; printf '%s' "$V_PATH"; rst
pill_at

# bar row 1 (bottom): Style-B chips (dark text) + orange fill + path notch blank
printf '\033[1B\033[%dG' $((ELBOW+1))
bg "$LIL"; fg '0;0;0'; printf '%s' "$V_VENV"
bg "$PERI"; fg '0;0;0'; printf '%s' "$V_PY"
bg "$GOLD"; fg '0;0;0'; printf '%s' "$V_GIT"
bg "$O"; sp "$fill"
blk; sp 1; bg "$O"; sp 1; blk; sp "$W_PATH"; rst

# stem rows: input line nested beside the stem
printf '\033[1B\033[3G'; fg "$DIM"; printf '→ 17:15:42'; rst
printf '\033[1B\033[3G'; fg "$W"; printf '17:15'; rst; printf ' '; fg "$O"; printf '%%'; rst; printf ' '
printf '\033[1B\033[1G'

# output
printf '   \033[38;2;136;187;136mbuild/\033[0m  README.md  main.py\n'

# footer
reserve 4
placeC1 "$DIR/elbow-bottom.png" "$ELBOW" 4
printf '\033[3G'; fg "$DIM"; printf '↩ 17:15:43  ⏱ 4ms'; rst
printf '\033[2B\033[%dG' $((ELBOW+1)); bg "$O"; sp "$mid"; rst; pill_at
printf '\033[1B\033[%dG' $((ELBOW+1)); bg "$O"; sp "$mid"; rst
printf '\033[1B\033[1G\n'
