"""The render loop and the command line.

One frame is: refresh whatever is due, draw the outer frame, then each panel and
its widget, then write the image transmissions followed by the cells in a single
``write`` call.

Single-write matters. A dashboard painted pane by pane tears visibly, and the
image escapes have to land before the placeholder cells that reference them --
batching both into one write makes the ordering a property of the string rather
than of how the terminal schedules reads.
"""
from __future__ import annotations

import argparse
import os
import signal
import sys
import time
from typing import List, Optional, TextIO

from . import layouts
from .assets import AssetLibrary, CellSize, probe_cell_size
from .canvas import (Canvas, enter_full_screen, frame, leave_full_screen,
                     restore)
from .geometry import terminal_size
from .images import ImageTransmitter
from .interaction import Button, Click, HitMap
from .palette import CANVAS
from .segments import Painter
from .terminal_input import TerminalInput


class Dashboard:
    """Owns the layout, the canvas, and the terminal for the duration of a run."""

    def __init__(
        self,
        layout: layouts.Layout,
        stream: Optional[TextIO] = None,
        cell_size: Optional[CellSize] = None,
        allow_images: bool = True,
    ) -> None:
        self.layout = layout
        self.stream = stream if stream is not None else sys.stdout
        self.cell_size = cell_size or probe_cell_size()
        self.allow_images = allow_images
        self.assets = AssetLibrary(self.cell_size)
        self.images = ImageTransmitter(self.stream)
        self.size = (0, 0)
        self.canvas: Optional[Canvas] = None
        self._resized = True
        #: Clickable regions, rebuilt by every render.
        self.hits = HitMap()
        self.running = True

    # -- lifecycle ---------------------------------------------------------

    def note_resize(self, *_: object) -> None:
        """Mark the terminal as needing re-measurement.

        Safe to call from a signal handler: it only sets a flag. Re-probing the
        cell size and regenerating PNGs from inside ``SIGWINCH`` would run image
        generation on the signal stack.
        """
        self._resized = True

    def _ensure_canvas(self) -> Canvas:
        columns, rows = terminal_size()
        if self.canvas is None or self._resized or (columns, rows) != self.size:
            probed = probe_cell_size()
            if probed != self.cell_size:
                # Font zoom or a display change: the cached PNGs are the wrong
                # pixel size now, and kitty would aspect-fit them with an inset.
                self.cell_size = probed
                self.assets = AssetLibrary(self.cell_size)
                self.images.forget()
            self.size = (columns, rows)
            self.canvas = Canvas(columns, rows)
            self._resized = False
        return self.canvas

    # -- one frame ---------------------------------------------------------

    def refresh(self, force: bool = False, wait: bool = False) -> None:
        widgets = self.layout.all_widgets()
        for widget in widgets:
            if force:
                widget._last_refresh = 0.0
            widget.refresh_if_due()
        if wait:
            # A single-frame render has no later frame to show late data in, so
            # it waits for the background fetches it just started.
            for widget in widgets:
                widget.wait_for_refresh()

    def compose(self) -> str:
        """Build one frame and return it as a string, without writing it."""
        canvas = self._ensure_canvas()
        canvas.fill(canvas.rect, background=CANVAS)
        self.hits.clear()
        painter = Painter(canvas, self.assets, self.images, hits=self.hits,
                          images_enabled=self.allow_images)

        screen = canvas.rect
        if screen.width < 40 or screen.height < 16:
            canvas.text(0, 0, "TERMINAL TOO SMALL FOR LCARS DASHBOARD")
            canvas.text(0, 1, "NEED AT LEAST 40x16, HAVE %dx%d"
                        % (screen.width, screen.height))
            return frame(canvas)

        content = self.layout.draw_frame(painter, screen)

        for placement in self.layout.place(content):
            placement.draw(painter)

        transmissions = painter.transmissions() if self.allow_images else ""
        return transmissions + frame(canvas)

    def switch_layout(self, name: str) -> bool:
        """Swap the displayed layout. Returns whether anything changed.

        Layouts were always data -- built by name, holding their own widgets --
        so switching is an assignment. The only care needed is refreshing the new
        layout's widgets, which have never been asked for data before.
        """
        if name == self.layout.name:
            return False
        self.layout = layouts.build(name)
        self.layout.on_navigate = self.switch_layout
        self.refresh(force=True)
        return True

    def render_once(self) -> None:
        self.stream.write(self.compose())
        self.stream.flush()

    # -- loops -------------------------------------------------------------

    def run(self, interval: float = 1.0, frames: Optional[int] = None,
            full_screen: bool = True, hold: bool = False,
            interactive: bool = True, mouse: bool = True) -> None:
        """Redraw on a timer, responding to input between frames.

        ``hold`` keeps the last frame up after the frame budget runs out. That is
        what a screenshot needs: a dashboard that exits restores the screen
        underneath it, and one that exits on the normal screen gets its top rows
        scrolled away by the next shell prompt.

        ``interactive`` puts the terminal in cbreak mode and enables mouse
        reporting. It is off for captures, where there is nobody to click and
        where leaving the terminal in a modified state would be a hazard.
        """
        if not interactive:
            self._run_timed(interval, frames, full_screen, hold)
            return

        with TerminalInput(mouse=mouse, on_exit=self._restore) as source:
            self._run_interactive(source, interval, frames, full_screen, hold)

    def _run_timed(self, interval: float, frames: Optional[int],
                   full_screen: bool, hold: bool) -> None:
        """The non-interactive path: draw, sleep, repeat."""
        if full_screen:
            self.stream.write(enter_full_screen())
            self.stream.flush()
        drawn = 0
        try:
            while frames is None or drawn < frames:
                self.refresh()
                self.render_once()
                drawn += 1
                if frames is not None and drawn >= frames:
                    break
                time.sleep(interval)
            while hold:
                time.sleep(3600)
        except KeyboardInterrupt:
            pass
        finally:
            self.stream.write(leave_full_screen() if full_screen else restore())
            self.stream.flush()

    def _run_interactive(self, source: TerminalInput, interval: float,
                         frames: Optional[int], full_screen: bool,
                         hold: bool) -> None:
        """Draw, then wait for input *or* the next tick, whichever comes first.

        The wait is the whole point: a plain sleep would swallow clicks for up to
        a second, and under ``hold`` -- a sleep of an hour -- forever.
        """
        if full_screen:
            self.stream.write(enter_full_screen())
            self.stream.flush()
        drawn = 0
        try:
            while self.running:
                self.refresh()
                self.render_once()
                drawn += 1
                if frames is not None and drawn >= frames and not hold:
                    break

                deadline = time.time() + interval
                redraw = False
                while not redraw and time.time() < deadline:
                    key, click = source.poll(timeout=deadline - time.time())
                    if click is not None:
                        redraw = self.hits.dispatch(click)
                    elif key is not None:
                        redraw = self.handle_key(key)
                    if not self.running:
                        return
        except KeyboardInterrupt:
            pass
        finally:
            self.stream.write(leave_full_screen() if full_screen else restore())
            self.stream.flush()

    def handle_key(self, key) -> bool:
        """Keyboard shortcuts. Returns whether to redraw immediately.

        Digits select a layout by position, matching the order the navigation
        rail draws them, so the keyboard and the mouse address the same list.
        """
        if key in ("q", "Q") or key.code == 3:  # 3 is ^C under cbreak
            self.running = False
            return False
        if key in ("r", "R"):
            self.refresh(force=True)
            return True
        if str(key).isdigit():
            index = int(str(key)) - 1
            names = layouts.names()
            if 0 <= index < len(names):
                return self.switch_layout(names[index])
        return False

    def _restore(self) -> None:
        """Put the screen back. Safe to call more than once."""
        try:
            self.stream.write(leave_full_screen())
            self.stream.flush()
        except Exception:  # noqa: BLE001 - nothing useful to do while dying
            pass


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="lcars-dashboard",
        description="An LCARS landing dashboard for a kitty pane.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="layouts:\n  " + "\n  ".join(layouts.descriptions()),
    )
    parser.add_argument(
        "-l", "--layout", default=os.environ.get("LCARCAT_LAYOUT", layouts.DEFAULT_LAYOUT),
        choices=layouts.names(),
        help="which arrangement to draw (default: %(default)s)",
    )
    parser.add_argument(
        "-i", "--interval", type=float, default=1.0,
        help="seconds between redraws (default: %(default)s)",
    )
    parser.add_argument(
        "--once", action="store_true",
        help="draw a single frame inline and exit. Note that the shell prompt "
             "printed afterwards will scroll the top rows away -- use --hold for "
             "a frame that stays put",
    )
    parser.add_argument(
        "--frames", type=int, default=None,
        help="draw this many frames, then stop redrawing",
    )
    parser.add_argument(
        "--hold", action="store_true",
        help="after the frame budget, keep the last frame on screen until "
             "interrupted; this is what screenshots want",
    )
    parser.add_argument(
        "--no-full-screen", action="store_true",
        help="draw on the normal screen instead of the alternate screen buffer",
    )
    parser.add_argument(
        "--no-images", action="store_true",
        help="skip the curve PNGs and draw chrome from cells alone "
             "(for terminals without the kitty graphics protocol)",
    )
    parser.add_argument(
        "--offline", action="store_true",
        help="do not contact Jira or GitHub; render from cache only",
    )
    parser.add_argument(
        "--size", metavar="COLUMNSxROWS", default=None,
        help="render at a fixed size instead of measuring the terminal",
    )
    parser.add_argument(
        "--no-interactive", action="store_true",
        help="do not read the keyboard or mouse; just redraw on the timer",
    )
    parser.add_argument(
        "--no-mouse", action="store_true",
        help="keyboard only. Mouse reporting takes over click-to-select in the "
             "terminal (hold shift to bypass it), so this turns it off",
    )
    parser.add_argument(
        "--list-layouts", action="store_true",
        help="print the available layouts and exit",
    )
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    arguments = build_parser().parse_args(argv)

    if arguments.list_layouts:
        for line in layouts.descriptions():
            print(line)
        return 0

    if arguments.size:
        try:
            columns, rows = arguments.size.lower().split("x")
            os.environ["COLUMNS"], os.environ["LINES"] = str(int(columns)), str(int(rows))
        except ValueError:
            print("--size wants COLUMNSxROWS, for example 200x50", file=sys.stderr)
            return 2

    layout = layouts.build(arguments.layout)

    if arguments.offline:
        for widget in layout.all_widgets():
            if hasattr(widget, "allow_live"):
                widget.allow_live = False

    dashboard = Dashboard(layout, allow_images=not arguments.no_images)

    # A one-shot render has nobody to click it, and putting the terminal into
    # cbreak plus mouse reporting for a single frame is a hazard with no upside.
    interactive = not (arguments.no_interactive or arguments.once
                       or arguments.hold or arguments.frames is not None)
    if interactive:
        layout.on_navigate = dashboard.switch_layout

    try:
        signal.signal(signal.SIGWINCH, dashboard.note_resize)
    except (AttributeError, ValueError):
        pass  # not every platform or thread can take the handler

    dashboard.refresh(force=True, wait=True)

    if arguments.once and not arguments.hold:
        # Inline single frame: no alternate screen, because switching to it and
        # straight back would leave nothing behind.
        dashboard.render_once()
        return 0

    dashboard.run(
        interval=arguments.interval,
        frames=1 if arguments.once else arguments.frames,
        full_screen=not arguments.no_full_screen,
        hold=arguments.hold,
        interactive=interactive,
        mouse=not arguments.no_mouse,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
