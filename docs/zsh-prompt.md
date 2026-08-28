# Zsh Prompt Architecture

Two files, split by job:

| File | Job |
|------|-----|
| `zsh/lcars_prompt_data.zsh` | **Data.** Gathers prompt state and emits it as escape sequences. Draws nothing, sets no `PROMPT`. |
| `zsh/prompt_lcars.zsh` | **Render.** The LCARS swoop prompt. Sources the data layer and draws on top of it. Toggle with `lcarsprompt on\|off`. |

Falls back to a plain two-line zsh prompt outside kitty (tmux, SSH).

The dependency runs one way. The data layer works with the renderer absent —
that is what `:LcarsTerm` uses — but the renderer cannot work without the data
layer, because it reads the `_LCARS_S_*` state the data layer gathered.

---

## Why they are separate

The renderer used to do both jobs, and the combination had a nasty property:
**the data job had no visual feedback in the environment where the rendering job
ran.** If the OSC 7447 payload broke while you were in kitty, the swoop bar still
looked perfect and nothing told you. You found out next time you opened
`:LcarsTerm`.

Splitting them makes the data layer independently testable — feed it a state,
assert on the emitted bytes, with no terminal, kitty, or screenshots involved.
See `test/unit/prompt_data_test.zsh`.

---

## What the data layer owns

- **Segment gathering** — `_lcars_git_branch`, `_lcars_git_counts`,
  `_lcars_py_seg`, `_lcars_venv_seg`, into the `_LCARS_S_*` globals, once per
  prompt. Both the swoop bar and the wire payload read those, so neither pays
  for a second round of git subprocesses.
- **OSC 133** command boundaries (`A`/`B`/`C`/`D`) for `lcars.pty_session`.
- **OSC 7** cwd reporting.
- **OSC 7447** the versioned chip feed — see [`osc-7447.md`](osc-7447.md).
- **Hook installation**, including the renderer's (below).

It is permanent, not a bridge. nvim could derive `py` and `git`/`gitstate` from
the cwd it already has, but `venv` (`$VIRTUAL_ENV`) and `aws` (`$AWS_PROFILE`)
are the live environment of a process nvim spawned and cannot inspect — no
`/proc` on macOS, and `ps eww` prints argv without environ. Activate a venv in a
`:LcarsTerm` shell and nvim can only learn of it by being told.

---

## Hook ordering

Load-bearing, and the reason the data layer installs the renderer's hooks rather
than the renderer installing its own. Within one prompt:

```
133;D  →  [renderer draws]  →  133;A, chips, OSC 7, 133;B
```

`D` goes first, before any decorative output, so whatever the renderer prints
streams out while no block is open — the previous block closed at `D` and the
next does not open until `A`. `pty_session` drops `output_line` callbacks with no
live block, so the prompt's own chrome never lands in a rendered command's
captured output.

`B` goes last for the mirror reason: it opens the `skip_lines` suppression window
that also swallows the renderer's `PROMPT` bytes until preexec's closing `133;C`.

`lcars_prompt_data_install` takes the render hooks as arguments and produces:

```
precmd_functions  = (_lcars_data_precmd_open  _lcars_swoop_precmd  _lcars_data_precmd_close)
preexec_functions = (_lcars_swoop_preexec     _lcars_data_preexec)
```

Called with no arguments it installs headless — correct feed, untouched
`PROMPT`. Stating the order there, as an argument list, is why neither file has
to reason about `precmd_functions` array indices.

**If you add another zsh hook to this prompt** (atuin, direnv, anything that
wants precmd/preexec), it has to be placed relative to those boundaries, not
appended blindly. A hook that prints goes in the renderer slot; a hook that only
computes can go anywhere.

---

## Rendering pipeline overview

```
[elbow image] → [Style-B chips] → [orange fill] → [Style-A notch] → [2 bar-color cols] → [cap image]
```

Drawn by `_lcars_swoop_precmd`, the middle of the three precmd hooks (see Hook ordering above). Two chrome lines (bar row 0 and row 1) are emitted as print statements with trailing newlines. The input line is set in `$PROMPT` as a third image row (the elbow's stem stub + inner fillet).

---

## Bar structure

The bar is 2 rows tall. Both rows span `$COLUMNS`. Left to right:

1. **Elbow image** (`_LCARS_ELBOW` = 5 cols × 3 rows) — Unicode placeholder cells, grid rows 0 and 1 on the bar rows, grid row 2 on the input line
2. **Left lead** — bar-color cells before chips (0 for elbow; 2 for cap-on-left variant)
3. **Style-B chips** — labeled color segments with combed 1-col black gaps
4. **Fill** — orange bar cells to fill remaining width
5. **Style-A notch** — `[1-col black rule][1-col accent][black notch: path text]`
6. **Right lead** — bar-color cells before the cap (0 for elbow; 2 for cap)
7. **Cap image** (`_LCARS_CAP` = 2 cols × 2 rows) — Unicode placeholder cells

### Fill width formula

```
mid = COLUMNS - left_w - right_w
amotif = 2 + len(path_text) + right_lead    # black rule + accent col + notch + right lead-in
gapw = nchips + 1                           # N+1 combed gap cols for N chips
fill = mid - left_lead - chipsw - gapw - amotif
```

---

## Unicode placeholder rendering

The elbow and cap are drawn as kitty **Unicode placeholder** cells, not cursor-anchored (`a=T`) images. A placeholder is a real text cell holding `U+10EEEE` plus combining diacritics for row/column; kitty paints the referenced image's matching grid cell into it.

Because the cell lives in the text stream, it **reflows and scrolls with its bar on pane resize** — fixing the "dangling elbow" problem that plain `a=T` placements leave behind (they stay pinned to the draw-time screen cell).

Each image is transmitted once with `_lc_transmit()` (which uses `t=d` inline base64 for synchronous delivery). The image id rides the cell's foreground color (`\e[38;5;<id>m`), so ids stay < 256.

Fixed image ids: 1 = elbow-left, 2 = elbow-right, 3 = cap-left, 4 = cap-right.

### `_lc_ph()` — emit one placeholder row

```zsh
_lc_ph  id  grid-row  ncols  [flat-col]
```

`flat-col` (optional): the column that butts against the flat bar (the elbow's outer edge, col `left_w - 1`). That cell gets bar-color background so a sub-pixel seam between the image cell and the abutting bar blends into the bar rather than showing a 1px black gap. This is `lflat = left_w - 1`.

The right cap's left edge (col 0) is fully opaque at all rows, so no seam fix is needed there — cap cells get black background (default, `rflat = -1`) so the arc's transparent corners show the terminal void.

### `_lc_transmit()` — transmit + create virtual placement

```zsh
_lc_transmit  path  id  cols  rows
```

Sends PNG bytes base64-encoded inline. Called once at enable time and after cell-size changes (when `_LCARS_IMAGES_SENT` is cleared).

---

## Style-B chips

`_lcars_chips` takes alternating `(text, color)` pairs. Chips ride on combed 1-col black gaps: N chips draw N+1 gaps (leading gap + trailing gap that combs with the next chip's leading gap). Width bookkeeping must match: `gapw = nchips + 1`.

`LC_ROWMODE=blank` emits chip-colored spaces on bar row 0 (top); `LC_ROWMODE=text` emits colored text on bar row 1 (bottom).

Active chips (shown only when non-empty):
- **error** — red chip, bare exit code ` <code> `. No glyph — the red color is the signal.
- **venv** — lilac, virtualenv name or `uv`
- **python** — sky, `py <version>` from `.tool-versions`
- **AWS** — orange, `AWS|<profile>` (red chip if profile is `dep`)
- **git branch** — gold, branch name
- **git state chips** — gold, `NN-STAGED`, `NN-MODIFIED`, `NN-UNTRACKED` (one chip per non-empty count, zero-padded)

### Narrow-pane chip dropping

When `$COLUMNS` is too small to render all chips in one row, chips are dropped in priority order (lowest first) until the row fits. The error chip is never dropped.

**Drop order:**
1. AWS chip
2. Python chip
3. All three git-state chips (staged/modified/untracked) as a group
4. Venv chip
5. Git-branch chip

If no chips remain and the path notch still overflows, `ptxt` is truncated to fit. Below ~5 available cols the notch collapses to ` ~ ` and the bar degrades to elbow + fill + cap.

This is purely a display decision made each `precmd` using `$COLUMNS` — no state is stored. Widening the pane restores all chips on the next prompt.

**Implementation:** `_lcars_swoop_precmd` builds six named arrays (`chips_err`, `chips_venv`, `chips_py`, `chips_aws`, `chips_branch`, `chips_state`) and assembles them into `chips` via a nested-if trim loop with an inline `_lcars_row_fits` helper.

---

## Style-A notch (path chip)

```
[1-col black rule] [1-col bar-color col] [black notch: path in bar color]
```

The path is rendered as `" $cwd "` in the bar's own accent color (`_LC_O`) on a black background. `amotif` in the fill calculation accounts for these 3 fields.

---

## Input line (PROMPT)

The input line draws the elbow's third grid row (stem stub + inner fillet) as real placeholder cells, making the stem a pixel-exact continuation of the bar above:

```zsh
PROMPT="%{ESC[48;2;0;0;0mESC[38;5;${left_id}m%}${_s0}${_s1}%{ESC[0m%}"
```

Where `_s0` = `U+10EEEE` + row-2 diacritic + col-0 diacritic, and `_s1` = row-2 + col-1.

zsh counts each placeholder cell as 1 display column (verified), so PROMPT stays width-correct with the editable area at col 3; the ESC runs are `%{…%}`-wrapped as zero-width.

`PROMPT2` continues the stem below as a plain periwinkle background cell (no fillet):

```zsh
PROMPT2="%K{#9999ff} %k "
```

---

## Scrollback bracket lines

`_lcars_swoop_preexec` emits the **start line** before each command:
```
[sky LED cell] STARDATE <JDN>  <UTC datetime>
```

Julian Day Number: `jdn = EPOCHSECONDS / 86400 + 2440588`

`_lcars_swoop_precmd` emits the **end line** after each command (if `_LCARS_S_CMD_RAN` is set — the data layer's snapshot of `_LCARS_CMD_RAN`, which it clears itself so a headless shell does not re-emit `133;D` with a stale exit code):
```
[green/red LED cell] <UTC datetime>  [duration if > CMD_DURATION_THRESHOLD]
```

LED cells are 1-col background cells (no glyph). Green = `_LC_OK`, red = `_LC_RED`.

Datetime format: `0%Y-%m-%dT%H:%M:%Sz` (Long Now / leading-zero year, UTC).

---

## Cell-size probe and SIGWINCH

`TRAPWINCH` sets `_LCARS_CELL_DIRTY=1`. On the next `precmd`:

1. `_lcars_probe_cell_size` — sends CSI 16t, reads reply, updates `_LCARS_CW`/`_LCARS_CH`, clears `_LCARS_IMAGES_SENT` if dims changed
2. `_lcars_ensure_assets` — regenerates missing PNGs for the new cell size
3. Next `_lcars_transmit_images` sends the fresh set

See `docs/kitty-graphics.md` for CSI 16t details and `docs/asset-pipeline.md` for `_lcars_ensure_assets`.

---

## Split-swoop feature (disabled)

`_LCARS_SPLIT_SWOOP` is empty (disabled). When enabled it queries pane neighbors via `kitty @ ls` and swaps the cap for a mirrored elbow on the divider-facing edge, creating a double swoop across vsplits. Disabled because: ~50ms per-prompt query, the right-edge stem never fully drew, and the benefit was marginal. All machinery is still in the file, gated on the flag.

---

## `_lcars_graphics_ok()`

Guards all image rendering:

```zsh
[[ -n $KITTY_WINDOW_ID && -z $TMUX && -z $SSH_TTY && $TERM == *kitty* ]]
```

Outside kitty (tmux, SSH), precmd falls back to a plain two-line prompt.
