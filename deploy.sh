#!/usr/bin/env bash
# Deploy lcarcat from this repo into the live ~/.config locations.
#
# NOTE: destinations are hardcoded for Seth's environment for now. See ROADMAP.md
# ("Packaging / distribution") for making these configurable before publishing.
#
# Usage:
#   ./deploy.sh          copy repo files into ~/.config and verify
#   ./deploy.sh --dry-run print what would be copied without touching anything
#   ./deploy.sh --prune-assets  also delete generated PNGs this deploy does not
#                        write, and the nvim asset cache, so both regenerate
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"

DRY=0
PRUNE=0
for argument in "$@"; do
  case "$argument" in
    --dry-run) DRY=1 ;;
    --prune-assets) PRUNE=1 ;;
    *) printf 'unknown option: %s\n' "$argument" >&2; exit 2 ;;
  esac
done

# src (repo-relative)            dest (absolute)
# One pair per line; globs in src are expanded.
mappings=(
  "zsh/lcars_prompt_data.zsh     $CONFIG/zsh/lcars_prompt_data.zsh"
  "zsh/prompt_lcars.zsh          $CONFIG/zsh/prompt_lcars.zsh"
  "generate/gen_swoops.py        $CONFIG/kitty/lcars/gen_swoops.py"
  "kitty/lcars.conf              $CONFIG/kitty/lcars.conf"
  "kitty/lcarcat.keybindings.conf $CONFIG/kitty/lcarcat.keybindings.conf"
  # The custom tab bar. kitty resolves tab_bar.py relative to its CONFIG dir, so
  # this path is load-bearing: lcars.conf sets `tab_bar_style custom`, and if the
  # file is missing kitty drops the tab bar in every window.
  "kitty/tab_bar.py              $CONFIG/kitty/tab_bar.py"
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
  "nvim/lua/lcars/assets.lua     $CONFIG/nvim/lua/lcars/assets.lua"
  "nvim/lua/lcars/palette.lua    $CONFIG/nvim/lua/lcars/palette.lua"
  "nvim/lua/lcars/statusline.lua $CONFIG/nvim/lua/lcars/statusline.lua"
  "nvim/lua/lcars/tabline.lua    $CONFIG/nvim/lua/lcars/tabline.lua"
  "nvim/lua/lcars/chrome.lua          $CONFIG/nvim/lua/lcars/chrome.lua"
  "nvim/lua/lcars/command_buffer.lua $CONFIG/nvim/lua/lcars/command_buffer.lua"
  "nvim/lua/lcars/gutter_eob_fill.lua $CONFIG/nvim/lua/lcars/gutter_eob_fill.lua"
  "nvim/lua/lcars/terminal_frame.lua  $CONFIG/nvim/lua/lcars/terminal_frame.lua"
  "nvim/lua/lcars/block_demo.lua      $CONFIG/nvim/lua/lcars/block_demo.lua"
  "nvim/lua/lcars/spike_placeholder.lua $CONFIG/nvim/lua/lcars/spike_placeholder.lua"
  "nvim/lua/lcars/spike_baleia.lua      $CONFIG/nvim/lua/lcars/spike_baleia.lua"
  "nvim/lua/lcars/block_record.lua     $CONFIG/nvim/lua/lcars/block_record.lua"
  "nvim/lua/lcars/block_chips.lua      $CONFIG/nvim/lua/lcars/block_chips.lua"
  "nvim/lua/lcars/image_registry.lua   $CONFIG/nvim/lua/lcars/image_registry.lua"
  "nvim/lua/lcars/frame_renderer.lua  $CONFIG/nvim/lua/lcars/frame_renderer.lua"
  "nvim/lua/lcars/frame_buffer.lua    $CONFIG/nvim/lua/lcars/frame_buffer.lua"
  "nvim/lua/lcars/pty_session.lua     $CONFIG/nvim/lua/lcars/pty_session.lua"
  "nvim/lua/lcars/term_input.lua      $CONFIG/nvim/lua/lcars/term_input.lua"
  "nvim/lua/lcars/terminal_win.lua    $CONFIG/nvim/lua/lcars/terminal_win.lua"
  "nvim/lua/lcars/alternate_screen.lua $CONFIG/nvim/lua/lcars/alternate_screen.lua"
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
  # Copy to a sibling temp, verify it, then rename(2) onto the destination.
  # A plain in-place copy opens the destination O_TRUNC, so it is momentarily
  # zero bytes; a reader holding it mmap'd (kitty decoding a t=f PNG from the
  # prompt) then faults past a truncated EOF and takes SIGBUS. rename(2) is
  # atomic on APFS and swaps the directory entry instead, leaving the old inode
  # alive for anyone still mapping it (lcarcat-46w).
  local tmp="$dest.deploy.$$"
  if ! cp "$src" "$tmp"; then
    rm -f "$tmp"
    printf '  FAIL  %s could not be copied\n' "$1" >&2; return 1
  fi
  if ! cmp -s "$src" "$tmp"; then
    rm -f "$tmp"
    printf '  FAIL  %s did not match after copy\n' "$1" >&2; return 1
  fi
  if ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"
    printf '  FAIL  %s could not be installed\n' "$1" >&2; return 1
  fi
  printf '  ok    %-28s -> %s\n' "$1" "$dest"
}

printf 'lcarcat deploy: %s -> %s%s\n' "$REPO" "$CONFIG" "$([[ $DRY == 1 ]] && echo '  (dry run)')"
for m in "${mappings[@]}"; do
  # split each mapping on whitespace into src + dest
  read -r src dest <<<"$m"
  deploy_one "$src" "$dest"
done

# The dashboard is a Python package rather than a handful of files, so it is
# copied as a tree. Listing every module above would mean editing this file for
# each new widget, and a widget missed there would fail at runtime rather than at
# deploy time. Only source and the launcher are copied — no caches, no bytecode.
deploy_tree() {
  local subdir="$1" dest_root="$2" relative
  [[ -d "$REPO/$subdir" ]] || { printf '  SKIP  %s (missing in repo)\n' "$subdir"; return; }
  while IFS= read -r file; do
    relative="${file#$REPO/$subdir/}"
    deploy_one "$subdir/$relative" "$dest_root/$relative"
  done < <(find "$REPO/$subdir" \
             \( -name '__pycache__' -o -name '*.pyc' \) -prune -o \
             -type f \( -name '*.py' -o -name '*.sh' \) -print | sort)
}

deploy_tree "dashboard" "$CONFIG/lcarcat/dashboard"
if (( ! DRY )) && [[ -f "$CONFIG/lcarcat/dashboard/run.sh" ]]; then
  chmod +x "$CONFIG/lcarcat/dashboard/run.sh"
fi

# Generated PNGs are named for their colour and cell size, never for their
# geometry, so a shape change in gen_swoops.py leaves every cached file looking
# current: the prompt and nvim both check "does this filename exist" and skip
# regeneration. Pruning is how a geometry change reaches the other cell sizes
# (font-size variants the prompt made at runtime) and nvim's own cache.
prune_generated_assets() {
  local kept=0 removed=0 file name
  for file in "$CONFIG"/kitty/lcars/*.png; do
    [[ -e "$file" ]] || continue
    name="$(basename "$file")"
    if printf '%s\n' "${mappings[@]}" | grep -q "/$name\$"; then
      kept=$((kept + 1))
      continue
    fi
    if (( DRY )); then printf '  would prune  %s\n' "$name"; else rm -f "$file"; fi
    removed=$((removed + 1))
  done
  printf '  pruned %d generated PNG(s), kept %d deployed by this run\n' "$removed" "$kept"

  local nvim_cache="${XDG_CACHE_HOME:-$HOME/.cache}/nvim/lcars"
  if [[ -d "$nvim_cache" ]]; then
    if (( DRY )); then printf '  would remove  %s\n' "$nvim_cache"; else rm -rf "$nvim_cache"; fi
    printf '  cleared nvim asset cache\n'
  fi

  local dashboard_cache="${XDG_CACHE_HOME:-$HOME/.cache}/lcarcat/dashboard-assets"
  if [[ -d "$dashboard_cache" ]]; then
    if (( DRY )); then printf '  would remove  %s\n' "$dashboard_cache"; else rm -rf "$dashboard_cache"; fi
    printf '  cleared dashboard asset cache\n'
  fi
}

if (( PRUNE )); then
  printf '\nPruning generated assets:\n'
  prune_generated_assets
fi

cat <<EOF

Done. Not handled automatically (one-time manual steps):
  - kitty.conf: ensure it includes lcarcat.keybindings.conf (already done if you ran setup)
  - reload the prompt:  source $CONFIG/zsh/prompt_lcars.zsh
EOF
