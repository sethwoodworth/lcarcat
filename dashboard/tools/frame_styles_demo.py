#!/usr/bin/env python3
"""Visual spike: frame styles the segment library can already express.

Answers "how hard would it be to build the reference LCARS layouts?" by drawing
them rather than estimating. Four things are on screen:

1. a left-facing bracket panel -- what every dashboard layout uses today
2. a right-facing bracket panel -- the mirror, so two panels face each other
   across a channel, which is the arrangement the reference screens use most
3. a column of pills -- segments capped at both ends
4. a rail whose blocks are labeled, against the mirrored rail on the other side

Run it in kitty:

    uv run --with pillow python -m dashboard.tools.frame_styles_demo
    uv run --with pillow python -m dashboard.tools.frame_styles_demo --hold
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
from dashboard.palette import (CANVAS, GOLD, LILAC, ORANGE, PERIWINKLE,  # noqa: E402
                               SAGE, SKY, TEXT)
from dashboard.segments import (Chip, ChipStyle, Painter, Panel,  # noqa: E402
                                PanelStyle, RailBlock, draw_pill)


def compose(canvas: Canvas, painter: Painter) -> None:
    screen = canvas.rect.pad(1)
    left, right = screen.split_horizontal(0.5, 0.5, gap=3)

    # 1. The familiar left-facing bracket.
    facing_left = Panel(
        rect=left,
        title="LEFT FACING",
        color=ORANGE,
        style=PanelStyle.BRACKET,
        facing="left",
        rail_width=8,
        chips=(Chip("01-STANDARD", GOLD, ChipStyle.COLOR),
               Chip("BRACKET", style=ChipStyle.HOLE)),
        rail_blocks=(RailBlock("SENSORS", PERIWINKLE, 2.0),
                     RailBlock("COMMS", SKY, 1.4),
                     RailBlock("NAV", GOLD, 1.8),
                     RailBlock("LIB", SAGE, 2.2)),
        content_gap=2,
    )
    body = facing_left.draw(painter)
    for index, line in enumerate((
            "THE RAIL IS ON THE LEFT AND BOTH BARS",
            "TERMINATE IN A ROUND CAP ON THE RIGHT.",
            "",
            "THIS IS WHAT EVERY DASHBOARD LAYOUT",
            "USES TODAY.")):
        canvas.text(body.x + 1, body.y + 1 + index, line, foreground=TEXT)

    # 2. The same panel mirrored -- rail on the right, caps on the left.
    facing_right = Panel(
        rect=right,
        title="RIGHT FACING",
        color=PERIWINKLE,
        style=PanelStyle.BRACKET,
        facing="right",
        rail_width=8,
        chips=(Chip("02-MIRRORED", LILAC, ChipStyle.COLOR),),
        rail_blocks=(RailBlock("HELM", ORANGE, 1.6),
                     RailBlock("OPS", LILAC, 2.0),
                     RailBlock("ENG", SAGE, 1.4),
                     RailBlock("TAC", GOLD, 2.0)),
        content_gap=2,
    )
    body = facing_right.draw(painter)
    for index, line in enumerate((
            "THE MIRROR. SAME FRAME, REFLECTED:",
            "ELBOW AND RAIL ON THE RIGHT, CAPS",
            "ON THE LEFT.",
            "",
            "gen_swoops.py ALREADY DREW BOTH",
            "FACINGS OF BOTH SHAPES, SO THIS IS",
            "A CHOICE OF ASSET, NOT NEW ART.")):
        canvas.text(body.x + 1, body.y + 1 + index, line, foreground=TEXT)

    # 3. Pills -- capped at both ends -- down the middle of the right panel.
    pill_row = body.y + 9
    canvas.text(body.x + 1, pill_row, "PILLS — CAPPED BOTH ENDS",
                foreground=PERIWINKLE)
    for index, (label, color) in enumerate((
            ("14 SENSORS", GOLD), ("07 COMMS", LILAC),
            ("22 ROUTING", SKY), ("03 ALERT", ORANGE))):
        if pill_row + 2 + index >= body.bottom:
            break
        draw_pill(painter, body.x + 1, pill_row + 2 + index,
                  min(26, body.width - 2), color, rows=1, label=label)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--hold", action="store_true",
                        help="keep the frame on screen until interrupted")
    parser.add_argument("--size", default=None, metavar="COLUMNSxROWS")
    arguments = parser.parse_args()

    if arguments.size:
        columns, rows = arguments.size.lower().split("x")
        os.environ["COLUMNS"], os.environ["LINES"] = columns, rows

    columns, rows = terminal_size()
    canvas = Canvas(columns, rows)
    canvas.fill(canvas.rect, background=CANVAS)
    cell = probe_cell_size()
    painter = Painter(canvas, AssetLibrary(cell), ImageTransmitter())
    compose(canvas, painter)

    sys.stdout.write(enter_full_screen())
    sys.stdout.write(painter.transmissions() + frame(canvas))
    sys.stdout.flush()
    try:
        while arguments.hold:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
    finally:
        sys.stdout.write(leave_full_screen())
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
