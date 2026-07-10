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
  "assets/elbow-top.png          $CONFIG/kitty/lcars/elbow-top.png"
  "assets/elbow-bottom.png       $CONFIG/kitty/lcars/elbow-bottom.png"
  "assets/elbow-top-mirror.png   $CONFIG/kitty/lcars/elbow-top-mirror.png"
  "assets/elbow-bottom-mirror.png $CONFIG/kitty/lcars/elbow-bottom-mirror.png"
  "assets/cap-right.png          $CONFIG/kitty/lcars/cap-right.png"
  "assets/cap-left.png           $CONFIG/kitty/lcars/cap-left.png"
  "assets/swoop-top.png          $CONFIG/kitty/lcars/swoop-top.png"
  "assets/swoop-bottom.png       $CONFIG/kitty/lcars/swoop-bottom.png"
  "nvim/colors/lcars.lua         $CONFIG/nvim/colors/lcars.lua"
  "nvim/lua/lcars/palette.lua    $CONFIG/nvim/lua/lcars/palette.lua"
  "nvim/lua/lcars/statusline.lua $CONFIG/nvim/lua/lcars/statusline.lua"
  "nvim/lua/lcars/tabline.lua    $CONFIG/nvim/lua/lcars/tabline.lua"
  "nvim/lua/lcars/chrome.lua     $CONFIG/nvim/lua/lcars/chrome.lua"
  "nvim/lua/lualine/themes/lcars.lua $CONFIG/nvim/lua/lualine/themes/lcars.lua"
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

Done. Not handled automatically (one-time manual step):
  - kitty/keybindings.snippet.conf  -> append into $CONFIG/kitty/keybindings.conf
  - reload the prompt:  source $CONFIG/zsh/prompt_lcars.zsh
EOF
