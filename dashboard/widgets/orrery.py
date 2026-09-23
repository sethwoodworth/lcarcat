"""The solar system, seen from above, and what is above the horizon right now.

Two widgets over one ephemeris. :class:`OrreryWidget` plots the planets on their
orbits looking down on the ecliptic; :class:`SkyWidget` is the readout -- where
each body is from the ground, and whether it is up.

The orrery is a generated PNG (see :mod:`dashboard.plots`), not cells. An orbit is
a curve, and this repo draws curves as images; a ring stippled out of punctuation
at one glyph per cell reads as a dotted line at any size a pane can offer.
"""
from __future__ import annotations

import math
from typing import Dict, List, Optional, Tuple

from ..geometry import Rect
from ..palette import (CANVAS, DIM_VIOLET, GOLD, LILAC, ORANGE, PERIWINKLE,
                       RED_ALERT, SAGE, SKY, STEM_DIM, TEXT, Color)
from .. import plots
from ..segments import Chip, ChipStyle, Painter
from ..sources import dialamoon, ephemeris
from .base import Widget, WidgetChrome
from .framed_image import FramedImageWidget

#: One color per body, held steady between the orrery and the readout so the same
#: planet is the same color wherever it appears.
#:
#: Every minor planet shares one color on purpose. LCARS assigns meaning to color
#: rather than decoration, so here color carries *class* -- planet, minor planet,
#: moon, sun -- and the symbol drawn on the marker carries identity. Giving each
#: dwarf planet its own accent would push the view past the five-color rule and
#: say nothing the glyph does not already say.
MINOR_PLANET_COLOR = LILAC

BODY_COLORS: Dict[str, Color] = {
    "SUN": ORANGE,
    "MERCURY": STEM_DIM,
    "VENUS": GOLD,
    "EARTH": SKY,
    "MARS": RED_ALERT,
    "JUPITER": ORANGE,
    "SATURN": GOLD,
    "URANUS": SAGE,
    "NEPTUNE": PERIWINKLE,
    "MOON": TEXT,
    "LUNA": TEXT,
    "CERES": MINOR_PLANET_COLOR,
    "PLUTO": MINOR_PLANET_COLOR,
    "HAUMEA": MINOR_PLANET_COLOR,
    "MAKEMAKE": MINOR_PLANET_COLOR,
    "ERIS": MINOR_PLANET_COLOR,
}


class OrreryWidget(Widget):
    """Top-down plot of the planets on their orbits."""

    refresh_interval = 60.0

    def __init__(
        self,
        title: str = "SOL SYSTEM",
        color: Color = PERIWINKLE,
        inner_only: bool = False,
        minor_planets: bool = True,
        show_moon: bool = True,
        show_key: bool = True,
        show_distance: bool = True,
    ) -> None:
        super().__init__(title=title, color=color)
        self.inner_only = inner_only
        self.minor_planets = minor_planets
        self.show_moon = show_moon
        #: The legend lives in the plot's own pane, as a strip beneath it. It
        #: was a separate widget in its own panel, which put a second rail, a
        #: second header bar and a cap between a picture and the names of the
        #: things in it. Centred, it reads as the plot's caption instead.
        self.show_key = show_key
        self.show_distance = show_distance
        self.observer = ephemeris.Observer.from_environment()
        self.positions: Dict[str, Tuple[float, float]] = {}
        self.moon_longitude: float = 0.0
        self.moon_distance_km: float = 0.0
        # Stable per-instance key so two orreries in one layout get separate
        # kitty image ids instead of overwriting each other's plot.
        self.image_key = "orrery-%d" % id(self)

    @property
    def bodies(self) -> Tuple[str, ...]:
        if self.inner_only:
            return ("MERCURY", "VENUS", "EARTH", "MARS", "CERES")
        names = ephemeris.PLANET_ORDER
        if self.minor_planets:
            # Sorted by semi-major axis so the rings come out sun-outward and
            # Ceres lands between Mars and Jupiter where it belongs.
            names = tuple(sorted(
                names + ephemeris.MINOR_PLANET_ORDER,
                key=ephemeris.mean_distance))
        return names

    def refresh(self) -> None:
        jd = ephemeris.julian_day()
        self.positions = ephemeris.heliocentric_longitudes(jd, self.bodies)
        if self.show_moon:
            self.moon_longitude = ephemeris.moon_geocentric_longitude(jd)
            # The key reports the moon's distance from the planet it orbits;
            # its heliocentric distance is Earth's and says nothing.
            self.moon_distance_km = ephemeris.moon_state(
                ephemeris.Observer("KEY", 0.0, 0.0), jd).distance_km

    def chrome(self) -> WidgetChrome:
        return WidgetChrome(
            title=self.title,
            color=self.color,
            chips=(Chip("HELIOCENTRIC", style=ChipStyle.COLOR),),
        )


    # -- the key ----------------------------------------------------------

    #: Clear columns between one key entry and the next.
    KEY_ENTRY_GAP = 2

    #: Rows the key strip takes, and the most of the pane it may take. A plot
    #: squeezed under its own legend is the wrong way round.
    KEY_ROWS = 9
    KEY_MAX_SHARE = 3

    #: Blank rows between the plot and the key. This is the whole separation:
    #: no bar, no rule, just the space.
    KEY_GAP_ROWS = 1

    @property
    def key_bodies(self) -> Tuple[str, ...]:
        """Everything the plot draws, in the order it is drawn -- sun outward.

        The key exists to explain the picture, so it lists exactly what the
        picture contains. Leaving out the sun and the moon made it a key to the
        planets rather than to the plot.
        """
        listed: List[str] = ["SUN"]
        for name in self.bodies:
            listed.append(name)
            # Luna belongs beside its parent, not at the end of a list sorted
            # by distance from the sun -- which is where its heliocentric
            # distance would put it, indistinguishable from Earth's.
            if name == "EARTH" and self.show_moon:
                listed.append("LUNA")
        return tuple(listed)

    def _key_value(self, name: str) -> str:
        """The distance column. Units differ by body, and are written out."""
        if name == "SUN":
            return "CENTRE"
        if name == "LUNA":
            return "%s KM" % format(int(self.moon_distance_km), ",")
        return "%.2f AU" % self.positions.get(name, (0.0, 0.0))[1]

    def _key_grid(self, rect: Rect):
        """Where every entry lands, and the box they occupy together.

        Split out of the drawing because the geometry has to be answerable
        without drawing it: centring the key against the plot needs the box the
        key ACTUALLY fills, and so does anything checking that alignment.

        Returns ``(entries, per_column, column_width, bounds)``, or None when
        the strip is too narrow to be worth drawing in.
        """
        if not rect or rect.height < 1:
            return None
        if not self.positions:
            self.refresh()

        entries = [(name, plots.SYMBOLS.get(name) or "",
                    self._key_value(name) if self.show_distance else "")
                   for name in self.key_bodies]
        name_width = max(len(name) for name, _, _ in entries)
        value_width = max((len(value) for _, _, value in entries), default=0)
        entry_width = 2 + name_width + (value_width + 2 if value_width else 0)

        # Flow into as many columns as the strip can hold, so a fifteen-body
        # key is three rows rather than fifteen.
        slots = max(1, min(len(entries),
                           (rect.width + self.KEY_ENTRY_GAP)
                           // (entry_width + self.KEY_ENTRY_GAP)))
        while slots < len(entries) and -(-len(entries) // slots) > rect.height:
            slots += 1
        per_column = -(-len(entries) // slots)
        # How many columns the entries FILL, which is not how many would fit:
        # fifteen entries three deep occupy five columns whether the strip has
        # room for five or for nine. Centring on the fitting count is what makes
        # a centred key look left-aligned.
        columns = -(-len(entries) // per_column)
        column_width = min(entry_width,
                           (rect.width - self.KEY_ENTRY_GAP * (columns - 1)) // columns)
        if column_width < 6:
            return None

        width = columns * column_width + self.KEY_ENTRY_GAP * (columns - 1)
        left = rect.x + max(0, (rect.width - width) // 2)
        return (entries, per_column, column_width,
                Rect(left, rect.y, width, min(per_column, rect.height)))

    def key_bounds(self, rect: Rect) -> Optional[Rect]:
        """The box the key fills inside the pane, before drawing it.

        ``rect`` is the whole pane, as passed to :meth:`render`.
        """
        grid = self._key_grid(self._key_strip(rect))
        return grid[3] if grid else None

    def _key_strip(self, rect: Rect) -> Rect:
        """The strip along the bottom of the pane the key draws into."""
        rows = min(self.KEY_ROWS, max(0, rect.height // self.KEY_MAX_SHARE))
        return Rect(rect.x, rect.bottom - rows, rect.width, rows)

    def _render_key(self, painter: Painter, rect: Rect) -> None:
        grid = self._key_grid(rect)
        if grid is None:
            return
        entries, per_column, column_width, box = grid
        canvas = painter.canvas
        name_width = max(len(name) for name, _, _ in entries)
        value_width = max((len(value) for _, _, value in entries), default=0)

        for index, (name, glyph, value) in enumerate(entries):
            column, row = divmod(index, per_column)
            x = box.x + column * (column_width + self.KEY_ENTRY_GAP)
            y = rect.y + row
            if y >= rect.bottom or x + column_width > rect.right + self.KEY_ENTRY_GAP:
                continue
            body_color = BODY_COLORS.get(name, TEXT)
            if glyph:
                canvas.put(x, y, glyph, foreground=body_color, bold=True)
            canvas.text(x + 2, y, name, foreground=body_color,
                        max_width=column_width - 2)
            if value and column_width >= name_width + value_width + 3:
                canvas.text_right(x + column_width, y, value,
                                  foreground=DIM_VIOLET)

    def render(self, painter: Painter, rect: Rect) -> None:
        if not rect or rect.width < 12 or rect.height < 7:
            return
        if not self.positions:
            self.refresh()

        # The key takes a strip along the bottom; the plot takes what is left.
        # Both are the pane's full width, so the centred key stands on the
        # plot's own midline.
        plot_rect = rect
        if self.show_key:
            strip = self._key_strip(rect)
            if strip.height:
                plot_rect = Rect(rect.x, rect.y, rect.width,
                                 max(0, strip.y - self.KEY_GAP_ROWS - rect.y))
                self._render_key(painter, strip)
        if plot_rect.height < 5:
            return
        rect = plot_rect

        bodies = [(name, *self.positions[name])
                  for name in self.bodies if name in self.positions]
        if not bodies:
            return

        # The plot is a real image: orbits are curves, and this repo draws curves
        # as PNGs. Stippling a ring out of "·" at one glyph per cell produces a
        # dotted line at any size a terminal pane can offer.
        cell = painter.assets.cell_size
        png = plots.render_orrery(
            pixel_width=rect.width * cell.width,
            pixel_height=rect.height * cell.height,
            bodies=bodies,
            colors=BODY_COLORS,
            ring_color=STEM_DIM,
            sun_color=ORANGE,
            marker_color=CANVAS,
            satellites=((("LUNA", "EARTH", self.moon_longitude),)
                        if self.show_moon else ()),
            highlight=("EARTH",),
        )
        if not png:
            return

        escapes, image_id = painter.images.dynamic_transmission(
            self.image_key, png, rect.width, rect.height)
        if escapes:
            painter.queue_transmission(escapes)
        painter.canvas.place_image(rect.x, rect.y, image_id, rect.width, rect.height)


class SkyWidget(Widget):
    """What is above the horizon, and where to look for it."""

    refresh_interval = 60.0

    def __init__(
        self,
        title: str = "SKY",
        color: Color = PERIWINKLE,
        include_moon: bool = True,
        include_sun: bool = True,
        include_minor_planets: bool = False,
        visible_only: bool = False,
    ) -> None:
        super().__init__(title=title, color=color)
        self.include_moon = include_moon
        self.include_sun = include_sun
        self.include_minor_planets = include_minor_planets
        self.visible_only = visible_only
        self.observer = ephemeris.Observer.from_environment()
        self.sun: Optional[ephemeris.SkyPosition] = None
        self.moon: Optional[ephemeris.MoonState] = None
        self.planets: List[ephemeris.SkyPosition] = []

    def refresh(self) -> None:
        jd = ephemeris.julian_day()
        names = ephemeris.PLANET_ORDER
        if self.include_minor_planets:
            names = names + ephemeris.MINOR_PLANET_ORDER
        self.sun = ephemeris.sun_position(self.observer, jd)
        self.moon = ephemeris.moon_state(self.observer, jd)
        self.planets = ephemeris.planet_positions(self.observer, jd, names)

    def chrome(self) -> WidgetChrome:
        chips: List[Chip] = []
        if self.planets:
            up = sum(1 for body in self.planets if body.is_up)
            chips.append(Chip("%02d-ABOVE" % up, SAGE, ChipStyle.COLOR))
        chips.append(Chip(self.observer.name, style=ChipStyle.COLOR))
        return WidgetChrome(title=self.title, color=self.color, chips=tuple(chips))

    def render(self, painter: Painter, rect: Rect) -> None:
        if not rect:
            return
        if self.sun is None:
            self.refresh()

        rows: List[Tuple[str, ephemeris.SkyPosition]] = []
        if self.include_sun and self.sun:
            rows.append(("SUN", self.sun))
        if self.include_moon and self.moon:
            rows.append(("MOON", self.moon.position))
        rows.extend((body.name, body) for body in self.planets)
        if self.visible_only:
            rows = [row for row in rows if row[1].is_up]

        wide = rect.width >= 42
        for index, (name, body) in enumerate(rows[: rect.height]):
            y = rect.y + index
            color = BODY_COLORS.get(name, TEXT)
            painter.canvas.put(rect.x, y, "●" if body.is_up else "○",
                               foreground=color if body.is_up else STEM_DIM)
            painter.canvas.text(rect.x + 2, y, name,
                               foreground=color if body.is_up else DIM_VIOLET)
            if wide:
                detail = "%s %s  %s %2d°" % (
                    body.right_ascension_hms(), body.declination_dm(),
                    body.compass.rjust(3), int(abs(body.altitude)))
            else:
                detail = "%s %2d°" % (body.compass.rjust(3), int(abs(body.altitude)))
            painter.canvas.text_right(
                rect.right, y, detail,
                foreground=TEXT if body.is_up else STEM_DIM)


class MoonWidget(FramedImageWidget):
    """The moon as NASA renders it this hour, with the geometry behind it.

    The picture is the current frame of Goddard's Dial-A-Moon animation: a real
    render of the lunar terrain at the correct phase *and* libration, which a
    shaded circle cannot show. The readouts carry the numbers that come with it
    -- libration, sub-solar point, apparent diameter, eclipse obscuration --
    none of which the local ephemeris computes.

    With no network the widget draws the phase from the local ephemeris instead.
    That path is not vestigial: it is the only thing between an offline laptop
    and an empty box, and it needs no network, no cache and no API.
    """

    refresh_interval = 900.0

    def __init__(self, title: str = "LUNA", color: Color = PERIWINKLE,
                 use_nasa_image: bool = True, framed: bool = True) -> None:
        super().__init__(title=title, color=color, framed=framed)
        self.use_nasa_image = use_nasa_image
        self.observer = ephemeris.Observer.from_environment()
        self.state: Optional[ephemeris.MoonState] = None
        self.frame: Optional[dialamoon.MoonFrame] = None

    def refresh(self) -> None:
        self.state = ephemeris.moon_state(self.observer, ephemeris.julian_day())
        if self.use_nasa_image:
            self.frame = dialamoon.load()

    def image_source(self):
        return self.frame.image_path if self.frame else None

    def chrome(self) -> WidgetChrome:
        chips: List[Chip] = []
        frame, state = self.frame, self.state
        if frame is not None:
            chips.append(Chip("%02d-PERCENT" % round(frame.phase),
                              LILAC, ChipStyle.COLOR))
            if frame.obscuration > 0:
                # An eclipse in progress is the one thing here worth an alert.
                chips.append(Chip("ECLIPSE", RED_ALERT, ChipStyle.COLOR))
        elif state is not None:
            chips.append(Chip("%02d-PERCENT" % round(state.illumination * 100),
                              LILAC, ChipStyle.COLOR))
            # Only worth saying when it is NOT the NASA frame: the fallback is
            # a computed approximation and the header should admit it.
            chips.append(Chip("COMPUTED", DIM_VIOLET, ChipStyle.COLOR))
        return WidgetChrome(title=self.title, color=self.color, chips=tuple(chips))

    def render(self, painter: Painter, rect: Rect) -> None:
        if self.state is None and self.frame is None:
            self.refresh()
        super().render(painter, rect)

    def readouts(self) -> List[Tuple[str, str, Color]]:
        """NASA's numbers when they are available, the computed ones otherwise."""
        frame, state = self.frame, self.state
        rows: List[Tuple[str, str, Color]] = []
        if frame is not None:
            rows.append(("PHASE", frame.phase_name(), TEXT))
            rows.append(("ILLUMINATED", "%.1f%%" % frame.phase, LILAC))
            rows.append(("AGE", "%.2f DAYS" % frame.age, TEXT))
            rows.append(("RANGE", "%s KM" % format(int(frame.distance), ","), TEXT))
            rows.append(("DIAMETER", "%.1f ARCSEC" % frame.diameter, DIM_VIOLET))
            rows.append(("LIBRATION", "%+.1f° %+.1f°" % (frame.libration_longitude,
                                                        frame.libration_latitude), SAGE))
            rows.append(("SUBSOLAR", "%+.1f° %+.1f°" % (frame.subsolar_longitude,
                                                       frame.subsolar_latitude), SKY))
            rows.append(("POLE ANGLE", "%.2f°" % frame.position_angle, DIM_VIOLET))
            if frame.obscuration > 0:
                rows.append(("OBSCURATION", "%.1f%%" % (frame.obscuration * 100),
                             RED_ALERT))
            if state is not None:
                rows.append(("ALTITUDE", "%+d°" % int(state.position.altitude),
                             TEXT if state.position.is_up else DIM_VIOLET))
            return rows

        if state is not None:
            rows.append(("PHASE", state.phase_name(), TEXT))
            rows.append(("ILLUMINATED", "%.1f%%" % (state.illumination * 100), LILAC))
            rows.append(("RANGE", "%s KM" % format(int(state.distance_km), ","), TEXT))
            rows.append(("ALTITUDE", "%+d°" % int(state.position.altitude),
                         TEXT if state.position.is_up else DIM_VIOLET))
        return rows

    def draw_without_image(self, painter: Painter, rect: Rect, rows: int) -> bool:
        """Offline fallback: shade the phase from the local ephemeris."""
        if self.state is None:
            return False
        self._draw_disc(painter, rect, self.state, min(rows, 11))
        return True

    def _draw_disc(self, painter: Painter, rect: Rect,
                   state: ephemeris.MoonState, height: int) -> None:
        """Shade a circle by which side of the terminator each cell falls on.

        The terminator is an ellipse whose width tracks the phase, so the shape is
        the real one: a crescent bulging the correct way, a straight edge at the
        quarters, and a gibbous curve past them. ``is_waxing`` decides which side is
        lit, which is the part a symmetric phase value alone cannot tell you.
        """
        radius = height / 2.0
        center_y = rect.y + radius
        center_x = rect.x + rect.width / 2.0
        # Twice the cells horizontally, because cells are about half as wide as tall.
        radius_x = radius * 2.0
        terminator = math.cos(2 * math.pi * state.phase)

        for row in range(height):
            y = rect.y + row
            if y >= rect.bottom:
                break
            dy = (y + 0.5 - center_y) / radius
            if abs(dy) > 1:
                continue
            half_width = math.sqrt(max(0.0, 1 - dy * dy))
            for column in range(int(-half_width * radius_x), int(half_width * radius_x) + 1):
                x = int(center_x + column)
                if not rect.contains(x, y):
                    continue
                dx = column / radius_x
                # The lit limb is the side of the terminator ellipse facing the sun.
                lit = (dx > terminator * half_width if state.is_waxing
                       else dx < -terminator * half_width)
                painter.canvas.put(
                    x, y, "█" if lit else "░",
                    foreground=TEXT if lit else STEM_DIM)
