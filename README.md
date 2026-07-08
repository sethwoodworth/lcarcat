# lcarcat

An LCARS-style UI toolkit for the terminal — building blocks for rendering the
*Library Computer Access/Retrieval System* look (Star Trek's UI) in a shell prompt
and other terminal chrome.

## Approach

LCARS is all bold color panels with **rounded elbow** joins and **round cap** ends. A character
grid can't draw curves, so lcarcat splits every element into two kinds of pieces:

- **Flat parts are terminal cells** — filled with a background color (`%K{…}`). They cost
  nothing, flex to any width, and scroll natively. This is the bulk of every panel.
- **Curved parts are images** — small PNGs placed with the kitty graphics protocol, used
  only where a corner or cap actually curves. They are the *only* images we draw.

Keeping the flat mass as cells (not one big PNG) is what makes panels resize with the
terminal, wrap correctly, and stay cheap.

## Nomenclature

```
  swoop                       chip (B)      chip (B)          fill        chip (A)    cap
 ┌──╮ ┌──────────────────────────────────────────────────────────────────────────────╮
 │  │ │ ███ venv ███ py 3.11 ███ ······· orange bar ······· ███▏black▕ ~/PROJ ▕███    ◗│
 │  │ └──────────────────────────────────────────────────────────────────────────────╯
 │  │   ← stem                                                        notch ↑
 │  •  nested content (input line, timestamps) sits beside the stem
```

### bar
A horizontal LCARS band: a run of terminal cells filled with a single accent color
(`%K{…}`). Full-width and dynamic to `$COLUMNS`; **2 rows tall** by convention. The bar is
the canvas that chips, notches, and caps sit on. Everything flat is "the bar."

### swoop
The curving **elbow** on the left of a bar where the horizontal band turns and drops into a
vertical **stem**. Drawn as a PNG because it curves. Two variants:
- **top swoop** — bar on top, stem descends (opens a frame above output).
- **bottom swoop** — the vertical mirror; stem rises into a bar (closes a frame below output).

Sub-parts of a swoop:
- **elbow** — the corner curve itself: a rounded *outer* corner plus a small concave *inner
  fillet* where the bar meets the stem.
- **stem** — a **1-cell-wide** vertical column (a colored cell, not an image) running down
  from the swoop. It frames the *nested content* (the prompt input line, timestamps) that
  sits just to its right.

### cap
The **right cap** of a bar: a half-round (semicircle) end drawn as a PNG, flat on the left
so it butts seamlessly against the cell bar. The prompt lays **2 bar-color cells** before the
cap so the round end reads as a continuation of the bar, not of the notch. Right-anchored —
on an input line it rides in `RPROMPT`; on a standalone bar it's positioned at the last columns.

### chip
A labeled **segment** within a bar. A chip is where information lives. Two styles:

- **Style A — notch chip** (label *in the bar color*, on black).
  Words are cut into the bar as a **black notch** with the text drawn in the bar's own
  accent color. By convention a Style-A chip only appears at the **far right** of a bar,
  introduced by the motif `[1-col black rule][1-col accent][black notch: words]`. Text is on
  the **top** bar row.

- **Style B — color chip** (dark text on a color).
  A solid colored segment (a different accent than the bar) with the label in **dark/black**
  text. Chips of different accents sit side by side to read as distinct fields. Text is on
  the **bottom** bar row and can be **right-justified** within the chip.

### notch
A black inset carved into a bar (used by Style-A chips) so accent-colored text can be read
against black rather than against the bar fill.

## Terminology cheat-sheet

| term  | what it is                       | rendered as        |
|-------|----------------------------------|--------------------|
| bar   | horizontal accent band           | terminal cells     |
| swoop | left elbow + stem                | PNG (elbow) + cell (stem) |
| stem  | 1-col vertical drop from a swoop | terminal cells     |
| cap   | right half-round end cap         | PNG                |
| chip  | labeled segment in a bar         | terminal cells     |
| notch | black inset holding accent text  | terminal cells     |

## Repository layout

```
README.md                      this file — approach & nomenclature
ROADMAP.md                     state, pending work, key decisions, install steps
generate/gen_swoops.py         Pillow generator for the elbow + round caps (run via uv)
assets/*.png                   generated caps (elbow-top/bottom, cap-right, legacy swoops)
zsh/prompt_lcars.zsh           the switchable LCARS prompt (`lcarsprompt on|off`)
kitty/lcars.conf               LCARS 16-color palette + tab-bar/border chrome
kitty/keybindings.snippet.conf scrollback prompt-navigation binds
demos/*.sh                     standalone previews (palette, swoop, cell bars, prompt)
```

Run any demo directly, e.g. `bash demos/prompt_preview.sh` (they read from `assets/`).

## Status

Early — extracted from a personal kitty + zsh LCARS setup; targets **kitty** (graphics
protocol for the curved caps) and **zsh** (prompt integration). See **`ROADMAP.md`** for the
full state, pending work, and install steps.
