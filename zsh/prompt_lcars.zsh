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
_LCARS_FRAME=3          # elbow image rows: bar(2) + stem(1) w/ inner fillet; regen if changed

# Swoop end-cap images. gen_swoops.py names each PNG for its inputs (kind, orientation,
# facing edge, bar color, and cell/pixel size) so variants coexist instead of overwriting
# one name. These must match the deployed periwinkle set at 19x40px cells; if you change
# _LC_O (the bar color) or the cell metrics, regenerate and update the filenames here:
#   gen_swoops.py --color <hex>            (default cells 19x40)
# elbow-left + cap-right are always used; the -right elbow / -left cap are used only by the
# (currently disabled) split-swoop feature — see _LCARS_SPLIT_SWOOP below.
_LCARS_ELBOW_LEFT="$_LCARS_DIR/elbow-top-left-9999ff-5x3cells-19x40pixels.png"
_LCARS_ELBOW_RIGHT="$_LCARS_DIR/elbow-top-right-9999ff-5x3cells-19x40pixels.png"
_LCARS_CAP_LEFT="$_LCARS_DIR/cap-round-left-9999ff-2x2cells-19x40pixels.png"
_LCARS_CAP_RIGHT="$_LCARS_DIR/cap-round-right-9999ff-2x2cells-19x40pixels.png"

# ---- split-swoop feature toggle (DISABLED) ---------------------------------
# When enabled, the prompt queries its kitty pane's neighbors (via `kitty @ ls`, cached +
# refreshed on SIGWINCH) and swaps the round cap on any pane-abutting edge for a mirrored
# elbow, so adjacent panes' elbows meet over the divider as a double swoop; a solo pane's
# elbow side then follows $_LCARS_STEM_SIDE. It's currently OFF: little benefit for the cost
# (a ~50ms per-prompt query, the WINCH trap, mirrored assets, and the right-edge stem/fillet
# it never fully drew). Left in place — all the machinery below (_lcars_detect_pane,
# TRAPWINCH, the elbow/cap selection, the id2/id3 transmit) is gated on this flag, so setting
# it back to 1 restores the behavior. With it off the bar is always left-elbow + right-cap.
_LCARS_SPLIT_SWOOP=          # empty = disabled; set to 1 to re-enable
: ${_LCARS_STEM_SIDE:=left}  # solo-pane elbow side, only consulted when split-swoop is on

# LCARS palette as SGR truecolor bodies
_LC_O='153;153;255'     # bar base (periwinkle — muted so the chips pop; was orange 255;153;0)
_LC_LIL='204;153;204'   # venv chip
_LC_PERI='102;153;204'  # python chip (deep sky — separates from venv violet)
_LC_GOLD='255;204;102'  # git chip
_LC_RED='255;51;0'      # error chip / failure LED (red-alert)
_LC_OK='153;204;153'    # success LED (sage green)
_LC_AWS='255;153;51'    # AWS chip (orange)
_LC_W='255;255;198'     # nested text
_LC_DIM='120;120;140'   # timestamps
# LED colors: start = _LC_PERI (sky, neutral), end = _LC_OK (ok) / _LC_RED (fail)

# ---- git chip labels: LCARS "NN-WORD" dashed codes (count on the left) ------
# One gold chip per state, shown only when its count > 0. Words, not symbols, so
# the meaning is legible; rename freely.
_LC_GIT_STAGED='STAGED'     # files staged in the index
_LC_GIT_MODIFIED='MODIFIED' # tracked files with unstaged edits
_LC_GIT_UNTRACKED='UNTRACKED' # untracked files

# ---- toolkit: raw SGR + spacing + image placement --------------------------
_lc_bg()    { print -n -- "\e[48;2;${1}m"; }
_lc_fg()    { print -n -- "\e[38;2;${1}m"; }
_lc_blk()   { print -n -- "\e[48;2;0;0;0m"; }
_lc_rst()   { print -n -- "\e[0m"; }
_lc_sp()    { print -n -- "${(l:$1:)}"; }                 # $1 spaces
_lc_rjust() { print -n -- "${(l:$(($1-${#2})):)}$2"; }    # right-justify $2 in width $1
_lc_col()   { printf '\e[%dG' "$1"; }                     # absolute column
_lc_down()  { printf '\e[%dB' "${1:-1}"; }

# ---- kitty Unicode placeholders (reflow-safe image cells) -------------------
# The elbow/cap curves are drawn as kitty *Unicode placeholders* rather than
# cursor-anchored (a=T) images. A placeholder is a real text cell holding U+10EEEE
# plus a (row,col) combining diacritic; kitty paints the referenced image's matching
# grid cell into it. Because the cell lives in the text stream, it reflows and scrolls
# with its bar on a pane resize — fixing the "dangling elbow" in scrollback that plain
# a=T placements leave behind (they stay pinned to the draw-time screen cell).
#
# Each image is transmitted ONCE with a fixed id and a virtual placement (U=1) sized in
# cells (c×r); the diacritics below index that c×r grid. The image id rides the cell's
# foreground color (\e[38;5;<id>m), so ids must stay < 256.
_LC_PH=$'\U0010EEEE'                                       # the placeholder codepoint
# rowcolumn diacritics 0..4 (kitty's fixed table): U+0305 030D 030E 0310 0312.
# We only need 3 rows (elbow) and up to 5 cols (elbow width).
_LC_RD=( $'\u0305' $'\u030d' $'\u030e' $'\u0310' $'\u0312' )
_lc_ph() {  # $1 image-id  $2 grid-row (0-based)  $3 ncols  [$4 flat-col]
  # Emit one row of placeholder cells. Cells default to a black background (shows through
  # the image's transparent corners = the LCARS void). $4, if given, is the column that
  # butts against the flat bar (the elbow's outer edge, or a cap's flat side): it gets the
  # bar-color bg instead, so a sub-pixel seam between the image cell and the abutting bar
  # cells blends into the bar rather than showing a 1px black gap.
  local -i id=$1 gr=$2 n=$3 flat=${4:--1} x
  print -n -- "\e[38;5;${id}m"                            # fg carries the image id (persists)
  for (( x=0; x<n; x++ )); do
    (( x == flat )) && _lc_bg "$_LC_O" || _lc_blk
    print -n -- "${_LC_PH}${_LC_RD[gr+1]}${_LC_RD[x+1]}"
  done
  print -n -- "\e[0m"
}
_lc_transmit() {  # $1 path  $2 id  $3 cols  $4 rows — transmit + create a virtual placement
  local b; b=$(print -rn -- "$1" | base64 | tr -d '\n')
  printf '\e_Ga=T,U=1,i=%d,f=100,t=f,c=%d,r=%d,q=2;%s\e\\' "$2" "$3" "$4" "$b"
}
# Fixed image ids: 1 elbow-left, 2 elbow-right, 3 cap-left, 4 cap-right. Sent once per
# shell; the c×r grid is in cells, so kitty rescales the placement on font/zoom changes
# and no retransmit is needed on resize. Re-armed by _lcars_prompt_enable. ids 2/3 are only
# needed by the split-swoop feature, so they're transmitted only when it's enabled.
_lcars_transmit_images() {
  [[ -n $_LCARS_IMAGES_SENT ]] && return
  _lc_transmit "$_LCARS_ELBOW_LEFT" 1 "$_LCARS_ELBOW" "$_LCARS_FRAME"
  _lc_transmit "$_LCARS_CAP_RIGHT"  4 "$_LCARS_CAP"   2
  if [[ -n $_LCARS_SPLIT_SWOOP ]]; then
    _lc_transmit "$_LCARS_ELBOW_RIGHT" 2 "$_LCARS_ELBOW" "$_LCARS_FRAME"
    _lc_transmit "$_LCARS_CAP_LEFT"    3 "$_LCARS_CAP"   2
  fi
  _LCARS_IMAGES_SENT=1
}

_lcars_graphics_ok() { [[ -n $KITTY_WINDOW_ID && -z $TMUX && -z $SSH_TTY && $TERM == *kitty* ]]; }

# ---- pane position: is there a split to our right? --------------------------
# NOTE: dormant unless _LCARS_SPLIT_SWOOP is set (feature disabled by default). Kept so the
# split double-swoop can be switched back on; precmd only calls this when the flag is on.
#
# In a vsplit, a left pane's divider-facing (right) edge swaps its round cap for a
# mirrored elbow so the bar sweeps down into the (orange) kitty border, meeting the
# right pane's existing left elbow -> a double swoop across the divider. The right
# pane needs no change (its left elbow already hugs the divider).
#
# kitty @ ls exposes each window's `neighbors` ({left|right|top|bottom: [ids]}); we
# read the is_self window's. The query is ~50ms, so we cache it and only refresh on
# SIGWINCH (split/close/resize all resize the pane and fire WINCH).
_lcars_detect_pane() {
  _LCARS_HAS_LEFT= _LCARS_HAS_RIGHT=
  _lcars_graphics_ok || return
  [[ -n $KITTY_LISTEN_ON ]] || return
  local sides
  sides=$(kitty @ --to "$KITTY_LISTEN_ON" ls 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
for osw in d:
  for t in osw.get("tabs", []):
    for w in t.get("windows", []):
      if w.get("is_self"):
        print(" ".join(w.get("neighbors", {}).keys())); raise SystemExit
') || return
  [[ $sides == *left*  ]] && _LCARS_HAS_LEFT=1
  [[ $sides == *right* ]] && _LCARS_HAS_RIGHT=1
}
TRAPWINCH() { _LCARS_PANE_DIRTY=1 }   # coalesce; precmd recomputes lazily when dirty

# ---- segment values (plain text) -------------------------------------------
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

# Compact branch + indicators, for the plain non-graphics fallback prompt only.
_lcars_git_seg() {
  local branch; branch=$(_lcars_git_branch) || return
  [[ -z $branch ]] && return
  local -a c; c=(${(s: :)$(_lcars_git_counts)}); local ind=""
  (( c[1] )) && ind+='+'; (( c[2] )) && ind+='!'; (( c[3] )) && ind+='?'
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

_lcars_aws_seg() {
  [[ -z $AWS_PROFILE ]] && return
  print -rn -- " AWS|${AWS_PROFILE} "
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
  _lcars_graphics_ok || return
  # start line: [sky LED] STARDATE <astronomical Julian Day Number>  <UTC datetime>
  local -i jdn=$(( EPOCHSECONDS / 86400 + 2440588 ))
  local dt; TZ=UTC strftime -s dt '0%Y-%m-%dT%H:%M:%Sz' $EPOCHSECONDS
  printf '\e[48;2;%sm \e[0m \e[38;2;%smSTARDATE %d  %s\e[0m\n' "$_LC_PERI" "$_LC_DIM" "$jdn" "$dt"
}

# ---- precmd ----------------------------------------------------------------
_lcars_swoop_precmd() {
  local last_exit=$?

  if ! _lcars_graphics_ok; then
    local gi; gi=$(_lcars_git_seg)
    local aw=""
    if [[ -n $AWS_PROFILE ]]; then
      local aw_color="#ff9933"; [[ $AWS_PROFILE == dep ]] && aw_color="#ff3300"
      aw="%F{${aw_color}}AWS|${AWS_PROFILE}%f "
    fi
    PROMPT="%F{#5599ff}%~%f ${gi:+%F{#ffcc66}$gi%f }${aw}"$'\n'"%K{#9999ff} %k "
    PROMPT2="%K{#9999ff} %k "
    return
  fi

  # Pick each end's image. Default (split-swoop disabled): always a left elbow + a right cap.
  # An elbow (rounded corner + stem) bakes its own bar (lead 0); a cap gets `lead` orange bar
  # cols between the flat bar and the round end. The two bar rows are drawn as placeholder
  # cells (grid rows 0-1); the left elbow's 3rd grid row (stem stub + inner fillet) is drawn
  # on the input line via PROMPT (below) so it reflows too.
  local -i left_elbow=1 right_elbow=0
  if [[ -n $_LCARS_SPLIT_SWOOP ]]; then
    # Split-swoop ON: an elbow goes on every side that abuts another pane, so adjacent panes'
    # elbows meet at the divider (a double swoop over the orange border); the outer,
    # non-abutting side gets a round cap. A solo pane falls back to $_LCARS_STEM_SIDE.
    if [[ -z $_LCARS_PANE_CHECKED || -n $_LCARS_PANE_DIRTY ]]; then
      _lcars_detect_pane; _LCARS_PANE_CHECKED=1; _LCARS_PANE_DIRTY=   # refresh on 1st prompt + WINCH
    fi
    left_elbow=0 right_elbow=0
    if [[ -n $_LCARS_HAS_LEFT || -n $_LCARS_HAS_RIGHT ]]; then
      [[ -n $_LCARS_HAS_LEFT  ]] && left_elbow=1
      [[ -n $_LCARS_HAS_RIGHT ]] && right_elbow=1
    else
      [[ $_LCARS_STEM_SIDE == right ]] && right_elbow=1 || left_elbow=1
    fi
  fi

  local -i left_id right_id left_w right_w left_lead right_lead
  if (( left_elbow )); then left_id=1; left_w=$_LCARS_ELBOW; left_lead=0
  else                      left_id=3; left_w=$_LCARS_CAP;   left_lead=2; fi
  if (( right_elbow )); then right_id=2; right_w=$_LCARS_ELBOW; right_lead=0
  else                       right_id=4; right_w=$_LCARS_CAP;   right_lead=2; fi

  # 1) Close the previous command with an end-timestamp line (no bottom bar).
  #    [LED: green ok / red fail] <UTC datetime>  <duration if over threshold>
  if [[ -n $_LCARS_CMD_RAN ]]; then
    local -i dur=0; (( dur = (EPOCHREALTIME - ${_LCARS_START:-$EPOCHREALTIME}) * 1000 ))
    local d=""; (( dur > ${CMD_DURATION_THRESHOLD:-2000} )) && d="  ${dur}ms"
    local led=$_LC_OK; (( last_exit != 0 )) && led=$_LC_RED
    local dt; TZ=UTC strftime -s dt '0%Y-%m-%dT%H:%M:%Sz' $EPOCHSECONDS
    printf '\e[48;2;%sm \e[0m \e[38;2;%sm%s%s\e[0m\n' "$led" "$_LC_DIM" "$dt" "$d"
    _LCARS_CMD_RAN=
  fi

  # 2) Gather segments.  (note: `status` is a read-only special in zsh -> use `estat`)
  local venv="" py gbranch estat cwd aws
  [[ -n $VIRTUAL_ENV ]] && venv="${VIRTUAL_ENV:t}"
  [[ -z $venv && -f pyproject.toml && -d .venv ]] && venv="uv"
  py=$(_lcars_py_seg); gbranch=$(_lcars_git_branch)
  (( last_exit != 0 )) && estat="$last_exit"
  cwd="${(%):-%~}"
  aws=$(_lcars_aws_seg)

  # Build chip list (label text incl. padding, color).
  local -a chips
  [[ -n $estat ]] && chips+=(" $estat " "$_LC_RED")
  [[ -n $venv   ]] && chips+=(" $venv "   "$_LC_LIL")
  [[ -n $py     ]] && chips+=(" $py "     "$_LC_PERI")
  if [[ -n $aws ]]; then
    local aws_color=$_LC_AWS
    [[ $AWS_PROFILE == dep ]] && aws_color=$_LC_RED
    chips+=("$aws" "$aws_color")
  fi
  # git: branch + one gold "NN-WORD" chip per non-empty state (staged/modified/untracked)
  if [[ -n $gbranch ]]; then
    chips+=(" $gbranch " "$_LC_GOLD")
    local -a gc; gc=(${(s: :)$(_lcars_git_counts)})
    (( gc[1] )) && chips+=(" $(printf '%02d-%s' $gc[1] $_LC_GIT_STAGED) "    "$_LC_GOLD")
    (( gc[2] )) && chips+=(" $(printf '%02d-%s' $gc[2] $_LC_GIT_MODIFIED) "  "$_LC_GOLD")
    (( gc[3] )) && chips+=(" $(printf '%02d-%s' $gc[3] $_LC_GIT_UNTRACKED) " "$_LC_GOLD")
  fi

  local ptxt=" $cwd "
  local -i mid=$(( COLUMNS - left_w - right_w ))       # cells between the two end images
  local -i amotif=$(( 2 + ${#ptxt} + right_lead ))     # black rule + accent col + notch + right lead-in
  local -i chipsw=0 i
  for (( i=1; i<=$#chips; i+=2 )); do (( chipsw += ${#chips[i]} )); done
  local -i nchips=$(( $#chips / 2 ))
  local -i gapw=0; (( nchips > 0 )) && gapw=$(( nchips + 1 ))   # N+1 combed gap cols
  local -i fill=$(( mid - left_lead - chipsw - gapw - amotif )); (( fill < 0 )) && fill=0

  # 3) Top swoop bar as two chrome lines. The curved ends are Unicode placeholders (real
  # text cells), so each row scrolls and reflows with its bar on a pane resize instead of
  # leaving a pinned, dangling elbow/cap in scrollback. Printing the rows with trailing
  # newlines lets the terminal scroll them naturally (no reserve/relative-cursor dance).
  _lcars_transmit_images
  # The bar-abutting edge is the LAST col of the left end and col 0 of the right end (true for
  # both the elbow and the cap on each side); pass it as flat-col so its cell blends into the
  # bar (no 1px seam). See _lc_ph.
  local -i lflat=$(( left_w - 1 )) rflat=0
  # bar row 0 (top): [left end] [left lead] chip colors blank + fill + blank notch + [right lead] [right end]
  _lc_ph "$left_id" 0 "$left_w" "$lflat"; _lc_bg "$_LC_O"; _lc_sp "$left_lead"
  LC_ROWMODE=blank _lcars_chips "${chips[@]}"
  _lc_bg "$_LC_O"; _lc_sp "$fill"
  _lc_blk; _lc_sp 1; _lc_bg "$_LC_O"; _lc_sp 1; _lc_blk; _lc_sp "${#ptxt}"
  _lc_bg "$_LC_O"; _lc_sp "$right_lead"; _lc_rst
  _lc_ph "$right_id" 0 "$right_w" "$rflat"; print
  # bar row 1 (bottom): [left end] [left lead] Style-B chips + fill + Style-A path notch + [right lead] [right end]
  _lc_ph "$left_id" 1 "$left_w" "$lflat"; _lc_bg "$_LC_O"; _lc_sp "$left_lead"
  LC_ROWMODE=text _lcars_chips "${chips[@]}"
  _lc_bg "$_LC_O"; _lc_sp "$fill"
  _lc_blk; _lc_sp 1; _lc_bg "$_LC_O"; _lc_sp 1; _lc_blk; _lc_fg "$_LC_O"; print -n -- "$ptxt"
  _lc_bg "$_LC_O"; _lc_sp "$right_lead"; _lc_rst
  _lc_ph "$right_id" 1 "$right_w" "$rflat"; print

  # Input line (elbow grid row 2). The stem stub + inner fillet ARE the elbow image's third
  # row, so drawing them as the real placeholder cells (grid row 2, cols 0-1) makes the stem
  # a pixel-exact continuation of the bar above — same image, so no seam and the fillet is
  # kept. zsh counts each placeholder cell as 1 display column (verified), so PROMPT stays
  # width-correct with the editable area at col 3; the ESC runs are %{…%}-wrapped as zero
  # width. PROMPT2 continues the stem below as a plain periwinkle bg cell (no fillet), which
  # lines up under the image stem at col 1. A cap on the left has no stem → both plain.
  if (( left_elbow )); then
    local E=$'\e'
    local _s0="${_LC_PH}${_LC_RD[3]}${_LC_RD[1]}"   # grid row 2, col 0: stem
    local _s1="${_LC_PH}${_LC_RD[3]}${_LC_RD[2]}"   # grid row 2, col 1: inner fillet
    PROMPT="%{${E}[48;2;0;0;0m${E}[38;5;${left_id}m%}${_s0}${_s1}%{${E}[0m%}"
    PROMPT2="%K{#9999ff} %k "
  else
    PROMPT="  "; PROMPT2="  "
  fi
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
  _LCARS_IMAGES_SENT=   # re-transmit the placeholder images on (re-)enable / re-source
  # Arm pane detection for the first prompt (only consulted when split-swoop is enabled).
  _LCARS_PANE_CHECKED=; _LCARS_PANE_DIRTY=1
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
