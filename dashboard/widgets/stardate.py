"""The clock: local time in block digits, the date, and a stardate.

The time is drawn from a small bitmap font rather than the terminal's own glyphs.
At one cell per pixel a digit would be three columns wide and five rows tall --
absurdly narrow, because terminal cells are about twice as tall as they are wide.
Each pixel is therefore two cells wide, which lands the digit at roughly the
proportions a real numeral has.
"""
from __future__ import annotations

import time
from datetime import datetime
from typing import Dict, List, Optional, Sequence, Tuple

from ..canvas import text_width
from ..geometry import Rect
from ..palette import (DIM_VIOLET, GOLD, ORANGE, PERIWINKLE, SAGE, TEXT, Color)
from ..segments import Chip, ChipStyle, Painter, draw_readout
from .base import Widget, WidgetChrome

#: A 3x5 bitmap font, one string per row, ``#`` for a lit pixel. Only the glyphs a
#: clock needs -- digits, a colon, and a blank.
GLYPHS: Dict[str, Tuple[str, ...]] = {
    "0": ("###", "# #", "# #", "# #", "###"),
    "1": ("  #", "  #", "  #", "  #", "  #"),
    "2": ("###", "  #", "###", "#  ", "###"),
    "3": ("###", "  #", "###", "  #", "###"),
    "4": ("# #", "# #", "###", "  #", "  #"),
    "5": ("###", "#  ", "###", "  #", "###"),
    "6": ("###", "#  ", "###", "# #", "###"),
    "7": ("###", "  #", "  #", "  #", "  #"),
    "8": ("###", "# #", "###", "# #", "###"),
    "9": ("###", "# #", "###", "  #", "###"),
    ":": ("   ", " # ", "   ", " # ", "   "),
    ".": ("   ", "   ", "   ", "   ", " # "),
    " ": ("   ", "   ", "   ", "   ", "   "),
}

GLYPH_ROWS = 5
GLYPH_COLUMNS = 3

#: The year this dashboard's stardates are measured from. Star Trek's own scale
#: sits four centuries ahead, which renders as a large negative number for any
#: present-day date, so the origin is moved to 2000 -- the arithmetic is the
#: series' own (a thousand units per year, advancing with the fraction elapsed),
#: and only the epoch differs.
STARDATE_EPOCH_YEAR = 2000


def stardate(moment: Optional[datetime] = None) -> float:
    moment = moment or datetime.now()
    start = datetime(moment.year, 1, 1)
    next_year = datetime(moment.year + 1, 1, 1)
    elapsed = (moment - start).total_seconds() / (next_year - start).total_seconds()
    return 1000 * (moment.year - STARDATE_EPOCH_YEAR) + 1000 * elapsed


def render_glyphs(text: str, pixel_width: int = 2) -> List[str]:
    """A string as rows of cells, each lit pixel widened to ``pixel_width`` cells."""
    rows: List[str] = []
    for row in range(GLYPH_ROWS):
        parts: List[str] = []
        for character in text:
            pattern = GLYPHS.get(character, GLYPHS[" "])[row]
            parts.append("".join(
                ("█" if pixel == "#" else " ") * pixel_width for pixel in pattern))
        rows.append(" ".join(parts))
    return rows


def glyph_width(text: str, pixel_width: int = 2) -> int:
    """Cells a rendered string will occupy, for centring it before drawing."""
    if not text:
        return 0
    return len(text) * GLYPH_COLUMNS * pixel_width + (len(text) - 1)


class StardateWidget(Widget):
    """Local time, calendar date, and a stardate."""

    refresh_interval = 1.0

    def __init__(
        self,
        title: str = "CHRONOMETER",
        color: Color = ORANGE,
        show_seconds: bool = True,
        pixel_width: int = 2,
        time_color: Color = ORANGE,
    ) -> None:
        super().__init__(title=title, color=color)
        self.show_seconds = show_seconds
        self.pixel_width = pixel_width
        self.time_color = time_color
        self.moment = datetime.now()

    def refresh(self) -> None:
        self.moment = datetime.now()

    def chrome(self) -> WidgetChrome:
        return WidgetChrome(
            title=self.title,
            color=self.color,
            chips=(Chip("%05.1f" % stardate(self.moment), GOLD, ChipStyle.COLOR),),
        )

    def render(self, painter: Painter, rect: Rect) -> None:
        if not rect:
            return
        moment = self.moment
        clock = moment.strftime("%H:%M:%S" if self.show_seconds else "%H:%M")

        # Shrink the pixel width, then drop the seconds, before giving up on the
        # block digits -- a narrow pane should still get the big clock.
        pixel_width = self.pixel_width
        while pixel_width > 1 and glyph_width(clock, pixel_width) > rect.width:
            pixel_width -= 1
        if glyph_width(clock, pixel_width) > rect.width and self.show_seconds:
            clock = moment.strftime("%H:%M")

        y = rect.y
        if rect.height >= GLYPH_ROWS and glyph_width(clock, pixel_width) <= rect.width:
            rows = render_glyphs(clock, pixel_width)
            start = rect.x + max(0, (rect.width - text_width(rows[0])) // 2)
            for offset, row in enumerate(rows):
                painter.canvas.text(start, rect.y + offset, row,
                                    foreground=self.time_color)
            y = rect.y + GLYPH_ROWS + 1
        else:
            painter.canvas.text_center(rect, y, clock, foreground=self.time_color,
                                       bold=True)
            y += 2

        lines: Sequence[Tuple[str, str, Color]] = (
            ("DATE", moment.strftime("%Y.%m.%d").upper(), TEXT),
            ("DAY", moment.strftime("%A").upper(), PERIWINKLE),
            ("STARDATE", "%.2f" % stardate(moment), GOLD),
            ("ZONE", (time.tzname[time.daylight and time.localtime().tm_isdst > 0]
                      or "LOCAL").upper(), SAGE),
        )
        for label, value, value_color in lines:
            if y >= rect.bottom:
                break
            draw_readout(painter, rect.x, y, label, value, rect.width,
                         label_color=DIM_VIOLET, value_color=value_color)
            y += 1
