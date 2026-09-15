"""Pull requests: the ones I opened, and the ones waiting on my review.

Both queues share a pane. The review queue goes on top when it is non-empty --
somebody else is blocked on those, which makes them the more urgent half of the
same question.
"""
from __future__ import annotations

from typing import List, Optional

from ..canvas import truncate
from ..geometry import Rect
from ..palette import (DIM_VIOLET, GOLD, ORANGE, PERIWINKLE, RED_ALERT, SAGE,
                       SKY, TEXT, Color)
from ..segments import Chip, ChipStyle, Painter, draw_chip, draw_pill_stack
from ..sources import github
from .base import Widget, WidgetChrome

#: Chip color per pull-request state. Green means it can land, red means somebody
#: has to do something, orange means it is moving, dim means it is not.
STATE_COLORS = {
    "APPROVED": SAGE,
    "CHANGES": RED_ALERT,
    "FAILING": RED_ALERT,
    "BUILDING": GOLD,
    "REVIEW": ORANGE,
    "DRAFT": DIM_VIOLET,
}


class PullRequestWidget(Widget):
    """The two pull-request queues, with review requests first."""

    refresh_interval = 180.0
    refresh_in_background = True

    def __init__(
        self,
        title: str = "PULL REQUESTS",
        color: Color = PERIWINKLE,
        allow_live: bool = True,
        show_mine: bool = True,
        show_reviews: bool = True,
        pill_style: bool = False,
    ) -> None:
        super().__init__(title=title, color=color)
        self.allow_live = allow_live
        self.show_mine = show_mine
        self.show_reviews = show_reviews
        #: Draw each pull request as a big capped pill rather than a chip row.
        self.pill_style = pill_style
        self.queues: Optional[github.PullRequestQueues] = None

    def refresh(self) -> None:
        self.queues = github.load(allow_live=self.allow_live)

    def chrome(self) -> WidgetChrome:
        chips: List[Chip] = []
        queues = self.queues
        if queues is not None:
            if self.show_reviews and queues.awaiting_my_review:
                chips.append(Chip("%02d-TO-REVIEW" % len(queues.awaiting_my_review),
                                  ORANGE, ChipStyle.COLOR))
            if self.show_mine and queues.mine:
                chips.append(Chip("%02d-MINE" % len(queues.mine), SKY, ChipStyle.COLOR))
            if not queues.live:
                label = ("CACHED-%s" % queues.cached.age_label()
                         if queues.cached else "NO-SOURCE")
                chips.insert(0, Chip(label, RED_ALERT if not queues.cached else SKY,
                                     ChipStyle.COLOR))
        return WidgetChrome(title=self.title, color=self.color, chips=tuple(chips))

    def render(self, painter: Painter, rect: Rect) -> None:
        if not rect:
            return
        canvas = painter.canvas
        queues = self.queues
        if queues is None:
            canvas.text(rect.x, rect.y, "LOADING", foreground=DIM_VIOLET)
            return
        if not queues.total:
            canvas.text(rect.x, rect.y, "PULL REQUEST QUEUE CLEAR", foreground=SAGE)
            return

        if self.pill_style:
            self.render_pills(painter, rect, queues)
            return

        sections = []
        if self.show_reviews and queues.awaiting_my_review:
            sections.append(("AWAITING MY REVIEW", queues.awaiting_my_review))
        if self.show_mine and queues.mine:
            sections.append(("MINE", queues.mine))

        # Give each section a share of the rows in proportion to what it holds, so a
        # long review queue does not push every one of my own pull requests off screen.
        available = rect.height - len(sections)
        if available <= 0:
            sections = sections[:1]
            available = max(0, rect.height - 1)
        total_items = sum(len(items) for _, items in sections) or 1
        quotas = [max(1, int(available * len(items) / total_items))
                  for _, items in sections]
        while sum(quotas) > available and max(quotas) > 1:
            quotas[quotas.index(max(quotas))] -= 1

        y = rect.y
        for (heading, items), quota in zip(sections, quotas):
            if y >= rect.bottom:
                break
            shown = items[:quota]
            canvas.text(rect.x, y, heading, foreground=DIM_VIOLET)
            if len(items) > len(shown):
                canvas.text_right(rect.right, y, "+%d MORE" % (len(items) - len(shown)),
                                  foreground=DIM_VIOLET)
            y += 1
            reference_width = max(len(p.reference) for p in shown) + 2
            for pull_request in shown:
                if y >= rect.bottom:
                    break
                self._draw_row(painter, rect, y, pull_request, reference_width)
                y += 1

    def render_pills(self, painter: Painter, rect: Rect,
                     queues: github.PullRequestQueues) -> None:
        """One big pill per pull request, stacked with a blank row between.

        The reference LCARS panels carry their short readouts as capped pills in a
        column, which is what a pull request queue is: a short identifier and one
        piece of state. The title does not fit and is deliberately dropped -- a
        pill is a status light, and the list beside it is where you read.
        """
        ordered = ([("REVIEW", p) for p in queues.awaiting_my_review]
                   + [("MINE", p) for p in queues.mine])
        pills = []
        for _, pull_request in ordered:
            state = pull_request.state_label()
            pills.append(("%s  %s" % (pull_request.reference, state),
                          STATE_COLORS.get(state, PERIWINKLE)))
        draw_pill_stack(painter, rect, pills, align="left")

    def _draw_row(self, painter: Painter, rect: Rect, y: int,
                  pull_request: github.PullRequest, reference_width: int) -> None:
        state = pull_request.state_label()
        chip = Chip(pull_request.reference.ljust(reference_width - 2),
                    STATE_COLORS.get(state, PERIWINKLE), ChipStyle.COLOR)
        after = draw_chip(painter, rect.x, y, 1, chip, self.color)

        state_width = len(state) + 1 if rect.width > reference_width + 26 else 0
        title_x = after + 1
        title_room = rect.right - title_x - state_width
        if title_room > 0:
            painter.canvas.text(title_x, y, truncate(pull_request.title, title_room),
                                foreground=TEXT if state != "DRAFT" else PERIWINKLE)
        if state_width:
            painter.canvas.text_right(rect.right, y, state,
                                      foreground=STATE_COLORS.get(state, PERIWINKLE))
