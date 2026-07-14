# AGENTS.md — working notes for agents on lcarcat

## Core rendering principle: minimum viable image, backgrounds everywhere

lcarcat renders LCARS chrome in the terminal. The rule that governs every rendering
decision:

- **Use the minimum viable image.** PNGs (kitty graphics protocol) are drawn *only* where a
  shape actually curves — the elbow corner and the right round cap. Nothing else.
- **Use background cells everywhere you can.** Every flat run — bars, fills, chip bodies,
  gaps, the notch, the bar-color columns before the cap — is colored terminal cells
  (`\e[48;2;R;G;Bm` + spaces), never baked into an image.

Why: cells cost nothing, flex to `$COLUMNS`, wrap and scroll natively, and recolor without
regenerating assets. An image is a last resort for curves only.

### Consequences for edits
- Do **not** regenerate or alter the cap/elbow PNGs to achieve a layout change. If you need
  more width, more color, or a separator, add background cells in `zsh/prompt_lcars.zsh`.
- Only touch `generate/gen_swoops.py` / the PNGs when the *curve itself* must change (radius,
  stem rows, base color of the asset). Renames are fine (content-preserving).
- When adding a visual element, ask "can this be a background cell?" first. It almost always
  can. Status markers (e.g. the start/end LEDs) are a **1-col background cell**, not a glyph.

## Images must match their placement size
An image placed with the kitty protocol is scaled to the `c×r` cells it's given. If the source
PNG's proportions don't match, it squashes and stops lining up with the cell bar.
- The elbow is **3 rows** (bar 2 + stem 1) generated with `--stem-rows 1`; it is placed at
  `_LCARS_FRAME` rows. The cap is **2 rows** (the bar height). Keep the generator and the
  prompt's row counts in sync — if you change one, change the other and regenerate.
- After (re)generating, **verify**: check `sips -g pixelWidth -g pixelHeight`, and `Read` the
  PNG to eyeball the shape, before deploying. A wrong-sized asset is the classic regression here.

## nvim chrome — image.nvim corner elbows (`nvim/lua/lcars/chrome.lua`)

The nvim theme draws the LCARS frame (elbows/caps/capped separators) with **image.nvim**
(kitty backend). This is the hardest-won part of the project; the notes below are the
things that cost real debugging time.

### LCARS routing: no T/+ junctions — only elbows and caps
This is the design law that dictates *where* chrome goes (see also the style section):
- An **elbow** joins a horizontal **bar** to a vertical **stem** — a 2-sided L-corner.
- A **cap** rounds the free end of a bar or stem.
- **T (3-way) and + (4-way) junctions do not exist in LCARS.** Where a stem would cross a
  bar, one of them must *terminate in a cap* or *turn in an elbow*.
- Therefore "an elbow at every window corner" is **wrong**: interior windows make their
  gutters/edges cross the global tabline/statusline → T-junctions. The model is instead
  **outer frame only**:
  - one **top-left elbow** (editor's top-left window) + one **bottom-left elbow** (into the
    global statusline), on the leftmost gutter = the **left rail**;
  - interior split edges are **capped channels**, never per-window elbows.
- **Elbow vs cap by gutter presence:** an elbow needs a stem to curve into. A **gutterless**
  window (`textoff == 0` — netrw, `number` off) has no stem, so its corner becomes a rounded
  **left cap** on the bar. Key on `textoff`, not filetype — it generalizes.
- **Capped channel separator:** keep the flat bar as periwinkle **cells** (`WinSeparator`);
  only the rounded ends are PNGs. Left cap carries a 1-col **black gap** so the segment sits
  *off* the continuous left rail; right cap rounds the far end. (Flat=cells still holds; only
  the curves are images.)

### image.nvim placement (the `+1` trap and the fix)
- image.nvim's **floating-window** path computes `screen_pos.row = window.rect.top +
  original_y + 1`. That `+1` pushes a float anchored at editor row 0 down to row 1, and row 0
  bails outright. You **cannot** put an image on the tabline row via a float.
- **Use a windowless image instead.** `image.from_file(path, { x=, y=, width=, height= })`
  with **no `window`/`buffer`** takes the absolute-screen path (`absolute_x = geometry.x`,
  `absolute_y = geometry.y`), lands on the true screen cell (including row 0), and stays
  fixed as the buffer scrolls — exactly what fixed chrome wants.
- Set `img.ignore_global_max_size = true` (a field on the image, not a `from_file` option) or
  the global `max_width/height` clamp can shrink it. The per-window `max_*_window_percentage`
  clamps are skipped automatically on the windowless path.
- **Ids don't collide on reuse.** Each `from_file` gets `opts.id or utils.random.id()` and
  clones on a repeated path, so one PNG placed in many windows is fine.
- Raw kitty **Unicode placeholders do not render inside nvim's own tabline/statusline
  strings** (nvim controls the SGR/codepoints). Windowless image.nvim is the way in.

### Transparency & baked negative space
- Transparent PNG areas reveal nvim's cells behind the image; opaque areas cover them.
- You can paint a black backdrop only where you own the cells (the tabline pad). You **cannot**
  paint the `WinSeparator` row or another pane's cells. So **bake the outer-curve negative
  space as opaque black into the PNG** (`gen_swoops.py --corner-bg 000000`) — then the elbow
  shows its rounded edge over anything. Keep the *inner* fillet / buffer side transparent so
  real content shows through.

### nvim geometry APIs (0-indexed screen math)
- `nvim_tabpage_list_wins(0)` — **use this, not `nvim_list_wins()`**, which spans *all*
  tabpages and lets another tab's window steal the top-left slot (this masked netrw's caps).
- `win_screenpos(win)` → 1-indexed `[row, col]` of the window's top-left **content** cell
  (gutter included). `y = row - 2` (0-indexed) lands on the tabline/separator row *above* it.
- `getwininfo(win)[1].textoff` = gutter width (number+sign+fold). `0` ⇒ gutterless.
- Global statusline row (`laststatus == 3`) = `lines - cmdheight - 1` (0-indexed).
- `WinSeparator` is a single uniform highlight — **no per-cell control**, so you can't gap or
  cap it directly; overlay small cap images (or use a winbar) instead.

### Assets, cell size, redraw
- Generate at the **exact physical cell size** from `require('image.utils.term').get_size()`
  (`math.ceil`), or Retina half-scaling gives a ~1px offset. Cell size is **dynamic** (font/
  zoom) → cache assets keyed by `<cellw>x<cellh>-<gutter>` and regenerate on change.
- The corner is `stem + 2` cols wide (2 extra for the inner fillet), so anything sharing its
  row must offset by `chrome.width()` (= `stem+2`), **not** the raw `textoff`: the tabline pad
  and the statusline `gutter_pad` both do this, or the bar overlaps the mode pill.
- Refresh on `VimResized, WinResized, WinNew, WinClosed, TabEnter, BufWinEnter, WinEnter,
  OptionSet(number/numberwidth/signcolumn)`. Splits fire many events — **debounce** (token +
  `vim.defer_fn`) so you regenerate/redraw once.
- `redrawtabline` alone won't refresh the statusline pad; also `redrawstatus`.

## Glyphs & LCARS style
- LCARS is **solid geometric shapes and color**, not icon-font glyphs. Avoid `✘ ✓ ⚠ ⏱ → ↩`.
  Prefer dropping the glyph and letting **color** carry meaning (see the LCARS glyph kit in
  `ROADMAP.md`).
- **No T/+ junctions.** Bars meet stems only via 2-sided elbows; free ends get caps. (Full
  reasoning in the nvim chrome section above — the rule is general LCARS, not nvim-specific.)
- **Spell words out in full.** Do not abbreviate labels/identifiers without asking first
  (`MODIFIED`, not `MOD`; `UNTRACKED`, not `UNTRK`). Full words are the default.
- Established idioms: chips use the **`NN-WORD`** dashed form (e.g. `03-STAGED`); labels are
  uppercase; leading-zero / Long-Now styling for numbers (`STARDATE`, `0yyyy-...z`).

## Deployment
Edits must land in the repo **and** the deployed copy under `~/.config` (the live shell/kitty
load from there). Run **`./deploy.sh`** from the repo root — it copies everything and verifies
each file (`./deploy.sh --dry-run` to preview). Destinations are hardcoded for now. Mappings:
- `zsh/prompt_lcars.zsh` → `~/.config/zsh/prompt_lcars.zsh`
- `generate/gen_swoops.py` → `~/.config/kitty/lcars/gen_swoops.py`
- `kitty/lcars.conf` → `~/.config/kitty/lcars.conf`
- PNG assets → `~/.config/kitty/lcars/`
- `nvim/colors/lcars.lua` → `~/.config/nvim/colors/lcars.lua`
- `nvim/lua/lcars/*.lua` (`palette`, `statusline`, `tabline`, `chrome`) → `~/.config/nvim/lua/lcars/`
- `nvim/lua/lualine/themes/lcars.lua` → `~/.config/nvim/lua/lualine/themes/`

The nvim chrome (`chrome.lua`) generates its corner/cap PNGs at runtime into
`stdpath('cache')/lcars/` from the deployed `gen_swoops.py`; nothing to copy for those.
The small integration edits (`init.lua`, `lua/plugins.lua`) live in the user's own
`~/.config/nvim` repo, not lcarcat.

Repo-only docs (`README.md`, `ROADMAP.md`, `AGENTS.md`) and `demos/` have no deployed counterpart.

See `README.md` for nomenclature (bar, swoop, elbow, stem, cap, chip, notch).

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->
