"""The widget protocol.

A widget renders into a :class:`Rect` it is handed and knows nothing about its
neighbours, the layout that placed it, or the chrome around it. Everything that
varies between dashboards -- which panes exist, how big they are, what color
their chrome is -- lives in a layout, so a widget can be moved or resized without
being edited.

Widgets are also free to be slow. ``refresh`` is where a widget talks to a data
source; ``render`` is expected to be pure drawing. The render loop calls
``refresh`` on its own schedule, so a slow Jira query cannot stall the clock.
"""
from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field
from typing import List, Optional, Sequence

from ..geometry import Rect
from ..palette import Color, PERIWINKLE
from ..segments import Chip, Painter, RailBlock


@dataclass
class WidgetChrome:
    """What a widget wants its panel to look like, if a layout gives it one.

    A layout is free to ignore all of it -- these are the widget's preferences,
    not its requirements, which is what keeps a widget usable inside any panel
    style.
    """

    title: str = ""
    color: Color = PERIWINKLE
    chips: Sequence[Chip] = field(default_factory=tuple)
    rail_blocks: Sequence[RailBlock] = field(default_factory=tuple)


class Widget:
    """Base class. Subclasses override ``render``, and usually ``refresh``."""

    #: Seconds between ``refresh`` calls. ``None`` means refresh once at startup.
    refresh_interval: Optional[float] = None

    #: Run ``refresh`` on a worker thread instead of inline. Set on any widget
    #: whose refresh talks to the network or spawns a process: the render loop
    #: calls ``refresh_if_due`` between frames, so a multi-second fetch on that
    #: thread freezes the whole dashboard, clock included. A background refresh
    #: leaves the previous data on screen until the new data lands.
    refresh_in_background: bool = False

    def __init__(self, title: str = "", color: Color = PERIWINKLE) -> None:
        self.title = title
        self.color = color
        self._last_refresh: float = 0.0
        self._error: Optional[str] = None
        self._refreshing = False
        self._refresh_lock = threading.Lock()

    # -- data -------------------------------------------------------------

    def refresh(self) -> None:
        """Fetch whatever this widget displays. Default: nothing to fetch."""

    def refresh_if_due(self, now: Optional[float] = None) -> bool:
        """Refresh when the interval has elapsed. Returns whether it ran.

        A failing refresh is recorded on the widget rather than raised: one
        unreachable data source should mark its own pane stale, not take down a
        screen of panes that are all fine.
        """
        now = time.time() if now is None else now
        if self._last_refresh and self.refresh_interval is None:
            return False
        if self._last_refresh and now - self._last_refresh < (self.refresh_interval or 0):
            return False

        if self.refresh_in_background:
            with self._refresh_lock:
                if self._refreshing:
                    # A previous fetch is still running -- slower than the
                    # interval. Let it finish rather than piling another on top.
                    return False
                self._refreshing = True
            self._last_refresh = now
            worker = threading.Thread(target=self._run_refresh, daemon=True,
                                      name="refresh-%s" % (self.title or "widget"))
            worker.start()
            return True

        self._last_refresh = now
        self._run_refresh()
        return True

    def _run_refresh(self) -> None:
        try:
            self.refresh()
            self._error = None
        except Exception as failure:  # noqa: BLE001 - a pane must not kill the frame
            self._error = str(failure) or failure.__class__.__name__
        finally:
            with self._refresh_lock:
                self._refreshing = False

    def wait_for_refresh(self, timeout: float = 5.0) -> None:
        """Block until a background refresh settles. For a one-shot render.

        ``--once`` and the screenshot captures draw a single frame and stop, so
        they need the data to have arrived; the redraw loop does not, because the
        next frame will show it.
        """
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self._refresh_lock:
                if not self._refreshing:
                    return
            time.sleep(0.05)

    @property
    def error(self) -> Optional[str]:
        return self._error

    # -- drawing ----------------------------------------------------------

    def chrome(self) -> WidgetChrome:
        """Panel appearance this widget would like. Layouts may override it."""
        return WidgetChrome(title=self.title, color=self.color)

    def render(self, painter: Painter, rect: Rect) -> None:
        """Draw into ``rect``. Must not write outside it."""
        raise NotImplementedError

    # -- helpers for subclasses -------------------------------------------

    def status_chips(self) -> List[Chip]:
        """Chips describing this widget's data state, for its panel header."""
        from ..palette import RED_ALERT
        from ..segments import ChipStyle

        if self._error:
            return [Chip("OFFLINE", RED_ALERT, ChipStyle.COLOR)]
        return []
