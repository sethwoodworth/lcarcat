# lcarcat — Codebase Overview

LCARS-themed terminal chrome for kitty + zsh + neovim. Curved elbows and caps are small PNGs placed with the kitty graphics protocol; everything else is colored terminal cells.

---

## Repo layout

```
lcarcat/
├── zsh/
│   └── prompt_lcars.zsh        — LCARS swoop prompt; toggle with lcarsprompt on|off
├── kitty/
│   ├── lcars.conf              — kitty color theme + font config
│   └── lcarcat.keybindings.conf — keybindings
├── nvim/
│   ├── colors/lcars.lua        — nvim colorscheme
│   └── lua/lcars/
│       ├── chrome.lua          — outer frame elbows/caps via image.nvim
│       ├── command_buffer.lua  — LCARS-styled ex-mode buffer
│       ├── statusline.lua      — statusline segments
│       ├── tabline.lua         — tabline segments
│       └── palette.lua         — color table (runtime source of truth)
├── generate/
│   └── gen_swoops.py           — PNG asset generator (Pillow); deployed to ~/.config/kitty/lcars/
├── assets/                     — pre-built PNGs for zsh prompt at 19×38 device px per cell
├── docs/                       — engineering reference docs (this directory)
├── test/
│   ├── screenshot_harness.sh   — drive kitty via remote control, capture screenshots
│   ├── analyze_left_edge.py    — raw pixel row scan for elbow/stem alignment
│   ├── analyze_gutter_cells.py — cell-center pixel sampler; asserts gutter column bg color
│   ├── get_cell_grid.py        — kitty @ get-text parser; asserts semantic SGR bg color
│   └── scenarios/              — named test scripts (prompt alignment, resize, nvim)
├── demos/                      — preview scripts for visual elements
├── deploy.sh                   — copy repo files to ~/.config; run after every edit
└── AGENTS.md                   — agent invariants and task routing (start here)
```

---

## Three subsystems

| Subsystem | Key files | Shared asset store |
|-----------|-----------|-------------------|
| **zsh** | `zsh/prompt_lcars.zsh` | `assets/` (19×38 px) |
| **kitty** | `kitty/lcars.conf`, `kitty/lcarcat.keybindings.conf` | (theme only, no PNGs) |
| **nvim** | `nvim/lua/lcars/chrome.lua` + siblings | `stdpath('cache')/lcars/` (generated at runtime) |

All three subsystems share `generate/gen_swoops.py` for PNG generation and the asset filename format (see below).

---

## Core rendering principle

PNGs are drawn only where a shape actually curves — the elbow corner and the right round cap. Every flat run is colored terminal cells (`\e[48;2;R;G;Bm` background). When adding a visual element, ask "can this be a background cell?" first.

---

## Asset filename contract

Every PNG is named for the inputs that change its rendered shape. The format is shared by `gen_swoops.py`, `zsh/prompt_lcars.zsh` (`_lcars_set_asset_paths`), and `nvim/lua/lcars/chrome.lua` (`asset_name()`). If you change it in one place, change it in all three.

```
{kind}-{orient}-{facing}-{color}[-background{hex}]-{cols}x{rows}cells-{cellw}x{cellh}pixels[-gap{n}].png
```

Examples:
```
elbow-top-left-9999ff-5x3cells-19x38pixels.png
cap-round-right-9999ff-2x2cells-19x38pixels.png
corner-top-left-9999ff-background000000-3x2cells-19x38pixels.png
```

`cellw`/`cellh` must match kitty's CSI 16t reply exactly. See `docs/asset-pipeline.md` for the full spec.

---

## Where to go next

| I want to… | Read |
|-----------|------|
| Work on the zsh LCARS prompt | [`docs/zsh-prompt.md`](zsh-prompt.md), [`docs/asset-pipeline.md`](asset-pipeline.md) |
| Work on kitty config or image rendering | [`docs/kitty-graphics.md`](kitty-graphics.md), [`docs/asset-pipeline.md`](asset-pipeline.md) |
| Work on nvim chrome (elbows, caps, frame) | [`docs/nvim-chrome.md`](nvim-chrome.md), [`docs/asset-pipeline.md`](asset-pipeline.md) |
| Work on colors or the palette | [`docs/palette.md`](palette.md) |
| Run or write screenshot tests | [`docs/testing.md`](testing.md) |
| Deploy changes to ~/.config | [`docs/deployment.md`](deployment.md) |
| Make design or layout decisions | [`docs/lcars-design.md`](lcars-design.md) |
| Understand PNG generation or asset caching | [`docs/asset-pipeline.md`](asset-pipeline.md) |
