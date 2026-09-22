"""LCARS tab bar for kitty.

Loaded by ``tab_bar_style custom``, which hands this module every cell of the tab
strip instead of filling in a title template. The templates could color a pill and
round its ends; they could not right-align a status readout, spell a title in
LCARS form, or put a rail stub at the left edge, because a template only ever
describes one tab.

The strip is one row, so it follows the same rules as any other one-row LCARS bar:
flat runs are colored cells, the rounded ends are the powerline half-circle glyphs
(the kitty graphics protocol is not available on this strip), pills are separated
by explicit black columns, and there are at least two bar-color columns before any
cap.

Layout, left to right::

    [rail stub] [ 01-ZSH ][ 02-NVIM ]  ...  [ STARDATE ][ 18:42 ]

The rail stub is a short orange run standing in for the left rail of the frame
below, so the tab bar reads as the top edge of the LCARS chrome rather than as a
separate widget sitting above it.

Deployed to ``~/.config/kitty/tab_bar.py`` by ``deploy.sh``.
"""
from __future__ import annotations

import datetime

from kitty.fast_data_types import Screen
from kitty.tab_bar import DrawData, ExtraData, TabBarData, as_rgb

# --- palette (docs/palette.md) ---------------------------------------------
CANVAS = 0x000000
TEXT = 0xFFFFC6
ORANGE = 0xFF9900        # active tab, and the rail stub
PERIWINKLE = 0x9999FF    # inactive tabs
GOLD = 0xFFCC66          # stardate
SKY = 0x6699CC           # clock
DIM_VIOLET = 0x666699

# Powerline half-circles. The left cap is the flat-right/round-left glyph and the
# right cap its mirror, so a pill reads as a bar terminated at both ends.
LEFT_CAP = ""
RIGHT_CAP = ""

# Columns of the rail stub at the far left. Two is enough to read as structure and
# narrow enough that it never competes with the first tab.
RAIL_COLUMNS = 2

#: Same origin as the dashboard's chronometer -- a thousand units per year,
#: advancing with the fraction of the year elapsed, measured from 2000.
STARDATE_EPOCH_YEAR = 2000


def _stardate(now: datetime.datetime) -> float:
    start = datetime.datetime(now.year, 1, 1)
    end = datetime.datetime(now.year + 1, 1, 1)
    elapsed = (now - start).total_seconds() / (end - start).total_seconds()
    return 1000 * (now.year - STARDATE_EPOCH_YEAR) + 1000 * elapsed


def _lcars_title(title: str, index: int) -> str:
    """A tab title in LCARS chip form: ``NN-NAME``, uppercase, spelled out.

    kitty puts a lot into a default title -- a path, a running command, shell
    decoration. Only the last path segment survives here, because a chip is a
    label rather than a location, and a chip wide enough for a full path would
    leave no room for the tabs beside it.
    """
    cleaned = (title or "").strip()
    for separator in ("/", "\\"):
        if separator in cleaned:
            cleaned = cleaned.rsplit(separator, 1)[-1] or cleaned
    cleaned = cleaned.replace("~", "").strip() or "SHELL"
    return "%02d-%s" % (index, cleaned.upper())


def _write(screen: Screen, text: str, foreground: int, background: int) -> None:
    screen.cursor.fg = as_rgb(foreground)
    screen.cursor.bg = as_rgb(background)
    screen.draw(text)


def _black(screen: Screen, count: int = 1) -> None:
    screen.cursor.fg = as_rgb(CANVAS)
    screen.cursor.bg = as_rgb(CANVAS)
    screen.draw(" " * count)


def _draw_pill(screen: Screen, text: str, color: int,
               label_color: int = CANVAS) -> None:
    """A capped, colored segment. The caps are drawn in the pill's color on black.

    The cap glyphs are foreground-on-black rather than a colored cell: a cap drawn
    over a colored background fills its own rounded notch and squares off the
    corner, which is the reason the existing templates set every tab background to
    black.
    """
    _write(screen, LEFT_CAP, color, CANVAS)
    _write(screen, text, label_color, color)
    _write(screen, RIGHT_CAP, color, CANVAS)


def _draw_rail_stub(screen: Screen) -> None:
    _write(screen, " " * RAIL_COLUMNS, CANVAS, ORANGE)
    _black(screen)


def _status_segments():
    now = datetime.datetime.now()
    return (
        ("%.1f" % _stardate(now), GOLD),
        (now.strftime("%H:%M"), SKY),
    )


def _status_width(segments) -> int:
    # Each pill is its text plus two cap columns, and each is preceded by a black
    # separator column.
    return sum(len(text) + 3 for text, _ in segments)


def _draw_status(screen: Screen) -> None:
    """Right-align the status pills against the end of the strip."""
    segments = _status_segments()
    width = _status_width(segments)
    start = screen.columns - width
    if start <= screen.cursor.x:
        return  # the tabs need the room more than the clock does
    _black(screen, start - screen.cursor.x)
    for text, color in segments:
        _draw_pill(screen, text, color)
        _black(screen)


def draw_tab(
    draw_data: DrawData,
    screen: Screen,
    tab: TabBarData,
    before: int,
    max_title_length: int,
    index: int,
    is_last: bool,
    extra_data: ExtraData,
) -> int:
    """Draw one tab. kitty calls this once per tab, left to right.

    kitty calls it twice per redraw. The first pass (``extra_data.for_layout``)
    measures each tab from column 0 with an unlimited budget; kitty then shares
    the strip out as ``max_title_length`` per tab, gives any spare width to the
    active tab, and during the real pass stops drawing as soon as the next tab's
    budget no longer fits. So a tab must stay within its budget, and the
    measuring pass must not include the status readout: counted there, the last
    tab measures as the whole strip, and once it is active the inflated budget
    makes kitty stop before drawing it at all.
    """
    if index == 1:
        _draw_rail_stub(screen)
    # The rail stub is chrome, not part of the first tab: measured against its
    # budget, it would squeeze that one title to a single character on a narrow
    # strip while every other tab keeps its NN- prefix.
    pill_start = screen.cursor.x

    color = ORANGE if tab.is_active else PERIWINKLE
    title = _lcars_title(tab.title, index)

    # Leave room for this tab's own caps and the separator after it, within both
    # kitty's budget for the tab and whatever the status readout will want on
    # the right.
    free_columns = screen.columns - screen.cursor.x
    if is_last and not extra_data.for_layout:
        free_columns -= _status_width(_status_segments())
    room = min(max_title_length - (screen.cursor.x - pill_start), free_columns) - 3
    if room < 4:
        title = title[:max(1, room)]
    elif len(title) > room:
        title = title[:room - 1] + "…"

    _draw_pill(screen, title, color)
    _black(screen)

    if is_last and not extra_data.for_layout:
        _draw_status(screen)

    return screen.cursor.x
