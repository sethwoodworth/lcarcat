"""A cell grid that paints one ANSI frame.

The dashboard is absolutely positioned: widgets write cells at screen coordinates
rather than printing lines in order. The canvas holds that grid and serialises it
once, which is what keeps a multi-pane redraw free of tearing -- a single write
lands as one frame instead of a pane at a time.

Two cell kinds live in the same grid:

* ordinary cells, carrying a character plus truecolor foreground and background
* image placeholder cells, carrying kitty's ``U+10EEEE`` plus row/column
  combining marks, whose *foreground* is a 256-color index holding an image id

Keeping both in one grid means a curved elbow PNG and the flat cells it abuts are
emitted in the same pass, in the same row, with no cursor gymnastics between them.
"""
from __future__ import annotations

import unicodedata
from typing import Iterable, List, Optional

from .diacritics import placeholder_cell
from .geometry import Rect
from .palette import CANVAS, TEXT, Color

# Written into the grid cell immediately after a double-width character. It emits
# nothing at render time -- the wide glyph before it already covered the column.
CONTINUATION = "\0"


def character_width(character: str) -> int:
    """Columns a character occupies: 0 for combining marks, 2 for wide glyphs, else 1."""
    if unicodedata.combining(character):
        return 0
    return 2 if unicodedata.east_asian_width(character) in ("W", "F") else 1


def text_width(text: str) -> int:
    return sum(character_width(character) for character in text)


def truncate(text: str, width: int, ellipsis: str = "…") -> str:
    """Clip ``text`` to ``width`` columns, marking the cut with an ellipsis.

    Width is counted in columns rather than characters so a wide glyph cannot push
    a line one column past its panel and bleed into the neighbour.
    """
    if width <= 0:
        return ""
    if text_width(text) <= width:
        return text
    marker_width = text_width(ellipsis)
    if width <= marker_width:
        return ellipsis[:width]
    budget = width - marker_width
    out, used = [], 0
    for character in text:
        step = character_width(character)
        if used + step > budget:
            break
        out.append(character)
        used += step
    return "".join(out) + ellipsis


class Cell:
    __slots__ = ("char", "foreground", "background", "image_id", "bold")

    def __init__(self) -> None:
        self.char = " "
        self.foreground: Optional[Color] = None
        self.background: Color = CANVAS
        self.image_id: Optional[int] = None
        self.bold = False


class Canvas:
    """A ``columns x rows`` grid of cells, painted black."""

    def __init__(self, columns: int, rows: int) -> None:
        self.columns = columns
        self.rows = rows
        self._cells: List[List[Cell]] = [
            [Cell() for _ in range(columns)] for _ in range(rows)
        ]

    @property
    def rect(self) -> Rect:
        return Rect(0, 0, self.columns, self.rows)

    def cell(self, x: int, y: int) -> Optional[Cell]:
        if 0 <= x < self.columns and 0 <= y < self.rows:
            return self._cells[y][x]
        return None

    # -- painting ---------------------------------------------------------

    def put(
        self,
        x: int,
        y: int,
        char: str = " ",
        foreground: Optional[Color] = None,
        background: Optional[Color] = None,
        image_id: Optional[int] = None,
        bold: bool = False,
    ) -> None:
        """Write one cell. Out-of-bounds writes are dropped, not an error.

        Clipping silently is deliberate: widgets compute positions from a Rect they
        were handed, and a dashboard that loses a character at the edge of a narrow
        terminal is better than one that raises out of a redraw loop.
        """
        cell = self.cell(x, y)
        if cell is None:
            return
        cell.char = char
        cell.foreground = foreground
        if background is not None:
            cell.background = background
        cell.image_id = image_id
        cell.bold = bold

    def fill(self, rect: Rect, background: Color, char: str = " ") -> None:
        for y in rect.rows():
            for x in rect.columns():
                self.put(x, y, char, background=background)

    def horizontal_run(
        self,
        x: int,
        y: int,
        width: int,
        background: Color,
        char: str = " ",
        foreground: Optional[Color] = None,
    ) -> None:
        """A flat colored run -- the workhorse of LCARS chrome."""
        for offset in range(max(0, width)):
            self.put(x + offset, y, char, foreground=foreground, background=background)

    def vertical_run(
        self,
        x: int,
        y: int,
        height: int,
        background: Color,
        char: str = " ",
        foreground: Optional[Color] = None,
    ) -> None:
        for offset in range(max(0, height)):
            self.put(x, y + offset, char, foreground=foreground, background=background)

    def text(
        self,
        x: int,
        y: int,
        text: str,
        foreground: Color = TEXT,
        background: Optional[Color] = None,
        bold: bool = False,
        max_width: Optional[int] = None,
    ) -> int:
        """Write a string left to right. Returns the columns consumed.

        ``background=None`` keeps whatever color the cells already carry, which is
        how a label lands on a colored chip without the caller repainting it.
        """
        if max_width is not None:
            text = truncate(text, max_width)
        column = x
        for character in text:
            width = character_width(character)
            if width == 0:
                # Combining marks belong to the character already written.
                previous = self.cell(column - 1, y)
                if previous is not None:
                    previous.char += character
                continue
            self.put(column, y, character, foreground=foreground,
                     background=background, bold=bold)
            if width == 2:
                self.put(column + 1, y, CONTINUATION, foreground=foreground,
                         background=background, bold=bold)
            column += width
        return column - x

    def text_right(
        self,
        right_edge: int,
        y: int,
        text: str,
        foreground: Color = TEXT,
        background: Optional[Color] = None,
        bold: bool = False,
    ) -> int:
        """Write a string ending at ``right_edge`` (exclusive). Returns its start column."""
        start = right_edge - text_width(text)
        self.text(start, y, text, foreground, background, bold)
        return start

    def text_center(
        self,
        rect: Rect,
        y: int,
        text: str,
        foreground: Color = TEXT,
        background: Optional[Color] = None,
        bold: bool = False,
    ) -> int:
        text = truncate(text, rect.width)
        start = rect.x + max(0, (rect.width - text_width(text)) // 2)
        self.text(start, y, text, foreground, background, bold)
        return start

    def place_image(
        self,
        x: int,
        y: int,
        image_id: int,
        columns: int,
        image_rows: int,
        background: Optional[Color] = None,
    ) -> None:
        """Lay down the placeholder cells for a transmitted image.

        Every placeholder cell is left black. The elbow and cap PNGs are transparent
        outside their curve, so the cell background is what shows through the cut-out
        -- and that has to be the LCARS void, not a color.

        There is deliberately no "blend the abutting column into the bar" option.
        An earlier version painted the image's edge column with the bar's color to
        hide a supposed sub-pixel seam, and it did real damage: a cap's first column
        is mostly *curve* (the semicircle spans the full cell height at its flat edge
        and narrows rightward), so filling that cell squared the cap off and made the
        radius appear to start a column late. On an elbow it filled the fillet row,
        leaving a stray colored cell below the bar. The seam it guarded against does
        not exist anyway: PNG dimensions match ``columns * cell_width`` by
        ``rows * cell_height`` exactly, so kitty places with zero inset and the
        image's opaque edge lands precisely on the cell boundary.
        """
        for row in range(image_rows):
            for column in range(columns):
                self.put(
                    x + column,
                    y + row,
                    placeholder_cell(row, column),
                    background=background if background is not None else CANVAS,
                    image_id=image_id,
                )

    # -- serialisation ----------------------------------------------------

    def render(self) -> str:
        """The whole grid as one ANSI string, positioned from the top-left.

        SGR sequences are emitted only when a color actually changes, which takes a
        full-screen repaint from roughly one escape per cell to one per run.
        """
        parts: List[str] = []
        for y, row in enumerate(self._cells):
            parts.append("\x1b[%d;1H" % (y + 1))
            foreground = background = image_id = bold = _UNSET
            for cell in row:
                if cell.char == CONTINUATION:
                    continue
                if cell.image_id is not None:
                    if cell.image_id != image_id:
                        parts.append("\x1b[38;5;%dm" % cell.image_id)
                        image_id = cell.image_id
                        foreground = _UNSET
                else:
                    if image_id is not _UNSET and image_id is not None:
                        image_id = None
                        foreground = _UNSET
                    if cell.foreground != foreground:
                        if cell.foreground is None:
                            parts.append("\x1b[39m")
                        else:
                            parts.append("\x1b[38;2;%d;%d;%dm" % cell.foreground)
                        foreground = cell.foreground
                if cell.background != background:
                    parts.append("\x1b[48;2;%d;%d;%dm" % cell.background)
                    background = cell.background
                if cell.bold != bold:
                    parts.append("\x1b[1m" if cell.bold else "\x1b[22m")
                    bold = cell.bold
                parts.append(cell.char)
            parts.append("\x1b[0m")
        return "".join(parts)


class _Unset:
    """Sentinel distinct from ``None``, which is a real foreground value (default fg)."""

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return "<unset>"


_UNSET = _Unset()


def frame(canvas: Canvas, clear: bool = True) -> str:
    """Wrap a rendered canvas in the escapes a full-screen repaint needs."""
    parts = ["\x1b[?25l"]  # hide cursor; a blinking block in the middle of chrome reads as damage
    if clear:
        parts.append("\x1b[H\x1b[2J")
    parts.append(canvas.render())
    # Park the cursor at the top-left rather than leaving it wherever the last
    # cell landed. The canvas paints the bottom row, so a cursor left there means
    # the next thing anything writes -- a shell prompt, a stray newline -- scrolls
    # the terminal and takes the top of the frame with it.
    parts.append("\x1b[H")
    return "".join(parts)


def enter_full_screen() -> str:
    """Switch to the alternate screen buffer.

    A full-screen dashboard belongs there for the same reason an editor does: it
    paints every row including the last, so on the normal screen the first newline
    written after it scrolls the top of the frame into scrollback. The alternate
    screen also means quitting restores whatever the pane held before, instead of
    leaving a screenful of chrome in the history.
    """
    return "\x1b[?1049h\x1b[?25l"


def leave_full_screen() -> str:
    return "\x1b[0m\x1b[?25h\x1b[?1049l"


def restore() -> str:
    """Undo what :func:`frame` set up, for a clean exit on the normal screen."""
    return "\x1b[0m\x1b[?25h"


def join_cells(cells: Iterable[str]) -> str:  # pragma: no cover - convenience
    return "".join(cells)
