#!/usr/bin/env python3
"""Visual spike: two readouts in ONE panel, with nothing drawn between them.

The Voyager PADD reference (references/elbows/) puts a tabular readout above a
main display inside a single frame. Every dashboard layout today gives each
readout its own panel instead, so the orrery and its KEY sit in separate frames,
with two rails and two sets of chrome between them.

This draws them the other way: one panel, one rail, the KEY as a strip on top
and the orrery below it. There is no divider at all -- the space between them is
what separates them -- and the KEY is centred so it stands on the same midline
as the plot it explains.

    uv run --with astropy --with pillow python -m dashboard.tools.panel_split_demo
    uv run --with astropy --with pillow python -m dashboard.tools.panel_split_demo --hold
"""
from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from dashboard.assets import AssetLibrary, probe_cell_size  # noqa: E402
from dashboard.canvas import (Canvas, enter_full_screen, frame,  # noqa: E402
                              leave_full_screen)
from dashboard.geometry import Rect, terminal_size  # noqa: E402
from dashboard.images import ImageTransmitter  # noqa: E402
from dashboard.palette import CANVAS, DIM_VIOLET, PERIWINKLE, SAGE  # noqa: E402
from dashboard.segments import (Painter, Panel, PanelStyle,  # noqa: E402
                                RailBlock)
from dashboard.widgets.orrery import OrreryWidget  # noqa: E402

def draw_guides(canvas: Canvas, key_box: Rect, plot: Rect) -> None:
    """Debug overlay: the key's box, and a line through the sun.

    Box-drawing glyphs are not LCARS and never ship -- this exists to make the
    alignment checkable by eye. The sun sits at the centre of the plot image, so
    the line through it should pass through the middle of the key's box.
    """
    centre = plot.x + plot.width // 2
    for y in range(plot.y, key_box.y - 1):
        canvas.put(centre, y, "\u2502", foreground=SAGE)

    for x in range(key_box.x, key_box.right):
        canvas.put(x, key_box.y - 1, "\u2500", foreground=DIM_VIOLET)
        canvas.put(x, key_box.bottom, "\u2500", foreground=DIM_VIOLET)
    for y in range(key_box.y - 1, key_box.bottom + 1):
        canvas.put(key_box.x - 1, y, "\u2502", foreground=DIM_VIOLET)
        canvas.put(key_box.right, y, "\u2502", foreground=DIM_VIOLET)
    # The key box's own midline, so the two marks can be compared directly.
    key_centre = key_box.x + key_box.width // 2
    for y in range(key_box.y - 1, key_box.bottom + 1):
        canvas.put(key_centre, y, "\u2502", foreground=SAGE)


def compose(canvas: Canvas, painter: Painter, orrery: OrreryWidget,
            guides: bool = False) -> None:
    screen = canvas.rect.pad(1)
    rail_width = 6

    panel = Panel(
        rect=screen,
        title="ASTROMETRICS",
        color=PERIWINKLE,
        style=PanelStyle.BRACKET,
        facing="left",
        rail_width=rail_width,
        header_rows=2,
        footer_rows=1,
        rail_blocks=(RailBlock("PLOT", weight=2.6),
                     RailBlock("KEY", weight=1.0)),
        content_gap=2,
    )
    content = panel.draw(painter)
    if not content:
        return

    # The orrery carries its own key now: it draws the plot with the key as a
    # centred strip beneath it, inside the one pane.
    orrery.render(painter, content)

    if guides:
        box = orrery.key_bounds(content)
        if box:
            draw_guides(canvas, box, content)


def main() -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    parser.add_argument("--hold", action="store_true",
                        help="keep the frame on screen until interrupted")
    parser.add_argument("--size", default=None, metavar="COLUMNSxROWS")
    parser.add_argument("--guides", action="store_true",
                        help="outline the key's box and rule a line through the sun")
    arguments = parser.parse_args()

    if arguments.size:
        columns, rows = arguments.size.lower().split("x")
        os.environ["COLUMNS"], os.environ["LINES"] = columns, rows

    columns, rows = terminal_size()
    canvas = Canvas(columns, rows)
    canvas.fill(canvas.rect, background=CANVAS)
    painter = Painter(canvas, AssetLibrary(probe_cell_size()),
                      ImageTransmitter(sys.stdout))

    orrery = OrreryWidget(title="SOL SYSTEM")
    orrery.refresh_if_due()

    compose(canvas, painter, orrery, guides=arguments.guides)

    enter_full_screen()
    try:
        sys.stdout.write(painter.transmissions() + frame(canvas))
        sys.stdout.flush()
        if arguments.hold:
            while True:
                time.sleep(3600)
    except KeyboardInterrupt:
        pass
    finally:
        leave_full_screen()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
