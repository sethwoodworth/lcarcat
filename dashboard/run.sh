#!/usr/bin/env bash
# Launch the LCARS dashboard.
#
# Resolves the repo from this script's own location, so it works from any
# directory and from a kitty keybinding, where the working directory is whatever
# the pane happened to be in.
#
#   dashboard/run.sh                       # default layout, redrawing
#   dashboard/run.sh --layout stellar-cartography
#   dashboard/run.sh --once                # paint one frame and exit
#   dashboard/run.sh --list-layouts
#
# Uses uv when it is available so Pillow is guaranteed, and falls back to the
# system interpreter otherwise — the dashboard only needs Pillow to generate the
# curve PNGs, and once they are cached it runs without it.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

if command -v uv >/dev/null 2>&1; then
  exec uv run --quiet --with pillow python -m dashboard.app "$@"
fi

exec python3 -m dashboard.app "$@"
