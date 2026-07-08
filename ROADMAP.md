# lcarcat — state & roadmap

Compacted state of the project (extracted from a personal kitty + zsh LCARS setup).
See `README.md` for nomenclature.

## Done

- **Kitty LCARS theme** — `kitty/lcars.conf`: 16-color palette (sage green slot
  `#88bb88`/`#99cc99`, cyan `#99ccff`, hot br-red `#ff3300`; `#ff9900` reserved for chrome),
  black tab strip with orange active / periwinkle inactive **pills** (rounded caps), LCARS
  borders. Switchable by `include`-ing it from `kitty.conf` after your base colorscheme.
- **Swoop asset generator** — `generate/gen_swoops.py` (Pillow, run via `uv`): produces the
  `elbow-top/bottom` left caps (rounded corner + stem + inner fillet), the `pill-right` cap,
  and legacy wide `swoop-top/bottom`. Recolor/resize via flags.
- **Cell-based LCARS prompt** — `zsh/prompt_lcars.zsh`: bar = colored terminal cells, only
  the elbow + pill are images. Renders your live segments as **Style-B chips**
  (exit/venv/python/git) finishing with the path as a **Style-A notch** at the far right;
  input on the stem row; output bracketed by dim `→`/`↩` timestamps. Toggle `lcarsprompt
  on|off`; guards for kitty/tmux/ssh; reserves rows so it renders at the screen bottom.
- **Scrollback navigation** — `kitty/keybindings.snippet.conf`: `scroll_to_prompt` binds
  over the OSC 133 marks kitty shell-integration already emits.
- **Demos** — `demos/*.sh`: palette swatches, swoop shapes, cell-bar styles, prompt layout.

## Pending / ideas

- `RPROMPT`-anchored pill on the **input line** (today only the bar rows carry the pill).
- **Style B** wants a 1px inter-segment gap — a cell grid can't do it (FIXME).
- **2-row Pillow label words** (Impact/condensed font baked to PNG) for block-letter labels.
- **Side command panel** navigating scrollback (capture commands in `preexec` → overlay
  driving `scroll_to_prompt`).
- **nvim** `colors/lcars.lua` + lightline (full dark editor theme) — not started.
- **Impact tab-bar font** (PUA-remapped font + custom `tab_bar.py`) — deferred.
- Package as an installable toolkit; stabilize the helper API for reuse.

## LCARS glyph kit (reference)

LCARS vocabulary is **solid geometric shapes** — filled triangles for direction/flow,
blocks and bars for status/separators, dots for discrete indicators. Avoid outlined,
hairline, or "icon-font" glyphs (`✘ ✓ ⚠ ⏱ ↩`) — they break the aesthetic. Prefer the
Geometric Shapes and Block Elements Unicode ranges, which render as bold monospace cells.
Current direction: **lean on chip colors** as the primary signal; use glyphs sparingly.

| Purpose | Candidates |
|---------|-----------|
| Directional / flow | `▸ ▹ ▶ ◀ ◂ ▲ ▼` |
| Status dots | `● ○ ◉ ◍` |
| Blocks / bars / separators | `■ ▪ ▮ █ ▌ ▐ ▬ ▭` |
| Chevrons (lighter motion) | `» « › ‹` |
| Diamonds (accent points) | `◆ ◇ ◈` |
| Progress / segmented | `▰▱ ▮▯` |

Per-slot picks when a glyph is warranted:
- **command start / done** — `▸` / `◂` (mirrored filled triangles) instead of `→` / `↩`.
- **error** — no glyph; the **red chip color** is the signal. Chip reads just ` <exit> `.
- **duration** — no glyph; bare bracket label `[+142ms]` instead of `⏱`.
- **git indicators** — ASCII `! ? +` are fine (terse, unfussy). If geometric is wanted:
  modified `▲`, untracked `◇` (hollow = not-yet-tracked), staged `◆` (filled = ready).

## Key decisions

- Flat parts = terminal cells; only curves (elbow, pill) are images.
- Two chip styles: **A** (accent words in a black notch, far-right only), **B** (dark text
  on a color chip, bottom row, right-justifiable).
- Stem = 1 col; bar = 2 rows. Dropped the continuous vertical rail (dynamic height + col-0
  occlusion) and the bottom bar (looked bad against the next top bar).
- Everything is opt-in/switchable via `$LCARS`; the default light setup is untouched.

## Install (into ~/.config)

- **Colors/tabs:** `include ~/.config/kitty/lcars.conf` in `kitty.conf` (after your base
  colorscheme); comment it out to revert.
- **Keybindings:** append `kitty/keybindings.snippet.conf`.
- **Prompt:** copy `zsh/prompt_lcars.zsh` to `~/.config/zsh/`, `source` it after your default
  prompt, then `lcarsprompt on` (or `export LCARS=1` for new shells). The prompt expects the
  PNGs at `~/.config/kitty/lcars/` — adjust `_LCARS_DIR` if you install elsewhere.
- **Assets:** `uv run --with pillow generate/gen_swoops.py [--color HEX] [--cols N]
  [--stem-rows N] [--outdir DIR]` (defaults to `assets/`).
