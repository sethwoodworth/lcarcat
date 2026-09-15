"""A picture with its numbers arranged around it.

The shape both the moon and the sun want: a square photograph in the middle of
the pane, readouts flanking it in two columns, and a stacked fallback -- picture
on top, readouts beneath -- for panes too narrow to hold all three side by side.

Subclasses supply two things: the image to draw (:meth:`image_source`) and the
rows to put beside it (:meth:`readouts`). Everything about *fitting* those into
a rectangle lives here, because it is fiddly, was got wrong several times, and
is identical for any widget of this shape.

Two sizing rules earned their comments the hard way:

* the text columns are measured first and the picture takes the width that is
  left. Letting the picture bid first makes it eat the pane and the text wraps
  around it.
* a label and its value stay on one line. Splitting them across two rows turns a
  column of nine readouts into eighteen unrelated fragments, and abbreviating the
  labels to fit is not available -- AGENTS.md wants words spelled out.
"""
from __future__ import annotations

from pathlib import Path
from typing import List, Optional, Tuple

from .. import plots
from ..geometry import Rect
from ..palette import Color
from ..segments import Painter, draw_readout
from .base import Widget


class FramedImageWidget(Widget):
    """Base for widgets that are a picture surrounded by readouts."""

    refresh_in_background = True

    #: Below this the picture is too coarse to be worth the rows it costs.
    MINIMUM_IMAGE_ROWS = 6
    #: Above this it stops adding detail and just crowds the readout.
    MAXIMUM_IMAGE_ROWS = 20
    #: Readouts always kept, however short the pane.
    MINIMUM_READOUTS = 4
    #: Narrowest flanking column that can carry anything useful.
    MINIMUM_COLUMN_WIDTH = 6
    #: Clear cells between a text column and the picture.
    COLUMN_GAP = 1

    def __init__(self, title: str = "", color: Color = None,  # type: ignore[assignment]
                 framed: bool = True) -> None:
        super().__init__(title=title, color=color)
        #: Flank the picture with readouts instead of stacking them beneath it.
        self.framed = framed
        self.image_key = "%s-%d" % (type(self).__name__.lower(), id(self))

    # -- to override -------------------------------------------------------

    def image_source(self) -> Optional[Path]:
        """The image file to draw, or ``None`` if there is nothing to show."""
        raise NotImplementedError

    def readouts(self) -> List[Tuple[str, str, Color]]:
        """``(label, value, color)`` rows, most important first."""
        raise NotImplementedError

    def draw_without_image(self, painter: Painter, rect: Rect, rows: int) -> bool:
        """Draw something in the picture's place when there is no image.

        Default: nothing. The moon overrides it to draw a computed phase disc, so
        an offline machine still gets a moon rather than an empty box.
        """
        return False

    # -- drawing -----------------------------------------------------------

    @staticmethod
    def readout_line_width(readouts: List[Tuple[str, str, Color]]) -> int:
        """Columns needed to keep every label and its value on one line."""
        if not readouts:
            return 0
        return max(len(label) + 2 + len(value) for label, value, _ in readouts)

    def render(self, painter: Painter, rect: Rect) -> None:
        if not rect:
            return
        rows = self.readouts()
        if self.framed and self._render_framed(painter, rect, rows):
            return
        self._render_stacked(painter, rect, rows)

    def _render_framed(self, painter: Painter, rect: Rect,
                       readouts: List[Tuple[str, str, Color]]) -> bool:
        """Picture centred, readouts down both sides. False if it will not fit."""
        source = self.image_source()
        if source is None or not readouts:
            return False

        cell = painter.assets.cell_size
        column_width = self.readout_line_width(readouts)
        available = rect.width - 2 * (column_width + self.COLUMN_GAP)
        if available < self.MINIMUM_IMAGE_ROWS or column_width < self.MINIMUM_COLUMN_WIDTH:
            return False

        image_rows = min(rect.height, self.MAXIMUM_IMAGE_ROWS,
                         int(available * cell.width / float(cell.height)))
        if image_rows < self.MINIMUM_IMAGE_ROWS:
            return False
        columns = min(available,
                      plots.square_cell_box(image_rows, cell.width, cell.height))

        half = (len(readouts) + 1) // 2
        self._draw_readout_column(
            painter, Rect(rect.x, rect.y, column_width, rect.height), readouts[:half])
        self._draw_readout_column(
            painter, Rect(rect.right - column_width, rect.y, column_width, rect.height),
            readouts[half:])

        return self._place(painter,
                           rect.x + (rect.width - columns) // 2,
                           rect.y + (rect.height - image_rows) // 2,
                           columns, image_rows, source)

    def _render_stacked(self, painter: Painter, rect: Rect,
                        readouts: List[Tuple[str, str, Color]]) -> None:
        """Picture on top, readouts beneath, trimmed to the rows available."""
        widest = min(rect.width // 2, self.MAXIMUM_IMAGE_ROWS)
        image_rows = 0
        if rect.height >= self.MINIMUM_IMAGE_ROWS + self.MINIMUM_READOUTS + 1:
            image_rows = max(0, min(
                widest,
                rect.height - self.MINIMUM_READOUTS - 1,
                max(0, rect.height - len(readouts) - 1)))
            if image_rows < self.MINIMUM_IMAGE_ROWS:
                image_rows = (self.MINIMUM_IMAGE_ROWS
                              if rect.height - self.MINIMUM_IMAGE_ROWS - 1
                              >= self.MINIMUM_READOUTS else 0)

        text_top = rect.y
        if image_rows >= self.MINIMUM_IMAGE_ROWS:
            cell = painter.assets.cell_size
            columns = min(rect.width,
                          plots.square_cell_box(image_rows, cell.width, cell.height))
            source = self.image_source()
            drawn = False
            if source is not None:
                drawn = self._place(painter, rect.x + (rect.width - columns) // 2,
                                    rect.y, columns, image_rows, source)
            if not drawn:
                drawn = self.draw_without_image(painter, rect, image_rows)
            if drawn:
                text_top = rect.y + image_rows + 1

        for index, (label, value, color) in enumerate(
                readouts[: max(0, rect.bottom - text_top)]):
            y = text_top + index
            if y >= rect.bottom:
                break
            draw_readout(painter, rect.x, y, label, value, rect.width,
                         value_color=color)

    def _place(self, painter: Painter, x: int, y: int, columns: int, rows: int,
               source: Path) -> bool:
        cell = painter.assets.cell_size
        png = plots.render_fitted_image(source, columns * cell.width,
                                        rows * cell.height)
        if not png:
            return False
        escapes, image_id = painter.images.dynamic_transmission(
            self.image_key, png, columns, rows)
        if escapes:
            painter.queue_transmission(escapes)
        painter.canvas.place_image(x, y, image_id, columns, rows)
        return True

    def _draw_readout_column(self, painter: Painter, column: Rect,
                             readouts: List[Tuple[str, str, Color]]) -> None:
        """One row per readout: label at the left, value right-aligned."""
        if column.width < self.MINIMUM_COLUMN_WIDTH or not readouts:
            return
        y = column.y + max(0, (column.height - len(readouts)) // 2)
        for label, value, color in readouts:
            if y >= column.bottom:
                break
            draw_readout(painter, column.x, y, label, value, column.width,
                         value_color=color)
            y += 1
