"""Clickable regions, and the events that reach them.

The dashboard is absolutely positioned, so hit-testing is a rectangle
containment check rather than anything that has to re-derive layout. What was
missing is a record of *what was drawn where*, which is all this is: a map
rebuilt each frame as things draw themselves, and consulted when a click
arrives.

Regions are registered during rendering, by whatever is drawing. A segment can
claim its own rectangle (a rail block, a chip, a pill), and so can a widget that
wants something finer -- a single row of a list, a marker on a plot. Nothing has
to know in advance which parts of the screen are interactive.

Later registrations win. Rendering runs outermost-first -- frame, then panel,
then widget contents -- so a widget's own regions naturally take precedence over
the panel chrome underneath them, matching what is visually on top.

This module knows nothing about terminals or escape sequences. It takes a cell
coordinate and returns what is there; decoding mouse reports is ``app``'s job.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Callable, List, Optional

from .geometry import Rect


class Button(Enum):
    LEFT = "left"
    MIDDLE = "middle"
    RIGHT = "right"
    WHEEL_UP = "wheel-up"
    WHEEL_DOWN = "wheel-down"
    OTHER = "other"


@dataclass(frozen=True)
class Click:
    """Where a click landed, in canvas cell coordinates, and how."""

    x: int
    y: int
    button: Button = Button.LEFT
    shift: bool = False
    ctrl: bool = False
    meta: bool = False

    @property
    def is_wheel(self) -> bool:
        return self.button in (Button.WHEEL_UP, Button.WHEEL_DOWN)


#: What a region does when clicked. Returning True means the frame should be
#: redrawn immediately rather than waiting for the next tick, which is what
#: makes a click feel like it did something.
Handler = Callable[[Click], bool]


@dataclass(frozen=True)
class Region:
    rect: Rect
    handler: Handler
    #: Shown by the region overlay, and useful when debugging a dead click.
    label: str = ""
    #: Regions that respond to the wheel as well as to a press.
    wants_wheel: bool = False


class HitMap:
    """Regions registered this frame, searched newest-first."""

    def __init__(self) -> None:
        self._regions: List[Region] = []

    def clear(self) -> None:
        """Called at the start of every frame. Regions do not outlive a render.

        Rebuilding rather than diffing is deliberate: a pane that moved, shrank
        or disappeared cannot leave a stale clickable rectangle behind, which is
        the failure mode that makes this kind of map untrustworthy.
        """
        self._regions.clear()

    def add(self, rect: Rect, handler: Handler, label: str = "",
            wants_wheel: bool = False) -> None:
        if rect and handler is not None:
            self._regions.append(Region(rect, handler, label, wants_wheel))

    def at(self, x: int, y: int) -> Optional[Region]:
        for region in reversed(self._regions):
            if region.rect.contains(x, y):
                return region
        return None

    def dispatch(self, click: Click) -> bool:
        """Deliver a click. Returns whether anything asked for a redraw."""
        region = self.at(click.x, click.y)
        if region is None:
            return False
        if click.is_wheel and not region.wants_wheel:
            return False
        return bool(region.handler(click))

    def __len__(self) -> int:
        return len(self._regions)

    def __iter__(self):
        return iter(self._regions)


def on_click(action: Callable[[], None], redraw: bool = True) -> Handler:
    """Adapt a plain no-argument callable into a :data:`Handler`.

    Most actions -- switch layout, change channel, refresh -- care about neither
    which button was used nor where exactly the click fell, and reading
    ``lambda click: (action(), True)[1]`` at every call site is worse than this.
    """
    def handler(_: Click) -> bool:
        action()
        return redraw
    return handler
