"""Data drawn as images rather than as cells.

The repo's rule is that flat runs are terminal cells and *curves are PNGs*. An
orbit is a curve, so an orrery belongs here rather than being stippled out of
punctuation -- a ring approximated by dots at one character per cell reads as a
dotted line, not as an orbit.

Unlike ``assets.py``, nothing here is cached by filename. These images change
whenever their data does, so they are drawn on demand and handed to
``ImageTransmitter.dynamic_transmission``, which re-sends only when the bytes
actually differ.

Everything is drawn supersampled and downsampled once at the end. PIL's ellipse
outlines are hard-aliased, and an aliased circle next to kitty's smoothly
rendered elbow PNGs looks like a mistake.

Images are produced at exactly ``columns * cell_width`` by ``rows * cell_height``
pixels. Any other size makes kitty aspect-fit and inset the result.
"""
from __future__ import annotations

import glob
import io
import math
import os
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

from PIL import Image, ImageDraw, ImageFont

from .palette import Color

#: Radius of the ring drawn around a planet that has a moon, as a multiple of
#: the planet's own marker radius. The satellite is centred on this exact
#: circle, so the ring reads as the moon's orbit rather than as decoration.
SATELLITE_ORBIT_SCALE = 1.75

#: Supersample factor. Three is enough to hide the stair-stepping on a thin ring
#: without making the intermediate bitmap large enough to matter.
SUPERSAMPLE = 3

#: Fonts to try for plain text labels, best first. If none load, labels are
#: skipped rather than drawn in PIL's unscalable default bitmap font, which at
#: these pixel sizes is illegible.
FONT_CANDIDATES = (
    "/System/Library/Fonts/Supplemental/Futura.ttc",
    "/System/Library/Fonts/HelveticaNeue.ttc",
    "/System/Library/Fonts/Menlo.ttc",
    "/System/Library/Fonts/SFNSMono.ttf",
    "/Library/Fonts/Arial.ttf",
)

#: Astronomical symbols, by body. Coverage across installed fonts is uneven and
#: splits by how recently the codepoint was added to Unicode:
#:
#: * planets and Pluto (U+263F..U+2647) are in hundreds of fonts
#: * Ceres, Pallas, Juno (U+26B3..U+26B5) are in Nerd-Font-patched families and
#:   STIX Two Math, but not in Apple's system fonts
#: * Eris (U+2BF0, Unicode 11) and Haumea/Makemake/Gonggong/Quaoar/Orcus
#:   (U+1F77B..U+1F77F, Unicode 15) are in almost nothing yet -- Noto Sans
#:   Symbols 2 is the font that carries both blocks
#:
#: Which is why fonts are resolved per glyph rather than once for the whole
#: image: no single installed font draws all of these, and a body whose symbol
#: nothing can render falls back to letters instead of showing a tofu box.
SYMBOLS: Dict[str, str] = {
    "SUN": "☉",
    "MERCURY": "☿", "VENUS": "♀", "EARTH": "♁", "MARS": "♂",
    "JUPITER": "♃", "SATURN": "♄", "URANUS": "♅",
    "NEPTUNE": "♆",
    "MOON": "☾", "LUNA": "☾",
    "PLUTO": "♇", "CERES": "⚳", "PALLAS": "⚴",
    "JUNO": "⚵", "VESTA": "⚶",
    "ERIS": "⯰",
    "HAUMEA": "\U0001f77b", "MAKEMAKE": "\U0001f77c",
    "GONGGONG": "\U0001f77d", "QUAOAR": "\U0001f77e", "ORCUS": "\U0001f77f",
}

#: Letters to fall back to when no installed font draws a body's symbol. Two
#: characters, because one is ambiguous across Mercury/Mars/Makemake and the
#: three M-named trans-Neptunians.
SYMBOL_FALLBACKS: Dict[str, str] = {
    "ERIS": "ER", "HAUMEA": "HA", "MAKEMAKE": "MK",
    "GONGGONG": "GG", "QUAOAR": "QU", "ORCUS": "OR",
    "CERES": "CE", "PALLAS": "PA", "JUNO": "JU", "VESTA": "VE",
}

#: Filename fragments of fonts worth trying for symbols, best first. Globbed
#: rather than hard-pathed so a font installed after this was written -- Noto
#: Sans Symbols 2 in particular -- is picked up with no code change.
SYMBOL_FONT_PATTERNS = (
    "NotoSansSymbols2*",
    "NotoSansSymbols*",
    "STIXTwoMath*",
    "Symbola*",
    "DejaVuSans*",
)

SYMBOL_FONT_ROOTS = (
    os.path.expanduser("~/Library/Fonts"),
    "/Library/Fonts",
    "/System/Library/Fonts",
    "/System/Library/Fonts/Supplemental",
    "/opt/homebrew/share/fonts",
)

#: Tried after the globbed patterns above; these carry the older symbols.
SYMBOL_FONT_FALLBACK_PATHS = (
    "/System/Library/Fonts/Apple Symbols.ttf",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/System/Library/Fonts/Menlo.ttc",
)

_font_cache: Dict[int, Optional[ImageFont.FreeTypeFont]] = {}
_symbol_font_cache: Dict[Tuple[str, int], Optional[ImageFont.FreeTypeFont]] = {}
_symbol_font_paths: Optional[List[str]] = None


def load_font(size: int) -> Optional[ImageFont.FreeTypeFont]:
    if size in _font_cache:
        return _font_cache[size]
    font = None
    for path in FONT_CANDIDATES:
        try:
            font = ImageFont.truetype(path, size)
            break
        except (OSError, ValueError):
            continue
    _font_cache[size] = font
    return font


def symbol_font_paths() -> List[str]:
    """Every font file worth asking about a symbol, in preference order."""
    global _symbol_font_paths
    if _symbol_font_paths is not None:
        return _symbol_font_paths
    found: List[str] = []
    for pattern in SYMBOL_FONT_PATTERNS:
        for root in SYMBOL_FONT_ROOTS:
            for extension in ("ttf", "otf", "ttc", "otc"):
                found.extend(sorted(glob.glob(
                    os.path.join(root, "**", "%s.%s" % (pattern, extension)),
                    recursive=True)))
    found.extend(SYMBOL_FONT_FALLBACK_PATHS)
    # Nerd-Font-patched families carry the asteroid symbols; take them last and
    # only one of them, since there are hundreds of weights installed.
    for root in SYMBOL_FONT_ROOTS:
        matches = sorted(glob.glob(
            os.path.join(root, "**", "*NF-Regular.otf"), recursive=True))
        if matches:
            found.append(matches[0])
            break
    seen, ordered = set(), []
    for path in found:
        if path not in seen and os.path.exists(path):
            seen.add(path)
            ordered.append(path)
    _symbol_font_paths = ordered
    return ordered


def _renders(font: ImageFont.FreeTypeFont, character: str) -> bool:
    """Whether ``font`` actually draws ``character`` rather than a blank or tofu.

    Compared against the mask for an unassigned private-use codepoint: a font
    that lacks a glyph draws its .notdef for both, so an identical bitmap means
    the character is missing. A blank mask means missing too.
    """
    try:
        mask = font.getmask(character, mode="L")
        if mask.size[0] == 0:
            return False
        drawn = bytes(mask)
        if not any(drawn):
            return False
        return drawn != bytes(font.getmask("\U000F0000", mode="L"))
    except Exception:  # noqa: BLE001 - a broken font must not stop the plot
        return False


def symbol_font(character: str, size: int) -> Optional[ImageFont.FreeTypeFont]:
    """The first installed font that really draws ``character``, or ``None``."""
    key = (character, size)
    if key in _symbol_font_cache:
        return _symbol_font_cache[key]
    chosen = None
    for path in symbol_font_paths():
        for index in (0, 1, 2, 3):
            try:
                candidate = ImageFont.truetype(path, size, index=index)
            except (OSError, ValueError):
                break
            if _renders(candidate, character):
                chosen = candidate
                break
            if not path.lower().endswith((".ttc", ".otc")):
                break
        if chosen is not None:
            break
    _symbol_font_cache[key] = chosen
    return chosen


def clear_font_cache() -> None:
    """Forget resolved fonts, so a newly installed one is picked up."""
    global _symbol_font_paths
    _symbol_font_paths = None
    _symbol_font_cache.clear()
    _font_cache.clear()


def body_glyph(name: str, size: int):
    """``(text, font)`` to draw on a body's marker.

    Prefers the astronomical symbol; falls back to letters in a text font when no
    installed font has the codepoint. Returns ``(None, None)`` if even that fails.
    """
    symbol = SYMBOLS.get(name)
    if symbol:
        font = symbol_font(symbol, size)
        if font is not None:
            return (symbol, font)
    fallback = SYMBOL_FALLBACKS.get(name, name[:2])
    text_font = load_font(int(size * 0.62))
    if text_font is None:
        return (None, None)
    return (fallback, text_font)


def _rgba(color: Color, alpha: int = 255) -> Tuple[int, int, int, int]:
    return (color[0], color[1], color[2], alpha)


class LogarithmicRadius:
    """Maps an orbital radius in au onto a plot radius in pixels.

    Drawn to scale, Neptune sits thirty times further out than Earth, so any plot
    wide enough to show Neptune puts the four inner planets inside the sun's own
    marker. Compressing logarithmically keeps every orbit distinguishable. The
    mapping is monotonic, so the *ordering* is always truthful even though the
    spacing is not -- which is the honest trade for a plot this small.
    """

    def __init__(self, smallest: float, largest: float,
                 inner_pixels: float, outer_pixels: float) -> None:
        self.low = math.log10(max(1e-3, smallest))
        self.high = math.log10(max(1e-3, largest))
        self.span = (self.high - self.low) or 1.0
        self.inner = inner_pixels
        self.outer = outer_pixels

    def __call__(self, distance_au: float) -> float:
        fraction = (math.log10(max(1e-3, distance_au)) - self.low) / self.span
        return self.inner + fraction * (self.outer - self.inner)


def square_cell_box(rows: int, cell_width: int, cell_height: int) -> int:
    """Columns that make a ``rows``-tall cell box come out square in pixels.

    Terminal cells are roughly twice as tall as wide, so a square picture needs
    about twice as many columns as rows. Getting this wrong is what makes a
    photograph of the moon render as an ellipse.
    """
    return max(1, int(round(rows * cell_height / float(cell_width))))


def render_fitted_image(
    source: "os.PathLike[str] | str",
    pixel_width: int,
    pixel_height: int,
) -> bytes:
    """Scale an image file to exactly ``pixel_width`` x ``pixel_height``.

    Aspect ratio is preserved and the result centred on a transparent field, so a
    square photograph in a non-square cell box keeps its shape instead of being
    stretched. The output is the exact size asked for, because kitty aspect-fits
    anything else and insets it by a pixel or two.
    """
    if pixel_width <= 0 or pixel_height <= 0:
        return b""
    try:
        with Image.open(source) as opened:
            picture = opened.convert("RGBA")
    except (OSError, ValueError):
        return b""

    scale = min(pixel_width / picture.width, pixel_height / picture.height)
    size = (max(1, int(picture.width * scale)), max(1, int(picture.height * scale)))
    picture = picture.resize(size, Image.LANCZOS)

    canvas = Image.new("RGBA", (pixel_width, pixel_height), (0, 0, 0, 0))
    canvas.paste(picture,
                 ((pixel_width - size[0]) // 2, (pixel_height - size[1]) // 2))
    buffer = io.BytesIO()
    canvas.save(buffer, format="PNG")
    return buffer.getvalue()


def draw_centred_text(
    draw: ImageDraw.ImageDraw,
    x: float,
    y: float,
    text: str,
    font: ImageFont.FreeTypeFont,
    color: Color,
) -> None:
    """Draw ``text`` with its INK centred on ``(x, y)``.

    PIL's ``anchor="mm"`` centres on the font's own vertical midpoint -- halfway
    between ascender and descender -- which is not where the glyph's ink sits.
    For ordinary text the difference is invisible, but these are symbols drawn
    from several different fonts onto a small disc, and the error varies by font:
    measured at 60px, Noto Sans Symbols 2 puts the sun, Eris, Haumea and Makemake
    about eight pixels high, STIX Two Math puts Saturn and Neptune four high, and
    most of the other planets land within a pixel.

    Measuring the ink box and correcting by its centre fixes every glyph at once,
    including any font installed later, which per-glyph nudges would not.
    """
    box = draw.textbbox((0, 0), text, font=font, anchor="mm")
    offset_x = (box[0] + box[2]) / 2.0
    offset_y = (box[1] + box[3]) / 2.0
    draw.text((x - offset_x, y - offset_y), text, font=font,
              fill=_rgba(color), anchor="mm")


def _draw_body(
    draw: ImageDraw.ImageDraw,
    x: float,
    y: float,
    radius: float,
    color: Color,
    name: str,
    glyph_size: int,
    marker_color: Color,
) -> None:
    """A filled disc with the body's symbol centred on it in the void color.

    The symbol goes *on* the marker rather than beside it: a label offset along
    the radius drifts over its own orbit ring as the body moves, and at this size
    there is not room for both a dot and a word.
    """
    draw.ellipse([x - radius, y - radius, x + radius, y + radius],
                 fill=_rgba(color))
    text, font = body_glyph(name, glyph_size)
    if text and font is not None:
        draw_centred_text(draw, x, y, text, font, marker_color)


def render_orrery(
    pixel_width: int,
    pixel_height: int,
    bodies: Sequence[Tuple[str, float, float]],
    colors: Dict[str, Color],
    ring_color: Color,
    sun_color: Color,
    marker_color: Color = (0, 0, 0),
    satellites: Sequence[Tuple[str, str, float]] = (),
    highlight: Iterable[str] = ("EARTH",),
) -> bytes:
    """Draw a top-down solar system and return PNG bytes.

    ``bodies`` is ``(name, heliocentric_longitude_degrees, distance_au)``, and
    ``satellites`` is ``(name, parent_name, longitude_around_parent_degrees)``.
    The sun is drawn at the centre and is not part of either sequence.

    Satellites are the one deliberate lie in the picture. The moon's orbit is a
    four-hundredth of Earth's, so at any size a terminal pane offers it lands
    inside Earth's own marker; it is drawn at a fixed offset instead, in the true
    direction. The direction is what sets the phase, so the schematic keeps the
    part that carries meaning and drops the part that cannot be shown.

    Circles are true circles in pixel space. The cell grid is about twice as tall
    as it is wide, but that only matters when *positioning by cell*; here the unit
    is the pixel, so no aspect correction belongs in the geometry.
    """
    if pixel_width <= 0 or pixel_height <= 0 or not bodies:
        return b""

    scale = SUPERSAMPLE
    width, height = pixel_width * scale, pixel_height * scale
    image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    centre_x, centre_y = width / 2.0, height / 2.0
    margin = max(8.0 * scale, min(width, height) * 0.06)
    outer = min(centre_x, centre_y) - margin
    if outer <= 0:
        return b""
    # Hold the innermost orbit off the sun so Mercury never lands on its marker.
    inner = max(outer * 0.18, 8.0 * scale)

    distances = [distance for _, _, distance in bodies]
    radius_for = LogarithmicRadius(min(distances), max(distances), inner, outer)

    ring_width = max(1, int(round(1.1 * scale)))
    for _, _, distance in bodies:
        radius = radius_for(distance)
        draw.ellipse(
            [centre_x - radius, centre_y - radius,
             centre_x + radius, centre_y + radius],
            outline=_rgba(ring_color, 150), width=ring_width,
        )

    # Markers have to be big enough to carry a glyph, which is what sets the
    # scale of everything drawn on top of the rings.
    glyph_size = max(7, int(round(min(width, height) / 30)))
    marker = glyph_size * 0.78

    sun_radius = max(marker * 1.1, inner * 0.42)
    _draw_body(draw, centre_x, centre_y, sun_radius, sun_color, "SUN",
               int(sun_radius * 1.5), marker_color)

    highlighted = {name.upper() for name in highlight}
    parents_of_satellites = {parent for _, parent, _ in satellites}
    placed: Dict[str, Tuple[float, float, float, float, float]] = {}

    for name, longitude, distance in bodies:
        radius = radius_for(distance)
        angle = math.radians(longitude)
        # Screen y grows downward; ecliptic longitude grows counter-clockwise.
        x = centre_x + math.cos(angle) * radius
        y = centre_y - math.sin(angle) * radius
        body_color = colors.get(name, ring_color)

        size = marker * (1.12 if name in highlighted else 1.0)
        if name in highlighted or name in parents_of_satellites:
            # A ring around the planet. For the observer's own planet it reads as
            # "you are here"; for a planet with a moon it IS the moon's orbit,
            # because the satellite below is placed centred on this exact radius.
            # Drawing a circle around Earth and then putting the moon inside it
            # is what made the moon look like it had missed its own orbit.
            halo = size * SATELLITE_ORBIT_SCALE
            draw.ellipse([x - halo, y - halo, x + halo, y + halo],
                         outline=_rgba(body_color, 200), width=max(1, scale))
        _draw_body(draw, x, y, size, body_color, name,
                   int(glyph_size * (1.12 if name in highlighted else 1.0)),
                   marker_color)
        placed[name] = (x, y, size, radius, angle)

    for name, parent, longitude in satellites:
        anchor = placed.get(parent)
        if anchor is None:
            continue
        parent_x, parent_y, parent_size, parent_radius, parent_angle = anchor
        satellite_size = marker * 0.46

        # Centred on the ring drawn around the parent -- that ring is the moon's
        # orbit, so the moon belongs ON it, not tucked inside.
        #
        # The step is taken ALONG the parent's heliocentric ring rather than
        # radially away from the sun, which keeps the moon's distance from the
        # sun equal to Earth's and leaves every orbit circle intact. Stepping
        # radially would cross into Venus's ring: the radii are logarithmically
        # compressed, so neighbouring orbits sit closer together than a marker is
        # wide.
        #
        # Which side it sits on is real: the moon's geocentric direction is
        # projected onto the tangent of Earth's orbit, so a leading moon is drawn
        # ahead of Earth and a trailing one behind.
        separation = parent_size * SATELLITE_ORBIT_SCALE
        arc = separation / max(1.0, parent_radius)
        tangential = math.cos(math.radians(longitude)) * -math.sin(parent_angle) \
            + math.sin(math.radians(longitude)) * math.cos(parent_angle)
        angle = parent_angle + (arc if tangential >= 0 else -arc)

        x = centre_x + math.cos(angle) * parent_radius
        y = centre_y - math.sin(angle) * parent_radius
        _draw_body(draw, x, y, satellite_size, colors.get(name, ring_color),
                   name, int(glyph_size * 0.46), marker_color)

    image = image.resize((pixel_width, pixel_height), Image.LANCZOS)
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()
