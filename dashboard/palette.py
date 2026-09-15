"""LCARS colors for the dashboard.

Mirrors ``docs/palette.md``, which is the documentation source of truth, and
``nvim/lua/lcars/palette.lua``, which is the runtime source of truth for nvim.
There is no generated sync step between the copies -- when a color changes it
changes in all of them by hand.

Colors are ``(red, green, blue)`` triples so segments can emit SGR truecolor
directly without reparsing hex on every cell.
"""
from __future__ import annotations

from typing import Dict, Tuple

Color = Tuple[int, int, int]


def from_hex(value: str) -> Color:
    value = value.lstrip("#")
    return (int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16))


def to_hex(color: Color) -> str:
    """Six hex digits, no leading ``#`` -- the form asset filenames use."""
    return "%02x%02x%02x" % color


CANVAS = from_hex("000000")        # universal background, never off-black
TEXT = from_hex("ffffc6")          # pale canary, never pure white
ORANGE = from_hex("ff9900")        # input accent / active
PERIWINKLE = from_hex("9999ff")    # structural / display
GOLD = from_hex("ffcc66")
LILAC = from_hex("cc99cc")
SKY = from_hex("6699cc")
RED_ALERT = from_hex("ff3300")
SAGE = from_hex("99cc99")
AWS_ORANGE = from_hex("ff9933")
DIM_VIOLET = from_hex("666699")
STEM_DIM = from_hex("5c5c99")
CURSOR_MAGENTA = from_hex("cc6699")

BY_NAME: Dict[str, Color] = {
    "canvas": CANVAS,
    "text": TEXT,
    "orange": ORANGE,
    "periwinkle": PERIWINKLE,
    "gold": GOLD,
    "lilac": LILAC,
    "sky": SKY,
    "red_alert": RED_ALERT,
    "sage": SAGE,
    "aws_orange": AWS_ORANGE,
    "dim_violet": DIM_VIOLET,
    "stem_dim": STEM_DIM,
    "cursor_magenta": CURSOR_MAGENTA,
}


def named(name: str) -> Color:
    try:
        return BY_NAME[name]
    except KeyError:
        raise KeyError(
            "unknown LCARS color %r; known colors: %s"
            % (name, ", ".join(sorted(BY_NAME)))
        )


# Structural color by panel role, per the semantic rule in docs/lcars-design.md:
# panels the user types into are orange, read-only display panels are periwinkle.
INPUT_PANEL = ORANGE
DISPLAY_PANEL = PERIWINKLE


# Chip accents, in the order a layout should reach for them. Keeping this a short
# ordered list is what enforces the "maximum ~5 colors in one view" rule -- a
# widget asks for accent 0, 1, 2 rather than inventing a color per row.
ACCENT_SEQUENCE = (PERIWINKLE, GOLD, LILAC, SKY, SAGE)


def accent(index: int) -> Color:
    return ACCENT_SEQUENCE[index % len(ACCENT_SEQUENCE)]
