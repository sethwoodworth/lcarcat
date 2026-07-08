#!/usr/bin/env bash
# LCARS palette decision demo. Truecolor, black bg — run in kitty.
BG=000000; FG=ffffc6
c()  { printf '\033[38;2;%d;%d;%dm' 0x${1:0:2} 0x${1:2:2} 0x${1:4:2}; }  # fg
b()  { printf '\033[48;2;%d;%d;%dm' 0x${1:0:2} 0x${1:2:2} 0x${1:4:2}; }  # bg
z()  { printf '\033[0m'; }
line() { b $BG; c $FG; printf '  %s\n' "$1"; z; }
head() { printf '\n'; b $BG; c ff9900; printf '  ▐ %s\n' "$1"; z; }

b $BG; c $FG; printf '\033[2J\033[H'   # clear on black
printf '\n'; b $BG; c ffcc66; printf '   LCARS PALETTE — DECISION PREVIEW\n'; z

# ---------- Q1: green slot in a git diff ----------
head "Q1  git diff: add(green slot) vs delete(red #cc6666)"
RED=cc6666
for pair in "A:orange:ff9966" "B:soft-green:99cc99" "C:sage:88bb88"; do
  IFS=: read opt name grn <<<"$pair"
  b $BG; c $FG; printf '     Option %s  (green=%-9s #%s)\n' "$opt" "$name" "$grn"
  b $BG; c $FG;  printf '       def warp_core(level):\n'
  b $BG; c $grn; printf '       +    return level * 1.618   # engaged\n'
  b $BG; c $RED; printf '       -    return level\n'
  z; printf '\n'
done

# ---------- Q1b: ls listing with each green ----------
head "Q1  ls -F  (dirs use green slot, exec=green, link=cyan)"
for pair in "orange:ff9966" "soft-green:99cc99"; do
  IFS=: read name grn <<<"$pair"
  b $BG; c $FG; printf '     %-10s ' "$name"
  c 9966ff; printf 'src/  '          # blue
  c $grn;   printf 'build/  bin*  '  # green slot
  c 9999cc; printf 'latest@  '       # cyan
  c ffcc99; printf 'README.md  '     # white
  c $RED;   printf 'core.dump\n'
  z
done

# ---------- Q2: br-red alert ----------
head "Q2  br-red for errors/alerts"
b $BG; c ff3300; printf '     A  #ff3300  '; c ff3300; printf 'ERROR: shields at 12%%  (hot/pure red)\n'
b $BG; c ff6644; printf '     B  #ff6644  '; c ff6644; printf 'ERROR: shields at 12%%  (warm LCARS red)\n'
z

# ---------- Q3: cyan vs br-black (link vs comment) ----------
head "Q3  cyan (links) distinct from br-black (comments)?"
for pair in "cyan-A:9999cc" "cyan-B:99ccff"; do
  IFS=: read name cy <<<"$pair"
  b $BG; c $FG; printf '     %-8s ' "$name"
  c $cy;     printf 'https://lcars.local  '   # link=cyan
  c 666699;  printf '# dim comment text\n'     # comment=br-black
  z
done

# ---------- Full syntax sample ----------
head "Full syntax sample (python) with current mappings"
b $BG; c 666699; printf '       # compute dilithium ratio\n'
b $BG
c ff9900; printf '       def '; c 9999ff; printf 'ratio'; c $FG; printf '('; c cc99cc; printf 'core'; c $FG; printf ': '; c cc99cc; printf 'Core'; c $FG; printf ') -> '; c cc99cc; printf 'float'; c $FG; printf ':\n'
c ff9900; printf '           if '; c $FG; printf 'core.level > '; c ffcc66; printf '42'; c $FG; printf ':\n'
c ff9900; printf '               return '; c ffcc99; printf '"nominal"'; c $FG; printf '\n'
c ff9900; printf '           return '; c ffcc66; printf 'None'; c $FG; printf '\n'
z
printf '\n'
b $BG; c $FG; printf '  legend: '; c ff9900; printf 'keyword '; c 9999ff; printf 'func '; c cc99cc; printf 'type '; c ffcc99; printf 'string '; c ffcc66; printf 'number '; c 666699; printf 'comment\n'
z; printf '\n'
