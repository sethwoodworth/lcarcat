#!/bin/sh
# A synthetic full-screen program, for test/integration/alternate_screen.sh.
#
# Enters the alternate screen, draws one identifiable line, leaves, and exits
# with the status given as $1. Deterministic where a real program is not: no
# terminfo lookup, no $LESS or $EDITOR to inherit, no keystroke needed to make
# it quit, and an exit code the test chooses rather than one it has to hope for.
printf '\033[?1049h'
printf '\033[2J\033[H'
echo "SYNTHETIC-ALTERNATE-SCREEN"
sleep 2
printf '\033[?1049l'
exit "${1:-0}"
