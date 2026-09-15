"""Positions of the sun, moon and planets.

Self-contained on purpose. ``astropy`` gives far better numbers, but it costs
several seconds to import, and a dashboard that redraws on a timer cannot pay
that -- the widget would spend more time loading an ephemeris library than
drawing the screen. The accuracy this buys is not the constraint either: the
orrery plots bodies at a few cells per astronomical unit, and the readout shows
positions to the arcminute.

Two standard low-precision methods, both from published sources:

* planets -- JPL's *Approximate Positions of the Planets*: Keplerian elements at
  J2000 plus linear rates, then Kepler's equation.
* moon -- a truncated lunar series (Meeus, *Astronomical Algorithms*, ch. 47),
  the leading terms only.

Measured against ``astropy``'s ephemeris at three dates spread over 2025-2027
(the check is ``EphemerisAccuracyTest`` in ``test/unit/dashboard_test.py``, which
skips when astropy is absent):

===========  ==========================  ===================
body         worst angular separation    worst distance error
===========  ==========================  ===================
sun          0.6 arcmin                  0.00005 au
planets      5.0 arcmin (Saturn)         0.006 au (Uranus)
moon         56 arcmin                   0.00004 au
===========  ==========================  ===================

The moon is the weak one -- just under a degree, or roughly two lunar diameters.
That is inherent to a truncated series, and it is acceptable here because nothing
this dashboard shows depends on better: the phase disc, the illuminated fraction
and whether the moon is above the horizon all survive a degree of error. Do not
reuse this module for anything that needs the moon placed among stars.

Angles are degrees at the boundary and radians inside. Distances are
astronomical units, except the moon's, which is kilometres.
"""
from __future__ import annotations

import math
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Dict, List, Optional, Sequence, Tuple

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


def heliocentric_ecliptic(name: str, jd: float) -> Tuple[float, float, float]:
    """A body's position in au, in J2000 ecliptic coordinates centred on the sun.

    Accepts a planet or a minor planet; the two use different element sets and
    different propagation, and this picks the right one by name.
    """
    if name in MINOR_PLANET_ELEMENTS:
        return minor_planet_ecliptic(name, jd)

    elements = PLANET_ELEMENTS[name]
    centuries = centuries_since_j2000(jd)
    (semi_major, eccentricity, inclination, mean_longitude,
     perihelion_longitude, node_longitude) = [
        value + rate * centuries for value, rate in elements
    ]
    return orbital_position(
        semi_major, eccentricity, inclination, node_longitude,
        perihelion_longitude - node_longitude,
        mean_longitude - perihelion_longitude,
    )


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


def ecliptic_to_equatorial(x: float, y: float, z: float) -> Tuple[float, float, float]:
    obliquity = math.radians(OBLIQUITY_J2000)
    return (x,
            y * math.cos(obliquity) - z * math.sin(obliquity),
            y * math.sin(obliquity) + z * math.cos(obliquity))


def greenwich_sidereal_degrees(jd: float) -> float:
    """Greenwich mean sidereal time in degrees (Meeus 12.4)."""
    days = jd - J2000
    centuries = days / DAYS_PER_CENTURY
    return _normalise_degrees(
        280.46061837 + 360.98564736629 * days
        + 0.000387933 * centuries ** 2 - centuries ** 3 / 38710000.0)


def horizontal_from_equatorial(right_ascension: float, declination: float,
                               observer: Observer, jd: float) -> Tuple[float, float]:
    """``(altitude, azimuth)`` in degrees, azimuth measured east from north."""
    hour_angle = math.radians(_normalise_degrees(
        greenwich_sidereal_degrees(jd) + observer.longitude - right_ascension))
    declination_radians = math.radians(declination)
    latitude = math.radians(observer.latitude)

    sin_altitude = (math.sin(declination_radians) * math.sin(latitude)
                    + math.cos(declination_radians) * math.cos(latitude)
                    * math.cos(hour_angle))
    altitude = math.asin(max(-1.0, min(1.0, sin_altitude)))
    azimuth = math.atan2(
        -math.sin(hour_angle) * math.cos(declination_radians),
        math.sin(declination_radians) * math.cos(latitude)
        - math.cos(declination_radians) * math.sin(latitude) * math.cos(hour_angle),
    )
    return (math.degrees(altitude), _normalise_degrees(math.degrees(azimuth)))


def _sky_position(name: str, geocentric: Tuple[float, float, float],
                  observer: Observer, jd: float,
                  ecliptic: Optional[Tuple[float, float, float]] = None) -> SkyPosition:
    x, y, z = ecliptic_to_equatorial(*geocentric)
    distance = math.sqrt(x * x + y * y + z * z)
    right_ascension = _normalise_degrees(math.degrees(math.atan2(y, x)))
    declination = math.degrees(math.asin(z / distance)) if distance else 0.0
    altitude, azimuth = horizontal_from_equatorial(
        right_ascension, declination, observer, jd)
    source = ecliptic or geocentric
    longitude = _normalise_degrees(math.degrees(math.atan2(source[1], source[0])))
    return SkyPosition(
        name=name,
        right_ascension=right_ascension,
        declination=declination,
        altitude=altitude,
        azimuth=azimuth,
        distance=distance,
        ecliptic_longitude=longitude,
    )


def sun_position(observer: Observer, jd: float) -> SkyPosition:
    """The sun, as the reflection of Earth's heliocentric position."""
    earth = heliocentric_ecliptic("EARTH", jd)
    geocentric = (-earth[0], -earth[1], -earth[2])
    return _sky_position("SUN", geocentric, observer, jd)


def planet_positions(observer: Observer, jd: float,
                     names: Optional[Tuple[str, ...]] = None) -> List[SkyPosition]:
    """Geocentric positions for the planets, with solar elongation filled in.

    Earth is skipped: it has no geocentric position, and the orrery draws it from
    its heliocentric coordinates instead.
    """
    earth = heliocentric_ecliptic("EARTH", jd)
    sun = sun_position(observer, jd)
    out: List[SkyPosition] = []
    for name in (names or PLANET_ORDER):
        if name == "EARTH":
            continue
        helio = heliocentric_ecliptic(name, jd)
        geocentric = (helio[0] - earth[0], helio[1] - earth[1], helio[2] - earth[2])
        position = _sky_position(name, geocentric, observer, jd, ecliptic=geocentric)
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


def heliocentric_longitudes(
    jd: float,
    names: Optional[Sequence[str]] = None,
) -> Dict[str, Tuple[float, float]]:
    """``name -> (longitude degrees, distance au)`` for the orrery's top-down view.

    Distance is the projection onto the ecliptic plane, which is what a top-down
    plot wants. For the steeply inclined minor planets -- Eris is tilted 44
    degrees -- that is visibly shorter than the true radius, and correctly so:
    seen from above, an inclined orbit projects to a smaller ellipse.
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
    return PLANET_ELEMENTS[name][0][0]


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
    """The moon's position and phase from a truncated lunar series."""
    centuries = centuries_since_j2000(jd)

    mean_longitude = _normalise_degrees(218.3164477 + 481267.88123421 * centuries)
    mean_elongation = _normalise_degrees(297.8501921 + 445267.1114034 * centuries)
    sun_anomaly = _normalise_degrees(357.5291092 + 35999.0502909 * centuries)
    moon_anomaly = _normalise_degrees(134.9633964 + 477198.8675055 * centuries)
    argument_of_latitude = _normalise_degrees(93.2720950 + 483202.0175233 * centuries)

    d = math.radians(mean_elongation)
    m = math.radians(sun_anomaly)
    m_prime = math.radians(moon_anomaly)
    f = math.radians(argument_of_latitude)

    longitude = mean_longitude + (
        6.289 * math.sin(m_prime)
        + 1.274 * math.sin(2 * d - m_prime)
        + 0.658 * math.sin(2 * d)
        + 0.214 * math.sin(2 * m_prime)
        - 0.186 * math.sin(m)
        - 0.114 * math.sin(2 * f)
        + 0.059 * math.sin(2 * d - 2 * m_prime)
        + 0.057 * math.sin(2 * d - m - m_prime)
        + 0.053 * math.sin(2 * d + m_prime)
    )
    latitude = (
        5.128 * math.sin(f)
        + 0.281 * math.sin(m_prime + f)
        - 0.278 * math.sin(f - m_prime)
        - 0.173 * math.sin(f - 2 * d)
        + 0.055 * math.sin(2 * d - m_prime + f)
        - 0.046 * math.sin(2 * d - m_prime - f)
        + 0.033 * math.sin(2 * d + f)
    )
    distance_km = (385000.56
                   - 20905.355 * math.cos(m_prime)
                   - 3699.111 * math.cos(2 * d - m_prime)
                   - 2955.968 * math.cos(2 * d)
                   - 569.925 * math.cos(2 * m_prime))

    distance_au = distance_km / ASTRONOMICAL_UNIT_KM
    longitude_radians = math.radians(_normalise_degrees(longitude))
    latitude_radians = math.radians(latitude)
    geocentric = (
        distance_au * math.cos(latitude_radians) * math.cos(longitude_radians),
        distance_au * math.cos(latitude_radians) * math.sin(longitude_radians),
        distance_au * math.sin(latitude_radians),
    )
    position = _sky_position("MOON", geocentric, observer, jd, ecliptic=geocentric)

    sun = sun_position(observer, jd)
    # Phase angle as the moon's elongation from the sun along the ecliptic: 0 at
    # new, 180 at full. Dividing by 360 puts a whole cycle on 0..1.
    elongation = _normalise_degrees(
        position.ecliptic_longitude - sun.ecliptic_longitude)
    illumination = (1 - math.cos(math.radians(elongation))) / 2

    return MoonState(
        position=SkyPosition(
            name="MOON",
            right_ascension=position.right_ascension,
            declination=position.declination,
            altitude=position.altitude,
            azimuth=position.azimuth,
            distance=distance_au,
            ecliptic_longitude=position.ecliptic_longitude,
            elongation=abs(((elongation + 180) % 360) - 180),
        ),
        phase=elongation / 360.0,
        illumination=illumination,
        distance_km=distance_km,
    )
