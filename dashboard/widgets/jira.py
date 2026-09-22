"""Assigned Jira work items.

One row per item: a key chip colored by how the item is moving, the summary, and
the status. Sorting puts in-flight and blocked work above the backlog, because a
pane that only fits a dozen rows should spend them on what is actually live.
"""
from __future__ import annotations

from typing import List, Optional

from ..canvas import truncate
from ..geometry import Rect
from ..palette import (CANVAS, DIM_VIOLET, GOLD, LILAC, ORANGE, PERIWINKLE,
                       RED_ALERT, SAGE, SKY, TEXT, Color)
from ..segments import Chip, ChipStyle, Painter, draw_chip
from ..sources import jira
from .base import Widget, WidgetChrome


def status_color(item: jira.WorkItem) -> Color:
    """The color a work item's key chip takes.

    Blocked reads as an alert, in-flight as the active accent, an epic as its own
    color because an epic is a container rather than a task, and everything else
    as the structural periwinkle that means "on the list, not moving".
    """
    if item.is_blocked:
        return RED_ALERT
    if item.is_active:
        return ORANGE
    if item.issue_type.lower() == "epic":
        return LILAC
    if item.priority_rank() <= 1:
        return GOLD
    return PERIWINKLE


class JiraWidget(Widget):
    """Work items from the Jira source, ranked and truncated to the pane."""

    refresh_interval = 300.0
    refresh_in_background = True

    def __init__(
        self,
        jql: str = jira.DEFAULT_JQL,
        title: str = "WORK ITEMS",
        color: Color = PERIWINKLE,
        allow_live: bool = True,
        show_status: bool = True,
        columnar: bool = False,
    ) -> None:
        super().__init__(title=title, color=color)
        self.jql = jql
        self.allow_live = allow_live
        self.show_status = show_status
        #: Draw as three aligned columns instead of a column of key chips.
        self.columnar = columnar
        self.queue: Optional[jira.WorkItemQueue] = None

    def refresh(self) -> None:
        self.queue = jira.load(jql=self.jql, allow_live=self.allow_live)

    def chrome(self) -> WidgetChrome:
        chips: List[Chip] = []
        queue = self.queue
        if queue is not None:
            active = len(queue.active)
            if active:
                chips.append(Chip("%02d-ACTIVE" % active, ORANGE, ChipStyle.COLOR))
            blocked = len(queue.blocked)
            if blocked:
                chips.append(Chip("%02d-BLOCKED" % blocked, RED_ALERT, ChipStyle.COLOR))
            chips.append(Chip("%02d" % len(queue.items), style=ChipStyle.COLOR))
            if not queue.live and queue.cached is not None:
                chips.insert(0, Chip("CACHED-%s" % queue.cached.age_label(),
                                     SKY, ChipStyle.COLOR))
            elif not queue.live:
                chips.insert(0, Chip("NO-SOURCE", RED_ALERT, ChipStyle.COLOR))
        return WidgetChrome(title=self.title, color=self.color, chips=tuple(chips))

    def render_columnar(self, painter: Painter, rect: Rect,
                        items: List[jira.WorkItem]) -> None:
        """The holodeck-panel list style: a code column, a title, a description.

        The reference LCARS directory screens put a bare catalogue number in one
        colour, the entry's name in another, and its description in body text --
        no chips, no boxes, just three aligned columns carrying three kinds of
        information. It reads much calmer than a column of coloured tags when the
        list is long, which is what an eighty-row backlog is.
        """
        canvas = painter.canvas
        key_width = max(len(item.key) for item in items) + 2
        status_width = min(16, max(len(i.status) for i in items) + 2)
        summary_x = rect.x + key_width
        summary_width = rect.right - summary_x - status_width

        for row, item in enumerate(items):
            y = rect.y + row
            if y >= rect.bottom:
                break
            canvas.text(rect.x, y, item.key, foreground=status_color(item))
            if summary_width > 0:
                canvas.text(summary_x, y, truncate(item.summary.upper(),
                                                   summary_width),
                            foreground=TEXT if item.is_active else PERIWINKLE)
            canvas.text_right(rect.right, y, item.status.upper(),
                              foreground=_status_text_color(item))

    def render(self, painter: Painter, rect: Rect) -> None:
        if not rect:
            return
        canvas = painter.canvas
        queue = self.queue
        if queue is None or not queue.items:
            message = "NO WORK ITEMS" if queue is not None else "LOADING"
            canvas.text(rect.x, rect.y, message, foreground=DIM_VIOLET)
            if queue is not None and not queue.live and queue.cached is None:
                canvas.text(rect.x, rect.y + 1,
                            "run: acli jira auth login", foreground=DIM_VIOLET)
            return

        # Key chips are set to one width so the summaries start on a common column;
        # a ragged left edge on a list of tickets reads as noise.
        items = queue.ranked()[: rect.height]
        if self.columnar:
            self.render_columnar(painter, rect, items)
            return
        key_width = max(len(item.key) for item in items) + 2

        status_width = 0
        if self.show_status and rect.width > key_width + 30:
            status_width = min(14, max(len(_status_label(i)) for i in items) + 1)

        for row, item in enumerate(items):
            y = rect.y + row
            chip = Chip(item.key.ljust(key_width - 2), status_color(item),
                        ChipStyle.COLOR)
            after = draw_chip(painter, rect.x, y, 1, chip, self.color)

            summary_x = after + 1
            summary_room = rect.right - summary_x - status_width
            if summary_room > 0:
                canvas.text(summary_x, y, truncate(item.summary, summary_room),
                            foreground=TEXT if item.is_active else PERIWINKLE)
            if status_width:
                canvas.text_right(rect.right, y, _status_label(item),
                                  foreground=_status_text_color(item))


def _status_label(item: jira.WorkItem) -> str:
    return item.status.upper()


def _status_text_color(item: jira.WorkItem) -> Color:
    if item.is_blocked:
        return RED_ALERT
    if item.is_active:
        return SAGE
    return DIM_VIOLET
