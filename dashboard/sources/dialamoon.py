"""NASA's Dial-A-Moon: a rendered image of the moon as it looks right now.

``https://svs.gsfc.nasa.gov/api/dialamoon/`` redirects to the current timestamp
and returns that hour's frame from Goddard's Scientific Visualization Studio
lunar animation, plus the numbers behind it.

This gives the dashboard things the local ephemeris cannot compute at all --
libration (the sub-earth point, i.e. which way the moon is tipped), the
sub-solar point, the position angle of the pole, apparent diameter in
arcseconds, and eclipse obscuration. The picture is a real render of the lunar
terrain at the correct phase and libration, not a shaded circle.

Two caches, because the two halves change at different rates and cost different
amounts: the JSON is small and hourly, the image is hundreds of kilobytes and
only needs refetching when the frame number changes.
"""
from __future__ import annotations

import dataclasses
import json
import os
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional

from . import cache

API_URL = "https://svs.gsfc.nasa.gov/api/dialamoon/"
CACHE_NAME = "dialamoon"
IMAGE_CACHE_DIR = cache.CACHE_DIR / "moon-frames"

#: The API publishes one frame an hour, so anything fresher than this is the
#: same picture and the same numbers.
REFRESH_SECONDS = 3600

DEFAULT_TIMEOUT = 12

USER_AGENT = "lcarcat-dashboard (+https://github.com/sethwoodworth/lcarcat)"


@dataclass(frozen=True)
class MoonFrame:
    """One hourly frame: the picture, and the geometry behind it."""

    time: str
    image_url: str
    #: Percent of the disc lit, 0-100.
    phase: float
    #: Days since new moon.
    age: float
    #: Apparent diameter in arcseconds.
    diameter: float
    #: Centre-to-centre distance in kilometres.
    distance: float
    right_ascension_hours: float
    declination: float
    #: Sub-earth point -- the libration. Which face is tipped toward us.
    libration_longitude: float
    libration_latitude: float
    #: Sub-solar point -- where the sun is overhead on the moon.
    subsolar_longitude: float
    subsolar_latitude: float
    #: Position angle of the moon's north pole, degrees east of celestial north.
    position_angle: float
    #: Fraction of the solar disc covered, during an eclipse. Zero almost always.
    obscuration: float
    image_path: Optional[Path] = None
    cached: Optional[cache.CachedValue] = None
    live: bool = True

    @property
    def frame_id(self) -> str:
        """The frame number in the image filename -- what identifies the picture."""
        return Path(self.image_url).stem if self.image_url else ""

    @property
    def is_waxing(self) -> bool:
        """Before full the moon is waxing. Age is the honest discriminator here:
        the illuminated percentage alone is symmetric about full."""
        return self.age < 14.77

    def phase_name(self) -> str:
        """The eight conventional names, chosen from age rather than percentage."""
        fraction = (self.age % 29.530588) / 29.530588
        eighth = int((fraction * 8) + 0.5) % 8
        return ("NEW MOON", "WAXING CRESCENT", "FIRST QUARTER", "WAXING GIBBOUS",
                "FULL MOON", "WANING GIBBOUS", "LAST QUARTER",
                "WANING CRESCENT")[eighth]

    def with_image(self, image_path: Optional[Path]) -> "MoonFrame":
        """A copy pointing at a downloaded frame. The dataclass stays frozen."""
        return dataclasses.replace(self, image_path=image_path)

    def observed_at(self) -> Optional[datetime]:
        try:
            stamp = datetime.fromisoformat(self.time)
        except (TypeError, ValueError):
            return None
        return stamp if stamp.tzinfo else stamp.replace(tzinfo=timezone.utc)


def _number(payload: Dict[str, Any], key: str, default: float = 0.0) -> float:
    try:
        return float(payload.get(key, default))
    except (TypeError, ValueError):
        return default


def _from_payload(payload: Dict[str, Any], **extra: Any) -> Optional[MoonFrame]:
    if not isinstance(payload, dict):
        return None
    image = payload.get("image") or {}
    return MoonFrame(
        time=str(payload.get("time", "")),
        image_url=str(image.get("url", "")),
        phase=_number(payload, "phase"),
        age=_number(payload, "age"),
        diameter=_number(payload, "diameter"),
        distance=_number(payload, "distance"),
        right_ascension_hours=_number(payload, "j2000_ra"),
        declination=_number(payload, "j2000_dec"),
        libration_longitude=_number(payload, "subearth_lon"),
        libration_latitude=_number(payload, "subearth_lat"),
        subsolar_longitude=_number(payload, "subsolar_lon"),
        subsolar_latitude=_number(payload, "subsolar_lat"),
        position_angle=_number(payload, "posangle"),
        obscuration=_number(payload, "obscuration"),
        **extra,
    )


def _get(url: str, timeout: int) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    # urllib follows the 302 to the current timestamp on its own.
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def fetch_image(url: str, timeout: int = DEFAULT_TIMEOUT) -> Optional[Path]:
    """Download the frame, or return the copy already on disk.

    Cached under the frame's own filename, which carries the frame number, so a
    new hour is a new file and an unchanged hour costs nothing.
    """
    if not url:
        return None
    IMAGE_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    target = IMAGE_CACHE_DIR / Path(url).name
    if target.exists() and target.stat().st_size > 0:
        return target
    try:
        data = _get(url, timeout)
    except (urllib.error.URLError, OSError, ValueError):
        return None
    if not data:
        return None
    temporary = target.with_suffix(target.suffix + ".%d.tmp" % os.getpid())
    try:
        temporary.write_bytes(data)
        os.replace(temporary, target)
    except OSError:
        temporary.unlink(missing_ok=True)
        return None
    _prune_frames()
    return target


def _prune_frames(keep: int = 6) -> None:
    """Keep only the newest few frames. One a day would otherwise accumulate."""
    try:
        frames = sorted(IMAGE_CACHE_DIR.glob("moon.*"),
                        key=lambda path: path.stat().st_mtime, reverse=True)
    except OSError:
        return
    for stale in frames[keep:]:
        try:
            stale.unlink()
        except OSError:
            pass


def fetch(timeout: int = DEFAULT_TIMEOUT) -> MoonFrame:
    """Query the API live and download the frame. Raises if either fails."""
    payload = json.loads(_get(API_URL, timeout).decode("utf-8"))
    frame = _from_payload(payload)
    if frame is None or not frame.image_url:
        raise RuntimeError("dial-a-moon returned no image")
    cache.write(CACHE_NAME, payload, source=API_URL)
    image_path = fetch_image(frame.image_url, timeout)
    return _from_payload(payload, image_path=image_path, live=True)  # type: ignore[return-value]


def load(timeout: int = DEFAULT_TIMEOUT, allow_live: bool = True,
         max_age: int = REFRESH_SECONDS) -> Optional[MoonFrame]:
    """Live if the cache has gone stale, cached otherwise. Never raises.

    The cache is preferred while it is fresh rather than only on failure: the API
    publishes hourly, so refetching more often than that is load with nothing to
    show for it.
    """
    cached = cache.read(CACHE_NAME)
    if cached is not None and cached.age_seconds < max_age:
        frame = _from_payload(cached.payload, cached=cached, live=False)
        if frame is not None:
            return frame.with_image(
                fetch_image(frame.image_url, timeout) if allow_live
                else _cached_image(frame.image_url))

    if allow_live:
        try:
            return fetch(timeout=timeout)
        except Exception:  # noqa: BLE001 - fall through to whatever is cached
            pass

    if cached is None:
        return None
    frame = _from_payload(cached.payload, cached=cached, live=False)
    if frame is None:
        return None
    return frame.with_image(_cached_image(frame.image_url))


def _cached_image(url: str) -> Optional[Path]:
    if not url:
        return None
    target = IMAGE_CACHE_DIR / Path(url).name
    return target if target.exists() else None
