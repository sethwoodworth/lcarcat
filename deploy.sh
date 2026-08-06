#!/usr/bin/env bash
# Deploy lcarcat from this repo into the live ~/.config locations.
#
# NOTE: destinations are hardcoded for Seth's environment for now. See ROADMAP.md
# ("Packaging / distribution") for making these configurable before publishing.
#
# Usage:
#   ./deploy.sh          copy repo files into ~/.config and verify
#   ./deploy.sh --dry-run print what would be copied without touching anything
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

# src (repo-relative)            dest (absolute)
# One pair per line; globs in src are expanded.
mappings=(
  "zsh/prompt_lcars.zsh          $CONFIG/zsh/prompt_lcars.zsh"
  "generate/gen_swoops.py        $CONFIG/kitty/lcars/gen_swoops.py"
  "kitty/lcars.conf              $CONFIG/kitty/lcars.conf"
  "kitty/lcarcat.keybindings.conf $CONFIG/kitty/lcarcat.keybindings.conf"
  # Swoop end-caps: gen_swoops.py names each PNG for its inputs (kind/orientation/facing/
  # color/cell+pixel size) so variants coexist. This is the periwinkle 19x38px set the
  # prompt references; regenerate + update both lists together if the color/metrics change.
  # cellh=38 matches kitty's actual cell.height (from CSI 16t) at font_size 18 Fantasque Sans
  # Mono. Any mismatch here produces a sub-cell aspect-fit inset — see gen_swoops.py header.
  "assets/elbow-top-left-9999ff-5x3cells-19x38pixels.png     $CONFIG/kitty/lcars/elbow-top-left-9999ff-5x3cells-19x38pixels.png"
  "assets/elbow-bottom-left-9999ff-5x3cells-19x38pixels.png  $CONFIG/kitty/lcars/elbow-bottom-left-9999ff-5x3cells-19x38pixels.png"
  "assets/elbow-top-right-9999ff-5x3cells-19x38pixels.png    $CONFIG/kitty/lcars/elbow-top-right-9999ff-5x3cells-19x38pixels.png"
  "assets/elbow-bottom-right-9999ff-5x3cells-19x38pixels.png $CONFIG/kitty/lcars/elbow-bottom-right-9999ff-5x3cells-19x38pixels.png"
  "assets/cap-round-right-9999ff-2x2cells-19x38pixels.png    $CONFIG/kitty/lcars/cap-round-right-9999ff-2x2cells-19x38pixels.png"
  "assets/cap-round-left-9999ff-2x2cells-19x38pixels.png     $CONFIG/kitty/lcars/cap-round-left-9999ff-2x2cells-19x38pixels.png"
  "assets/swoop-top-left-9999ff-48x3cells-19x38pixels.png    $CONFIG/kitty/lcars/swoop-top-left-9999ff-48x3cells-19x38pixels.png"
  "assets/swoop-bottom-left-9999ff-48x3cells-19x38pixels.png $CONFIG/kitty/lcars/swoop-bottom-left-9999ff-48x3cells-19x38pixels.png"
  "nvim/colors/lcars.lua         $CONFIG/nvim/colors/lcars.lua"
  "nvim/lua/lcars/palette.lua    $CONFIG/nvim/lua/lcars/palette.lua"
  "nvim/lua/lcars/statusline.lua $CONFIG/nvim/lua/lcars/statusline.lua"
  "nvim/lua/lcars/tabline.lua    $CONFIG/nvim/lua/lcars/tabline.lua"
  "nvim/lua/lcars/chrome.lua          $CONFIG/nvim/lua/lcars/chrome.lua"
  "nvim/lua/lcars/command_buffer.lua $CONFIG/nvim/lua/lcars/command_buffer.lua"
  "nvim/lua/lcars/gutter_eob_fill.lua $CONFIG/nvim/lua/lcars/gutter_eob_fill.lua"
  "nvim/lua/lualine/themes/lcars.lua $CONFIG/nvim/lua/lualine/themes/lcars.lua"
  ".claude/hooks/kitty-tab-alert.sh  $HOME/.claude/hooks/kitty-tab-alert.sh"
)

deploy_one() {
  local src="$REPO/$1" dest="$2"
  if [[ ! -e "$src" ]]; then
    printf '  SKIP  %s (missing in repo)\n' "$1"; return
  fi
  if (( DRY )); then
    printf '  would copy  %-28s -> %s\n' "$1" "$dest"; return
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  if cmp -s "$src" "$dest"; then
    printf '  ok    %-28s -> %s\n' "$1" "$dest"
  else
    printf '  FAIL  %s did not match after copy\n' "$1" >&2; return 1
  fi
}

printf 'lcarcat deploy: %s -> %s%s\n' "$REPO" "$CONFIG" "$([[ $DRY == 1 ]] && echo '  (dry run)')"
for m in "${mappings[@]}"; do
  # split each mapping on whitespace into src + dest
  read -r src dest <<<"$m"
  deploy_one "$src" "$dest"
done

cat <<EOF

Done. Not handled automatically (one-time manual steps):
  - kitty.conf: ensure it includes lcarcat.keybindings.conf (already done if you ran setup)
  - reload the prompt:  source $CONFIG/zsh/prompt_lcars.zsh
EOF
