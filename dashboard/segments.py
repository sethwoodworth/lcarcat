"""Reusable LCARS segments.

Everything a widget needs to draw LCARS chrome, and nothing about what the
chrome contains. A segment takes a :class:`Painter`, a position, and its own
parameters; it never consults a widget, a layout, or a data source. That is what
makes the same elbow serve a Jira pane, an orrery, and the outer frame.

The vocabulary follows ``docs/lcars-design.md``:

``bar``     a horizontal accent band, two rows tall by convention
``elbow``   the rounded corner where a bar turns into a stem -- an image
``stem``    the vertical drop below an elbow; also called a rail when wide
``cap``     a half-round bar terminator -- an image
``chip``    a labeled segment sitting in a bar
``notch``   a black inset holding accent-colored text
``pill``    a segment capped on both ends

The design laws these functions enforce so callers cannot break them: bars meet
stems only through two-sided elbows (never a T or a + junction), caps appear only
where a bar terminates, and at least two bar-color columns precede every cap.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import List, Optional, Sequence, Tuple

from .assets import Asset, AssetLibrary
from .canvas import Canvas, text_width, truncate
from .geometry import Rect
from .images import ImageTransmitter
from .interaction import Click, Handler, HitMap, on_click
from .palette import CANVAS, TEXT, Color

# A cap needs clear air before it or it reads as a blob stuck to the last chip.
PRE_CAP_COLUMNS = 2
# Colored chips are separated from their neighbours by explicit black columns.
CHIP_GAP = 1


class Painter:
    """Canvas, asset library and image transmitter bundled into one handle.

    Segments need all three -- cells to write, PNGs to generate, ids to reference
    them by -- and passing one object keeps their signatures about geometry.
    """

    def __init__(
        self,
        canvas: Canvas,
        assets: AssetLibrary,
        images: ImageTransmitter,
        hits: Optional[HitMap] = None,
    ) -> None:
        self.canvas = canvas
        self.assets = assets
        self.images = images
        #: Clickable regions claimed during this frame. Anything that draws may
        #: register one; nothing is required to.
        self.hits = hits if hits is not None else HitMap()
        self._transmissions: List[str] = []

    def claim(self, rect: Rect, handler: Optional[Handler], label: str = "",
              wants_wheel: bool = False) -> None:
        """Mark a rectangle as interactive. A ``None`` handler claims nothing."""
        if handler is not None:
            self.hits.add(rect, handler, label, wants_wheel)

    def register(self, asset: Asset) -> int:
        """Queue ``asset`` for transmission and return the id placeholders will use."""
        escape = self.images.transmission(asset)
        if escape:
            self._transmissions.append(escape)
        return self.images.image_id(asset)

    def queue_transmission(self, escape: str) -> None:
        """Queue an image escape a widget produced itself (see dashboard.plots).

        Segments register cached assets through :meth:`register`; a widget drawing
        its own plot has already built the escape and only needs it emitted before
        the cells.
        """
        if escape:
            self._transmissions.append(escape)

    def transmissions(self) -> str:
        """Every image escape queued this render, to write before the cells."""
        queued = "".join(self._transmissions)
        self._transmissions.clear()
        return queued


# --------------------------------------------------------------------------
# chips
# --------------------------------------------------------------------------


class ChipStyle(Enum):
    """How a chip sits in its bar.

    ``COLOR``  a solid segment in a different accent, dark label (Style B)
    ``HOLE``   no fill change, label only -- ambient context that should read but
               not assert (goes rightmost)
    ``NOTCH``  a black inset holding bar-colored text (Style A)
    """

    COLOR = "color"
    HOLE = "hole"
    NOTCH = "notch"


@dataclass(frozen=True)
class Chip:
    label: str
    color: Optional[Color] = None
    style: ChipStyle = ChipStyle.COLOR
    label_color: Optional[Color] = None
    padding: int = 1
    #: Makes the chip clickable wherever it is drawn -- in a bar's header, in a
    #: row of a list, anywhere draw_chip or draw_chips places it.
    action: Optional[Handler] = None

    @property
    def width(self) -> int:
        return text_width(self.label) + 2 * self.padding


def chip_colors(chip: Chip, bar_color: Color) -> Tuple[Color, Color]:
    """``(fill, label)`` for a chip sitting in a bar of ``bar_color``.

    A hole chip takes the bar's own color so nothing changes but the text; a notch
    cuts to black and writes in the bar's color; a color chip fills with its own
    accent and writes in black.
    """
    if chip.style is ChipStyle.HOLE:
        return (bar_color, chip.label_color or CANVAS)
    if chip.style is ChipStyle.NOTCH:
        return (CANVAS, chip.label_color or bar_color)
    return (chip.color or bar_color, chip.label_color or CANVAS)


def draw_chip(
    painter: Painter,
    x: int,
    y: int,
    rows: int,
    chip: Chip,
    bar_color: Color,
) -> int:
    """Draw one chip with its left edge at ``x``. Returns the column after it.

    The left-anchored counterpart to :func:`draw_chips`. Bars right-align their
    chips as a group, but a list of rows inside a panel wants each row's chip to
    start at the same column, so it places them one at a time.
    """
    fill, label_color = chip_colors(chip, bar_color)
    for row in range(rows):
        painter.canvas.horizontal_run(x, y + row, chip.width, fill)
    painter.canvas.text(x + chip.padding, y + rows - 1, chip.label,
                        foreground=label_color)
    painter.claim(Rect(x, y, chip.width, rows), chip.action, chip.label)
    return x + chip.width


def draw_chips(
    painter: Painter,
    right_edge: int,
    y: int,
    rows: int,
    chips: Sequence[Chip],
    bar_color: Color,
    left_limit: Optional[int] = None,
) -> int:
    """Lay chips out right-to-left ending at ``right_edge`` (exclusive).

    Returns the leftmost column consumed, so the caller knows where the bar's plain
    fill has to stop. Chips that would cross ``left_limit`` are dropped whole rather
    than clipped -- half a label in a colored box reads as a rendering bug, while a
    missing chip reads as a narrow window.

    Labels sit on the bar's bottom row, matching the prompt's convention, and a
    colored chip spans the bar's full height.
    """
    canvas = painter.canvas
    label_row = y + rows - 1
    column = right_edge

    for index, chip in enumerate(chips):
        width = chip.width
        gap_before = 0 if index == 0 else CHIP_GAP
        # A hole chip is separated from the colored chip on its left by a black
        # column and a bar-color column; only the black one is drawn explicitly.
        if index > 0 and chips[index - 1].style is ChipStyle.HOLE:
            gap_before = CHIP_GAP + 1

        start = column - width - gap_before
        if left_limit is not None and start < left_limit:
            break

        if gap_before:
            canvas.horizontal_run(column - gap_before, y, gap_before, CANVAS)
            for row in range(1, rows):
                canvas.horizontal_run(column - gap_before, y + row, gap_before, CANVAS)

        body_start = column - width - gap_before
        fill, label_color = chip_colors(chip, bar_color)

        for row in range(rows):
            canvas.horizontal_run(body_start, y + row, width, fill)
        canvas.text(body_start + chip.padding, label_row, chip.label,
                    foreground=label_color)
        painter.claim(Rect(body_start, y, width, rows), chip.action, chip.label)

        column = body_start

    return column


# --------------------------------------------------------------------------
# bars, elbows, caps
# --------------------------------------------------------------------------


class End(Enum):
    """What terminates one end of a bar.

    ``CAP``    a half-round terminator -- the bar stops here
    ``ELBOW``  the bar turns into a stem -- something continues below or above
    ``FLAT``   the bar runs to the edge of its rect and is continued by something
               else the caller is drawing
    """

    CAP = "cap"
    ELBOW = "elbow"
    FLAT = "flat"


@dataclass
class Bar:
    """A horizontal accent band with terminators and chips.

    The flat run is terminal cells; only the elbow and cap are images. Drawing
    returns the columns the flat fill actually occupied, which callers use to place
    a title without colliding with the chips.
    """

    rect: Rect
    color: Color
    rows: int = 2
    left_end: End = End.ELBOW
    right_end: End = End.CAP
    orientation: str = "top"
    stem_columns: int = 1
    elbow_columns: int = 5
    chips: Sequence[Chip] = field(default_factory=tuple)
    title: Optional[str] = None
    title_color: Optional[Color] = None

    def draw(self, painter: Painter) -> Rect:
        canvas = painter.canvas
        x, y = self.rect.x, self.rect.y
        right = self.rect.right
        flat_start, flat_end = x, right

        if self.left_end is End.ELBOW:
            asset = painter.assets.elbow(
                self.color, self.orientation, facing="left",
                columns=max(self.elbow_columns, self.stem_columns + 2),
                bar_rows=self.rows, stem_rows=1, stem_columns=self.stem_columns,
            )
            image_id = painter.register(asset)
            elbow_y = y if self.orientation == "top" else y - 1
            canvas.place_image(x, elbow_y, image_id, asset.columns, asset.rows)
            flat_start = x + asset.columns
        elif self.left_end is End.CAP:
            asset = painter.assets.cap(self.color, rows=self.rows, facing="left")
            image_id = painter.register(asset)
            canvas.place_image(x, y, image_id, asset.columns, asset.rows)
            flat_start = x + asset.columns

        if self.right_end is End.CAP:
            asset = painter.assets.cap(self.color, rows=self.rows, facing="right")
            image_id = painter.register(asset)
            canvas.place_image(right - asset.columns, y, image_id,
                               asset.columns, asset.rows)
            flat_end = right - asset.columns
        elif self.right_end is End.ELBOW:
            asset = painter.assets.elbow(
                self.color, self.orientation, facing="right",
                columns=max(self.elbow_columns, self.stem_columns + 2),
                bar_rows=self.rows, stem_rows=1, stem_columns=self.stem_columns,
            )
            image_id = painter.register(asset)
            elbow_y = y if self.orientation == "top" else y - 1
            canvas.place_image(right - asset.columns, elbow_y, image_id,
                               asset.columns, asset.rows)
            flat_end = right - asset.columns

        for row in range(self.rows):
            canvas.horizontal_run(flat_start, y + row, flat_end - flat_start, self.color)

        content_end = flat_end
        if self.right_end is End.CAP:
            # Design law: at least two bar-color columns before a cap, so the round
            # end reads as the bar continuing rather than a blob on the last chip.
            content_end -= PRE_CAP_COLUMNS

        if self.chips:
            content_end = draw_chips(
                painter, content_end, y, self.rows, self.chips, self.color,
                left_limit=flat_start,
            )

        if self.title:
            label = truncate(self.title, max(0, content_end - flat_start - 2))
            if label:
                canvas.text(flat_start + 1, y + self.rows - 1, label,
                            foreground=self.title_color or CANVAS)

        return Rect(flat_start, y, max(0, flat_end - flat_start), self.rows)


#: A pill is at least two rows tall. At one row the round caps are a half-cell
#: wide and read as punctuation stuck to the text rather than as a capped
#: segment -- the shape only becomes a pill once the cap has height to curve
#: through. The reference LCARS panels never draw a one-row pill.
PILL_ROWS = 2

#: Blank rows between stacked pills. Without it the caps of adjacent pills touch
#: and the column reads as one lumpy bar.
PILL_GAP = 1


def draw_pill(
    painter: Painter,
    x: int,
    y: int,
    width: int,
    color: Color,
    rows: int = PILL_ROWS,
    label: str = "",
    label_color: Optional[Color] = None,
    align: str = "center",
    label_row_offset: Optional[int] = None,
    action: Optional[Handler] = None,
) -> int:
    """A segment capped at BOTH ends. Returns the column after it.

    The shape the reference LCARS panels use for a row of buttons or readouts,
    and the one this vocabulary was missing an entry for -- though not a
    capability: a :class:`Bar` with a cap at each end already draws it, so this is
    a name for an arrangement rather than new machinery.

    ``width`` is the whole pill including both caps. A pill narrower than its two
    caps plus a column is not drawn at all, because a cap pair with no body
    between them reads as a dropped glyph rather than as a small pill.

    ``rows`` is clamped to :data:`PILL_ROWS` at the bottom. Callers asking for a
    one-row pill get a two-row one rather than a squashed shape.
    """
    rows = max(PILL_ROWS, rows)
    cap_columns = painter.assets.cap_columns(rows)
    if width < cap_columns * 2 + 1:
        return x + max(0, width)

    Bar(
        rect=Rect(x, y, width, rows),
        color=color,
        rows=rows,
        left_end=End.CAP,
        right_end=End.CAP,
    ).draw(painter)
    painter.claim(Rect(x, y, width, rows), action, label)

    if label:
        body = Rect(x + cap_columns, y, width - 2 * cap_columns, rows)
        text = truncate(label, body.width)
        # Centre the label vertically in a tall pill; a label pinned to the last
        # row of a four-row pill looks like it fell out of the shape.
        offset = (label_row_offset if label_row_offset is not None
                  else (rows - 1) // 2)
        label_row = y + min(rows - 1, offset)
        if align == "left":
            painter.canvas.text(body.x, label_row, text,
                                foreground=label_color or CANVAS)
        elif align == "right":
            painter.canvas.text_right(body.right, label_row, text,
                                      foreground=label_color or CANVAS)
        else:
            painter.canvas.text_center(body, label_row, text,
                                       foreground=label_color or CANVAS)
    return x + width


def draw_pill_stack(
    painter: Painter,
    rect: Rect,
    pills: Sequence[Tuple[str, Color]],
    rows: int = PILL_ROWS,
    gap: int = PILL_GAP,
    align: str = "center",
) -> int:
    """Stack pills down ``rect``, separated by blank rows. Returns rows consumed.

    Stops when the next pill would not fit whole. A clipped pill has one cap and
    is worse than a missing one.
    """
    stride = rows + gap
    y = rect.y
    drawn = 0
    for label, color in pills:
        if y + rows > rect.bottom:
            break
        draw_pill(painter, rect.x, y, rect.width, color, rows=rows,
                  label=label, align=align)
        y += stride
        drawn += 1
    return max(0, y - rect.y - gap) if drawn else 0


def draw_stem(
    painter: Painter,
    x: int,
    y: int,
    height: int,
    color: Color,
    width: int = 1,
) -> None:
    """The vertical drop below (or above) an elbow. Always cells, never an image."""
    for column in range(width):
        painter.canvas.vertical_run(x + column, y, height, color)


# --------------------------------------------------------------------------
# rails
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class RailBlock:
    """One colored block in a vertical rail, optionally labeled.

    ``weight`` is proportional height within the rail; blocks are separated by a
    black gap so they read as distinct segments rather than one long bar.

    ``action`` makes the block clickable. A rail of labeled blocks is the most
    button-like thing LCARS has, so this is the obvious place to hang navigation
    -- but nothing here assumes that is what it is for.
    """

    label: str = ""
    color: Optional[Color] = None
    weight: float = 1.0
    label_color: Optional[Color] = None
    action: Optional[Handler] = None


def draw_rail(
    painter: Painter,
    rect: Rect,
    color: Color,
    blocks: Sequence[RailBlock] = (),
    gap: int = 1,
    align_labels: str = "right",
) -> None:
    """Fill a vertical rail with stacked blocks.

    With no blocks the rail is one solid run -- a plain stem. With blocks it becomes
    the LCARS sidebar: segments in varying accents, each labeled in black, which is
    where a dashboard puts section names without spending content width on them.
    """
    canvas = painter.canvas
    if not rect:
        return
    if not blocks:
        canvas.fill(rect, color)
        return

    weights = [max(0.01, block.weight) for block in blocks]
    heights = _proportional(rect.height - gap * (len(blocks) - 1), weights)

    y = rect.y
    for block, height in zip(blocks, heights):
        if height <= 0:
            continue
        body = Rect(rect.x, y, rect.width, height)
        canvas.fill(body, block.color or color)
        painter.claim(body, block.action, block.label)
        if block.label and rect.width >= 3:
            label = truncate(block.label, rect.width - 1)
            label_row = body.bottom - 1
            if align_labels == "right":
                canvas.text_right(rect.right - 1, label_row, label,
                                  foreground=block.label_color or CANVAS)
            else:
                canvas.text(rect.x + 1, label_row, label,
                            foreground=block.label_color or CANVAS)
        y += height + gap


def _proportional(total: int, weights: Sequence[float]) -> List[int]:
    if total <= 0:
        return [0] * len(weights)
    share = sum(weights)
    sizes = [int(total * weight / share) for weight in weights]
    leftover = total - sum(sizes)
    for index in sorted(range(len(sizes)), key=lambda i: -weights[i])[:leftover]:
        sizes[index] += 1
    return sizes


# --------------------------------------------------------------------------
# panels
# --------------------------------------------------------------------------


class PanelStyle(Enum):
    """The chrome wrapped around a widget's content.

    ``BRACKET``  header bar, rail down the left, footer bar -- a C opening right.
                 Both bars terminate in caps, so there are no T junctions.
    ``HEADER``   a header bar only, for panes too short to carry a rail.
    ``PLAIN``    no chrome; the widget owns every cell of its rect.
    """

    BRACKET = "bracket"
    HEADER = "header"
    PLAIN = "plain"


@dataclass
class Panel:
    """LCARS chrome around a content area.

    ``draw`` paints the chrome and returns the :class:`Rect` the widget should
    render into. The widget never computes chrome offsets itself, which is what
    lets a layout swap a panel's style without touching any widget.
    """

    rect: Rect
    title: str = ""
    color: Color = TEXT
    style: PanelStyle = PanelStyle.BRACKET
    facing: str = "left"
    rail_width: int = 1
    header_rows: int = 2
    footer_rows: int = 1
    chips: Sequence[Chip] = field(default_factory=tuple)
    rail_blocks: Sequence[RailBlock] = field(default_factory=tuple)
    content_gap: int = 1

    @property
    def mirrored(self) -> bool:
        """Whether the rail is on the right and the bars terminate on the left."""
        return self.facing == "right"

    def draw(self, painter: Painter) -> Rect:
        if self.style is PanelStyle.PLAIN:
            return self.rect
        if not self.rect or self.rect.height < self.header_rows + 2:
            return self.rect

        rect = self.rect
        # A mirrored panel is the same frame reflected: the elbow moves to the end
        # the rail is on, and the cap to the other. gen_swoops.py already draws
        # both facings of both shapes, so this is a choice of which asset to ask
        # for rather than new art. Two panels facing each other across a gap is
        # the arrangement the LCARS reference screens use most.
        left_end = End.CAP if self.mirrored else End.ELBOW
        right_end = End.ELBOW if self.mirrored else End.CAP

        header = Bar(
            rect=Rect(rect.x, rect.y, rect.width, self.header_rows),
            color=self.color,
            rows=self.header_rows,
            orientation="top",
            stem_columns=self.rail_width,
            elbow_columns=max(5, self.rail_width + 2),
            chips=self.chips,
            title=self.title,
            left_end=left_end,
            right_end=right_end,
        )
        header.draw(painter)

        # The elbow image carries one stem row below the bar (its inner fillet), so
        # the rail picks up immediately after it.
        rail_top = rect.y + self.header_rows + 1
        rail_x = (rect.right - self.rail_width) if self.mirrored else rect.x
        content_left = (rect.x if self.mirrored
                        else rect.x + self.rail_width + self.content_gap)
        content_width = max(0, rect.width - self.rail_width - self.content_gap)

        if self.style is PanelStyle.HEADER:
            return Rect(content_left, rail_top, content_width,
                        max(0, rect.bottom - rail_top))

        footer_top = rect.bottom - self.footer_rows
        footer = Bar(
            rect=Rect(rect.x, footer_top, rect.width, self.footer_rows),
            color=self.color,
            rows=self.footer_rows,
            orientation="bottom",
            stem_columns=self.rail_width,
            elbow_columns=max(5, self.rail_width + 2),
            left_end=left_end,
            right_end=right_end,
        )
        footer.draw(painter)

        # The bottom elbow's fillet row sits one row above its bar.
        rail_bottom = footer_top - 1
        draw_rail(
            painter,
            Rect(rail_x, rail_top, self.rail_width, max(0, rail_bottom - rail_top)),
            self.color,
            self.rail_blocks,
            align_labels="left" if self.mirrored else "right",
        )

        return Rect(content_left, rail_top, content_width,
                    max(0, rail_bottom - rail_top))


# --------------------------------------------------------------------------
# meters and readouts
# --------------------------------------------------------------------------


def draw_meter(
    painter: Painter,
    x: int,
    y: int,
    width: int,
    fraction: float,
    color: Color,
    empty_color: Color = CANVAS,
    segment: int = 2,
    gap: int = 1,
) -> None:
    """A segmented LCARS bar meter.

    Segments rather than a smooth fill: LCARS reads as discrete lit blocks, and a
    segmented bar stays legible at one row tall where a partial block glyph would
    not. ``fraction`` is clamped, so a caller passing a ratio above one gets a full
    meter instead of an overrun.
    """
    fraction = min(1.0, max(0.0, fraction))
    stride = segment + gap
    count = max(1, (width + gap) // stride)
    lit = int(round(count * fraction))
    for index in range(count):
        start = x + index * stride
        painter.canvas.horizontal_run(
            start, y, segment, color if index < lit else empty_color)


def draw_readout(
    painter: Painter,
    x: int,
    y: int,
    label: str,
    value: str,
    width: int,
    label_color: Optional[Color] = None,
    value_color: Color = TEXT,
) -> None:
    """A label on the left and a right-aligned value, with the gap left black.

    The standard way this dashboard writes one line of data, so panes line up
    without each widget inventing its own spacing.
    """
    from .palette import DIM_VIOLET

    canvas = painter.canvas
    value = truncate(value, max(0, width - 2))
    value_start = x + width - text_width(value)
    label_room = max(0, value_start - x - 1)
    canvas.text(x, y, truncate(label, label_room),
                foreground=label_color or DIM_VIOLET)
    canvas.text(value_start, y, value, foreground=value_color)


def draw_status_dot(
    painter: Painter,
    x: int,
    y: int,
    color: Color,
    filled: bool = True,
) -> None:
    """A single status LED. Geometric, never an icon glyph."""
    painter.canvas.text(x, y, "●" if filled else "○", foreground=color)


def scale_to_columns(values: Sequence[float], width: int) -> List[int]:
    """Resample a series onto ``width`` columns, for sparklines in a panel."""
    if width <= 0 or not values:
        return []
    if len(values) == width:
        return [int(round(value)) for value in values]
    out = []
    for column in range(width):
        index = column * len(values) / width
        low = int(index)
        high = min(len(values) - 1, low + 1)
        blend = index - low
        out.append(int(round(values[low] * (1 - blend) + values[high] * blend)))
    return out


SPARK_GLYPHS: Tuple[str, ...] = (" ", "▁", "▂", "▃", "▄",
                                 "▅", "▆", "▇", "█")


def draw_sparkline(
    painter: Painter,
    x: int,
    y: int,
    width: int,
    values: Sequence[float],
    color: Color,
) -> None:
    """One row of block glyphs tracking a series. Cells only, no image."""
    if not values or width <= 0:
        return
    low, high = min(values), max(values)
    span = high - low or 1.0
    for column in range(min(width, len(values))):
        level = (values[column] - low) / span
        glyph = SPARK_GLYPHS[min(len(SPARK_GLYPHS) - 1,
                                 int(level * (len(SPARK_GLYPHS) - 1) + 0.5))]
        painter.canvas.put(x + column, y, glyph, foreground=color)
