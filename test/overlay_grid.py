#!/usr/bin/env python3
"""Annotate a screenshot PNG with a cell-boundary grid and col/row numbers.

Cell boundaries are anchored to the terminal content area. Pass --term-left
and --term-top explicitly (measured from a calibration screenshot) for reliable
alignment. Fallback scanning is provided but unreliable — prefer explicit values.

Calibrated values for test/kitty_test.conf (fullscreen, placement_strategy top-left, window_padding_width 0):
  All tabs: --term-left 0 --term-top 0 --cellw 19 --cellh 38

  Fullscreen + placement_strategy top-left means cell (0,0) is always at pixel (0,0).
  Any remainder pixels land at the right/bottom edges.

Usage:
  overlay_grid.py <input.png> <output.png>
      [--cellw PX]         device pixels per cell width (default: 19)
      [--cellh PX]         device pixels per cell height (default: 38)
      [--term-left PX]     x of terminal col 0 left edge (default: 76)
      [--term-top PX]      y of terminal row 0 top edge (default: 108)
      [--label-every-n-cols N]   (default: 5)
      [--label-every-n-rows N]   (default: 3)
"""
import argparse
from PIL import Image, ImageDraw, ImageFont


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input",  help="Input PNG path")
    ap.add_argument("output", help="Output PNG path")
    ap.add_argument("--cellw",              type=int, default=19,  help="Device px per cell width (default: 19)")
    ap.add_argument("--cellh",              type=int, default=38,  help="Device px per cell height (default: 38)")
    ap.add_argument("--term-left",          type=int, default=0,   help="X of col 0 left edge in device px (default: 0)")
    ap.add_argument("--term-top",           type=int, default=0,   help="Y of row 0 top edge in device px (default: 0 = fullscreen with placement_strategy top-left)")
    ap.add_argument("--label-every-n-cols", type=int, default=5,   help="Label every Nth column (default: 5)")
    ap.add_argument("--label-every-n-rows", type=int, default=3,   help="Label every Nth row (default: 3)")
    args = ap.parse_args()

    cw = args.cellw
    ch = args.cellh
    term_left = args.term_left
    term_top  = args.term_top

    img = Image.open(args.input).convert("RGBA")
    w, h = img.size

    print(f"Terminal origin: ({term_left}, {term_top})  cell: {cw}x{ch}px  image: {w}x{h}px")

    overlay = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    grid_color = (0, 255, 255, 60)

    x = term_left
    while x <= w:
        draw.line([(x, term_top), (x, h - 1)], fill=grid_color, width=1)
        x += cw

    y = term_top
    while y <= h:
        draw.line([(term_left, y), (w - 1, y)], fill=grid_color, width=1)
        y += ch

    img = Image.alpha_composite(img, overlay)
    draw = ImageDraw.Draw(img)

    try:
        font = ImageFont.load_default(size=10)
    except TypeError:
        font = ImageFont.load_default()

    label_color = (0, 255, 255, 220)
    n_cols = (w - term_left) // cw
    n_rows = (h - term_top) // ch

    for ci in range(n_cols):
        if ci % args.label_every_n_cols == 0:
            draw.text((term_left + ci * cw + 2, term_top + 2), str(ci),
                      fill=label_color, font=font)

    for ri in range(n_rows):
        if ri % args.label_every_n_rows == 0:
            draw.text((term_left + 2, term_top + ri * ch + 2), str(ri),
                      fill=label_color, font=font)

    img.convert("RGB").save(args.output)
    print(f"Wrote {args.output}  ({n_cols}x{n_rows} cells)")


if __name__ == "__main__":
    main()
