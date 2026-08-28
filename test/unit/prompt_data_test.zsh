#!/usr/bin/env zsh
# Headless unit tests for zsh/lcars_prompt_data.zsh.
# Run with: zsh test/unit/prompt_data_test.zsh   (or bash test/unit/run_prompt_data_tests.sh)
#
# These assert on the *bytes the shell emits*. That is the whole point of
# splitting the data layer out of prompt_lcars.zsh: the OSC feed previously had
# no visual feedback in the environment where it was produced — if the payload
# broke while you were in kitty the swoop bar still looked perfect, and you
# found out next time you opened :LcarsTerm. Here it breaks a test instead.
#
# No terminal, no kitty, no nvim, no screenshots.

emulate -L zsh
setopt no_unset warn_create_global

REPO="${0:A:h}/../.."
typeset -i PASS=0 FAIL=0

# Once the hooks are installed, zsh fires preexec_functions before every command
# in this script too, so each subsequent line emits an OSC 133;C onto stdout.
# Assertions therefore report on fd 3, leaving stdout free to be redirected to
# /dev/null around the sections that have hooks live.
exec 3>&1

# The hook functions mutate shell state (_LCARS_CMD_RAN) as well as emitting
# bytes. "$(f)" would run f in a subshell and throw those mutations away, so
# capture through a file and keep the call in THIS shell.
TMPOUT=$(mktemp); trap 'rm -f "$TMPOUT"' EXIT
# Assigns the captured bytes to $out. Deliberately NOT "out=$(capture ...)" —
# that would subshell the call again and lose the mutations all over.
typeset -g out=
capture() { "$@" >|"$TMPOUT" 2>&1; out="$(<"$TMPOUT")" }

# Render control bytes printable so failures are readable: ESC -> <E>, ST -> <ST>.
vis() { print -rn -- "${${1//$'\e\\'/<ST>}//$'\e'/<E>}" }

eq() {  # $1 label  $2 got  $3 expected
  if [[ $2 == $3 ]]; then
    (( PASS++ ))
  else
    (( FAIL++ ))
    print -ru3 -- "FAIL [$1]"
    print -ru3 -- "  expected: $(vis "$3")"
    print -ru3 -- "  got:      $(vis "$2")"
  fi
}

contains() {  # $1 label  $2 haystack  $3 needle
  if [[ $2 == *$3* ]]; then
    (( PASS++ ))
  else
    (( FAIL++ ))
    print -ru3 -- "FAIL [$1]: expected to contain $(vis "$3")"
    print -ru3 -- "  got: $(vis "$2")"
  fi
}

# The layer reads $HOST and $AWS_PROFILE; give them defined values so
# `no_unset` does not fire on an unrelated missing variable.
typeset -g HOST=testhost
typeset -g AWS_PROFILE=
typeset -g VIRTUAL_ENV=
typeset -g _LCARS_CMD_RAN=
typeset -g _LCARS_S_CMD_RAN=

source "$REPO/zsh/lcars_prompt_data.zsh"

# Set the gathered state directly instead of shelling out to git, so these
# tests do not depend on the repo's working-tree state.
set_state() {
  _LCARS_S_VENV=${1-} _LCARS_S_PY=${2-} _LCARS_S_AWS=${3-} _LCARS_S_BRANCH=${4-}
  _LCARS_S_GC=(${5:-0} ${6:-0} ${7:-0})
}
typeset -g _LCARS_S_VENV= _LCARS_S_PY= _LCARS_S_AWS= _LCARS_S_BRANCH= _LCARS_S_CWD= _LCARS_S_EXIT=0
typeset -ga _LCARS_S_GC=(0 0 0)

# ── envelope ───────────────────────────────────────────────────────────────
# The version sits BEFORE the message type. A pre-version reader matches
# ^7447;lcars;chips and therefore ignores these entirely, rather than reading
# the version as a chip kind and the first real kind as its label.

eq "1a empty chip set is a bare message, no trailing ;" \
   "$(_lcars_emit_chips)" \
   $'\e]7447;lcars;1;chips\e\\'

eq "1b one chip" \
   "$(_lcars_emit_chips git main)" \
   $'\e]7447;lcars;1;chips;git;main\e\\'

eq "1c version precedes the message type" \
   "${$(_lcars_emit_chips git main)#$'\e]'}" \
   "7447;lcars;1;chips;git;main"$'\e\\'

# ── escaping ───────────────────────────────────────────────────────────────
# % must be encoded first and ; second, or a literal % in a branch name would
# corrupt the encoding of a following ;. Branch names may legally contain both.

eq "2a semicolon in a label" \
   "$(_lcars_emit_chips git 'feat;odd')" \
   $'\e]7447;lcars;1;chips;git;feat%3Bodd\e\\'

eq "2b percent in a label" \
   "$(_lcars_emit_chips git '100%done')" \
   $'\e]7447;lcars;1;chips;git;100%25done\e\\'

eq "2c percent encoded before semicolon" \
   "$(_lcars_emit_chips git '%3B')" \
   $'\e]7447;lcars;1;chips;git;%253B\e\\'

# ── chip assembly order and content ────────────────────────────────────────

set_state "" "" "" ""
_lcars_build_chips
eq "3a nothing to report yields no chips" "${#_LCARS_CHIP_KV}" "0"

set_state "lcarcat" "py 3.12" "" "main" 0 0 0
_lcars_build_chips
eq "3b order is venv, py, git" \
   "${_LCARS_CHIP_KV[*]}" \
   "venv lcarcat py py 3.12 git main"

set_state "" "" "prod" "main" 0 0 0
_lcars_build_chips
eq "3c ordinary aws profile uses kind aws" \
   "${_LCARS_CHIP_KV[*]}" \
   "aws AWS|prod git main"

set_state "" "" "dep" "main" 0 0 0
_lcars_build_chips
eq "3d the dep profile gets its own kind so nvim can colour it red" \
   "${_LCARS_CHIP_KV[*]}" \
   "awsdep AWS|dep git main"

# gitstate chips appear only for nonzero counts, zero-padded, count on the left.
set_state "" "" "" "main" 0 3 0
_lcars_build_chips
eq "3e only nonzero git counts produce a chip" \
   "${_LCARS_CHIP_KV[*]}" \
   "git main gitstate 03-MODIFIED"

set_state "" "" "" "main" 1 2 12
_lcars_build_chips
eq "3f all three git states, staged/modified/untracked order" \
   "${_LCARS_CHIP_KV[*]}" \
   "git main gitstate 01-STAGED gitstate 02-MODIFIED gitstate 12-UNTRACKED"

# No branch means no git chips at all, even if counts are somehow set.
set_state "" "" "" "" 5 5 5
_lcars_build_chips
eq "3g no branch means no git chips" "${#_LCARS_CHIP_KV}" "0"

# There is deliberately no err chip: precmd runs after a command, so the exit
# status belongs to the command that just finished, while these chips attach to
# the block about to open. nvim derives outcome from OSC 133;D instead.
set_state "" "" "" "main" 0 0 0
_LCARS_S_EXIT=1
_lcars_build_chips
eq "3h a nonzero exit does not add an err chip" \
   "${_LCARS_CHIP_KV[*]}" "git main"

# A label containing a space survives as ONE field (it is not word-split).
set_state "" "py 3.12" "" ""
_lcars_build_chips
eq "3i a label with a space stays one label" "${#_LCARS_CHIP_KV}" "2"
eq "3j and reaches the wire intact" \
   "$(_lcars_emit_chips "${_LCARS_CHIP_KV[@]}")" \
   $'\e]7447;lcars;1;chips;py;py 3.12\e\\'

# ── hook ordering ──────────────────────────────────────────────────────────
# The renderer must run BETWEEN the data layer's two precmd halves: 133;D has to
# precede any decorative output, and 133;A/chips/OSC 7/133;B has to follow it.

render_pre() { : }
render_pex() { : }

{   # stdout muted: hooks are live in here, so every command emits a 133;C
lcars_prompt_data_install render_pre render_pex
eq "4a precmd order: open, render, close" \
   "${precmd_functions[*]-}" \
   "_lcars_data_precmd_open render_pre _lcars_data_precmd_close"
eq "4b preexec order: render, then C last" \
   "${preexec_functions[*]-}" \
   "render_pex _lcars_data_preexec"

# Installing headless leaves PROMPT untouched — this layer renders nothing.
typeset -g PROMPT='UNTOUCHED' PROMPT2='UNTOUCHED2'
lcars_prompt_data_install
eq "4c headless install registers only the data hooks" \
   "${precmd_functions[*]-}" \
   "_lcars_data_precmd_open _lcars_data_precmd_close"
eq "4d headless install does not set PROMPT"  "$PROMPT"  "UNTOUCHED"
eq "4e headless install does not set PROMPT2" "$PROMPT2" "UNTOUCHED2"

# Reinstalling must not accumulate duplicate hooks.
lcars_prompt_data_install render_pre render_pex
lcars_prompt_data_install render_pre render_pex
eq "4f reinstall is idempotent" \
   "${precmd_functions[*]-}" \
   "_lcars_data_precmd_open render_pre _lcars_data_precmd_close"

lcars_prompt_data_uninstall
eq "4g uninstall removes the data hooks"   "${precmd_functions[*]-}"  ""
eq "4h uninstall removes the preexec hook" "${preexec_functions[*]-}" ""
} >/dev/null

# ── emitted sequence across a prompt cycle ─────────────────────────────────

set_state "" "" "" ""
_LCARS_CMD_RAN=
capture _lcars_data_precmd_open
eq "5a no 133;D before any command has run" "$out" ""

# After a command, D carries its exit code.
_LCARS_CMD_RAN=1
false
capture _lcars_data_precmd_open
contains "5b 133;D carries the exit code" "$out" $'\e]133;D;1\e\\'

# ...and only once. The data layer clears _LCARS_CMD_RAN itself rather than
# leaving it to the renderer, so a headless shell does not re-emit D with a
# stale exit code on every bare-Enter prompt afterwards.
capture _lcars_data_precmd_open
eq "5c 133;D is not repeated on the next bare prompt" "$out" ""

# The renderer reads the snapshot, not the flag.
_LCARS_CMD_RAN=1
capture _lcars_data_precmd_open
eq "5d the renderer's snapshot survives the clear" "$_LCARS_S_CMD_RAN" "1"
eq "5e while the flag itself is cleared" "$_LCARS_CMD_RAN" ""

# The closing half, in order: A, chips, cwd, B. B must be last — it opens the
# suppression window that hides the renderer's PROMPT bytes from the captured
# output of the command about to run.
set_state "" "" "" "main" 0 0 0
typeset -g PWD_SAVE=$PWD
capture _lcars_data_precmd_close
eq "6a full closing sequence, B last" \
   "$out" \
   $'\e]133;A\e\\\e]7447;lcars;1;chips;git;main\e\\\e]7;file://testhost'"$PWD_SAVE"$'\e\\\e]133;B\e\\'

capture _lcars_data_preexec
eq "6b preexec emits 133;C" "$out" $'\e]133;C\e\\'
eq "6c preexec re-arms the command flag" "$_LCARS_CMD_RAN" "1"

# ── protocol version ───────────────────────────────────────────────────────

eq "7a version is exported for the renderer and the docs" "$_LCARS_OSC_VERSION" "1"

# nvim announces itself through the environment rather than over the pty, so the
# shell can know someone is listening without any request/response machinery.
eq "7b peer version is recorded when nvim sets it" "$_LCARS_OSC_PEER" "${LCARS_TERM_PROTO:-}"

# ── report ─────────────────────────────────────────────────────────────────
print -ru3 -- "prompt_data: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
