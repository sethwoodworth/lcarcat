"""The sun: a picture from SDO, and space-weather numbers from NOAA SWPC.

There is no Dial-A-Moon equivalent for the sun -- NASA's SVS publishes
``/api/dialamoon/`` and nothing else of that shape -- so this pairs two sources
the way the moon widget uses one:

* **Solar Dynamics Observatory** publishes its latest frames as plain JPEGs at
  fixed URLs, one per instrument channel. No key, no metadata, and PIL reads
  them directly. The default is AIA 304A with the PFSS magnetic field overlay:
  the chromosphere shows prominences arcing off the limb, and the overlay draws
  the field lines they follow. A plain visible-light disc on a quiet sun is a
  blank circle.
* **NOAA Space Weather Prediction Center** publishes the numbers as small JSON
  documents. These are the sun's equivalent of the moon's libration and
  diameter: what the sun is *doing*, rather than what it looks like.

Helioviewer offers a genuine timestamped API over the same imagery and would be
the better source for a specific moment, but its image endpoint returns JPEG
2000, which Pillow cannot decode without OpenJPEG. Its PNG path goes through a
screenshot call heavy enough to be worth avoiding for a dashboard that only ever
wants "now".
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Optional

from . import cache

SDO_LATEST = "https://sdo.gsfc.nasa.gov/assets/img/latest/latest_1024_%s.jpg"
SWPC = "https://services.swpc.noaa.gov/"

CACHE_NAME = "solar-conditions"
IMAGE_CACHE_DIR = cache.CACHE_DIR / "solar-frames"

#: SDO publishes a new frame every few minutes; a dashboard does not need them
#: all, and the space-weather numbers update on a similar cadence.
REFRESH_SECONDS = 900

DEFAULT_TIMEOUT = 12
USER_AGENT = "lcarcat-dashboard (+https://github.com/sethwoodworth/lcarcat)"

#: SDO channels, by the code in the filename. Read from the published directory
#: listing rather than guessed -- SDO puts out thirty-three of these, and the
#: ``pfss`` half were missed entirely by probing for filenames one at a time.
#:
#: A ``pfss`` suffix means the frame carries a Potential Field Source Surface
#: overlay: the computed coronal magnetic field lines, drawn arcing off the limb
#: over the disc. That is the magnetic structure the plain magnetogram only
#: implies, and it is why the default is a PFSS frame rather than the bare
#: magnetogram.
CHANNELS: Dict[str, str] = {
    # Chromosphere and corona, with field lines
    "0304pfss": "304A PFSS",
    "0171pfss": "171A PFSS",
    "0193pfss": "193A PFSS",
    "0211pfss": "211A PFSS",
    "0094pfss": "94A PFSS",
    "0131pfss": "131A PFSS",
    "0335pfss": "335A PFSS",
    "1600pfss": "1600A PFSS",
    "1700pfss": "1700A PFSS",
    "HMIBpfss": "MAGNETOGRAM PFSS",
    "HMI171pfss": "HMI 171A PFSS",
    "211193171pfss": "COMPOSITE PFSS",
    "304211171pfss": "COMPOSITE 304 PFSS",
    "094335193pfss": "COMPOSITE 94 PFSS",
    # Plain frames, no overlay
    "0304": "CHROMOSPHERE 304A",
    "0171": "CORONA 171A",
    "0193": "CORONA 193A",
    "0211": "CORONA 211A",
    "0094": "CORONA 94A",
    "0131": "CORONA 131A",
    "0335": "CORONA 335A",
    "1600": "TRANSITION 1600A",
    "1700": "PHOTOSPHERE 1700A",
    "4500": "WHITE LIGHT",
    "d0193": "193A DIFFERENCE",
    "211193171": "COMPOSITE",
    # Helioseismic and Magnetic Imager
    "HMIBC": "MAGNETOGRAM COLOUR",
    "HMIB": "MAGNETOGRAM MONO",
    "HMII": "INTENSITYGRAM",
    "HMIIC": "INTENSITYGRAM COLOUR",
    "HMIIF": "INTENSITYGRAM FLAT",
    "HMIIHI": "INTENSITYGRAM SHARP",
    "HMID": "DOPPLERGRAM",
}

#: AIA 304A shows the chromosphere -- prominences and filaments arcing off the
#: limb -- and the PFSS overlay draws the magnetic field those structures follow.
DEFAULT_CHANNEL = "0304pfss"

#: Small SWPC documents, fetched one per refresh. Each is a few hundred bytes to
#: a few tens of kilobytes; the bulk solar-cycle files are deliberately avoided.
FEEDS: Dict[str, str] = {
    "xray": "json/goes/primary/xray-flares-latest.json",
    "flux": "products/summary/10cm-flux.json",
    "wind": "products/summary/solar-wind-speed.json",
    "scales": "products/noaa-scales.json",
    "kindex": "products/noaa-planetary-k-index.json",
}


@dataclass(frozen=True)
class SolarConditions:
    """What the sun is doing, and the frame showing it."""

    channel: str
    image_path: Optional[Path] = None
    #: GOES X-ray classification right now, e.g. "B2.7", "M1.4", "X8.2".
    xray_class: str = ""
    #: The strongest class reached in the current flare event.
    xray_peak: str = ""
    #: F10.7 centimetre radio flux, in solar flux units.
    radio_flux: Optional[float] = None
    #: Solar wind proton speed, kilometres per second.
    wind_speed: Optional[float] = None
    #: Planetary K index, 0-9.
    k_index: Optional[float] = None
    #: NOAA severity scales, 0-5: radio blackout, radiation storm, geomagnetic.
    radio_blackout: str = ""
    radiation_storm: str = ""
    geomagnetic_storm: str = ""
    observed: str = ""
    cached: Optional[cache.CachedValue] = None
    live: bool = True

    @property
    def channel_name(self) -> str:
        return CHANNELS.get(self.channel, self.channel)

    @property
    def flare_letter(self) -> str:
        """A, B, C, M or X -- the order-of-magnitude part of the class."""
        return self.xray_class[:1].upper() if self.xray_class else ""

    @property
    def is_flaring(self) -> bool:
        """M and X are the classes that disrupt radio and matter on the ground."""
        return self.flare_letter in ("M", "X")

    @property
    def is_storming(self) -> bool:
        """Any NOAA scale above zero means a storm is in progress."""
        return any(scale not in ("", "0")
                   for scale in (self.radio_blackout, self.radiation_storm,
                                 self.geomagnetic_storm))

    def scale_label(self, scale: str, prefix: str) -> str:
        """``R0`` reads as nothing happening; say so in words."""
        if not scale:
            return "UNKNOWN"
        return "NONE" if scale == "0" else "%s%s" % (prefix, scale)


def _get(url: str, timeout: int) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def _feed(name: str, timeout: int) -> Any:
    """One SWPC document, or ``None``. A missing feed blanks its own rows only."""
    try:
        return json.loads(_get(SWPC + FEEDS[name], timeout).decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError, KeyError):
        return None


def fetch_image(channel: str, timeout: int = DEFAULT_TIMEOUT) -> Optional[Path]:
    """Download the latest frame for a channel.

    Unlike the moon's, these URLs always point at "latest" and carry no frame
    number, so the cache is keyed by channel and refreshed by age rather than by
    identity -- there is no way to tell from the URL whether the picture changed.
    """
    if channel not in CHANNELS:
        channel = DEFAULT_CHANNEL
    IMAGE_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    target = IMAGE_CACHE_DIR / ("latest_1024_%s.jpg" % channel)
    try:
        data = _get(SDO_LATEST % channel, timeout)
    except (urllib.error.URLError, OSError, ValueError):
        return target if target.exists() else None
    if not data:
        return target if target.exists() else None
    temporary = target.with_suffix(".%d.tmp" % os.getpid())
    try:
        temporary.write_bytes(data)
        os.replace(temporary, target)
    except OSError:
        temporary.unlink(missing_ok=True)
        return target if target.exists() else None
    return target


def _parse(payloads: Dict[str, Any], channel: str, **extra: Any) -> SolarConditions:
    xray = payloads.get("xray") or []
    latest_xray = xray[0] if isinstance(xray, list) and xray else {}

    flux = payloads.get("flux") or []
    radio_flux = None
    if isinstance(flux, list) and flux:
        try:
            radio_flux = float(flux[0].get("flux"))
        except (TypeError, ValueError, AttributeError):
            radio_flux = None

    wind = payloads.get("wind") or []
    wind_speed = None
    if isinstance(wind, list) and wind:
        try:
            wind_speed = float(wind[0].get("proton_speed"))
        except (TypeError, ValueError, AttributeError):
            wind_speed = None

    # The K index feed is a long time series; the current value is the last row.
    kindex = payloads.get("kindex") or []
    k_index = None
    if isinstance(kindex, list) and kindex:
        try:
            k_index = float(kindex[-1].get("Kp"))
        except (TypeError, ValueError, AttributeError):
            k_index = None

    # noaa-scales is keyed by horizon: "0" is now, "1".."3" are forecasts.
    scales = payloads.get("scales") or {}
    current = scales.get("0") if isinstance(scales, dict) else None
    current = current if isinstance(current, dict) else {}

    def scale_of(key: str) -> str:
        value = current.get(key)
        if isinstance(value, dict) and value.get("Scale") is not None:
            return str(value["Scale"])
        return ""

    observed = str(latest_xray.get("time_tag", "")) or "%s %s" % (
        current.get("DateStamp", ""), current.get("TimeStamp", ""))

    return SolarConditions(
        channel=channel,
        xray_class=str(latest_xray.get("current_class", "") or ""),
        xray_peak=str(latest_xray.get("max_class", "") or ""),
        radio_flux=radio_flux,
        wind_speed=wind_speed,
        k_index=k_index,
        radio_blackout=scale_of("R"),
        radiation_storm=scale_of("S"),
        geomagnetic_storm=scale_of("G"),
        observed=observed.strip(),
        **extra,
    )


def fetch(channel: str = DEFAULT_CHANNEL,
          timeout: int = DEFAULT_TIMEOUT) -> SolarConditions:
    """Query SWPC and download the SDO frame. Raises only if everything fails."""
    payloads = {name: _feed(name, timeout) for name in FEEDS}
    if not any(value is not None for value in payloads.values()):
        raise RuntimeError("no space weather feed answered")
    cache.write(CACHE_NAME, payloads, source=SWPC)
    return _parse(payloads, channel,
                  image_path=fetch_image(channel, timeout), live=True)


def load(channel: str = DEFAULT_CHANNEL, timeout: int = DEFAULT_TIMEOUT,
         allow_live: bool = True,
         max_age: int = REFRESH_SECONDS) -> Optional[SolarConditions]:
    """Live when the cache has aged out, cached otherwise. Never raises."""
    cached = cache.read(CACHE_NAME)
    fresh = cached is not None and cached.age_seconds < max_age

    if allow_live and not fresh:
        try:
            return fetch(channel=channel, timeout=timeout)
        except Exception:  # noqa: BLE001 - fall through to the cache
            pass

    if cached is None:
        return None
    payloads = cached.payload if isinstance(cached.payload, dict) else {}
    image = IMAGE_CACHE_DIR / ("latest_1024_%s.jpg" % channel)
    return _parse(payloads, channel,
                  image_path=image if image.exists() else None,
                  cached=cached, live=False)
