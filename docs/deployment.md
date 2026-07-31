# Deployment

Edits must land in the repo **and** in `~/.config` — the live kitty/zsh/nvim config loads from there.

## deploy.sh

Run from the repo root:

```bash
./deploy.sh           # copy and verify all files
./deploy.sh --dry-run # preview without touching anything
```

Destinations are hardcoded for `$XDG_CONFIG_HOME` (defaults `~/.config`). See `ROADMAP.md` → "Packaging" for the plan to make them configurable.

## File mappings

| Repo path | Deployed to |
|-----------|-------------|
| `zsh/prompt_lcars.zsh` | `~/.config/zsh/prompt_lcars.zsh` |
| `generate/gen_swoops.py` | `~/.config/kitty/lcars/gen_swoops.py` |
| `kitty/lcars.conf` | `~/.config/kitty/lcars.conf` |
| `kitty/lcarcat.keybindings.conf` | `~/.config/kitty/lcarcat.keybindings.conf` |
| `assets/elbow-top-left-9999ff-5x3cells-19x38pixels.png` | `~/.config/kitty/lcars/` |
| `assets/elbow-bottom-left-9999ff-5x3cells-19x38pixels.png` | `~/.config/kitty/lcars/` |
| `assets/elbow-top-right-9999ff-5x3cells-19x38pixels.png` | `~/.config/kitty/lcars/` |
| `assets/elbow-bottom-right-9999ff-5x3cells-19x38pixels.png` | `~/.config/kitty/lcars/` |
| `assets/cap-round-right-9999ff-2x2cells-19x38pixels.png` | `~/.config/kitty/lcars/` |
| `assets/cap-round-left-9999ff-2x2cells-19x38pixels.png` | `~/.config/kitty/lcars/` |
| `assets/swoop-top-left-9999ff-48x3cells-19x38pixels.png` | `~/.config/kitty/lcars/` |
| `assets/swoop-bottom-left-9999ff-48x3cells-19x38pixels.png` | `~/.config/kitty/lcars/` |
| `nvim/colors/lcars.lua` | `~/.config/nvim/colors/lcars.lua` |
| `nvim/lua/lcars/palette.lua` | `~/.config/nvim/lua/lcars/palette.lua` |
| `nvim/lua/lcars/statusline.lua` | `~/.config/nvim/lua/lcars/statusline.lua` |
| `nvim/lua/lcars/tabline.lua` | `~/.config/nvim/lua/lcars/tabline.lua` |
| `nvim/lua/lcars/chrome.lua` | `~/.config/nvim/lua/lcars/chrome.lua` |
| `nvim/lua/lcars/command_buffer.lua` | `~/.config/nvim/lua/lcars/command_buffer.lua` |
| `nvim/lua/lualine/themes/lcars.lua` | `~/.config/nvim/lua/lualine/themes/lcars.lua` |

## Not deployed by deploy.sh

- **nvim corner/cap PNGs** — `chrome.lua` generates them at runtime into `stdpath('cache')/lcars/` using the deployed `gen_swoops.py`. Nothing to copy.
- **nvim init.lua / plugins.lua** — live in the user's own `~/.config/nvim` repo, not lcarcat.
- **Docs, demos, AGENTS.md, README.md, ROADMAP.md** — repo-only, no deployed counterpart.

## One-time manual steps

`deploy.sh` prints these at the end:

1. **kitty.conf** — ensure it includes `lcarcat.keybindings.conf` (already done if you ran initial setup).
2. **Reload prompt** — `source ~/.config/zsh/prompt_lcars.zsh`

## Asset naming and the 19x38 default

The deployed asset set is named for `cellw=19, cellh=38` — kitty's actual cell pixel dimensions at font_size 18 Fantasque Sans Mono. If you change font or size, the zsh prompt will probe and regenerate automatically (see `docs/asset-pipeline.md`). The static list in `deploy.sh` only covers the default set; mismatched-size sets live in `~/.config/kitty/lcars/` alongside them.
