# LCARS swoop prompt — a switchable prompt that renders your prompt segments as an
# LCARS bar: Style-B color chips (dark text on a color) finishing with the path as a
# Style-A notch (accent text on black), framed by a swoop elbow + a round cap.
#
# Nomenclature (see lcarcat): bar = colored cells, swoop = left elbow + stem,
# cap = right round end, chip = labeled segment (Style B), notch = accent text on black (Style A).
#
# Flat parts are terminal cells; only the curved ends (elbow/cap) are kitty images.
# Depends on nothing from prompt.zsh. Toggle with:  lcarsprompt on | off | (toggle)

zmodload zsh/datetime 2>/dev/null
autoload -Uz add-zsh-hook

_LCARS_DIR=${HOME}/.config/kitty/lcars
_LCARS_ELBOW=5          # cols reserved for the left elbow image
_LCARS_CAP=2            # cols reserved for the right cap image
_LCARS_FRAME=3          # bar(2) + stem(1); regenerate images if you change stem rows

# LCARS palette as SGR truecolor bodies
_LC_O='255;153;0'       # bar accent (orange)
_LC_LIL='204;153;204'   # venv chip
_LC_PERI='102;153;204'  # python chip (deep sky — separates from venv violet)
_LC_GOLD='255;204;102'  # git chip
_LC_RED='255;51;0'      # error chip (red-alert; color alone signals failure)
_LC_W='255;255;198'     # nested text
_LC_DIM='120;120;140'   # timestamps

# ---- toolkit: raw SGR + spacing + image placement --------------------------
_lc_bg()    { print -n -- "\e[48;2;${1}m"; }
_lc_fg()    { print -n -- "\e[38;2;${1}m"; }
_lc_blk()   { print -n -- "\e[48;2;0;0;0m"; }
_lc_rst()   { print -n -- "\e[0m"; }
_lc_sp()    { print -n -- "${(l:$1:)}"; }                 # $1 spaces
_lc_rjust() { print -n -- "${(l:$(($1-${#2})):)}$2"; }    # right-justify $2 in width $1
_lc_col()   { printf '\e[%dG' "$1"; }                     # absolute column
_lc_down()  { printf '\e[%dB' "${1:-1}"; }
_lc_place() {  # $1 path  $2 cols  $3 rows  (placed at cursor, cursor unmoved)
  local b; b=$(print -rn -- "$1" | base64 | tr -d '\n')
  printf '\e_Ga=T,f=100,t=f,c=%s,r=%s,C=1;%s\e\\' "$2" "$3" "$b"
}
# Scroll to guarantee $1 rows exist below the cursor, then return to the top of them
# (so a multi-row bar drawn with relative cursor moves fits even at the screen bottom).
_lc_reserve() { local -i i; for (( i=0; i<$1; i++ )); do print; done; printf '\e[%dA' "$1"; }
_lc_cap_at() { _lc_col $(( COLUMNS - _LCARS_CAP + 1 )); _lc_place "$_LCARS_DIR/cap-right.png" "$_LCARS_CAP" 2; }

_lcars_graphics_ok() { [[ -n $KITTY_WINDOW_ID && -z $TMUX && -z $SSH_TTY && $TERM == *kitty* ]]; }

# ---- segment values (plain text) -------------------------------------------
_lcars_git_seg() {
  git rev-parse --is-inside-work-tree &>/dev/null || return
  local branch st ind=""
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || git describe --tags --exact-match 2>/dev/null || echo detached)
  st=$(git status --porcelain 2>/dev/null)
  [[ $st == *$'\n'* || -n $st ]] && {
    print -r -- "$st" | grep -qE '^.M|^M ' && ind+='!'
    print -r -- "$st" | grep -q  '^??'      && ind+='?'
    print -r -- "$st" | grep -qE '^[MARCD]' && ind+='+'
  }
  print -rn -- "${branch}${ind:+ $ind}"
}

_lcars_py_seg() {
  local tv=""
  if git rev-parse --show-toplevel &>/dev/null; then tv="$(git rev-parse --show-toplevel)/.tool-versions"
  elif [[ -f .tool-versions ]]; then tv=.tool-versions; fi
  [[ -f $tv ]] || return
  local v; v=$(awk '/^python / {print $2}' "$tv")
  [[ -n $v ]] && print -rn -- "py $v"
}

# ---- render one bar row of Style-B chips (text row) or blanks (other row) ---
# args: alternating "text" "color" ... ; $LC_ROWMODE = text|blank
# Chips ride on a 1-col black gap on either side; adjacent chips share (comb) a
# single gap column, so N chips draw N+1 gaps. Width bookkeeping must match: see
# `gapw` in the precmd fill calc.
_lcars_chips() {
  local i
  (( $# > 0 )) && { _lc_blk; _lc_sp 1; }                  # leading gap
  for (( i=1; i<=$#; i+=2 )); do
    _lc_bg "${@[i+1]}"
    if [[ $LC_ROWMODE == text ]]; then _lc_fg '0;0;0'; print -n -- "${@[i]}"; else _lc_sp "${#${@[i]}}"; fi
    _lc_blk; _lc_sp 1                                      # trailing gap (combs with next chip's leading)
  done
}

# ---- preexec ---------------------------------------------------------------
_lcars_swoop_preexec() {
  _LCARS_START=$EPOCHREALTIME
  _LCARS_CMD_RAN=1
  _lcars_graphics_ok && printf '\e[38;2;%sm  → [%s]\e[0m\n' "$_LC_DIM" "$(strftime '%H:%M:%S' $EPOCHSECONDS)"
}

# ---- precmd ----------------------------------------------------------------
_lcars_swoop_precmd() {
  local last_exit=$?

  if ! _lcars_graphics_ok; then
    local gi; gi=$(_lcars_git_seg)
    PROMPT="%F{#5599ff}%~%f ${gi:+%F{#ffcc66}$gi%f }"$'\n'"%F{#ff9900}%#%f "
    return
  fi

  # 1) Close the previous command with a plain end-timestamp line (no bottom bar).
  if [[ -n $_LCARS_CMD_RAN ]]; then
    local -i dur=0; (( dur = (EPOCHREALTIME - ${_LCARS_START:-$EPOCHREALTIME}) * 1000 ))
    local d=""; (( dur > ${CMD_DURATION_THRESHOLD:-2000} )) && d=" ⏱ ${dur}ms"
    printf '\e[38;2;%sm  ↩ [%s]%s\e[0m\n' "$_LC_DIM" "$(strftime '%H:%M:%S' $EPOCHSECONDS)" "$d"
    _LCARS_CMD_RAN=
  fi

  # 2) Gather segments.  (note: `status` is a read-only special in zsh -> use `estat`)
  local venv="" py gitseg estat cwd
  [[ -n $VIRTUAL_ENV ]] && venv="${VIRTUAL_ENV:t}"
  [[ -z $venv && -f pyproject.toml && -d .venv ]] && venv="uv"
  py=$(_lcars_py_seg); gitseg=$(_lcars_git_seg)
  (( last_exit != 0 )) && estat="$last_exit"
  cwd="${(%):-%~}"

  # Build chip list (label text incl. padding, color).
  local -a chips
  [[ -n $estat ]] && chips+=(" $estat " "$_LC_RED")
  [[ -n $venv   ]] && chips+=(" $venv "   "$_LC_LIL")
  [[ -n $py     ]] && chips+=(" $py "     "$_LC_PERI")
  [[ -n $gitseg ]] && chips+=(" $gitseg " "$_LC_GOLD")

  local ptxt=" $cwd "
  local -i mid=$(( COLUMNS - _LCARS_ELBOW - _LCARS_CAP ))
  local -i amotif=$(( 4 + ${#ptxt} ))          # black rule + accent col + notch + 2 bar cols before cap
  local -i chipsw=0 i
  for (( i=1; i<=$#chips; i+=2 )); do (( chipsw += ${#chips[i]} )); done
  local -i nchips=$(( $#chips / 2 ))
  local -i gapw=0; (( nchips > 0 )) && gapw=$(( nchips + 1 ))   # N+1 combed gap cols
  local -i fill=$(( mid - chipsw - gapw - amotif )); (( fill < 0 )) && fill=0

  # 3) Top swoop bar. Reserve its rows first so it fits at the screen bottom.
  _lc_reserve "$_LCARS_FRAME"
  _lc_place "$_LCARS_DIR/elbow-top.png" "$_LCARS_ELBOW" "$_LCARS_FRAME"       # bar rows0-1, stem row2
  # bar row 0 (top): chip colors blank + fill + Style-A path notch (accent text) + 2 bar cols + cap
  _lc_col $((_LCARS_ELBOW+1)); LC_ROWMODE=blank _lcars_chips "${chips[@]}"
  _lc_bg "$_LC_O"; _lc_sp "$fill"
  _lc_blk; _lc_sp 1; _lc_bg "$_LC_O"; _lc_sp 1; _lc_blk; _lc_fg "$_LC_O"; print -n -- "$ptxt"
  _lc_bg "$_LC_O"; _lc_sp 2; _lc_rst          # two bar-color cols before the round cap
  _lc_cap_at
  # bar row 1 (bottom): Style-B chips (dark text) + fill + blank notch + 2 bar cols
  _lc_down 1; _lc_col $((_LCARS_ELBOW+1)); LC_ROWMODE=text _lcars_chips "${chips[@]}"
  _lc_bg "$_LC_O"; _lc_sp "$fill"
  _lc_blk; _lc_sp 1; _lc_bg "$_LC_O"; _lc_sp 1; _lc_blk; _lc_sp "${#ptxt}"
  _lc_bg "$_LC_O"; _lc_sp 2; _lc_rst          # two bar-color cols before the round cap
  # stem row (input line): drop to it, leave cursor at col 1 for the prompt
  _lc_down 1; _lc_col 1

  PROMPT="  %F{#ff9900}%#%f "
}

# ---- toggle ----------------------------------------------------------------
_lcars_prompt_enable() {
  add-zsh-hook -d precmd  print_prompt_timestamp
  add-zsh-hook -d preexec print_command_timestamp
  add-zsh-hook -d preexec track_command_start
  unfunction precmd 2>/dev/null
  add-zsh-hook precmd  _lcars_swoop_precmd
  add-zsh-hook preexec _lcars_swoop_preexec
  _LCARS_PROMPT_ON=1
  if zle; then zle reset-prompt; fi
  return 0
}
_lcars_prompt_disable() {
  add-zsh-hook -d precmd  _lcars_swoop_precmd
  add-zsh-hook -d preexec _lcars_swoop_preexec
  _LCARS_PROMPT_ON=
  source ~/.config/zsh/prompt.zsh
  if zle; then zle reset-prompt; fi
  return 0
}
lcarsprompt() {
  case "${1:-toggle}" in
    on)  _lcars_prompt_enable ;;
    off) _lcars_prompt_disable ;;
    *)   [[ -n $_LCARS_PROMPT_ON ]] && _lcars_prompt_disable || _lcars_prompt_enable ;;
  esac
}
