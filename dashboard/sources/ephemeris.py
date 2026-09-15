"""Positions of the sun, moon and planets.

``astropy`` does the work for the sun, the moon and the eight planets. An
earlier version of this module computed them from Keplerian elements instead,
justified by astropy's import cost -- a justification that did not survive being
measured properly. On this machine, from an installed environment:

===========================  ========
warm import                  0.30-0.50 s, once
first query                  0.34 s, once
nine bodies, subsequently    0.02-0.04 s per refresh
===========================  ========

The earlier figure of 3.8 s came from ``uv run --with astropy``, which folds
environment resolution into the measurement, taken once on cold bytecode. Four
hundredths of a second per refresh, on a background thread, against a sixty
second interval, is not a cost worth trading accuracy for.

**Minor planets are still computed here**, because no ephemeris astropy can
reach contains them. Its ``builtin`` covers the sun, the moon and the eight
planets and nothing else -- not even Pluto -- and while a downloaded DE kernel
adds Pluto, Ceres, Haumea, Makemake and Eris appear in no DE kernel at all.
Those five use osculating elements from JPL's Small-Body Database and a
two-body propagation, which is good for a few years either side of the epoch.

Their *frame* conversions still go through astropy: the Keplerian solution
produces a heliocentric ecliptic vector, which is handed to a
``HeliocentricTrueEcliptic`` coordinate and transformed like anything else. That
matters -- converting to ICRS rather than GCRS puts Ceres 22 degrees wrong,
because ICRS is barycentric and a body at 2.7 au has a large parallax from
Earth's one-au offset.

Angles are degrees at the boundary. Distances are astronomical units, except the
moon's, which is kilometres. The public functions take a Julian Day so callers
need no astropy types of their own.
"""
from __future__ import annotations

import math
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Dict, List, Optional, Sequence, Tuple

import astropy.units as units
from astropy.coordinates import (AltAz, CartesianRepresentation, EarthLocation,
                                 GCRS, GeocentricTrueEcliptic,
                                 HeliocentricTrueEcliptic, SkyCoord, get_body)
from astropy.time import Time
from astropy.utils import iers

# Earth-orientation corrections are downloaded on demand by default, which makes
# the first query depend on the network and can stall a dashboard's startup.
# The bundled table is accurate to far better than anything shown here -- these
# are readouts to the arcminute and a plot a few hundred pixels wide -- so the
# download is switched off and astropy falls back to what ships with it.
iers.conf.auto_download = False

J2000 = 2451545.0
DAYS_PER_CENTURY = 36525.0
OBLIQUITY_J2000 = 23.43928  # degrees
ASTRONOMICAL_UNIT_KM = 149597870.7


# a (au), e, inclination, mean longitude, longitude of perihelion, longitude of
# ascending node -- each as (value at J2000, change per Julian century).
# Degrees except a. Source: JPL Solar System Dynamics, valid 1800-2050.
PLANET_ELEMENTS: Dict[str, Tuple[Tuple[float, float], ...]] = {
    "MERCURY": (
        (0.38709927, 0.00000037), (0.20563593, 0.00001906),
        (7.00497902, -0.00594749), (252.25032350, 149472.67411175),
        (77.45779628, 0.16047689), (48.33076593, -0.12534081),
    ),
    "VENUS": (
        (0.72333566, 0.00000390), (0.00677672, -0.00004107),
        (3.39467605, -0.00078890), (181.97909950, 58517.81538729),
        (131.60246718, 0.00268329), (76.67984255, -0.27769418),
    ),
    "EARTH": (
        (1.00000261, 0.00000562), (0.01671123, -0.00004392),
        (-0.00001531, -0.01294668), (100.46457166, 35999.37244981),
        (102.93768193, 0.32327364), (0.0, 0.0),
    ),
    "MARS": (
        (1.52371034, 0.00001847), (0.09339410, 0.00007882),
        (1.84969142, -0.00813131), (-4.55343205, 19140.30268499),
        (-23.94362959, 0.44441088), (49.55953891, -0.29257343),
    ),
    "JUPITER": (
        (5.20288700, -0.00011607), (0.04838624, -0.00013253),
        (1.30439695, -0.00183714), (34.39644051, 3034.74612775),
        (14.72847983, 0.21252668), (100.47390909, 0.20469106),
    ),
    "SATURN": (
        (9.53667594, -0.00125060), (0.05386179, -0.00050991),
        (2.48599187, 0.00193609), (49.95424423, 1222.49362201),
        (92.59887831, -0.41897216), (113.66242448, -0.28867794),
    ),
    "URANUS": (
        (19.18916464, -0.00196176), (0.04725744, -0.00004397),
        (0.77263783, -0.00242939), (313.23810451, 428.48202785),
        (170.95427630, 0.40805281), (74.01692503, 0.04240589),
    ),
    "NEPTUNE": (
        (30.06992276, 0.00026291), (0.00859048, 0.00005105),
        (1.77004347, 0.00035372), (-55.12002969, 218.45945325),
        (44.96476227, -0.32241464), (131.78422574, -0.00508664),
    ),
}

#: Drawing order for the orrery -- sun outward. Earth is included because the
#: orrery marks where the observer is standing.
PLANET_ORDER = ("MERCURY", "VENUS", "EARTH", "MARS",
                "JUPITER", "SATURN", "URANUS", "NEPTUNE")


#: Osculating elements for the minor planets, fetched from JPL's Small-Body
#: Database (``ssd-api.jpl.nasa.gov/sbdb.api``) rather than transcribed from
#: memory, and kept at full precision as JPL returned them.
#:
#: These are *osculating* elements at a stated epoch, not the mean elements with
#: secular rates that PLANET_ELEMENTS carries. Propagating them is a matter of
#: advancing the mean anomaly at the two-body mean motion, which ignores
#: planetary perturbations -- fine over a few years for a plot, and increasingly
#: wrong the further the date is from the epoch. Note Pluto's epoch is several
#: years earlier than the rest, because that is the solution JPL publishes.
#:
#: Ordered as (epoch_jd, a, e, inclination, ascending_node, argument_of_perihelion,
#: mean_anomaly) -- degrees except a, which is au. Unlike the planets these give
#: the argument of perihelion directly rather than the longitude of perihelion.
MINOR_PLANET_ELEMENTS: Dict[str, Tuple[float, ...]] = {
    "CERES": (2461200.5, 2.765552595034094, 0.07969229514816586,
              10.58802780183462, 80.24862682043221, 73.29421453021587,
              274.4193463761342),
    "PLUTO": (2457588.5, 39.58862938517124, 0.2518378778576892,
              17.14771140999114, 110.2923840543057, 113.7090015158565,
              38.68366347318184),
    "HAUMEA": (2461200.5, 43.06029023650952, 0.1944430148898797,
               28.20847393040364, 121.7860561329425, 240.6905472508661,
               223.2104118812299),
    "MAKEMAKE": (2461200.5, 45.57093317300052, 0.1588889953992523,
                 29.02785603743067, 79.2948338209406, 297.0922733397207,
                 169.9379962048232),
    "ERIS": (2461200.5, 67.93394687853566, 0.4382385347971672,
             43.9258279471791, 36.00477044417249, 150.7949235840312,
             211.774434275007),
}

#: The five bodies the IAU recognises as dwarf planets, sun outward.
MINOR_PLANET_ORDER = ("CERES", "PLUTO", "HAUMEA", "MAKEMAKE", "ERIS")

#: Gaussian gravitational constant expressed as degrees per day, so mean motion
#: is ``GAUSSIAN_DEGREES_PER_DAY / a ** 1.5`` straight from Kepler's third law.
GAUSSIAN_DEGREES_PER_DAY = 0.9856076686

#: Bodies astropy's builtin ephemeris resolves. Anything else falls to the
#: Keplerian path below.
ASTROPY_BODIES = frozenset({
    "SUN", "MOON", "MERCURY", "VENUS", "EARTH", "MARS",
    "JUPITER", "SATURN", "URANUS", "NEPTUNE",
})

#: Semi-major axes in au, for ordering orbit rings sun-outward without asking
#: astropy for a position first.
PLANET_SEMI_MAJOR_AXIS: Dict[str, float] = {
    "MERCURY": 0.38709927, "VENUS": 0.72333566, "EARTH": 1.00000261,
    "MARS": 1.52371034, "JUPITER": 5.20288700, "SATURN": 9.53667594,
    "URANUS": 19.18916464, "NEPTUNE": 30.06992276,
}

#: Mean apparent magnitude at a typical elongation. Only used to size a plotted
#: marker and to sort a "what is up tonight" list, never reported as a number.
TYPICAL_MAGNITUDE = {
    "MERCURY": 0.0, "VENUS": -4.1, "EARTH": 0.0, "MARS": 0.7,
    "JUPITER": -2.2, "SATURN": 0.5, "URANUS": 5.7, "NEPTUNE": 7.8,
}


@dataclass(frozen=True)
class Observer:
    name: str
    latitude: float
    longitude: float

    @classmethod
    def from_environment(cls) -> "Observer":
        """Read ``LCARCAT_OBSERVER`` as ``latitude,longitude[,name]``.

        The default is a placeholder, not a guess about where anyone is: altitude
        and azimuth are meaningless without a real site, so the widget labels
        whatever it used and this is the one knob that changes it.
        """
        raw = os.environ.get("LCARCAT_OBSERVER", "").strip()
        if raw:
            parts = [part.strip() for part in raw.split(",")]
            try:
                latitude, longitude = float(parts[0]), float(parts[1])
            except (IndexError, ValueError):
                pass
            else:
                name = parts[2] if len(parts) > 2 and parts[2] else "OBSERVER"
                return cls(name.upper(), latitude, longitude)
        return cls("NEW YORK", 40.7128, -74.0060)


@dataclass(frozen=True)
class SkyPosition:
    """Where a body is, from the ground up.

    ``right_ascension`` and ``declination`` are equatorial J2000 in degrees;
    ``altitude`` and ``azimuth`` are topocentric, so they depend on the observer
    and the moment. ``distance`` is astronomical units.
    """

    name: str
    right_ascension: float
    declination: float
    altitude: float
    azimuth: float
    distance: float
    ecliptic_longitude: float
    elongation: float = 0.0

    @property
    def is_up(self) -> bool:
        return self.altitude > 0.0

    @property
    def compass(self) -> str:
        points = ("N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                  "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW")
        return points[int((self.azimuth % 360) / 22.5 + 0.5) % 16]

    def right_ascension_hms(self) -> str:
        hours_total = (self.right_ascension % 360) / 15.0
        hours = int(hours_total)
        minutes_total = (hours_total - hours) * 60
        return "%02dh%02dm" % (hours, int(minutes_total))

    def declination_dm(self) -> str:
        sign = "+" if self.declination >= 0 else "-"
        magnitude = abs(self.declination)
        return "%s%02d°%02d'" % (sign, int(magnitude), int((magnitude % 1) * 60))


def julian_day(moment: Optional[datetime] = None) -> float:
    """Julian Day for a moment, defaulting to now in UTC."""
    moment = moment.astimezone(timezone.utc) if moment else datetime.now(timezone.utc)
    year, month = moment.year, moment.month
    day = (moment.day
           + (moment.hour + (moment.minute + moment.second / 60.0) / 60.0) / 24.0)
    if month <= 2:
        year -= 1
        month += 12
    a = year // 100
    b = 2 - a + a // 4
    return (math.floor(365.25 * (year + 4716))
            + math.floor(30.6001 * (month + 1)) + day + b - 1524.5)


def centuries_since_j2000(jd: float) -> float:
    return (jd - J2000) / DAYS_PER_CENTURY


def _normalise_degrees(value: float) -> float:
    return value % 360.0


def solve_kepler(mean_anomaly_degrees: float, eccentricity: float,
                 tolerance: float = 1e-8) -> float:
    """Eccentric anomaly in radians, by Newton iteration on Kepler's equation.

    Converges in a handful of steps for every planetary eccentricity; the iteration
    cap only exists so a pathological input cannot spin the render loop.
    """
    mean_anomaly = math.radians(((mean_anomaly_degrees + 180) % 360) - 180)
    eccentric = mean_anomaly + eccentricity * math.sin(mean_anomaly)
    for _ in range(60):
        delta = ((eccentric - eccentricity * math.sin(eccentric) - mean_anomaly)
                 / (1 - eccentricity * math.cos(eccentric)))
        eccentric -= delta
        if abs(delta) < tolerance:
            break
    return eccentric


def orbital_position(
    semi_major: float,
    eccentricity: float,
    inclination: float,
    node_longitude: float,
    argument_of_perihelion: float,
    mean_anomaly: float,
) -> Tuple[float, float, float]:
    """Solve one Keplerian orbit into J2000 ecliptic coordinates, in au.

    Shared by the planets and the minor planets, which differ only in how their
    elements are *stated*: planets carry a longitude of perihelion and a mean
    longitude (both measured from the equinox), minor planets an argument of
    perihelion and a mean anomaly (both measured from the node). Both reduce to
    the same six numbers this takes, so the geometry is written once.
    """
    argument = math.radians(argument_of_perihelion)
    node = math.radians(node_longitude)
    inclination_radians = math.radians(inclination)
    eccentric = solve_kepler(mean_anomaly, eccentricity)

    # Position in the orbital plane, perihelion along +x.
    x_orbital = semi_major * (math.cos(eccentric) - eccentricity)
    y_orbital = semi_major * math.sqrt(1 - eccentricity ** 2) * math.sin(eccentric)

    cos_argument, sin_argument = math.cos(argument), math.sin(argument)
    cos_node, sin_node = math.cos(node), math.sin(node)
    cos_inclination, sin_inclination = (math.cos(inclination_radians),
                                        math.sin(inclination_radians))

    x = ((cos_argument * cos_node - sin_argument * sin_node * cos_inclination) * x_orbital
         + (-sin_argument * cos_node - cos_argument * sin_node * cos_inclination) * y_orbital)
    y = ((cos_argument * sin_node + sin_argument * cos_node * cos_inclination) * x_orbital
         + (-sin_argument * sin_node + cos_argument * cos_node * cos_inclination) * y_orbital)
    z = (sin_argument * sin_inclination * x_orbital
         + cos_argument * sin_inclination * y_orbital)
    return (x, y, z)


def minor_planet_ecliptic(name: str, jd: float) -> Tuple[float, float, float]:
    """A minor planet's heliocentric position, propagated from its JPL epoch.

    The mean anomaly advances at the two-body mean motion from Kepler's third
    law. No perturbations: over the years a dashboard will be looked at, the
    error stays far below what a plot a few hundred pixels across can show.
    """
    (epoch, semi_major, eccentricity, inclination,
     node_longitude, argument_of_perihelion, mean_anomaly) = MINOR_PLANET_ELEMENTS[name]
    mean_motion = GAUSSIAN_DEGREES_PER_DAY / (semi_major ** 1.5)
    return orbital_position(
        semi_major, eccentricity, inclination, node_longitude,
        argument_of_perihelion,
        mean_anomaly + mean_motion * (jd - epoch),
    )


def _time(jd: float) -> Time:
    return Time(jd, format="jd", scale="utc")


def _location(observer: Observer) -> EarthLocation:
    return EarthLocation(lat=observer.latitude * units.deg,
                         lon=observer.longitude * units.deg)


def _coordinate(name: str, jd: float) -> SkyCoord:
    """A body's geocentric coordinate, whichever engine can produce it.

    astropy for anything its builtin ephemeris knows; for the minor planets, the
    Keplerian solution is wrapped as a heliocentric ecliptic coordinate and
    handed to astropy to transform. GCRS, not ICRS: ICRS is barycentric, and
    Earth's one-au offset is a 22 degree parallax on a body as close as Ceres.
    """
    moment = _time(jd)
    if name in ASTROPY_BODIES:
        return get_body(name.lower(), moment)
    x, y, z = minor_planet_ecliptic(name, jd)
    helio = SkyCoord(
        CartesianRepresentation(x * units.AU, y * units.AU, z * units.AU),
        frame=HeliocentricTrueEcliptic(obstime=moment),
    )
    return helio.transform_to(GCRS(obstime=moment))


def _sky_position(name: str, jd: float, observer: Observer,
                  elongation: float = 0.0) -> SkyPosition:
    moment = _time(jd)
    coordinate = _coordinate(name, jd)
    horizontal = coordinate.transform_to(
        AltAz(obstime=moment, location=_location(observer)))
    ecliptic = coordinate.transform_to(GeocentricTrueEcliptic(equinox=moment))
    try:
        distance = float(coordinate.distance.to(units.AU).value)
    except Exception:  # noqa: BLE001 - a directionless coordinate has no distance
        distance = 0.0
    return SkyPosition(
        name=name,
        right_ascension=float(coordinate.ra.deg),
        declination=float(coordinate.dec.deg),
        altitude=float(horizontal.alt.deg),
        azimuth=float(horizontal.az.deg),
        distance=distance,
        ecliptic_longitude=float(ecliptic.lon.deg),
        elongation=elongation,
    )


def sun_position(observer: Observer, jd: float) -> SkyPosition:
    return _sky_position("SUN", jd, observer)


def planet_positions(observer: Observer, jd: float,
                     names: Optional[Sequence[str]] = None) -> List[SkyPosition]:
    """Geocentric positions, with solar elongation filled in.

    Earth is skipped: it has no geocentric position of its own, and the orrery
    draws it from heliocentric coordinates instead.
    """
    sun = sun_position(observer, jd)
    out: List[SkyPosition] = []
    for name in (names or PLANET_ORDER):
        if name == "EARTH":
            continue
        position = _sky_position(name, jd, observer)
        separation = abs(((position.ecliptic_longitude - sun.ecliptic_longitude
                           + 180) % 360) - 180)
        out.append(SkyPosition(
            name=position.name,
            right_ascension=position.right_ascension,
            declination=position.declination,
            altitude=position.altitude,
            azimuth=position.azimuth,
            distance=position.distance,
            ecliptic_longitude=position.ecliptic_longitude,
            elongation=separation,
        ))
    return out


def heliocentric_ecliptic(name: str, jd: float) -> Tuple[float, float, float]:
    """A body's position in au, sun-centred, in ecliptic coordinates."""
    if name not in ASTROPY_BODIES:
        return minor_planet_ecliptic(name, jd)
    moment = _time(jd)
    helio = get_body(name.lower(), moment).transform_to(
        HeliocentricTrueEcliptic(obstime=moment))
    cartesian = helio.cartesian
    return (float(cartesian.x.to(units.AU).value),
            float(cartesian.y.to(units.AU).value),
            float(cartesian.z.to(units.AU).value))


def heliocentric_longitudes(
    jd: float,
    names: Optional[Sequence[str]] = None,
) -> Dict[str, Tuple[float, float]]:
    """``name -> (longitude degrees, distance au)`` for the orrery's top-down view.

    Distance is the projection onto the ecliptic plane, which is what a top-down
    plot wants: seen from above, an inclined orbit projects to a smaller ellipse,
    and Eris is tilted 44 degrees.
    """
    out: Dict[str, Tuple[float, float]] = {}
    for name in (names or PLANET_ORDER):
        x, y, _ = heliocentric_ecliptic(name, jd)
        out[name] = (_normalise_degrees(math.degrees(math.atan2(y, x))),
                     math.sqrt(x * x + y * y))
    return out


def mean_distance(name: str) -> float:
    """A body's semi-major axis in au, for ordering rings sun-outward."""
    if name in MINOR_PLANET_ELEMENTS:
        return MINOR_PLANET_ELEMENTS[name][1]
    return PLANET_SEMI_MAJOR_AXIS[name]


def moon_geocentric_longitude(jd: float) -> float:
    """Where the moon sits around the earth, in ecliptic longitude.

    The orrery cannot plot the moon to scale -- its orbit is a four-hundredth of
    Earth's, so at any size a terminal pane offers it lands inside Earth's own
    marker. What a schematic *can* show truthfully is the direction, which is
    also the thing that determines the phase, so that is what this returns and
    what the plot draws at an exaggerated radius.
    """
    return moon_state(Observer("PLOT", 0.0, 0.0), jd).position.ecliptic_longitude


# --------------------------------------------------------------------------
# moon
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class MoonState:
    position: SkyPosition
    #: 0 at new moon, 0.5 at full, approaching 1 back at new.
    phase: float
    #: Fraction of the disc lit, 0 to 1.
    illumination: float
    distance_km: float

    @property
    def is_waxing(self) -> bool:
        return self.phase < 0.5

    def phase_name(self) -> str:
        """The eight conventional phase names.

        Boundaries at one sixteenth of a cycle either side of each quarter, so the
        four exact phases get a narrow window and the crescents and gibbous phases
        get the wide ones -- which is how the names are actually used.
        """
        eighth = int((self.phase * 8) + 0.5) % 8
        return ("NEW MOON", "WAXING CRESCENT", "FIRST QUARTER", "WAXING GIBBOUS",
                "FULL MOON", "WANING GIBBOUS", "LAST QUARTER",
                "WANING CRESCENT")[eighth]


def moon_state(observer: Observer, jd: float) -> MoonState:
    """The moon's position, phase and illuminated fraction, from astropy.

    The phase angle is the sun-moon-earth angle, built from the elongation and
    the two distances rather than from elongation alone -- the sun is not at
    infinity, and the difference shows near the quarters. Illumination follows
    from it directly.

    ``is_waxing`` cannot come from the illuminated fraction, which is symmetric
    about full; it comes from whether the moon leads the sun in ecliptic
    longitude.
    """
    moment = _time(jd)
    location = _location(observer)
    moon = get_body("moon", moment, location)
    sun = get_body("sun", moment, location)

    elongation = sun.separation(moon)
    phase_angle = math.atan2(
        float(sun.distance.to(units.AU).value) * math.sin(elongation.radian),
        float(moon.distance.to(units.AU).value)
        - float(sun.distance.to(units.AU).value) * math.cos(elongation.radian),
    )
    illumination = (1.0 + math.cos(phase_angle)) / 2.0

    position = _sky_position("MOON", jd, observer,
                             elongation=float(elongation.deg))
    sun_longitude = _sky_position("SUN", jd, observer).ecliptic_longitude
    separation = _normalise_degrees(position.ecliptic_longitude - sun_longitude)

    return MoonState(
        position=position,
        phase=separation / 360.0,
        illumination=illumination,
        distance_km=float(moon.distance.to(units.km).value),
    )
