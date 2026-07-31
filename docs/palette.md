# LCARS Palette

Single source of truth for documentation. Runtime source of truth is `nvim/lua/lcars/palette.lua`.

**Sync warning:** The same hex values appear in three files. When you change a color, update all three:
- `nvim/lua/lcars/palette.lua` — Lua table, runtime source
- `zsh/prompt_lcars.zsh` lines 57–66 — SGR truecolor bodies (`R;G;B` strings)
- `kitty/lcars.conf` lines 12–37 — 16-color terminal slots

There is no generated or validated sync step; it is manual.

## Colors

| Role | Hex | SGR (R;G;B) | Notes |
|------|-----|-------------|-------|
| Canvas | `#000000` | `0;0;0` | Universal background — never off-black |
| Primary text | `#ffffc6` | `255;255;198` | Pale canary — never pure white |
| Orange / input accent | `#ff9900` | `255;153;0` | Keywords, active border, input-panel stems, prompt bar fill |
| Periwinkle / structural | `#9999ff` | `153;153;255` | Gutter, tabline fill, elbow images, display-panel stems |
| Gold | `#ffcc66` | `255;204;102` | Git branch chip, numbers, constants |
| Lilac | `#cc99cc` | `204;153;204` | Venv chip, types/classes |
| Sky | `#6699cc` | `102;153;204` | Python chip, info, scrollback start LED |
| Red-alert | `#ff3300` | `255;51;0` | Errors, failure LED |
| Sage | `#99cc99` | `153;204;153` | Success LED, diff-add, directories |
| AWS orange | `#ff9933` | `255;153;51` | AWS profile chip |
| String warm-white | `#ffcc99` | — | String literals (nvim only) |
| Dim violet | `#666699` | `120;120;140` | Comments, timestamps |
| Dim2 | `#78788c` | — | Non-text whitespace (nvim only) |
| Cursor magenta | `#cc6699` | — | Matches kitty cursor color |
| Stem dim | `#5c5c99` | — | Recessive line numbers on periwinkle gutter |
| Buf off | `#6699cc` | — | Non-selected buffer pills |

## Semantic rules

**Input panels** (where the user types): orange structural color — prompt bar, insert-mode pill, active split border.

**Display panels** (read-only, status, output): periwinkle structural color — gutter, tabline, inactive splits.

Maximum ~5 colors visible in any single view. Every color has a specific semantic role; no decorative variation.
