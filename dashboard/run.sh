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
# Uses uv so the dependencies are guaranteed: Pillow generates the curve PNGs
# and scales the fetched images, astropy supplies the ephemeris, and blessed
# handles terminal modes and mouse decoding. Falling
# back to the bare system interpreter works only if both happen to be installed
# there, so it is a last resort rather than a supported path.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

if command -v uv >/dev/null 2>&1; then
  exec uv run --quiet --with pillow --with astropy --with blessed python -m dashboard.app "$@"
fi

exec python3 -m dashboard.app "$@"
