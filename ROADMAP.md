# lcarcat — state & roadmap

Compacted state of the project (extracted from a personal kitty + zsh LCARS setup).
See `README.md` for nomenclature.

## Done

- **Kitty LCARS theme** — `kitty/lcars.conf`: 16-color palette (sage green slot
  `#88bb88`/`#99cc99`, cyan `#99ccff`, hot br-red `#ff3300`; `#ff9900` reserved for chrome),
  black tab strip with orange active / periwinkle inactive **pills** (rounded caps), LCARS
  borders. Switchable by `include`-ing it from `kitty.conf` after your base colorscheme.
- **Swoop asset generator** — `generate/gen_swoops.py` (Pillow, run via `uv`): produces the
  `elbow-top/bottom` left caps (rounded corner + stem + inner fillet), their horizontal
  `-mirror` twins (stem on the right), the `cap-right`/`cap-left` round caps, and legacy wide
  `swoop-top/bottom`. Recolor/resize via flags.
- **Split-aware double swoop** — the prompt reads its pane's `neighbors` from `kitty @ ls`
  (cached; refreshed on first prompt + `SIGWINCH`) and draws an elbow on every side that abuts
  another pane, a round cap on the outer side. Adjacent panes' elbows meet over the (orange)
  kitty border → a double swoop across a vsplit. `_LCARS_STEM_SIDE` sets a solo pane's elbow
  side. Input stays left; `PROMPT2`'s stem only continues when there's a left elbow. Known
  issue: images on prior prompts don't reflow on split resize (see *Pending*).
- **Cell-based LCARS prompt** — `zsh/prompt_lcars.zsh`: bar = colored terminal cells, only
  the elbow + cap are images. **Style-B chips** with combed 1-col gaps — error (red, no glyph),
  venv (lilac), python (sky), and git (gold **branch** + `NN-WORD` chips: `NN-STAGED`/
  `NN-MODIFIED`/`NN-UNTRACKED`) — plus the path as a **Style-A notch** on the bottom bar row.
  Input on the **stem** (orange bg cell + space, no symbol; continued via `PROMPT2`). Commands
  are bracketed by dim scrollback lines with a **1-col LED cell** (sky start / green-ok /
  red-fail) carrying `STARDATE <JDN>` + UTC datetime + duration. Toggle `lcarsprompt on|off`;
  guards for kitty/tmux/ssh; reserves rows so it renders at the screen bottom.
- **Deploy** — `deploy.sh` copies repo → `~/.config` and verifies each file (`--dry-run` to
  preview); destinations hardcoded for now (see *Packaging*).
- **Scrollback navigation** — `kitty/keybindings.snippet.conf`: `scroll_to_prompt` binds
  over the OSC 133 marks kitty shell-integration already emits.
- **Demos** — `demos/*.sh`: palette swatches, swoop shapes, cell-bar styles, prompt layout,
  timestamp styles.

## Pending / ideas

- **Split resize reflows stale swoop images** — opening/closing a vsplit reflows the pane, but
  the elbow/cap PNGs already drawn on *previous* prompts don't move with their (now-shifted)
  text: kitty graphics placed with `a=T` are anchored to a cursor cell at draw time, not
  re-laid-out on resize, so old bars end up with elbows/caps in the wrong columns until those
  lines scroll away. The current prompt redraws correctly on the *next* prompt (pane detection
  refreshes on `SIGWINCH`); only scrollback history is affected. May not be cheaply fixable —
  options to explore: clear/redraw graphics on `WINCH`, use unicode placeholders, or accept it.
- `RPROMPT`-anchored **cap** on the **input line** (today only the bar rows carry the cap).
- **Pill element** — a segment with a round cap on *both* ends, as a discrete widget (e.g. a
  status badge). Previewed in `demos/timestamps_preview.sh`; not yet built in zsh.
- **Style B** inter-segment gap: done as combed **1-col** black gaps. A true sub-cell (1px)
  gap is still impossible on a character grid (won't fix).
- **2-row Pillow label words** (Impact/condensed font baked to PNG) for block-letter labels.
- **Side command panel** navigating scrollback (capture commands in `preexec` → overlay
  driving `scroll_to_prompt`).
- **nvim** dark editor theme — **colorscheme + statusline + image chrome working.**
  `nvim/colors/lcars.lua` (legacy + treesitter groups, shared `nvim/lua/lcars/palette.lua`),
  a **lualine** statusline + LCARS pill buffer row (`nvim/lua/lcars/statusline.lua`,
  `tabline.lua`, `nvim/lua/lualine/themes/lcars.lua`), and the **image chrome**
  (`nvim/lua/lcars/chrome.lua`, opt-in `:LcarsCorner`). Migrated off lightline. Deployed
  via `deploy.sh`. **Full engineering notes: see `AGENTS.md` → "nvim chrome".**
  **Done (image chrome):** kitty-image elbows/caps drawn by **image.nvim** as **windowless**
  absolute-screen images (the float path's `+1` row offset can't reach the tabline row; the
  windowless path can, and stays fixed on scroll). Outer-frame model: one top-left + one
  bottom-left elbow on the leftmost gutter (the left rail into the global tabline/statusline);
  gutterless windows (netrw, `textoff 0`) get a rounded left **cap** instead of an elbow;
  horizontal split separators are **capped channels** (flat periwinkle cells + a left cap with
  a black gap off the rail + a right cap). The outer-curve negative space is **baked black**
  into the PNG (`--corner-bg`) so curves show over separators/panes we can't paint. Window
  separators are solid periwinkle (`WinSeparator fg=bg=stem`). Assets regenerate at the exact
  physical cell size, cached by `<cellw>x<cellh>-<gutter>`.
  - **TODO — vertical (left/right) split separators.** Apply the same capped-channel
    treatment to vertical separators (caps at top just under the tabline, bottom just above
    the statusline). Only horizontal separators are done so far.
  - **TODO — reuse one in-memory image per shape.** image.nvim already assigns an id per
    `from_file` and won't resend unchanged bytes, but we recreate image objects on every
    refresh; key the placement by id and skip re-render when geometry/asset is unchanged, and
    delete stale ids. (See kitty graphics-protocol docs on displaying one image at multiple
    locations.)
  - **TODO — anchor the prompt swoops the same way.** The zsh prompt still places swoops
    cursor-anchored (`a=T,C=1`). It could reuse the windowless / transmit-once-by-id machinery
    to be redraw/resize-robust. (Raw Unicode placeholders — proven in
    `demos/placeholder_preview.py` — are the alternative for cells we fully control; note they
    do NOT render inside nvim's own tabline/statusline strings.)
  - **TODO — soften the corner radius.** The `corner-tl` outer radius currently fills the bar
    height (fairly tight); try a gentler/larger radius. `demos/corner_preview.py` shows the
    confirmed shape (1-row bar, inner fillet kept).
  - **TODO — dynamic gutter width (partially handled).** `chrome.lua` reads `textoff` live and
    regenerates per width on `OptionSet`/layout events, and the tabline/statusline pad by
    `chrome.width()`. Still to verify: the gutter growing mid-session as line count crosses a
    digit boundary (does it fire `OptionSet numberwidth`? may need a cheaper poll).
  - **TODO — chip backgrounds for the bar segments.** Give each top- and bottom-bar
    segment its own LCARS chip background (like the prompt's Style-B chips) with
    black gaps between. Right now the bottom bar's `branch` and `filename` share one
    periwinkle field and blend together; distinct chip bg colors (and combed 1-col
    gaps) would separate them the way the kitty tab pills and prompt chips do.
- **Impact tab-bar font** (PUA-remapped font + custom `tab_bar.py`) — deferred.
- **Packaging / distribution** — `deploy.sh` currently **hardcodes** Seth's `~/.config`
  destinations and the exact asset list. Before publishing: drive destinations from a small
  config (or `$XDG_CONFIG_HOME` + flags), glob the asset list instead of enumerating it,
  make the kitty-keybindings snippet append idempotent (marker-guarded) instead of a manual
  step, and add an uninstall/revert path.
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

- Flat parts = terminal cells; only curves (elbow, cap) are images. See `AGENTS.md`.
- Two chip styles: **A** (accent words in a black notch, far-right only), **B** (dark text
  on a color chip, bottom row, right-justifiable).
- Stem = 1 col; bar = 2 rows. Dropped the continuous vertical rail (dynamic height + col-0
  occlusion) and the bottom bar (looked bad against the next top bar).
- Everything is opt-in/switchable via `$LCARS`; the default light setup is untouched.

## Install (into ~/.config)

- **Everything at once:** `./deploy.sh` copies the prompt, generator, `lcars.conf`, and the
  PNG assets into `~/.config` (destinations hardcoded for now — see *Packaging* above).
  `./deploy.sh --dry-run` previews. Then do the one-time keybindings append + prompt source
  it prints.
- **Colors/tabs:** `include ~/.config/kitty/lcars.conf` in `kitty.conf` (after your base
  colorscheme); comment it out to revert.
- **Keybindings:** append `kitty/keybindings.snippet.conf`.
- **Prompt:** copy `zsh/prompt_lcars.zsh` *and* `zsh/lcars_prompt_data.zsh` to `~/.config/zsh/`, `source` the former after your default
  prompt, then `lcarsprompt on` (or `export LCARS=1` for new shells). The prompt expects the
  PNGs at `~/.config/kitty/lcars/` — adjust `_LCARS_DIR` if you install elsewhere.
- **Assets:** `uv run --with pillow generate/gen_swoops.py [--color HEX] [--cols N]
  [--stem-rows N] [--outdir DIR]` (defaults to `assets/`).
