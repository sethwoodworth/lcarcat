"""Local machine status, as LCARS meters.

Segmented bars rather than numbers alone. A number tells you the value; a lit bar
tells you at a glance whether it is fine, which is what a status board is for.
The number goes on the same row for when the glance is not enough.
"""
from __future__ import annotations

from typing import List, Optional, Tuple

from ..geometry import Rect
from ..palette import (DIM_VIOLET, GOLD, ORANGE, PERIWINKLE, RED_ALERT, SAGE,
                       SKY, STEM_DIM, TEXT, Color)
from ..segments import (Chip, ChipStyle, Painter, draw_meter, draw_readout,
                        draw_sparkline)
from ..sources import system
from .base import Widget, WidgetChrome

#: Where a reading stops being fine. Below the first it is green, between them
#: amber, above the second it is an alert.
WARNING_LEVEL = 0.75
ALERT_LEVEL = 0.90


def level_color(fraction: Optional[float]) -> Color:
    if fraction is None:
        return STEM_DIM
    if fraction >= ALERT_LEVEL:
        return RED_ALERT
    if fraction >= WARNING_LEVEL:
        return GOLD
    return SAGE


class TelemetryWidget(Widget):
    """Load, memory, disk and battery, each as a labeled meter."""

    refresh_interval = 5.0

    def __init__(
        self,
        title: str = "SYSTEM STATUS",
        color: Color = PERIWINKLE,
        disk_path: str = "/",
        show_sparkline: bool = True,
    ) -> None:
        super().__init__(title=title, color=color)
        self.disk_path = disk_path
        self.show_sparkline = show_sparkline
        self.reading: Optional[system.Telemetry] = None
        self.load_history = system.History(size=180)

    def refresh(self) -> None:
        reading = system.read(self.disk_path)
        self.reading = reading
        self.load_history.push(reading.load_fraction)

    def chrome(self) -> WidgetChrome:
        chips: List[Chip] = []
        reading = self.reading
        if reading is not None:
            worst = max(
                (value for value in (reading.load_fraction, reading.memory_fraction,
                                     reading.disk_fraction) if value is not None),
                default=0.0)
            if worst >= ALERT_LEVEL:
                chips.append(Chip("ALERT", RED_ALERT, ChipStyle.COLOR))
            elif worst >= WARNING_LEVEL:
                chips.append(Chip("CAUTION", GOLD, ChipStyle.COLOR))
            else:
                chips.append(Chip("NOMINAL", SAGE, ChipStyle.COLOR))
            chips.append(Chip(reading.hostname.upper(), style=ChipStyle.HOLE))
        return WidgetChrome(title=self.title, color=self.color, chips=tuple(chips))

    def render(self, painter: Painter, rect: Rect) -> None:
        if not rect:
            return
        if self.reading is None:
            self.refresh()
        reading = self.reading
        if reading is None:
            return

        rows: List[Tuple[str, Optional[float], str]] = [
            ("CPU LOAD", reading.load_fraction,
             ("%.2f" % reading.load_average[0]) if reading.load_average else "--"),
            ("MEMORY", reading.memory_fraction,
             "%s/%s" % (system.format_bytes(reading.memory_used_bytes),
                        system.format_bytes(reading.memory_total_bytes))),
            ("STORAGE", reading.disk_fraction,
             "%s FREE" % system.format_bytes(
                 (reading.disk_total_bytes - reading.disk_used_bytes)
                 if reading.disk_total_bytes and reading.disk_used_bytes is not None
                 else None)),
        ]
        if reading.battery_percent is not None:
            rows.append((
                "POWER" if not reading.battery_charging else "POWER · AC",
                reading.battery_percent / 100.0,
                "%d%%" % int(reading.battery_percent),
            ))

        # The value column is sized from the widest value so the meters all start
        # and end on the same columns; ragged meters read as a broken grid.
        label_width = max(len(label) for label, _, _ in rows) + 1
        value_width = max(len(value) for _, _, value in rows) + 1
        meter_width = rect.width - label_width - value_width - 1

        y = rect.y
        for label, fraction, value in rows:
            if y >= rect.bottom:
                break
            painter.canvas.text(rect.x, y, label, foreground=DIM_VIOLET)
            if meter_width >= 6 and fraction is not None:
                # Battery is the one reading where full is good, so it keeps the
                # structural color instead of turning red as it fills.
                color = (SKY if label.startswith("POWER") and fraction > 0.25
                         else RED_ALERT if label.startswith("POWER")
                         else level_color(fraction))
                draw_meter(painter, rect.x + label_width, y, meter_width,
                           fraction, color, empty_color=STEM_DIM)
            painter.canvas.text_right(rect.right, y, value, foreground=TEXT)
            y += 1

        if y < rect.bottom:
            y += 1
        if y < rect.bottom:
            draw_readout(painter, rect.x, y, "UPTIME", reading.uptime_label(),
                         rect.width, value_color=PERIWINKLE)
            y += 1
        if y < rect.bottom:
            draw_readout(painter, rect.x, y, "CORES", str(reading.cpu_count),
                         rect.width, value_color=PERIWINKLE)
            y += 1

        if (self.show_sparkline and y + 1 < rect.bottom
                and len(self.load_history.values) > 2):
            painter.canvas.text(rect.x, y + 1, "LOAD", foreground=DIM_VIOLET)
            spark_x = rect.x + 5
            spark_width = rect.right - spark_x
            draw_sparkline(painter, spark_x, y + 1, spark_width,
                           self.load_history.tail(spark_width), ORANGE)
