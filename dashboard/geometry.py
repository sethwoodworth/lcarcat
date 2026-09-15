"""Rectangles and terminal measurement.

Every dashboard widget is handed a :class:`Rect` and paints inside it. Rects are
value objects in *cell* coordinates with the origin at the top-left of the
screen, x growing right and y growing down -- the same convention the canvas and
kitty's own cell grid use.
"""
from __future__ import annotations

import os
import shutil
from dataclasses import dataclass
from typing import Iterator, List, Sequence, Tuple

#: Blank cells left between adjacent panes, and the reason it is a *default*
#: rather than something each layout passes: LCARS frames must never touch. Two
#: panels flush against each other read as one malformed frame -- the lower one's
#: header bar sits directly on the upper one's footer bar, and the eye joins them.
#: A layout has to deliberately pass ``gap=0`` to opt out.
DEFAULT_GAP = 1


@dataclass(frozen=True)
class Rect:
    x: int
    y: int
    width: int
    height: int

    @property
    def right(self) -> int:
        """One past the last occupied column, so ``range(r.x, r.right)`` is the row."""
        return self.x + self.width

    @property
    def bottom(self) -> int:
        return self.y + self.height

    @property
    def area(self) -> int:
        return max(0, self.width) * max(0, self.height)

    def __bool__(self) -> bool:
        return self.width > 0 and self.height > 0

    def contains(self, x: int, y: int) -> bool:
        return self.x <= x < self.right and self.y <= y < self.bottom

    def inset(self, left: int = 0, top: int = 0, right: int = 0, bottom: int = 0) -> "Rect":
        return Rect(
            self.x + left,
            self.y + top,
            max(0, self.width - left - right),
            max(0, self.height - top - bottom),
        )

    def pad(self, amount: int) -> "Rect":
        return self.inset(amount, amount, amount, amount)

    def rows(self) -> Iterator[int]:
        return iter(range(self.y, self.bottom))

    def columns(self) -> Iterator[int]:
        return iter(range(self.x, self.right))

    def split_horizontal(self, *weights: float, gap: int = DEFAULT_GAP) -> List["Rect"]:
        """Divide into side-by-side columns sized by ``weights``, separated by ``gap``.

        Integer weights >= 1 that sum to no more than the available width are taken
        as exact column counts; anything else is treated as proportional. Remainder
        columns go to the widest slices first, so a 3-way split of an odd width
        never produces a zero-width pane.
        """
        return _divide(self.width, weights, gap, lambda offset, size: Rect(
            self.x + offset, self.y, size, self.height))

    def split_vertical(self, *weights: float, gap: int = DEFAULT_GAP) -> List["Rect"]:
        """Divide into stacked rows sized by ``weights``, separated by ``gap``."""
        return _divide(self.height, weights, gap, lambda offset, size: Rect(
            self.x, self.y + offset, self.width, size))

    def take_top(self, rows: int, gap: int = DEFAULT_GAP) -> Tuple["Rect", "Rect"]:
        """``(top, remainder)`` -- the common "carve a header off" move."""
        rows = max(0, min(rows, self.height))
        gap = min(gap, max(0, self.height - rows))
        return (Rect(self.x, self.y, self.width, rows),
                Rect(self.x, self.y + rows + gap, self.width,
                     self.height - rows - gap))

    def take_bottom(self, rows: int, gap: int = DEFAULT_GAP) -> Tuple["Rect", "Rect"]:
        """``(remainder, bottom)``, ordered top-to-bottom so unpacking reads in order."""
        rows = max(0, min(rows, self.height))
        gap = min(gap, max(0, self.height - rows))
        return (Rect(self.x, self.y, self.width, self.height - rows - gap),
                Rect(self.x, self.bottom - rows, self.width, rows))


def _divide(total: int, weights: Sequence[float], gap: int, build) -> List[Rect]:
    if not weights:
        return []
    available = total - gap * (len(weights) - 1)
    if available <= 0:
        return [build(0, 0) for _ in weights]

    # Weights are ALWAYS proportional. An earlier version treated whole numbers as
    # exact cell counts when they fitted, which made split_vertical(1, 1) -- the
    # obvious way to write "two equal halves" -- return one row and the remainder
    # instead. A split that changes meaning based on whether its weights happen to
    # be integers is a trap; callers wanting exact sizes use take_top/take_bottom.
    share = sum(weights)
    sizes = [int(available * weight / share) for weight in weights]
    # Distribute the rounding remainder to the largest slices, so a split of three
    # across a width of 100 gives 34/33/33 rather than 33/33/33 and a dropped column.
    leftover = available - sum(sizes)
    for index in sorted(range(len(sizes)), key=lambda i: -weights[i])[:leftover]:
        sizes[index] += 1

    rects, offset = [], 0
    for size in sizes:
        rects.append(build(offset, size))
        offset += size + gap
    return rects


def terminal_size(default: Tuple[int, int] = (120, 40)) -> Tuple[int, int]:
    """``(columns, rows)`` of the controlling terminal.

    ``COLUMNS``/``LINES`` win when set, which is how the screenshot harness pins a
    dashboard to a known geometry without resizing a real window.
    """
    env_columns, env_rows = os.environ.get("COLUMNS"), os.environ.get("LINES")
    if env_columns and env_rows:
        try:
            return (int(env_columns), int(env_rows))
        except ValueError:
            pass
    size = shutil.get_terminal_size(fallback=default)
    return (size.columns, size.lines)
