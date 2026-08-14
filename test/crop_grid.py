#!/usr/bin/env python3
"""Crop a screenshot to a cell-grid region and optionally zoom it up.

Usage:
  crop_grid.py <input.png> <output.png>
    --col C      left cell column (0-indexed)
    --row R      top cell row    (0-indexed)
    --cols W     width in cells  (default: 10)
    --rows H     height in cells (default: 6)
    [--cellw 19] device px per cell width  (default: 19)
    [--cellh 38] device px per cell height (default: 38)
    [--term-left 0]  x of col 0 (default: 0)
    [--term-top  0]  y of row 0 (default: 0)
    [--zoom N]   integer zoom factor (default: auto — each cell at least 40px wide)

Grid lines and col/row labels are drawn on the output at every cell boundary.
"""
import argparse
from PIL import Image, ImageDraw, ImageFont


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--col",       type=int, required=True,  help="Left cell column")
    ap.add_argument("--row",       type=int, required=True,  help="Top cell row")
    ap.add_argument("--cols",      type=int, default=10,     help="Width in cells (default: 10)")
    ap.add_argument("--rows",      type=int, default=6,      help="Height in cells (default: 6)")
    ap.add_argument("--cellw",     type=int, default=19,     help="Device px per cell width (default: 19)")
    ap.add_argument("--cellh",     type=int, default=38,     help="Device px per cell height (default: 38)")
    ap.add_argument("--term-left", type=int, default=0,      help="X of col 0 (default: 0)")
    ap.add_argument("--term-top",  type=int, default=0,      help="Y of row 0 (default: 0)")
    ap.add_argument("--zoom",      type=int, default=0,      help="Zoom factor (default: auto)")
    args = ap.parse_args()

    cw, ch = args.cellw, args.cellh
    tl, tt = args.term_left, args.term_top

    # Pixel bounds of the requested region in the source image
    x0 = tl + args.col  * cw
    y0 = tt + args.row  * ch
    x1 = x0 + args.cols * cw
    y1 = y0 + args.rows * ch

    img = Image.open(args.input).convert("RGB")
    iw, ih = img.size
    x0, y0 = max(0, x0), max(0, y0)
    x1, y1 = min(iw, x1), min(ih, y1)

    crop = img.crop((x0, y0, x1, y1))

    # Zoom: auto-pick so each cell is at least 40px wide
    zoom = args.zoom
    if zoom <= 0:
        zoom = max(1, 40 // cw)

    if zoom > 1:
        crop = crop.resize((crop.width * zoom, crop.height * zoom), Image.NEAREST)

    # Draw grid lines and labels on the zoomed crop
    zcw = cw * zoom
    zch = ch * zoom
    out_w, out_h = crop.size

    overlay = Image.new("RGBA", (out_w, out_h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    grid_color = (0, 255, 255, 80)

    for ci in range(args.cols + 1):
        x = ci * zcw
        draw.line([(x, 0), (x, out_h - 1)], fill=grid_color, width=1)

    for ri in range(args.rows + 1):
        y = ri * zch
        draw.line([(0, y), (out_w - 1, y)], fill=grid_color, width=1)

    crop = Image.alpha_composite(crop.convert("RGBA"), overlay).convert("RGB")
    draw = ImageDraw.Draw(crop)

    label_color = (0, 255, 255, 220)
    try:
        font = ImageFont.load_default(size=max(10, zcw // 2))
    except TypeError:
        font = ImageFont.load_default()

    for ci in range(args.cols):
        draw.text((ci * zcw + 2, 2), str(args.col + ci), fill=label_color, font=font)

    for ri in range(args.rows):
        draw.text((2, ri * zch + 2), str(args.row + ri), fill=label_color, font=font)

    crop.save(args.output)
    print(f"Cropped cols {args.col}–{args.col + args.cols - 1}, "
          f"rows {args.row}–{args.row + args.rows - 1}  "
          f"zoom {zoom}×  →  {args.output}")


if __name__ == "__main__":
    main()
