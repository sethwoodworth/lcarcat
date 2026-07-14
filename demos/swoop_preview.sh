#!/usr/bin/env bash
# Preview the LCARS swoop frame with the prompt timestamps nested beside the stem.
DIR="$(cd "$(dirname "$0")/../assets" && pwd)"
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

STEM=2
ROWS=$((2 + STEM))          # bar(2) + stem
COLS=${COLUMNS:-100}
dim='\033[38;2;120;120;140m'; blue='\033[38;2;153;204;255m'
lilac='\033[38;2;204;153;204m'; green='\033[38;2;136;187;136m'; rst='\033[0m'

# reserve n blank lines then return cursor to the top of them
reserve() { local i; for ((i=0;i<$1;i++)); do printf '\n'; done; printf '\033[%dA' "$1"; }
# place image at cursor WITHOUT moving the cursor (C=1)
placeC1() { local p; p=$(b64 "$1"); printf '\033_Ga=T,f=100,t=f,c=%s,r=%s,C=1;%s\033\\' "$2" "$3" "$p"; }

printf '\n'
# ---------- TOP swoop: bar(rows0-1) + stem(rows2-3) ----------
reserve $ROWS
placeC1 "$DIR/swoop-top-left-9999ff-48x3cells-19x40pixels.png" "$COLS" "$ROWS"
printf '\033[2B\033[3G'"${blue} ~/proj${rst}  ${lilac}git:main${rst}"     # stem row 1: prompt
printf '\033[1B\033[3G'"${dim}→ [2026-07-07T17:15:42Z]${rst}  \$ ls"       # stem row 2: start ts + cmd
printf '\033[1B\033[1G'                                                    # move below the image
# ---------- command output (full width, no stem) ----------
printf "${green}build/${rst}  README.md  main.py\n"

# ---------- BOTTOM swoop: stem(rows0-1) + bar(rows2-3) ----------
reserve $ROWS
placeC1 "$DIR/swoop-bottom-left-9999ff-48x3cells-19x40pixels.png" "$COLS" "$ROWS"
printf '\033[3G'"${dim}↩ [2026-07-07T17:15:43Z] ⏱ 4ms${rst}"              # stem row 1: end ts
printf '\033[3B\033[1G'                                                    # move below the image
printf '\n'
