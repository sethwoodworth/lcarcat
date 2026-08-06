#!/usr/bin/env python3
"""Cell-grid-aware gutter color checker for LCARS screenshot tests.

Samples the center pixel of each terminal cell in a named column (the gutter)
rather than scanning raw pixel rows. This avoids false positives from
anti-aliasing and sub-pixel rendering at cell edges.

Usage:
  analyze_gutter_cells.py <png>
      [--cellw 19] [--cellh 38] [--scale 2]
      [--gutter-col 0]
      [--skip-rows N]       # rows to skip at the top (e.g. nvim winbar)
      [--skip-bottom N]     # rows to skip at the bottom (nvim statusline)
      [--expect-bg COLOR]   # assert all sampled cells have this bg color
      [--verbose]

Exit codes: 0 = pass (or no assertion), 1 = assertion failed.

COLOR values understood by --expect-bg:
  periwinkle  #9999ff  (153,153,255)  -- main LineNr gutter
  orange      #ff9900  (255,153,0)    -- command buffer LineNr
  black       #000000  (0,0,0)        -- text area / terminal bg
  or a hex string: #rrggbb
"""
import sys
import argparse
import re
from PIL import Image

# Named colors from the LCARS palette
NAMED_COLORS = {
    "periwinkle": (153, 153, 255),
    "stem":       (153, 153, 255),
    "orange":     (255, 153,   0),
    "black":      (  0,   0,   0),
    "sky":        (102, 153, 204),
    "sky-blue":   (102, 153, 204),
    "gold":       (255, 204, 102),
    "sage":       (153, 204, 153),
    "red":        (255,  51,   0),
    "lilac":      (204, 153, 204),
    "stem-dim":   ( 92,  92, 153),
}
COLOR_TOLERANCE = 12


def parse_color(s):
    """Return (r, g, b) from a named color or #rrggbb hex string."""
    s = s.lower().strip()
    if s in NAMED_COLORS:
        return NAMED_COLORS[s]
    m = re.fullmatch(r"#([0-9a-f]{6})", s)
    if m:
        h = m.group(1)
        return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))
    raise ValueError(f"Unknown color: {s!r}")


def color_label(px):
    r, g, b = px[0], px[1], px[2]
    for name, (nr, ng, nb) in NAMED_COLORS.items():
        if abs(r - nr) <= COLOR_TOLERANCE and abs(g - ng) <= COLOR_TOLERANCE and abs(b - nb) <= COLOR_TOLERANCE:
            return name
    return f"#{r:02x}{g:02x}{b:02x}"


def color_matches(px, target_rgb):
    r, g, b = px[0], px[1], px[2]
    tr, tg, tb = target_rgb
    return abs(r - tr) <= COLOR_TOLERANCE and abs(g - tg) <= COLOR_TOLERANCE and abs(b - tb) <= COLOR_TOLERANCE


def find_terminal_top(img, scan_x):
    """Return y of the first near-black opaque pixel at scan_x (terminal content start).

    scan_x should be the center of the gutter column — inside the actual terminal
    content area, past the transparent rounded-corner border at the left edge of
    the kitty window (which makes x=0 unreliable on macOS).
    """
    _, H = img.size
    for y in range(H):
        px = img.getpixel((scan_x, y))
        if len(px) == 4:
            r, g, b, a = px
        else:
            r, g, b = px; a = 255
        if a > 200 and r < 20 and g < 20 and b < 20:
            return y
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("png", help="Screenshot PNG path")
    p.add_argument("--cellw",       type=int, default=19, help="Cell width in device pixels")
    p.add_argument("--cellh",       type=int, default=38, help="Cell height in device pixels")
    p.add_argument("--scale",       type=int, default=2,  help="Retina scale factor (1 or 2)")
    p.add_argument("--gutter-col",  type=int, default=0,  help="Terminal column to sample (0-indexed)")
    p.add_argument("--skip-rows",   type=int, default=0,  help="Skip N cell rows from the top")
    p.add_argument("--skip-bottom", type=int, default=1,  help="Skip N cell rows from the bottom (default: 1 for statusline)")
    p.add_argument("--expect-bg",   default=None,         help="Assert all sampled cells match this bg color")
    p.add_argument("--verbose",     action="store_true",  help="Print per-cell color table")
    args = p.parse_args()

    img = Image.open(args.png).convert("RGBA")
    W, H = img.size  # noqa: F841 — W used in cell-center bounds check below
    cell_px_w = args.cellw * args.scale
    cell_px_h = args.cellh * args.scale

    # Column: x center of the gutter column
    col = args.gutter_col
    cx = col * cell_px_w + cell_px_w // 2

    terminal_top = find_terminal_top(img, cx)

    # How many full cell rows fit between terminal_top and image bottom?
    usable_height = H - terminal_top
    total_rows = usable_height // cell_px_h

    if total_rows <= args.skip_rows + args.skip_bottom:
        print(f"FAIL: image too small — only {total_rows} cell rows detected, "
              f"skip-rows={args.skip_rows}, skip-bottom={args.skip_bottom}", file=sys.stderr)
        sys.exit(1)

    if args.verbose:
        print(f"PNG: {W}x{H} px  terminal_top={terminal_top}")
        print(f"Cell: {cell_px_w}x{cell_px_h} px (scale={args.scale})")
        print(f"Total rows: {total_rows}  sampling rows {args.skip_rows}..{total_rows - args.skip_bottom - 1}")
        print(f"Gutter column {col} center x={cx}")
        print(f"\n{'row':>4}  {'cy':>5}  {'color'}")

    target_rgb = parse_color(args.expect_bg) if args.expect_bg else None
    failures = []

    for row in range(args.skip_rows, total_rows - args.skip_bottom):
        cy = terminal_top + row * cell_px_h + cell_px_h // 2
        if cy >= H or cx >= W:
            break
        px = img.getpixel((cx, cy))
        label = color_label(px)

        if args.verbose:
            print(f"{row:>4}  {cy:>5}  {label}")

        if target_rgb is not None and not color_matches(px, target_rgb):
            failures.append((row, cy, label))

    if target_rgb is None:
        sys.exit(0)

    if failures:
        target_label = color_label(target_rgb + (255,))
        print(f"FAIL: gutter column {col} expected {args.expect_bg} ({target_label}) "
              f"but {len(failures)}/{total_rows - args.skip_rows - args.skip_bottom} rows differ:")
        for row, cy, label in failures[:10]:
            print(f"  row {row} (y={cy}): {label}")
        if len(failures) > 10:
            print(f"  ... and {len(failures) - 10} more")
        sys.exit(1)

    sampled = total_rows - args.skip_rows - args.skip_bottom
    print(f"PASS: gutter column {col} — all {sampled} rows are {args.expect_bg}")
    sys.exit(0)


if __name__ == "__main__":
    main()
