# LCARS prompt DATA layer — headless. No rendering, no PROMPT.
#
# This file gathers prompt state and emits it as terminal escape sequences.
# It draws nothing and sets neither PROMPT nor PROMPT2. Sourcing it gives you a
# shell that *reports* what it knows (cwd, git, venv, python, aws, command
# boundaries) to whatever is listening, while leaving the appearance of your
# prompt entirely to someone else.
#
# Two consumers exist today:
#   - nvim's :LcarsTerm (lcars.pty_session), which draws block headers from
#     this feed because it has no kitty graphics available.
#   - zsh/prompt_lcars.zsh, the kitty swoop bar, which renders the same values
#     as pixels. It sources this file and adds a render layer on top.
#
# The split exists because the data job has no visual feedback in the
# environment where the rendering job runs: if the chip payload broke while you
# were in kitty, the bar still looked perfect and nothing told you — you found
# out next time you opened :LcarsTerm. Keeping the data layer separate makes it
# testable without a terminal, kitty, or screenshots (test/unit/prompt_data_test.zsh).
#
# ---- why the shell is the source of truth, permanently ---------------------
# nvim could compute some of this itself. It knows the cwd (OSC 7 below), so
# `py` (.tool-versions at the git toplevel) and `git`/`gitstate` (branch +
# porcelain counts) are pure functions of a directory it already has.
#
# `venv` and `aws` are not. $VIRTUAL_ENV and $AWS_PROFILE are the live
# environment of a process nvim spawned but cannot inspect — macOS has no
# /proc, and `ps eww` prints argv without environ. Activate a venv inside a
# :LcarsTerm shell and nvim can only learn of it by being told. That is why
# this feed is permanent rather than a bridge; and once the channel exists for
# those two, carrying git/py over it as well is free and spares nvim a
# duplicate `git status --porcelain` on every prompt.
#
# The `err` chip is deliberately NOT emitted here — see the note in
# _lcars_build_chips.

# ---- protocol version ------------------------------------------------------
# Rides the envelope of every OSC 7447 message (see docs/osc-7447.md). It is
# diagnostic, not gating: a reader that sees a version it does not speak warns
# and renders best-effort. It exists so a skewed deploy is *detectable* — the
# failure it addresses is a stale ~/.config/nvim half showing no chips, which
# is otherwise indistinguishable from a shell that never emitted any.
#
# Bump on a grammar change to an existing message. Adding a new message type,
# a new chip kind, or a new trailing field does NOT need a bump — those are
# already absorbed by the forward-compat rules in the spec.
typeset -g _LCARS_OSC_VERSION=1

# nvim exports this (via jobstart's `env`) to announce that something is
# listening and what version it speaks. Unset means nobody is known to be
# listening, which is not the same as nobody being there — a shell in plain
# kitty emits anyway, since unknown OSC sequences are ignored by terminals that
# do not implement them. We record it for diagnostics rather than gating on it.
typeset -g _LCARS_OSC_PEER=${LCARS_TERM_PROTO:-}

# ---- mutable state ---------------------------------------------------------
# Declared up front so the file is clean under `setopt no_unset` — the unit
# tests run with it on, which is how the uninstall-before-first-install path
# below got caught.
#   _LCARS_CMD_RAN     set by preexec, consumed and cleared by precmd's open half
#   _LCARS_S_*         this prompt's gathered state, read by both layers
#   _LCARS_CHIP_KV     flat kind/label pairs for the wire
#   _LCARS_DATA_RENDER_*  the renderer hooks this layer installed, so it can
#                         remove exactly those on uninstall
typeset -g  _LCARS_CMD_RAN= _LCARS_S_CMD_RAN=
typeset -g  _LCARS_S_EXIT=0 _LCARS_S_VENV= _LCARS_S_PY= _LCARS_S_BRANCH= _LCARS_S_CWD= _LCARS_S_AWS=
typeset -ga _LCARS_S_GC=(0 0 0)
typeset -ga _LCARS_CHIP_KV=()
typeset -g  _LCARS_DATA_RENDER_PRECMD= _LCARS_DATA_RENDER_PREEXEC=

# ---- git chip labels: LCARS "NN-WORD" dashed codes (count on the left) ------
# One gold chip per state, shown only when its count > 0. Words, not symbols, so
# the meaning is legible; rename freely. Lives here rather than in the renderer
# because the labels travel on the wire, so both consumers must agree on them.
: ${_LC_GIT_STAGED:=STAGED}
: ${_LC_GIT_MODIFIED:=MODIFIED}
: ${_LC_GIT_UNTRACKED:=UNTRACKED}

# ---- segment values --------------------------------------------------------
# Each returns a bare value with no padding or color. Padding is a rendering
# decision and belongs to whoever draws.

_lcars_git_branch() {
  git rev-parse --is-inside-work-tree &>/dev/null || return
  git symbolic-ref --short HEAD 2>/dev/null || git describe --tags --exact-match 2>/dev/null || echo detached
}

# Echo three counts: "<staged> <modified> <untracked>" for the current repo.
_lcars_git_counts() {
  local st; st=$(git status --porcelain 2>/dev/null)
  printf '%d %d %d' \
    "$(print -r -- "$st" | grep -cE '^[MARCD]')" \
    "$(print -r -- "$st" | grep -cE '^.M')" \
    "$(print -r -- "$st" | grep -c  '^??')"
}

_lcars_py_seg() {
  local tv=""
  if git rev-parse --show-toplevel &>/dev/null; then tv="$(git rev-parse --show-toplevel)/.tool-versions"
  elif [[ -f .tool-versions ]]; then tv=.tool-versions; fi
  [[ -f $tv ]] || return
  local v; v=$(awk '/^python / {print $2}' "$tv")
  [[ -n $v ]] && print -rn -- "py $v"
}

_lcars_venv_seg() {
  [[ -n $VIRTUAL_ENV ]] && { print -rn -- "${VIRTUAL_ENV:t}"; return }
  [[ -f pyproject.toml && -d .venv ]] && print -rn -- "uv"
}

# ---- gather ----------------------------------------------------------------
# Populate the _LCARS_S_* globals from the current directory and environment.
# Called once per prompt, before either consumer needs them, so that the swoop
# bar and the OSC payload are built from one set of values and neither pays for
# a second round of git subprocesses.
#
# Takes the just-finished command's exit status as $1 — the caller must capture
# `$?` before anything else clobbers it.
# (note: `status` is a read-only special in zsh -> use _LCARS_S_EXIT)
_lcars_gather_state() {
  typeset -g _LCARS_S_EXIT=$1
  typeset -g _LCARS_S_VENV _LCARS_S_PY _LCARS_S_BRANCH _LCARS_S_CWD _LCARS_S_AWS
  typeset -ga _LCARS_S_GC
  _LCARS_S_VENV=$(_lcars_venv_seg)
  _LCARS_S_PY=$(_lcars_py_seg)
  _LCARS_S_BRANCH=$(_lcars_git_branch)
  _LCARS_S_CWD="${(%):-%~}"
  _LCARS_S_AWS=$AWS_PROFILE
  if [[ -n $_LCARS_S_BRANCH ]]; then
    _LCARS_S_GC=(${(s: :)$(_lcars_git_counts)})
  else
    _LCARS_S_GC=(0 0 0)
  fi
}

# Flat kind/label pairs for _lcars_emit_chips, in the same left-to-right order
# the swoop bar uses. Labels carry no padding: nvim's frame_renderer chips_block
# adds its own, and the swoop bar adds its own. `printf -v` keeps the git-state
# labels fork-free. Echoes nothing when there is nothing to report.
#
# No `err` chip. This runs in precmd, i.e. *after* a command, so the exit status
# in hand belongs to the command that just finished — but these chips attach to
# the block about to open, which is the NEXT command. nvim reports exit status
# on the correct block itself, as a footer chip (block_chips.outcome), derived
# from the OSC 133;D below. The swoop bar keeps its own error chip, where "the
# command that just ran" is exactly the right meaning.
# Sets the global array _LCARS_CHIP_KV rather than echoing, so labels
# containing spaces, quotes or `;` never round-trip through word splitting.
_lcars_build_chips() {
  local _cs
  typeset -ga _LCARS_CHIP_KV; _LCARS_CHIP_KV=()
  [[ -n $_LCARS_S_VENV ]] && _LCARS_CHIP_KV+=(venv "$_LCARS_S_VENV")
  [[ -n $_LCARS_S_PY   ]] && _LCARS_CHIP_KV+=(py   "$_LCARS_S_PY")
  if [[ -n $_LCARS_S_AWS ]]; then
    if [[ $_LCARS_S_AWS == dep ]]; then
      _LCARS_CHIP_KV+=(awsdep "AWS|${_LCARS_S_AWS}")
    else
      _LCARS_CHIP_KV+=(aws "AWS|${_LCARS_S_AWS}")
    fi
  fi
  if [[ -n $_LCARS_S_BRANCH ]]; then
    _LCARS_CHIP_KV+=(git "$_LCARS_S_BRANCH")
    (( _LCARS_S_GC[1] )) && { printf -v _cs '%02d-%s' $_LCARS_S_GC[1] $_LC_GIT_STAGED;    _LCARS_CHIP_KV+=(gitstate "$_cs") }
    (( _LCARS_S_GC[2] )) && { printf -v _cs '%02d-%s' $_LCARS_S_GC[2] $_LC_GIT_MODIFIED;  _LCARS_CHIP_KV+=(gitstate "$_cs") }
    (( _LCARS_S_GC[3] )) && { printf -v _cs '%02d-%s' $_LCARS_S_GC[3] $_LC_GIT_UNTRACKED; _LCARS_CHIP_KV+=(gitstate "$_cs") }
  fi
  return 0
}

# ---- OSC 7447: semantic chip payload (spec: docs/osc-7447.md) --------------
# The kitty swoop bar draws its chips itself, as pixels. Inside :LcarsTerm there
# are no graphics, so nvim's frame_renderer draws the block-header chips and
# needs the *values* rather than the rendering. Body:
#
#   ESC ] 7447 ; lcars ; <version> ; chips [ ; <kind> ; <label> ]... ST
#
# The shell names what a chip means (err/venv/py/aws/awsdep/git/gitstate);
# nvim/lua/lcars/block_chips.lua maps kind -> highlight group, so colors stay a
# neovim concern. `;` separates fields, so `;` and `%` are percent-encoded in
# labels (branch names may legally contain either). Terminals that don't know
# OSC 7447 ignore it, which makes this safe to emit unconditionally.
#
# The version sits BEFORE the message type, not after it. After `chips` the
# fields are kind/label pairs read two at a time, so a version there would make
# a pre-version reader treat it as a kind and the first real kind as its label —
# silent garbage. In front of the message type, a pre-version reader's
# `^7447;lcars;chips` match simply fails and it ignores the message, which is
# the required behavior for an unrecognized message.
_lcars_emit_chips() {
  local out="" lbl
  local -i i
  for (( i=1; i<=$#; i+=2 )); do
    lbl=${argv[i+1]//\%/%25}
    out+=";${argv[i]};${lbl//;/%3B}"
  done
  printf '\e]7447;lcars;%s;chips%s\e\\' "$_LCARS_OSC_VERSION" "$out"
}

# ---- hooks -----------------------------------------------------------------
# The order below is load-bearing and is the reason this layer installs the
# renderer's hooks rather than letting the renderer install its own. Within one
# prompt the sequence must be:
#
#   133;D  ->  [renderer draws]  ->  133;A, chips, OSC 7, 133;B
#
# D goes first, before any decorative output, so that whatever the renderer
# prints streams out while no block is open — the previous block closed at D and
# the next does not open until A. pty_session drops output_line callbacks with
# no live block, so the prompt's own chrome never lands in a rendered command's
# captured output.
#
# B goes last for the mirror-image reason: it opens the skip_lines suppression
# window that pty_session already uses for echoed input, which also swallows the
# renderer's PROMPT bytes until preexec's closing 133;C. See
# docs/nvim-terminal-frame.md.

# precmd, first half: close the previous command, then gather state for this
# prompt so the renderer (which runs between the halves) can use it.
# _LCARS_CMD_RAN is set by preexec and consumed here. It is snapshotted into
# _LCARS_S_CMD_RAN (which the renderer reads to decide whether to draw its
# end-of-command line) and cleared HERE rather than by the renderer, so a
# headless shell — where no renderer runs — does not keep re-emitting 133;D
# with a stale exit code on every bare-Enter prompt.
_lcars_data_precmd_open() {
  local last_exit=$?
  typeset -g _LCARS_S_CMD_RAN=$_LCARS_CMD_RAN
  _LCARS_CMD_RAN=
  [[ -n $_LCARS_S_CMD_RAN ]] && printf '\e]133;D;%d\e\\' "$last_exit"
  _lcars_gather_state "$last_exit"
}

# precmd, second half: open the next block and describe it.
_lcars_data_precmd_close() {
  printf '\e]133;A\e\\'
  _lcars_build_chips
  _lcars_emit_chips "${_LCARS_CHIP_KV[@]}"
  printf '\e]7;file://%s%s\e\\' "$HOST" "$PWD"
  printf '\e]133;B\e\\'
}

# preexec: ends the suppression window opened by the trailing 133;B above, which
# is what keeps the renderer's own bytes out of the command's captured output.
# Must be the LAST preexec hook to run.
_lcars_data_preexec() {
  _LCARS_CMD_RAN=1
  printf '\e]133;C\e\\'
}

# ---- install ---------------------------------------------------------------
# lcars_prompt_data_install [render_precmd] [render_preexec]
#
# Registers the data hooks, with the renderer's hooks interleaved at the one
# point where they belong. Stating the order here — in one place, as an argument
# list — is why neither file has to reason about precmd_functions array indices.
#
# Called with no arguments you get a fully headless shell: correct OSC feed,
# untouched PROMPT.
lcars_prompt_data_install() {
  local render_precmd=${1-} render_preexec=${2-}
  autoload -Uz add-zsh-hook
  lcars_prompt_data_uninstall
  add-zsh-hook precmd _lcars_data_precmd_open
  [[ -n $render_precmd ]] && add-zsh-hook precmd "$render_precmd"
  add-zsh-hook precmd _lcars_data_precmd_close
  [[ -n $render_preexec ]] && add-zsh-hook preexec "$render_preexec"
  add-zsh-hook preexec _lcars_data_preexec
  typeset -g _LCARS_DATA_RENDER_PRECMD=$render_precmd
  typeset -g _LCARS_DATA_RENDER_PREEXEC=$render_preexec
  return 0
}

lcars_prompt_data_uninstall() {
  autoload -Uz add-zsh-hook
  add-zsh-hook -d precmd  _lcars_data_precmd_open
  add-zsh-hook -d precmd  _lcars_data_precmd_close
  add-zsh-hook -d preexec _lcars_data_preexec
  [[ -n $_LCARS_DATA_RENDER_PRECMD  ]] && add-zsh-hook -d precmd  "$_LCARS_DATA_RENDER_PRECMD"
  [[ -n $_LCARS_DATA_RENDER_PREEXEC ]] && add-zsh-hook -d preexec "$_LCARS_DATA_RENDER_PREEXEC"
  _LCARS_DATA_RENDER_PRECMD= _LCARS_DATA_RENDER_PREEXEC=
  return 0
}
