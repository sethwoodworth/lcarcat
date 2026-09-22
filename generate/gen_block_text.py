#!/usr/bin/env python3
"""Two-row block-letter labels, baked to PNG for the kitty graphics protocol.

LCARS labels are set in an ultra-condensed face at a size no terminal font can
give us: the letters are as tall as the bar they sit in. Terminal cells cannot
do that -- a cell holds one glyph at the terminal's own font size -- so a label
that has to be bar-height is an image, the same exception the elbow and the cap
already are.

The PNG is sized to an exact multiple of the cell box (``columns * cellw`` by
``rows * cellh``), because kitty aspect-fits a Unicode-placeholder image into
its cell box and any mismatch shows up as a sub-cell inset. See the header of
``gen_swoops.py`` for that arithmetic.

The caller decides which colour is which. A label cut into a bar takes the
LCARS void as its background and the bar's own accent for the glyphs, so it
reads as cut into the bar rather than printed on it; pass the colours the other
way round for a label knocked out of a solid segment.

    uv run --with pillow generate/gen_block_text.py --text "STELLAR CARTOGRAPHY"
"""
from __future__ import annotations

import argparse
import os
from typing import Optional, Tuple

from PIL import Image, ImageDraw, ImageFont

SS = 4  # supersample factor, matching gen_swoops

#: Candidate faces, in preference order. Swiss 911 Ultra Compressed is the canon
#: LCARS face and ships with nothing. Antonio is the closest free stand-in and
#: the one this repo's own pages set their headings in (`brew install
#: font-antonio`); the rest are macOS built-ins, kept as a fallback so a machine
#: without Antonio still renders something in the right spirit.
FONT_CANDIDATES = (
    os.path.expanduser("~/Library/Fonts/Antonio[wght].ttf"),
    "/opt/homebrew/Caskroom/font-antonio/latest/Antonio[wght].ttf",
    "/System/Library/Fonts/Supplemental/Impact.ttf",
    "/System/Library/Fonts/Supplemental/DIN Condensed Bold.ttf",
    "/System/Library/Fonts/Supplemental/Arial Narrow Bold.ttf",
)

#: Weight to pull from a variable face. Antonio's axis runs 100-700; the label
#: is small on screen and knocked out of a bright bar, so it wants the top of
#: that range to hold its counters.
FONT_WEIGHT = 700

#: Fraction of the image height the capital letters fill. Leaves a little air
#: above and below so the label does not touch the bar's edges, which is what
#: the reference panels do.
CAP_HEIGHT_RATIO = 0.74

#: Extra space between letters, as a fraction of the cap height. The condensed
#: faces set very tight by default; LCARS labels are letterspaced.
TRACKING_RATIO = 0.06

#: Whole cells of ground kept either side of the letters. The label is cut into
#: a bar, so without it the black ends where the glyphs do and the letters read
#: as pressed against the colour on both sides.
PAD_COLUMNS = 1


def resolve_font(path: Optional[str] = None) -> str:
    for candidate in ([path] if path else []) + list(FONT_CANDIDATES):
        if candidate and os.path.exists(candidate):
            return candidate
    raise FileNotFoundError("no block-letter font found; pass --font")


def _set_weight(font: ImageFont.FreeTypeFont, weight: int) -> ImageFont.FreeTypeFont:
    """Pull `weight` from a variable face; a static face is left alone."""
    try:
        font.set_variation_by_axes([weight])
    except Exception:
        pass
    return font


def _fitted_font(font_path: str, cap_height_px: float,
                 weight: int = FONT_WEIGHT) -> ImageFont.FreeTypeFont:
    """A font whose CAP height (not line height) is cap_height_px."""
    probe_size = 100
    probe = _set_weight(ImageFont.truetype(font_path, probe_size), weight)
    top, bottom = probe.getbbox("H")[1], probe.getbbox("H")[3]
    measured = bottom - top
    return _set_weight(
        ImageFont.truetype(font_path, max(1, round(probe_size * cap_height_px / measured))),
        weight,
    )


def measure(text: str, rows: int, cellw: int, cellh: int,
            font_path: Optional[str] = None,
            cap_height_ratio: float = CAP_HEIGHT_RATIO,
            tracking_ratio: float = TRACKING_RATIO) -> Tuple[int, int]:
    """Columns the label needs, and the pixel width it actually draws.

    Rounds up to whole cells: the image has to land on the cell grid, so the
    label is centred in whatever slack the rounding leaves.
    """
    height = rows * cellh * SS
    font = _fitted_font(resolve_font(font_path), height * cap_height_ratio)
    tracking = round(height * cap_height_ratio * tracking_ratio)
    width = 0
    for index, character in enumerate(text):
        width += round(font.getlength(character))
        if index < len(text) - 1:
            width += tracking
    columns = max(1, -(-width // (cellw * SS))) + 2 * PAD_COLUMNS
    return columns, width


def render(path: str, text: str, color: Tuple[int, int, int, int],
           label_color: Tuple[int, int, int, int], rows: int, cellw: int, cellh: int,
           columns: Optional[int] = None, font_path: Optional[str] = None,
           cap_height_ratio: float = CAP_HEIGHT_RATIO,
           tracking_ratio: float = TRACKING_RATIO) -> Tuple[str, int]:
    """Draw the label and return (path, columns it occupies)."""
    needed, _ = measure(text, rows, cellw, cellh, font_path, cap_height_ratio, tracking_ratio)
    columns = columns or needed
    width, height = columns * cellw * SS, rows * cellh * SS
    font = _fitted_font(resolve_font(font_path), height * cap_height_ratio)
    tracking = round(height * cap_height_ratio * tracking_ratio)

    image = Image.new("RGBA", (width, height), color)
    draw = ImageDraw.Draw(image)

    # Centre on the CAP box, not on the font's line box: the descender space
    # below the baseline would otherwise push an all-caps label visibly high.
    cap_top, cap_bottom = font.getbbox("H")[1], font.getbbox("H")[3]
    drawn_width = sum(round(font.getlength(c)) for c in text) + tracking * max(0, len(text) - 1)
    pen_x = (width - drawn_width) / 2
    pen_y = (height - (cap_bottom - cap_top)) / 2 - cap_top
    for character in text:
        draw.text((pen_x, pen_y), character, font=font, fill=label_color)
        pen_x += round(font.getlength(character)) + tracking

    image = image.resize((columns * cellw, rows * cellh), Image.LANCZOS)
    image.save(path)
    return path, columns


def hex_rgba(value: str) -> Tuple[int, int, int, int]:
    value = value.lstrip("#")
    return (int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16), 255)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--text", required=True)
    parser.add_argument("--color", default="ff9900", help="bar colour the letters are cut out of")
    parser.add_argument("--label-color", default="000000")
    parser.add_argument("--rows", type=int, default=2)
    parser.add_argument("--cellw", type=int, default=19)
    parser.add_argument("--cellh", type=int, default=38)
    parser.add_argument("--columns", type=int, default=None)
    parser.add_argument("--font", default=None)
    parser.add_argument("--cap-height", type=float, default=CAP_HEIGHT_RATIO)
    parser.add_argument("--tracking", type=float, default=TRACKING_RATIO)
    parser.add_argument("--out", default="block-text.png")
    arguments = parser.parse_args()
    path, columns = render(
        arguments.out, arguments.text, hex_rgba(arguments.color),
        hex_rgba(arguments.label_color), arguments.rows, arguments.cellw,
        arguments.cellh, arguments.columns, arguments.font,
        arguments.cap_height, arguments.tracking,
    )
    print(f"wrote: {path}  ({columns} cols x {arguments.rows} rows, "
          f"{columns * arguments.cellw}x{arguments.rows * arguments.cellh}px, "
          f"font {os.path.basename(resolve_font(arguments.font))})")


if __name__ == "__main__":
    main()
