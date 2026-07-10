#!/usr/bin/env bash
# LCARS scrollback-timestamp style demo. Truecolor, black bg — run in kitty.
#
# These are the dim, stem-nested lines the prompt prints when a command starts
# (preexec) and finishes (precmd). Today they use glyphs: → start, ↩ end, ⏱ dur.
# This previews glyph-free / more-LCARS alternatives. Nothing here is wired in yet.
b()  { printf '\033[48;2;%d;%d;%dm' 0x${1:0:2} 0x${1:2:2} 0x${1:4:2}; }  # bg
c()  { printf '\033[38;2;%d;%d;%dm' 0x${1:0:2} 0x${1:2:2} 0x${1:4:2}; }  # fg
z()  { printf '\033[0m'; }

BG=000000
DIM=78788c        # the current dim timestamp color (120;120;140)
GOLD=ffcc66       # section headers
OK=99cc99         # success (sage green)
FAIL=ff3300       # failure (red alert)
RUN=6699cc        # running / neutral (sky)
BLK=000000

START=14:23:01
END=14:23:05
DUR=1200ms

hdr()  { printf '\n'; b $BG; c $GOLD; printf '  %s\n' "$1"; z; }
note() { b $BG; c $DIM; printf '     %s\n' "$1"; z; }

b $BG; printf '\033[2J\033[H'
b $BG; c $GOLD; printf '   LCARS SCROLLBACK TIMESTAMPS — STYLE PREVIEW\n'; z

# ---------- current ----------
hdr "CURRENT  (glyphs: →  ↩  ⏱)"
b $BG; c $DIM; printf '  → [%s]\n' "$START"; z
b $BG; c $DIM; printf '  ↩ [%s] ⏱ %s\n' "$END" "$DUR"; z

# ---------- A: word labels, no glyphs ----------
hdr "A  word labels, no glyphs (dim, column-aligned)"
b $BG; c $DIM; printf '  %-7s %s\n' "START" "$START"; z
b $BG; c $DIM; printf '  %-7s %s   %s\n' "END" "$END" "$DUR"; z

# ---------- B: colored LED cell  (IMPLEMENTED) ----------
hdr "B  background LED cell (color = result)  <-- IMPLEMENTED"
note "start: sky LED + STARDATE (astronomical Julian Day Number) + UTC datetime"
b $RUN;  printf ' '; z; c $DIM; printf ' STARDATE 2461230  02026-07-08T21:30:31z\n'; z
note "end: green LED (ok) / red LED (fail) + UTC datetime + duration (if over threshold)"
b $OK;   printf ' '; z; c $DIM; printf ' 02026-07-08T21:30:35z  1200ms\n'; z
b $FAIL; printf ' '; z; c $DIM; printf ' 02026-07-08T21:30:35z  8ms\n'; z

# ---------- C: bracketed code ----------
hdr "C  bracketed LCARS code, dash separator"
b $BG; c $DIM; printf '  [ %-5s %s ]\n' "START" "$START"; z
b $BG; c $DIM; printf '  [ %-5s %s - %s ]\n' "END" "$END" "$DUR"; z

# ---------- D: drop glyphs entirely ----------
hdr "D  bare times, no labels or markers"
b $BG; c $DIM; printf '  %s\n' "$START"; z
b $BG; c $DIM; printf '  %s   %s\n' "$END" "$DUR"; z

# ---------- E: pill (segment with a rounded cap on each end) ----------
hdr "E  pill: a segment capped on both ends (◖ ◗)  — likely too heavy for flow"
c $RUN;  printf '  ◖'; b $RUN;  c $BLK; printf ' START %s ' "$START"; z; c $RUN;  printf '◗\n'; z
c $OK;   printf '  ◖'; b $OK;   c $BLK; printf ' END %s · %s ' "$END" "$DUR"; z; c $OK; printf '◗\n'; z
note "muted (dim) variant, less shouty:"
c $DIM;  printf '  ◖'; b $DIM;  c $BLK; printf ' START %s ' "$START"; z; c $DIM;  printf '◗\n'; z

printf '\n'
b $BG; c $DIM; printf '   (start=%s end=%s dur=%s are placeholder values)\n' "$START" "$END" "$DUR"; z
printf '\n'
