"""The sun: SDO's latest frame, with NOAA's space-weather numbers around it.

The moon's panel shows what the moon *looks like*; this one shows what the sun
is *doing*. On a quiet day the visible disc is a blank circle, so the default
channel is the colorized magnetogram -- magnetic flux is the thing with structure
on it, and it is also what the numbers beside it are about.
"""
from __future__ import annotations

from pathlib import Path
from typing import List, Optional, Tuple

from ..geometry import Rect
from ..palette import (DIM_VIOLET, GOLD, ORANGE, RED_ALERT, SAGE, SKY, TEXT,
                       Color)
from ..segments import Chip, ChipStyle, Painter
from ..sources import solar
from .base import WidgetChrome
from .framed_image import FramedImageWidget

#: Colour by X-ray flare class. A/B/C are ordinary and want no attention; M
#: disrupts radio at the poles; X is the class that reaches the ground.
FLARE_COLORS = {"A": SAGE, "B": SAGE, "C": GOLD, "M": ORANGE, "X": RED_ALERT}

#: The K index is a 0-9 scale; five is the threshold for a geomagnetic storm.
STORM_K_INDEX = 5.0


class SolWidget(FramedImageWidget):
    """Solar disc plus space weather."""

    refresh_interval = 900.0

    def __init__(
        self,
        title: str = "SOL",
        color: Color = GOLD,
        channel: str = solar.DEFAULT_CHANNEL,
        allow_live: bool = True,
        framed: bool = True,
    ) -> None:
        super().__init__(title=title, color=color, framed=framed)
        self.channel = channel
        self.allow_live = allow_live
        self.conditions: Optional[solar.SolarConditions] = None

    def refresh(self) -> None:
        self.conditions = solar.load(channel=self.channel,
                                     allow_live=self.allow_live)

    def image_source(self) -> Optional[Path]:
        return self.conditions.image_path if self.conditions else None

    def chrome(self) -> WidgetChrome:
        chips: List[Chip] = []
        conditions = self.conditions
        if conditions is not None:
            if conditions.is_flaring:
                chips.append(Chip("FLARE %s" % conditions.xray_class,
                                  RED_ALERT, ChipStyle.COLOR))
            elif conditions.is_storming:
                chips.append(Chip("STORM", ORANGE, ChipStyle.COLOR))
            else:
                chips.append(Chip("QUIET", SAGE, ChipStyle.COLOR))
            chips.append(Chip(conditions.channel_name, style=ChipStyle.HOLE))
        return WidgetChrome(title=self.title, color=self.color, chips=tuple(chips))

    def readouts(self) -> List[Tuple[str, str, Color]]:
        conditions = self.conditions
        if conditions is None:
            return []

        rows: List[Tuple[str, str, Color]] = []
        flare_color = FLARE_COLORS.get(conditions.flare_letter, DIM_VIOLET)
        rows.append(("X-RAY CLASS", conditions.xray_class or "UNKNOWN", flare_color))
        if conditions.xray_peak:
            rows.append(("EVENT PEAK", conditions.xray_peak,
                         FLARE_COLORS.get(conditions.xray_peak[:1].upper(),
                                          DIM_VIOLET)))
        if conditions.radio_flux is not None:
            rows.append(("RADIO FLUX", "%.0f SFU" % conditions.radio_flux, TEXT))
        if conditions.wind_speed is not None:
            rows.append(("SOLAR WIND", "%.0f KM/S" % conditions.wind_speed, SKY))
        if conditions.k_index is not None:
            rows.append(("PLANETARY K", "%.1f" % conditions.k_index,
                         ORANGE if conditions.k_index >= STORM_K_INDEX else SAGE))
        rows.append(("RADIO BLACKOUT",
                     conditions.scale_label(conditions.radio_blackout, "R"),
                     RED_ALERT if conditions.radio_blackout not in ("", "0") else SAGE))
        rows.append(("RADIATION STORM",
                     conditions.scale_label(conditions.radiation_storm, "S"),
                     RED_ALERT if conditions.radiation_storm not in ("", "0") else SAGE))
        rows.append(("GEOMAGNETIC",
                     conditions.scale_label(conditions.geomagnetic_storm, "G"),
                     RED_ALERT if conditions.geomagnetic_storm not in ("", "0") else SAGE))
        if conditions.observed:
            # Trim the date: the panel is about now, and the time is the part
            # that says how stale "now" is.
            stamp = conditions.observed.replace("T", " ").rstrip("Z")
            rows.append(("OBSERVED", stamp[-8:].strip() or stamp, DIM_VIOLET))
        return rows

    def render(self, painter: Painter, rect: Rect) -> None:
        if self.conditions is None:
            painter.canvas.text(rect.x, rect.y, "NO SOLAR DATA",
                                foreground=DIM_VIOLET)
            return
        super().render(painter, rect)
