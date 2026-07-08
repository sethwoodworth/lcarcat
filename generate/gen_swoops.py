#!/usr/bin/env python3
"""Generate LCARS "swoop" elbows as PNGs for the kitty graphics protocol.

Shape (top swoop), matching the LCARS elbow:

  .------------------------------   <- 2-row-tall horizontal bar,
  |                                     rounded outer top-left corner
  |  \\  <- inner fillet
  |                                 <- 1-column-wide stem drops down
  |                                    from the left end; content
  |                                    (prompt, timestamps) nests to
                                       the right of the stem.

  swoop-top.png     bar on top, stem descends   (header)
  swoop-bottom.png  vertical mirror: bar on bottom, stem ascends (footer)

Drawn supersampled from an explicit outline (arcs sampled to points) so the outer
corner and the inner fillet are smooth. Placed by kitty scaled to r=(2+stem) rows
x c=cols cells, so the source is rendered at the cell aspect ratio to avoid distortion.

Run via uv:
  uv run --with pillow ~/.config/kitty/lcars/gen_swoops.py

Options:
  --color HEX     bar color               (default ff9900)
  --cols N        total cell columns wide (default 48)
  --stem-rows N   rows the stem descends  (default 2)
  --cellw PX      approx cell width  px   (default 19)
  --cellh PX      approx cell height px   (default 40)
  --outdir DIR    output dir (default: alongside this script)

The horizontal bar is fixed at 2 rows tall and the stem at 1 column wide, per design.
"""
import argparse
import math
import os

from PIL import Image, ImageDraw

SS = 4  # supersample factor
BAR_ROWS = 2
STEM_COLS = 1


def hex_rgba(h: str):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) + (255,)


def arc(cx, cy, r, deg0, deg1, n=48):
    pts = []
    for i in range(n + 1):
        a = math.radians(deg0 + (deg1 - deg0) * i / n)
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def make_swoop(path, color, cols, stem_rows, cellw, cellh, flip):
    cw, ch = cellw * SS, cellh * SS
    W = cols * cw
    barH = BAR_ROWS * ch
    stemW = STEM_COLS * cw
    stemH = stem_rows * ch
    H = barH + stemH
    r_out = ch * 0.9                       # outer top-left corner radius (~1 row)
    r_in = min(stemW * 0.9, ch * 0.6)      # inner fillet radius

    pts = []
    pts.append((r_out, 0))                 # top edge start
    pts.append((W, 0))                     # top edge -> right
    pts.append((W, barH))                  # right edge down
    pts.append((stemW + r_in, barH))       # bottom edge of bar -> toward stem
    pts += arc(stemW + r_in, barH + r_in, r_in, 270, 180)  # inner concave fillet
    pts.append((stemW, H))                 # stem right edge down
    pts.append((0, H))                     # stem bottom -> left
    pts.append((0, r_out))                 # left edge up
    pts += arc(r_out, r_out, r_out, 180, 270)              # outer rounded corner

    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(img).polygon(pts, fill=color)
    img = img.resize((cols * cellw, (BAR_ROWS + stem_rows) * cellh), Image.LANCZOS)
    if flip:
        img = img.transpose(Image.FLIP_TOP_BOTTOM)
    img.save(path)
    return path


def make_cap(path, color, rows, cellw, cellh):
    """A right half-round cap (flat left edge, rounded right) for the end of a bar.

    Width is chosen so the semicircle (radius = half the bar height) isn't squashed;
    the chosen cell-column count is returned so the caller knows how wide to place it.
    """
    ch = cellh * SS
    H = rows * ch
    r = H / 2.0
    cols = max(1, round(r / (cellw * SS)))
    W = cols * cellw * SS
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    # circle centered on the left edge, keep the right half (angles -90..90)
    ImageDraw.Draw(img).pieslice([-W, 0, W, H], -90, 90, fill=color)
    img = img.resize((cols * cellw, rows * cellh), Image.LANCZOS)
    img.save(path)
    return path, cols


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--color", default="ff9900")
    p.add_argument("--cols", type=int, default=48)
    p.add_argument("--elbow-cols", type=int, default=5,
                   help="width of the small left elbow caps (cell-based bar fills the rest)")
    p.add_argument("--stem-rows", type=int, default=2)
    p.add_argument("--cellw", type=int, default=19)
    p.add_argument("--cellh", type=int, default=40)
    p.add_argument("--outdir", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "assets"))
    a = p.parse_args()

    os.makedirs(a.outdir, exist_ok=True)
    color = hex_rgba(a.color)

    # Legacy wide swoops (whole bar baked into the PNG) -- kept for the current prompt.
    for name, flip in (("swoop-top.png", False), ("swoop-bottom.png", True)):
        print("wrote:", make_swoop(os.path.join(a.outdir, name), color,
                                   a.cols, a.stem_rows, a.cellw, a.cellh, flip))

    # New cell-based approach: small left elbow caps + a right round cap; the flat
    # bar + stem are drawn as colored terminal cells by the prompt.
    for name, flip in (("elbow-top.png", False), ("elbow-bottom.png", True)):
        print("wrote:", make_swoop(os.path.join(a.outdir, name), color,
                                   a.elbow_cols, a.stem_rows, a.cellw, a.cellh, flip))
    path, cols = make_cap(os.path.join(a.outdir, "cap-right.png"),
                          color, 2, a.cellw, a.cellh)
    print(f"wrote: {path}  (cap width = {cols} cols)")


if __name__ == "__main__":
    main()
