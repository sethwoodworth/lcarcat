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


def make_swoop(path, color, cols, stem_rows, cellw, cellh, flip, mirror=False,
               bar_rows=BAR_ROWS, stem_cols=STEM_COLS, corner_bg=None):
    cw, ch = cellw * SS, cellh * SS
    W = cols * cw
    barH = bar_rows * ch
    stemW = stem_cols * cw
    stemH = stem_rows * ch
    H = barH + stemH
    r_out = min(ch * 0.9, barH)            # outer top-left corner radius (<= bar height)
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
    draw = ImageDraw.Draw(img)
    # Bake an opaque backdrop into ONLY the outer rounded-corner sliver (the transparent
    # cut-out above/left of the outer arc). This lets the elbow show its curve against
    # its own backdrop wherever it's placed — over periwinkle window separators or other
    # windows' cells that we can't paint. The inner fillet and the buffer side of the
    # image stay transparent so real content shows through there.
    if corner_bg is not None:
        draw.rectangle([0, 0, r_out, r_out], fill=corner_bg)
    draw.polygon(pts, fill=color)
    img = img.resize((cols * cellw, (bar_rows + stem_rows) * cellh), Image.LANCZOS)
    if flip:
        img = img.transpose(Image.FLIP_TOP_BOTTOM)
    if mirror:
        img = img.transpose(Image.FLIP_LEFT_RIGHT)   # stem moves to the right edge
    img.save(path)
    return path


def make_cap(path, color, rows, cellw, cellh, mirror=False):
    """A right half-round cap (flat left edge, rounded right) for the end of a bar.

    Width is chosen so the semicircle (radius = half the bar height) isn't squashed;
    the chosen cell-column count is returned so the caller knows how wide to place it.
    With mirror=True the cap faces left instead (flat right edge, rounded left) — used
    when the stem/elbow moves to the right end and the cap swaps to the left.
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
    if mirror:
        img = img.transpose(Image.FLIP_LEFT_RIGHT)
    img.save(path)
    return path, cols


def make_hcap(path, color, cellw, cellh, side, gap_cols=0, bg=None, rows=1):
    """A 1-row (default) end-cap for a horizontal LCARS channel (e.g. a split
    separator). The flat run of the channel is drawn as terminal cells; this image
    is only the rounded end (+ an optional black gap) so the cell bar reads as a
    capped segment.

      side='l': [gap][round-left cap]. The bar continues to the RIGHT of the cap, so
                its flat side faces right. Use `gap_cols` for the black offset that
                separates the segment from a rail to its left.
      side='r': [round-right cap]. The bar arrives from the LEFT; its flat side faces
                left. No gap (the segment ends here).

    `bg` (opaque) is baked around the semicircle so the cap's rounded edge shows even
    when it sits over a solid periwinkle separator we can't otherwise paint. Returns
    (path, total_cols).
    """
    ch = cellh * SS
    H = rows * ch
    r = H / 2.0
    capcols = max(1, round(r / (cellw * SS)))
    wcap = capcols * cellw * SS
    wgap = gap_cols * cellw * SS
    W = wgap + wcap
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if bg is not None:
        d.rectangle([0, 0, W, H], fill=bg)  # gap + the cap's outer corners
    if side == "l":
        # left semicircle centered on the cap's RIGHT edge (flat side faces right)
        cx = wgap + wcap
        d.pieslice([cx - wcap, 0, cx + wcap, H], 90, 270, fill=color)
    else:
        # right semicircle centered on the cap's LEFT edge (flat side faces left)
        d.pieslice([-wcap, 0, wcap, H], -90, 90, fill=color)
    total = gap_cols + capcols
    img = img.resize((total * cellw, rows * cellh), Image.LANCZOS)
    img.save(path)
    return path, total, capcols


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--color", default="ff9900")
    p.add_argument("--cols", type=int, default=48)
    p.add_argument("--elbow-cols", type=int, default=5,
                   help="width of the small left elbow caps (cell-based bar fills the rest)")
    p.add_argument("--stem-rows", type=int, default=1,
                   help="rows the stem (with inner fillet) descends below the 2-row bar. "
                        "MUST match the prompt's _LCARS_FRAME = bar(2) + stem-rows. Default 1.")
    p.add_argument("--cellw", type=int, default=19)
    p.add_argument("--cellh", type=int, default=40)
    p.add_argument("--bar-rows", type=int, default=BAR_ROWS,
                   help="rows the horizontal bar is tall for the CORNER elbow "
                        "(nvim tabline is 1). Legacy swoops/elbows stay 2.")
    p.add_argument("--stem-cols", type=int, default=STEM_COLS,
                   help="columns the stem is wide for the CORNER elbow "
                        "(nvim: number-gutter width). Legacy swoops/elbows stay 1.")
    p.add_argument("--outdir", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "assets"))
    p.add_argument("--corner-bg", default=None,
                   help="HEX fill baked into the CORNER elbows' outer rounded-corner "
                        "sliver (e.g. 000000). Lets the elbow show its curve over window "
                        "separators / other panes we can't paint. Default: transparent.")
    a = p.parse_args()

    os.makedirs(a.outdir, exist_ok=True)
    color = hex_rgba(a.color)

    # Legacy wide swoops (whole bar baked into the PNG) -- kept for the current prompt.
    for name, flip in (("swoop-top.png", False), ("swoop-bottom.png", True)):
        print("wrote:", make_swoop(os.path.join(a.outdir, name), color,
                                   a.cols, a.stem_rows, a.cellw, a.cellh, flip))

    # Cell-based approach: a small left elbow cap (rounded corner + inner fillet + a
    # 1-row stem stub) + a right round cap; the flat bar fill is drawn as terminal cells
    # by the prompt, and the stem continues below the image as a background cell.
    for name, flip in (("elbow-top.png", False), ("elbow-bottom.png", True)):
        print("wrote:", make_swoop(os.path.join(a.outdir, name), color,
                                   a.elbow_cols, a.stem_rows, a.cellw, a.cellh, flip))

    # Divider elbows: horizontal mirror of the above (outer rounded corner + stem on the
    # RIGHT edge). Used at a pane's divider-facing edge so the bar sweeps down into the
    # kitty border (set to the bar color), forming a double swoop across a vsplit.
    for name, flip in (("elbow-top-mirror.png", False), ("elbow-bottom-mirror.png", True)):
        print("wrote:", make_swoop(os.path.join(a.outdir, name), color,
                                   a.elbow_cols, a.stem_rows, a.cellw, a.cellh, flip,
                                   mirror=True))
    path, cols = make_cap(os.path.join(a.outdir, "cap-right.png"),
                          color, 2, a.cellw, a.cellh)
    print(f"wrote: {path}  (cap width = {cols} cols)")
    # Left-facing cap, for when the stem/elbow lives on the right end instead.
    path, cols = make_cap(os.path.join(a.outdir, "cap-left.png"),
                          color, 2, a.cellw, a.cellh, mirror=True)
    print(f"wrote: {path}  (cap width = {cols} cols)")

    # Corner elbow for the nvim chrome: a short bar (default 1 row) whose left end
    # rounds down into a wide stem (= number-gutter width). Width = stem + 2 cols so
    # the inner fillet (bar bottom meeting the buffer area, right of the stem) is
    # captured; everything below/right of the fillet is transparent so the tabline
    # pills and gutter show through. corner-tl = top-left, corner-bl = bottom-left.
    corner_cols = a.stem_cols + 2
    corner_bg = hex_rgba(a.corner_bg) if a.corner_bg else None
    for name, flip in (("corner-tl.png", False), ("corner-bl.png", True)):
        print("wrote:", make_swoop(os.path.join(a.outdir, name), color,
                                   corner_cols, a.stem_rows, a.cellw, a.cellh, flip,
                                   bar_rows=a.bar_rows, stem_cols=a.stem_cols,
                                   corner_bg=corner_bg))

    # 1-row channel end-caps for split separators: a left cap (with a 1-col black gap
    # so the segment sits off the left rail) and a right cap. The flat run between them
    # is drawn as periwinkle cells (the WinSeparator), so only the rounded ends are PNGs.
    path, total, _ = make_hcap(os.path.join(a.outdir, "hcap-l.png"), color,
                               a.cellw, a.cellh, "l", gap_cols=1, bg=corner_bg)
    print(f"wrote: {path}  ({total} cols)")
    path, total, capcols = make_hcap(os.path.join(a.outdir, "hcap-r.png"), color,
                                     a.cellw, a.cellh, "r", bg=corner_bg)
    print(f"wrote: {path}  ({total} cols, cap {capcols})")

    # Gapless 1-row round-left cap for the editor edge: used in place of the corner
    # elbow when the top-left / bottom-left window has NO gutter (e.g. netrw), so the
    # tabline / statusline bar simply rounds off at the left instead of curving into a
    # (non-existent) stem.
    path, total, _ = make_hcap(os.path.join(a.outdir, "cap-left1.png"), color,
                               a.cellw, a.cellh, "l", gap_cols=0, bg=corner_bg)
    print(f"wrote: {path}  ({total} cols)")


if __name__ == "__main__":
    main()
