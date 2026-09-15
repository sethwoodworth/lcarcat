"""Reading the keyboard and the mouse, without taking over the screen.

``blessed`` supplies the terminal-mode handling and the mouse decoding. What it
deliberately does *not* do is own rendering, which is why it fits: the dashboard
paints its own cell grid and places kitty graphics, so anything that wanted the
screen -- curses, textual, urwid -- would fight it.

Three things are worth knowing about what this does to the terminal.

**Mouse reporting takes over selection.** With SGR mouse mode on, kitty sends
clicks to the application instead of selecting text. Hold shift to get the
terminal's own behaviour back.

**The modes have to be turned off again.** A process that exits without clearing
them leaves the shell emitting escape sequences at every mouse movement.
``blessed``'s context managers handle the ordinary paths, and
:class:`TerminalInput` adds signal handlers for the ones they cannot reach --
a context manager does not run on SIGTERM.

**Coordinates arrive zero-indexed.** blessed converts from the wire format's
one-indexed columns, which happens to match the canvas, so no adjustment is made
here. That is worth stating because the raw escape does not look like that.
"""
from __future__ import annotations

import signal
from contextlib import ExitStack
from typing import Callable, List, Optional

from .interaction import Button, Click

#: Button names as they appear inside blessed's keystroke name, longest first so
#: SCROLL_UP is matched before any shorter substring could be.
_BUTTONS = (
    ("SCROLL_UP", Button.WHEEL_UP),
    ("SCROLL_DOWN", Button.WHEEL_DOWN),
    ("MIDDLE", Button.MIDDLE),
    ("RIGHT", Button.RIGHT),
    ("LEFT", Button.LEFT),
)


def is_mouse(keystroke) -> bool:
    """Whether a keystroke is a mouse report.

    By ``name``, because blessed's DEC-mode path builds mouse keystrokes with no
    keycode: ``Keystroke.code`` is ``None`` for them, so comparing against
    ``Terminal.KEY_MOUSE`` never matches even though the constant exists.
    """
    return (getattr(keystroke, "name", "") or "").upper().startswith("MOUSE")


def to_click(keystroke) -> Optional[Click]:
    """Convert a mouse :class:`~blessed.keyboard.Keystroke` into a :class:`Click`.

    Read from the documented properties -- ``name`` and ``mouse_xy`` -- rather
    than from the event object behind them. ``name`` is a string of the form
    ``MOUSE_LEFT``, ``MOUSE_CTRL_LEFT``, ``MOUSE_SCROLL_UP``,
    ``MOUSE_LEFT_RELEASED``, ``MOUSE_RIGHT_MOTION``.

    ``mouse_xy`` is already zero-indexed, matching the canvas; the wire format's
    columns are one-indexed and blessed has converted them.

    Releases and motion are dropped: the dashboard acts on presses, and
    delivering both halves of a click would fire every handler twice.
    """
    name = (getattr(keystroke, "name", "") or "").upper()
    if not name.startswith("MOUSE"):
        return None
    if name.endswith("_RELEASED") or name.endswith("_MOTION"):
        return None

    x, y = getattr(keystroke, "mouse_xy", (-1, -1))
    if x < 0 or y < 0:
        return None

    button = Button.OTHER
    for token, value in _BUTTONS:
        if token in name:
            button = value
            break

    return Click(
        x=int(x),
        y=int(y),
        button=button,
        shift="SHIFT" in name,
        ctrl="CTRL" in name,
        meta="ALT" in name or "META" in name,
    )


class TerminalInput:
    """Terminal modes and a timed read, as a context manager.

    Used as::

        with TerminalInput(on_exit=dashboard.restore) as source:
            key, click = source.poll(timeout=0.25)

    ``poll`` returns whichever arrived, or ``(None, None)`` when the timeout
    expired -- which is what lets the redraw loop keep its cadence while still
    responding to a click within a fraction of a second.
    """

    def __init__(self, mouse: bool = True,
                 on_exit: Optional[Callable[[], None]] = None) -> None:
        self.mouse = mouse
        self.on_exit = on_exit
        self.terminal = None
        self._stack: Optional[ExitStack] = None
        self._previous_handlers: List = []

    # -- lifecycle ---------------------------------------------------------

    def __enter__(self) -> "TerminalInput":
        import blessed

        self.terminal = blessed.Terminal()
        self._stack = ExitStack()
        self._stack.enter_context(self.terminal.cbreak())
        if self.mouse:
            # clicks only: motion and drag reporting would flood the input
            # stream for a dashboard that has nothing to do with either.
            self._stack.enter_context(self.terminal.mouse_enabled(clicks=True))
        self._install_signal_handlers()
        return self

    def __exit__(self, *exception) -> None:
        self._remove_signal_handlers()
        if self._stack is not None:
            self._stack.close()
            self._stack = None

    def _install_signal_handlers(self) -> None:
        """Restore the terminal on the signals a context manager never sees.

        SIGTERM and SIGHUP unwind nothing by default, so without this a killed
        dashboard leaves mouse reporting and the alternate screen enabled. The
        previous handlers are chained rather than discarded -- something else may
        care about the signal too.
        """
        def handler(signum, frame):
            self.__exit__(None, None, None)
            if self.on_exit is not None:
                self.on_exit()
            for number, previous in self._previous_handlers:
                if number == signum and callable(previous):
                    previous(signum, frame)
                    return
            raise SystemExit(128 + signum)

        for number in (signal.SIGTERM, signal.SIGHUP):
            try:
                self._previous_handlers.append(
                    (number, signal.signal(number, handler)))
            except (ValueError, OSError):
                # Not the main thread, or the platform lacks the signal.
                pass

    def _remove_signal_handlers(self) -> None:
        for number, previous in self._previous_handlers:
            try:
                signal.signal(number, previous)
            except (ValueError, OSError):
                pass
        self._previous_handlers.clear()

    # -- reading -----------------------------------------------------------

    def poll(self, timeout: float):
        """``(key, click)`` -- whichever arrived first, or ``(None, None)``.

        Mouse events are recognised by ``name``, not by ``code``. blessed builds
        them through its DEC-mode path, which constructs the keystroke without a
        keycode at all -- ``code`` is ``None`` and never equals ``KEY_MOUSE``,
        despite that constant existing. Testing ``code`` silently routes every
        click into the keyboard handler, which is a dead-click bug that looks
        exactly like the region map being wrong.
        """
        terminal = self.terminal
        if terminal is None:
            return (None, None)
        key = terminal.inkey(timeout=max(0.0, timeout))
        if not key:
            return (None, None)
        if is_mouse(key):
            # to_click returns None for releases and motion; swallow those
            # rather than letting them fall through as keystrokes.
            return (None, to_click(key))
        return (key, None)
