"""Curve PNGs for the dashboard, generated on demand at the live cell size.

The dashboard needs elbows and caps in several colors, which the pre-built
``assets/`` directory does not carry -- it holds one periwinkle set for the zsh
prompt. Rather than duplicate the drawing code, this module imports
``generate/gen_swoops.py`` and calls the same ``make_swoop``/``make_cap``
functions, writing into a cache keyed by the asset filename. The filename encodes
every input that changes the image (kind, orientation, facing, color, size in
cells, size in pixels), so a cache hit is a guarantee that the PNG on disk is the
one being asked for.

Pixel dimensions must equal ``columns * cell_width`` by ``rows * cell_height``
exactly. kitty aspect-fits any mismatch into the cell box and centers it, which
shows up as a one- or two-pixel seam between the curve and the flat cells beside
it. That is why the cell size is probed rather than assumed.
"""
from __future__ import annotations

import importlib.util
import os
import select
import sys
import termios
import tty
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Optional, Tuple

from .palette import Color, to_hex

REPO_ROOT = Path(__file__).resolve().parent.parent
GENERATOR = REPO_ROOT / "generate" / "gen_swoops.py"

CACHE_DIR = Path(
    os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")
) / "lcarcat" / "dashboard-assets"

# kitty's cell size at font_size 18 Fantasque Sans Mono -- the metrics the
# checked-in assets were built at. Used only when the probe cannot run.
FALLBACK_CELL_WIDTH = 19
FALLBACK_CELL_HEIGHT = 38


@dataclass(frozen=True)
class CellSize:
    width: int
    height: int

    @property
    def is_probed(self) -> bool:
        return (self.width, self.height) != (FALLBACK_CELL_WIDTH, FALLBACK_CELL_HEIGHT)


def probe_cell_size(timeout: float = 0.4) -> CellSize:
    """Ask the terminal for its cell size in pixels via CSI 16t.

    Reply format is ``ESC [ 6 ; height ; width t``. kitty answers in device pixels
    on HiDPI, which is the same unit its graphics renderer uses internally, so the
    numbers feed straight into PNG generation with no scaling.

    Falls back to the known-good metrics when there is no terminal to ask, when the
    terminal does not answer in time, or when the reply does not parse -- a stray
    keystroke mixed into the response is worse than a default, so anything that
    does not match the exact shape is rejected.
    """
    if os.environ.get("LCARCAT_CELL_SIZE"):
        try:
            width, height = os.environ["LCARCAT_CELL_SIZE"].split("x")
            return CellSize(int(width), int(height))
        except ValueError:
            pass

    try:
        terminal = open("/dev/tty", "r+b", buffering=0)
    except OSError:
        return CellSize(FALLBACK_CELL_WIDTH, FALLBACK_CELL_HEIGHT)

    with terminal:
        fileno = terminal.fileno()
        if not os.isatty(fileno):
            return CellSize(FALLBACK_CELL_WIDTH, FALLBACK_CELL_HEIGHT)
        saved = termios.tcgetattr(fileno)
        try:
            tty.setraw(fileno)
            terminal.write(b"\x1b[16t")
            reply = bytearray()
            while len(reply) < 32:
                if not select.select([fileno], [], [], timeout)[0]:
                    break
                chunk = os.read(fileno, 1)
                if not chunk:
                    break
                reply += chunk
                if chunk == b"t":
                    break
        except (OSError, termios.error):
            return CellSize(FALLBACK_CELL_WIDTH, FALLBACK_CELL_HEIGHT)
        finally:
            try:
                termios.tcsetattr(fileno, termios.TCSADRAIN, saved)
            except termios.error:
                pass

    text = reply.decode("ascii", "ignore")
    if text.startswith("\x1b[6;") and text.endswith("t"):
        fields = text[4:-1].split(";")
        if len(fields) == 2 and all(f.isdigit() for f in fields):
            height, width = int(fields[0]), int(fields[1])
            if 4 <= width <= 200 and 4 <= height <= 400:
                return CellSize(width, height)
    return CellSize(FALLBACK_CELL_WIDTH, FALLBACK_CELL_HEIGHT)


def _load_generator():
    """Import gen_swoops.py by path -- it lives outside any package."""
    spec = importlib.util.spec_from_file_location("lcarcat_gen_swoops", GENERATOR)
    if spec is None or spec.loader is None:
        raise ImportError("cannot load the PNG generator at %s" % GENERATOR)
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("lcarcat_gen_swoops", module)
    spec.loader.exec_module(module)
    return module


_generator = None


def generator():
    global _generator
    if _generator is None:
        _generator = _load_generator()
    return _generator


@dataclass(frozen=True)
class Asset:
    """A generated PNG plus the cell-grid size kitty should place it at."""

    path: Path
    columns: int
    rows: int


class AssetLibrary:
    """Generates and caches the curve PNGs a dashboard asks for.

    One library serves a whole render: it memoises by filename so a layout drawing
    twenty periwinkle elbows generates one PNG and transmits one image.
    """

    def __init__(self, cell_size: CellSize, cache_dir: Optional[Path] = None) -> None:
        self.cell_size = cell_size
        self.cache_dir = cache_dir or CACHE_DIR
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self._by_name: Dict[str, Asset] = {}

    # -- the shapes a dashboard uses ---------------------------------------

    def elbow(
        self,
        color: Color,
        orientation: str,
        facing: str = "left",
        columns: int = 5,
        bar_rows: int = 2,
        stem_rows: int = 1,
        stem_columns: int = 1,
        corner_background: Optional[Color] = None,
    ) -> Asset:
        """A rounded outer corner plus inner fillet, where a bar turns into a stem.

        ``orientation`` is ``top`` (bar above, stem descending) or ``bottom``.
        ``facing`` is the edge that carries the stem.
        """
        swoops = generator()
        background_hex = to_hex(corner_background) if corner_background else None
        name = swoops.asset_name(
            "elbow", to_hex(color), columns, bar_rows + stem_rows,
            self.cell_size.width, self.cell_size.height,
            orient=orientation, facing=facing, bg=background_hex,
        )
        # A non-default stem width or bar height changes the drawing but not the
        # name that asset_name() produces, so fold them in to keep the cache honest.
        if (bar_rows, stem_columns) != (2, 1):
            name = name.replace(".png", "-bar%d-stem%d.png" % (bar_rows, stem_columns))

        def draw(path: Path) -> None:
            swoops.make_swoop(
                str(path), swoops.hex_rgba(to_hex(color)), columns, stem_rows,
                self.cell_size.width, self.cell_size.height,
                flip=(orientation == "bottom"),
                mirror=(facing == "right"),
                bar_rows=bar_rows, stem_cols=stem_columns,
                corner_bg=swoops.hex_rgba(to_hex(corner_background))
                if corner_background else None,
            )

        return self._cached(name, columns, bar_rows + stem_rows, draw)

    def cap(self, color: Color, rows: int = 2, facing: str = "right") -> Asset:
        """A half-round bar terminator. ``facing`` is the side the curve is on."""
        swoops = generator()
        columns = swoops.round_cap_cols(rows, self.cell_size.width, self.cell_size.height)
        name = swoops.asset_name(
            "cap", to_hex(color), columns, rows,
            self.cell_size.width, self.cell_size.height,
            orient="round", facing=facing,
        )

        def draw(path: Path) -> None:
            swoops.make_cap(
                str(path), swoops.hex_rgba(to_hex(color)), rows,
                self.cell_size.width, self.cell_size.height,
                mirror=(facing == "left"),
            )

        return self._cached(name, columns, rows, draw)

    def cap_columns(self, rows: int = 2) -> int:
        """How wide a cap of ``rows`` height will be, without generating it.

        Layout code needs this before it decides where a bar's flat run ends.
        """
        return generator().round_cap_cols(rows, self.cell_size.width, self.cell_size.height)

    # -- cache -------------------------------------------------------------

    def _cached(self, name: str, columns: int, rows: int, draw) -> Asset:
        cached = self._by_name.get(name)
        if cached is not None:
            return cached
        path = self.cache_dir / name
        if not path.exists() or path.stat().st_size == 0:
            draw(path)
        asset = Asset(path, columns, rows)
        self._by_name[name] = asset
        return asset


def expected_pixels(asset: Asset, cell_size: CellSize) -> Tuple[int, int]:
    """The dimensions a correctly-sized PNG must have, for assertions and tests."""
    return (asset.columns * cell_size.width, asset.rows * cell_size.height)
