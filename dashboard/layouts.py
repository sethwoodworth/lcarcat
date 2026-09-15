"""Named arrangements of widgets.

A layout decides three things: which widgets exist, where their panels go, and
what those panels look like. Widgets know none of it, which is why the same Jira
pane appears as a tall column in one layout and a short strip in another without
being touched.

The outer frame is itself a :class:`~dashboard.segments.Panel`. There is no
separate "frame" concept -- the screen is a panel whose content area happens to
contain more panels, which is what keeps the elbow, rail and cap rules identical
at both levels.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Sequence

from .geometry import Rect
from .palette import (GOLD, LILAC, ORANGE, PERIWINKLE, SAGE, SKY, Color)
from .segments import Chip, ChipStyle, Painter, Panel, PanelStyle, RailBlock
from .widgets import (JiraWidget, MoonWidget, OrreryKeyWidget, OrreryWidget,
                      PullRequestWidget, SkyWidget, SolWidget, StardateWidget,
                      TelemetryWidget, Widget)

#: Chrome a panel needs beyond its content: two header rows, the elbow's fillet
#: row, the footer's fillet row, and the footer bar.
BRACKET_CHROME_ROWS = 5


@dataclass
class Placement:
    """One widget and the panel it is drawn inside."""

    widget: Widget
    rect: Rect
    style: PanelStyle = PanelStyle.BRACKET
    facing: str = "left"
    rail_width: int = 4
    color: Optional[Color] = None
    rail_blocks: Sequence[RailBlock] = field(default_factory=tuple)

    def draw(self, painter: Painter) -> None:
        chrome = self.widget.chrome()
        panel = Panel(
            rect=self.rect,
            title=chrome.title,
            color=self.color or chrome.color,
            style=self.style,
            facing=self.facing,
            rail_width=self.rail_width,
            chips=chrome.chips,
            rail_blocks=self.rail_blocks or chrome.rail_blocks,
        )
        content = panel.draw(painter)
        if content:
            self.widget.render(painter, content)


class Layout:
    """A named screen: which widgets exist, and where their panels go."""

    name = "layout"
    description = ""
    #: Color of the outer frame and the label on its rail.
    frame_color: Color = ORANGE
    frame_title = "LCARCAT"

    def __init__(self) -> None:
        self.widgets: List[Widget] = []

    # -- to override -------------------------------------------------------

    def place(self, content: Rect) -> List[Placement]:
        raise NotImplementedError

    def frame_rail_blocks(self) -> Sequence[RailBlock]:
        """Blocks stacked down the outer rail. Decorative, in the LCARS tradition."""
        return (
            RailBlock("SENSORS", PERIWINKLE, 2.0),
            RailBlock("COMMS", SKY, 1.4),
            RailBlock("NAV", GOLD, 1.8),
            RailBlock("OPS", LILAC, 1.2),
            RailBlock("LIB", SAGE, 2.4),
        )

    def frame_chips(self) -> Sequence[Chip]:
        return (Chip(self.name.upper(), style=ChipStyle.HOLE),)

    # -- shared ------------------------------------------------------------

    def frame_rail_width(self, screen: Rect) -> int:
        """A rail proportional to the screen, clamped to what reads as LCARS.

        Below about six columns the stacked block labels stop fitting and the rail
        reads as a stray line; above ten it eats content width for no gain.
        """
        return max(6, min(10, screen.width // 22))

    def draw_frame(self, painter: Painter, screen: Rect) -> Rect:
        panel = Panel(
            rect=screen,
            title=self.frame_title,
            color=self.frame_color,
            style=PanelStyle.BRACKET,
            rail_width=self.frame_rail_width(screen),
            header_rows=2,
            footer_rows=1,
            chips=tuple(self.frame_chips()),
            rail_blocks=self.frame_rail_blocks(),
            content_gap=2,
        )
        return panel.draw(painter)

    def all_widgets(self) -> List[Widget]:
        return list(self.widgets)


def _rail_for(rect: Rect) -> int:
    """Inner-panel rail width, scaled to the panel so narrow panes stay legible."""
    return max(2, min(5, rect.width // 14))


# --------------------------------------------------------------------------


class BridgeLayout(Layout):
    """The default: space across the top, work down the right, status below.

    Three quarters of the interior is sky. The two work panes share one column on
    the right, which is the side a right-handed reader's eye lands on last -- they
    are reference, not the thing you are looking at.
    """

    name = "bridge"
    description = "Orrery and sky with a work column on the right"

    def __init__(self) -> None:
        super().__init__()
        self.orrery = OrreryWidget()
        self.sky = SkyWidget()
        self.jira = JiraWidget()
        self.pull_requests = PullRequestWidget()
        self.stardate = StardateWidget()
        self.telemetry = TelemetryWidget(color=SKY)
        self.widgets = [self.orrery, self.sky, self.jira, self.pull_requests,
                        self.stardate, self.telemetry]

    def place(self, content: Rect) -> List[Placement]:
        space, work = content.split_horizontal(0.72, 0.28)

        upper, lower = space.split_vertical(0.62, 0.38)
        orrery_rect, sky_rect = upper.split_horizontal(0.56, 0.44)
        clock_rect, telemetry_rect = lower.split_horizontal(0.42, 0.58)

        jira_rect, pull_rect = work.split_vertical(0.55, 0.45)

        return [
            Placement(self.orrery, orrery_rect, rail_width=_rail_for(orrery_rect),
                      color=PERIWINKLE),
            Placement(self.sky, sky_rect, rail_width=_rail_for(sky_rect), color=SKY),
            Placement(self.stardate, clock_rect, rail_width=_rail_for(clock_rect),
                      color=ORANGE),
            Placement(self.telemetry, telemetry_rect,
                      rail_width=_rail_for(telemetry_rect), color=SAGE),
            Placement(self.jira, jira_rect, rail_width=_rail_for(jira_rect),
                      color=GOLD),
            Placement(self.pull_requests, pull_rect, rail_width=_rail_for(pull_rect),
                      color=LILAC),
        ]


class OperationsLayout(Layout):
    """Work only: the Jira queue and the pull request queue, nothing else.

    The exact complement of ``stellar-cartography``, which carries the sky and no
    work. This is the screen to open when the dashboard is the thing being read
    rather than glanced at, so every row goes to something actionable.

    Two full-height columns rather than a stack. Both panes are lists, and a list
    is limited by rows: side by side each gets the whole height of the terminal,
    where stacking would halve both. That is the difference between showing most
    of a sixty-item backlog and showing a third of it.
    """

    name = "operations"
    description = "Work only: the Jira queue beside the pull request queue"
    frame_color = GOLD

    def __init__(self) -> None:
        super().__init__()
        # The holodeck-panel arrangement: a long calm catalogue on the left, a
        # column of capped pills on the right. The list is where you read; the
        # pills are status lights you scan.
        self.jira = JiraWidget(title="ACTIVE WORK", columnar=True)
        self.pull_requests = PullRequestWidget(pill_style=True)
        self.widgets = [self.jira, self.pull_requests]

    def frame_rail_blocks(self) -> Sequence[RailBlock]:
        return (
            RailBlock("TASKS", GOLD, 2.4),
            RailBlock("REVIEW", LILAC, 2.0),
            RailBlock("QUEUE", SKY, 1.6),
        )

    def place(self, content: Rect) -> List[Placement]:
        # The catalogue takes the larger share: its rows carry three columns of
        # text, where a pill carries a reference and a word.
        jira_rect, pull_rect = content.split_horizontal(0.62, 0.38, gap=3)
        return [
            Placement(self.jira, jira_rect, rail_width=_rail_for(jira_rect),
                      color=GOLD),
            Placement(self.pull_requests, pull_rect, facing="right",
                      rail_width=_rail_for(pull_rect), color=LILAC),
        ]


class StellarCartographyLayout(Layout):
    """Nothing but the sky. No work panes at all.

    The orrery takes the centre at full height, which is what the plot wants: it
    is drawn into a square-ish pixel box, and a column running the whole height of
    a wide terminal is the closest a pane gets to square.

    Both side columns are full height too, so the readouts they carry are sized to
    fill them rather than leaving a tall empty box -- which is why the sky list
    here includes the minor planets. It reports exactly the bodies the orrery
    plots, so the two panes can be read against each other.
    """

    name = "stellar-cartography"
    description = "The sky alone: full-height orrery, sky readout, moon and clock"
    frame_color = PERIWINKLE

    def __init__(self) -> None:
        super().__init__()
        self.orrery = OrreryWidget(title="SOL SYSTEM")
        self.sky = SkyWidget(title="BODIES", include_minor_planets=True)
        self.moon = MoonWidget()
        self.stardate = StardateWidget()
        self.widgets = [self.orrery, self.sky, self.moon, self.stardate]

    def frame_rail_blocks(self) -> Sequence[RailBlock]:
        return (
            RailBlock("STELLAR", PERIWINKLE, 2.6),
            RailBlock("CARTO", SKY, 2.0),
            RailBlock("EPHEM", GOLD, 1.6),
            RailBlock("LUNA", LILAC, 1.4),
        )

    def place(self, content: Rect) -> List[Placement]:
        left, centre, right = content.split_horizontal(0.24, 0.48, 0.28)
        moon_rect, clock_rect = left.split_vertical(0.56, 0.44)

        return [
            Placement(self.moon, moon_rect, rail_width=_rail_for(moon_rect),
                      color=LILAC),
            Placement(self.stardate, clock_rect, rail_width=_rail_for(clock_rect),
                      color=ORANGE),
            Placement(self.orrery, centre, rail_width=_rail_for(centre),
                      color=PERIWINKLE),
            Placement(self.sky, right, rail_width=_rail_for(right), color=SKY),
        ]


class AstrometricsLayout(Layout):
    """Facing frames: a large orrery on the left, its readouts on the right.

    The arrangement the reference LCARS panels use most, and the reason ``Panel``
    grew a ``facing``. The orrery's rail and elbows sit on its *right* edge, the
    right-hand column's on their *left*, so the two sets of chrome face each other
    across a black channel down the middle of the screen.

    They face but never meet. A bar running into another bar would be the T
    junction ``docs/lcars-design.md`` rule 4 forbids; the gap between the columns
    is what keeps every bar terminating in its own cap or elbow.
    """

    name = "astrometrics"
    description = "Facing frames: large orrery left, key/moon/clock right"
    frame_color = PERIWINKLE

    def __init__(self) -> None:
        super().__init__()
        self.orrery = OrreryWidget(title="ASTROMETRICS")
        self.key = OrreryKeyWidget(title="KEY")
        self.moon = MoonWidget()
        # The sun replaces the clock here: this screen is about what is in the
        # sky, and a solar disc with its space weather says more than the time.
        self.sol = SolWidget()
        self.widgets = [self.orrery, self.key, self.moon, self.sol]

    def frame_rail_blocks(self) -> Sequence[RailBlock]:
        return (
            RailBlock("ASTRO", PERIWINKLE, 2.4),
            RailBlock("METRICS", SKY, 1.8),
            RailBlock("EPHEM", GOLD, 1.6),
            RailBlock("LUNA", LILAC, 1.4),
        )

    def place(self, content: Rect) -> List[Placement]:
        # A wider gap than the default: this is the channel the two sets of
        # chrome face across, and it has to read as deliberate space rather than
        # as the seam between two panels that nearly touch.
        orrery_rect, right = content.split_horizontal(0.60, 0.40, gap=3)
        # Heights follow what each pane actually holds rather than a tidy split.
        # The moon is a square picture flanked by readout columns, so past a
        # certain height it stops growing and just pads itself with empty rows --
        # which is what a half-column share gave it. The key is the opposite: it
        # is a list that was being truncated, losing the minor planets off the
        # bottom.
        # Each share is what the pane needs, not a tidy fraction: the moon and
        # the sun are square pictures flanked by readouts (about ten content rows
        # each) and the key is a two-column list of fifteen bodies (eight rows).
        moon_rect, lower = right.split_vertical(0.35, 0.65)
        key_rect, sol_rect = lower.split_vertical(0.48, 0.52)

        return [
            Placement(self.orrery, orrery_rect, facing="right",
                      rail_width=max(6, min(10, orrery_rect.width // 12)),
                      color=PERIWINKLE),
            Placement(self.key, key_rect, rail_width=_rail_for(key_rect),
                      color=SKY),
            Placement(self.moon, moon_rect, rail_width=_rail_for(moon_rect),
                      color=LILAC),
            Placement(self.sol, sol_rect, rail_width=_rail_for(sol_rect),
                      color=GOLD),
        ]


class ViewscreenLayout(Layout):
    """One enormous clock, and just enough else to be worth glancing at.

    For leaving on a screen across the room. The chronometer takes the upper
    two thirds at triple pixel width, which is the size that stays readable from
    further away than any of the other layouts survive. Everything that would
    make it a working dashboard is deliberately absent: the queue counts live in
    the panel headers, so a glance says whether anything changed without a list
    of ticket titles nobody is close enough to read.

    The negative space is the point, and it is left genuinely empty rather than
    filled -- decoration at this size competes with the one thing meant to carry
    across a room.
    """

    name = "viewscreen"
    description = "Ambient: an oversized clock with sky and queue counts"
    frame_color = PERIWINKLE

    def __init__(self) -> None:
        super().__init__()
        self.stardate = StardateWidget(pixel_width=3)
        self.sky = SkyWidget(visible_only=True)
        self.jira = JiraWidget(title="WORK QUEUE")
        self.pull_requests = PullRequestWidget(title="PULL REQUESTS")
        self.widgets = [self.stardate, self.sky, self.jira, self.pull_requests]

    def frame_rail_blocks(self) -> Sequence[RailBlock]:
        return (
            RailBlock("VIEW", PERIWINKLE, 3.0),
            RailBlock("SCAN", SKY, 2.0),
            RailBlock("IDLE", LILAC, 4.0),
        )

    def place(self, content: Rect) -> List[Placement]:
        upper, bottom = content.take_bottom(max(9, content.height // 3))
        clock_rect, sky_rect = upper.split_horizontal(0.68, 0.32)
        jira_rect, pull_rect = bottom.split_horizontal(0.5, 0.5)

        return [
            Placement(self.stardate, clock_rect, rail_width=_rail_for(clock_rect),
                      color=ORANGE),
            Placement(self.sky, sky_rect, rail_width=_rail_for(sky_rect), color=SKY),
            Placement(self.jira, jira_rect, rail_width=_rail_for(jira_rect),
                      style=PanelStyle.HEADER, color=GOLD),
            Placement(self.pull_requests, pull_rect, rail_width=_rail_for(pull_rect),
                      style=PanelStyle.HEADER, color=LILAC),
        ]


LAYOUTS: Dict[str, Callable[[], Layout]] = {
    BridgeLayout.name: BridgeLayout,
    OperationsLayout.name: OperationsLayout,
    StellarCartographyLayout.name: StellarCartographyLayout,
    AstrometricsLayout.name: AstrometricsLayout,
    ViewscreenLayout.name: ViewscreenLayout,
}

DEFAULT_LAYOUT = BridgeLayout.name


def build(name: str) -> Layout:
    try:
        return LAYOUTS[name]()
    except KeyError:
        raise KeyError("unknown layout %r; available: %s"
                       % (name, ", ".join(sorted(LAYOUTS))))


def names() -> List[str]:
    return sorted(LAYOUTS)


def descriptions() -> List[str]:
    """One aligned line per layout, sized to the longest name present."""
    width = max((len(name) for name in names()), default=0)
    return ["%-*s  %s" % (width, name, LAYOUTS[name].description)
            for name in names()]
