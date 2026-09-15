#!/usr/bin/env python3
"""Unit tests for the dashboard's pure logic.

Everything here is testable without a terminal, a network, or a PNG: rectangle
arithmetic, column-accurate text measurement, the ANSI serialiser, the data
parsers, and the ephemeris. The parts that genuinely need a screen -- whether an
elbow lines up with its bar -- are covered by ``test/captures/dashboard.sh``
instead, because no assertion available here can answer that.

    python3 test/unit/dashboard_test.py
"""
from __future__ import annotations

import math
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from dashboard.canvas import Canvas, text_width, truncate  # noqa: E402
from dashboard.diacritics import DIACRITICS, placeholder_cell  # noqa: E402
from dashboard.geometry import Rect  # noqa: E402
from dashboard.palette import CANVAS, ORANGE, TEXT, from_hex, to_hex  # noqa: E402
from dashboard.sources import ephemeris, jira  # noqa: E402


class RectTest(unittest.TestCase):
    def test_horizontal_split_fills_the_whole_width(self):
        rect = Rect(0, 0, 100, 10)
        for weights in ((1, 1), (1, 1, 1), (0.72, 0.28), (0.36, 0.32, 0.32)):
            parts = rect.split_horizontal(*weights, gap=0)
            self.assertEqual(parts[0].x, rect.x)
            self.assertEqual(parts[-1].right, rect.right,
                             "weights %r left a gap at the right edge" % (weights,))
            for left, right in zip(parts, parts[1:]):
                self.assertEqual(left.right, right.x, "panes overlap or leave a hole")

    def test_split_with_gap_reserves_exactly_the_gap(self):
        parts = Rect(0, 0, 100, 10).split_horizontal(1, 1, 1, gap=2)
        self.assertEqual(parts[0].right + 2, parts[1].x)
        self.assertEqual(parts[1].right + 2, parts[2].x)
        self.assertEqual(parts[-1].right, 100)

    def test_panes_never_touch_by_default(self):
        # LCARS frames must never sit flush: the lower panel's header bar would
        # land directly on the upper panel's footer bar and read as one broken
        # frame. The gap is a default so a new layout cannot forget it.
        stacked = Rect(0, 0, 100, 40).split_vertical(1, 1, 1)
        for upper, lower in zip(stacked, stacked[1:]):
            self.assertGreater(lower.y, upper.bottom,
                               "stacked panes are touching: %r then %r" % (upper, lower))

        columns = Rect(0, 0, 100, 40).split_horizontal(1, 1, 1)
        for left, right in zip(columns, columns[1:]):
            self.assertGreater(right.x, left.right,
                               "side-by-side panes are touching: %r then %r"
                               % (left, right))
        upper, lower = Rect(0, 0, 100, 40).take_bottom(9)
        self.assertGreater(lower.y, upper.bottom, "take_bottom left panes touching")
        upper, lower = Rect(0, 0, 100, 40).take_top(9)
        self.assertGreater(lower.y, upper.bottom, "take_top left panes touching")

    def test_equal_weights_give_equal_shares(self):
        # The trap this guards: treating whole-number weights as exact cell counts
        # made split_vertical(1, 1) -- the obvious spelling of "two equal halves" --
        # return one row and the remainder.
        for count in (2, 3, 4):
            parts = Rect(0, 0, 400, 400).split_vertical(*([1] * count), gap=0)
            heights = [part.height for part in parts]
            self.assertLessEqual(max(heights) - min(heights), 1,
                                 "%d equal weights gave %r" % (count, heights))

    def test_three_way_split_of_odd_width_keeps_every_pane(self):
        # The bug this guards: integer division alone drops the remainder and can
        # leave a pane a column narrower than the layout believes it is.
        for width in range(10, 60):
            parts = Rect(0, 0, width, 10).split_horizontal(1, 1, 1, gap=0)
            self.assertEqual(sum(p.width for p in parts), width)
            self.assertTrue(all(p.width > 0 for p in parts))

    def test_split_narrower_than_its_gaps_does_not_produce_negative_widths(self):
        for part in Rect(0, 0, 3, 10).split_horizontal(1, 1, 1, gap=5):
            self.assertGreaterEqual(part.width, 0)

    def test_inset_never_goes_negative(self):
        self.assertEqual(Rect(0, 0, 4, 4).inset(left=10).width, 0)

    def test_take_bottom_returns_top_then_bottom(self):
        top, bottom = Rect(0, 0, 10, 20).take_bottom(6, gap=0)
        self.assertEqual((top.y, top.height), (0, 14))
        self.assertEqual((bottom.y, bottom.height), (14, 6))


class TextMeasurementTest(unittest.TestCase):
    def test_wide_characters_count_two_columns(self):
        self.assertEqual(text_width("AB"), 2)
        self.assertEqual(text_width("🌑"), 2)
        self.assertEqual(text_width("●"), 1)

    def test_combining_marks_count_zero_columns(self):
        self.assertEqual(text_width(placeholder_cell(0, 0)), 1,
                         "a placeholder cell must measure as exactly one column")

    def test_truncate_respects_columns_not_characters(self):
        self.assertEqual(text_width(truncate("🌑🌒🌓🌔", 5)), 5)
        self.assertEqual(truncate("SHORT", 20), "SHORT")
        self.assertEqual(truncate("ANYTHING", 0), "")

    def test_truncate_never_exceeds_the_budget(self):
        for width in range(1, 12):
            self.assertLessEqual(text_width(truncate("ABCDEFGHIJKL", width)), width)


class CanvasTest(unittest.TestCase):
    def test_out_of_bounds_writes_are_dropped(self):
        canvas = Canvas(10, 3)
        canvas.put(-1, 0, "X")
        canvas.put(99, 0, "X")
        canvas.put(0, 99, "X")
        self.assertNotIn("X", canvas.render())

    def test_text_is_clipped_at_the_right_edge(self):
        canvas = Canvas(5, 1)
        canvas.text(3, 0, "ABCDEFG")
        rendered = canvas.render()
        self.assertIn("A", rendered)
        self.assertIn("B", rendered)
        self.assertNotIn("D", rendered, "text ran past the canvas width")

    def test_render_emits_one_cursor_move_per_row(self):
        canvas = Canvas(4, 3)
        self.assertEqual(canvas.render().count("\x1b["  "1;1H"), 1)
        self.assertEqual(canvas.render().count("H"), 0 + 3,
                         "expected exactly one positioning escape per row")

    def test_repeated_colors_are_not_re_emitted(self):
        canvas = Canvas(20, 1)
        canvas.horizontal_run(0, 0, 20, ORANGE)
        # One background escape for the run, not twenty.
        self.assertEqual(canvas.render().count("48;2;255;153;0m"), 1)

    def test_wide_glyph_reserves_its_second_column(self):
        canvas = Canvas(4, 1)
        canvas.text(0, 0, "🌑X")
        row = canvas.render()
        self.assertIn("🌑", row)
        self.assertIn("X", row)
        # The continuation cell must not be emitted as a character of its own.
        self.assertNotIn("\0", row)

    def test_image_placeholders_carry_a_256_color_foreground(self):
        canvas = Canvas(4, 2)
        canvas.place_image(0, 0, image_id=42, columns=2, image_rows=2)
        rendered = canvas.render()
        self.assertIn("\x1b[38;5;42m", rendered)
        self.assertEqual(rendered.count("\U0010EEEE"), 4)


class DiacriticsTest(unittest.TestCase):
    def test_table_is_kittys_full_length(self):
        self.assertEqual(len(DIACRITICS), 297)

    def test_first_entries_match_the_zsh_prompt(self):
        # zsh/prompt_lcars.zsh hardcodes these five; both ends must agree.
        self.assertEqual(DIACRITICS[:5],
                         ("̅", "̍", "̎", "̐", "̒"))

    def test_out_of_range_index_is_refused(self):
        with self.assertRaises(ValueError):
            placeholder_cell(0, 297)


class PaletteTest(unittest.TestCase):
    def test_hex_round_trip(self):
        for color in (CANVAS, TEXT, ORANGE):
            self.assertEqual(from_hex(to_hex(color)), color)

    def test_to_hex_has_no_leading_hash(self):
        # Asset filenames embed the color, and gen_swoops.py expects it bare.
        self.assertEqual(to_hex(ORANGE), "ff9900")


class JiraParsingTest(unittest.TestCase):
    NESTED = {
        "key": "DATA-17489",
        "fields": {
            "summary": "RichRelevance feeds",
            "status": {"name": "In Progress",
                       "statusCategory": {"key": "indeterminate"}},
            "issuetype": {"name": "Story"},
            "priority": {"name": "High"},
            "updated": "2026-08-31T10:00:00.000-0400",
        },
    }

    def test_nested_jira_rest_shape(self):
        item = jira.parse_item(self.NESTED)
        self.assertIsNotNone(item)
        assert item is not None
        self.assertEqual(item.key, "DATA-17489")
        self.assertEqual(item.issue_type, "Story")
        self.assertEqual(item.status_category, "indeterminate")
        self.assertTrue(item.is_active)

    def test_flat_acli_shape(self):
        item = jira.parse_item({
            "key": "DATA-1", "summary": "Flat", "status": "Blocked",
            "issuetype": "Bug", "priority": "P1", "updated": "2026-01-01T00:00:00Z",
        })
        assert item is not None
        self.assertEqual(item.issue_type, "Bug")
        self.assertTrue(item.is_blocked)

    def test_cache_round_trip_preserves_every_field(self):
        # The regression this pins: the cache is written from the dataclass, whose
        # field names (issue_type, status_category) differ from Jira's, and an
        # earlier parser read only Jira's spelling -- so reloading a cache silently
        # dropped the issue type and the status category.
        from dataclasses import asdict

        original = jira.parse_item(self.NESTED)
        assert original is not None
        reloaded = jira.parse_item(asdict(original))
        self.assertEqual(reloaded, original)

    def test_rows_are_found_in_every_envelope(self):
        row = {"key": "X-1"}
        self.assertEqual(len(jira._rows_from([row])), 1)
        self.assertEqual(len(jira._rows_from({"issues": [row]})), 1)
        self.assertEqual(len(jira._rows_from({"values": [row]})), 1)
        self.assertEqual(len(jira._rows_from({"issues": {"nodes": [row]}})), 1)

    def test_unparseable_row_is_skipped_not_raised(self):
        self.assertIsNone(jira.parse_item({}))
        self.assertIsNone(jira.parse_item({"summary": "no key"}))

    def test_priority_ranking_orders_high_before_low(self):
        def rank(name):
            item = jira.parse_item({"key": "A-1", "priority": name})
            assert item is not None
            return item.priority_rank()

        self.assertLess(rank("Highest"), rank("High"))
        self.assertLess(rank("High"), rank("Medium"))
        self.assertLess(rank("Medium"), rank("Low"))
        self.assertLess(rank("P1"), rank("P3"))


class EphemerisTest(unittest.TestCase):
    """Checks against facts that are true independent of this implementation."""

    OBSERVER = ephemeris.Observer("TEST", 40.7128, -74.0060)

    def test_julian_day_of_j2000_epoch(self):
        moment = datetime(2000, 1, 1, 12, 0, 0, tzinfo=timezone.utc)
        self.assertAlmostEqual(ephemeris.julian_day(moment), 2451545.0, places=5)

    def test_sun_longitude_tracks_the_calendar(self):
        # The sun is at 0 degrees ecliptic longitude at the March equinox and 180
        # at the September equinox, within a degree either side of the date.
        for month, day, expected in ((3, 20, 0.0), (6, 21, 90.0),
                                     (9, 22, 180.0), (12, 21, 270.0)):
            moment = datetime(2026, month, day, 12, tzinfo=timezone.utc)
            longitude = ephemeris.sun_position(
                self.OBSERVER, ephemeris.julian_day(moment)).ecliptic_longitude
            difference = abs(((longitude - expected + 180) % 360) - 180)
            self.assertLess(difference, 2.0,
                            "sun at %d/%d was %.2f deg, expected near %.0f"
                            % (month, day, longitude, expected))

    def test_earth_sun_distance_stays_within_the_real_range(self):
        for day in range(0, 365, 7):
            moment = datetime(2026, 1, 1, tzinfo=timezone.utc)
            jd = ephemeris.julian_day(moment) + day
            distance = ephemeris.sun_position(self.OBSERVER, jd).distance
            self.assertTrue(0.980 < distance < 1.020,
                            "earth-sun distance %.4f au is off the real range" % distance)

    def test_perihelion_falls_in_early_january(self):
        distances = []
        for day in range(365):
            jd = ephemeris.julian_day(datetime(2026, 1, 1, tzinfo=timezone.utc)) + day
            distances.append((ephemeris.sun_position(self.OBSERVER, jd).distance, day))
        _, closest_day = min(distances)
        self.assertLess(closest_day, 10, "perihelion should be in the first days of January")

    def test_planet_distances_bracket_their_orbits(self):
        jd = ephemeris.julian_day(datetime(2026, 9, 11, tzinfo=timezone.utc))
        bounds = {"MERCURY": (0.30, 0.48), "VENUS": (0.71, 0.74),
                  "MARS": (1.38, 1.67), "JUPITER": (4.95, 5.46),
                  "SATURN": (9.0, 10.1), "URANUS": (18.2, 20.1),
                  "NEPTUNE": (29.7, 30.4)}
        for name, (low, high) in bounds.items():
            x, y, z = ephemeris.heliocentric_ecliptic(name, jd)
            radius = math.sqrt(x * x + y * y + z * z)
            self.assertTrue(low <= radius <= high,
                            "%s heliocentric radius %.3f au is outside %.2f..%.2f"
                            % (name, radius, low, high))

    def test_kepler_solution_satisfies_the_equation(self):
        for mean_anomaly in range(0, 360, 17):
            for eccentricity in (0.0, 0.017, 0.093, 0.206, 0.5):
                eccentric = ephemeris.solve_kepler(mean_anomaly, eccentricity)
                residual = (eccentric - eccentricity * math.sin(eccentric))
                expected = math.radians(((mean_anomaly + 180) % 360) - 180)
                self.assertAlmostEqual(residual, expected, places=7)

    def test_altitude_stays_within_the_horizon_range(self):
        jd = ephemeris.julian_day(datetime(2026, 9, 11, 16, tzinfo=timezone.utc))
        for body in ephemeris.planet_positions(self.OBSERVER, jd):
            self.assertTrue(-90.0 <= body.altitude <= 90.0)
            self.assertTrue(0.0 <= body.azimuth < 360.0)

    def test_moon_phase_completes_a_cycle_at_the_synodic_period(self):
        start = ephemeris.julian_day(datetime(2026, 6, 1, tzinfo=timezone.utc))
        first = ephemeris.moon_state(self.OBSERVER, start).phase
        later = ephemeris.moon_state(self.OBSERVER, start + 29.530588).phase
        difference = abs(((later - first + 0.5) % 1.0) - 0.5)
        self.assertLess(difference, 0.02,
                        "phase drifted %.3f of a cycle over one synodic month" % difference)

    def test_new_moon_sits_beside_the_sun(self):
        # Whatever the absolute accuracy, a moon reported as new must be close to
        # the sun on the sky -- that is what "new" means.
        start = ephemeris.julian_day(datetime(2026, 1, 1, tzinfo=timezone.utc))
        for step in range(0, 400):
            jd = start + step * 0.25
            state = ephemeris.moon_state(self.OBSERVER, jd)
            if state.illumination < 0.005:
                self.assertLess(state.position.elongation, 10.0)
                return
        self.fail("no new moon found in 100 days")

    def test_full_moon_is_opposite_the_sun(self):
        start = ephemeris.julian_day(datetime(2026, 1, 1, tzinfo=timezone.utc))
        for step in range(0, 400):
            jd = start + step * 0.25
            state = ephemeris.moon_state(self.OBSERVER, jd)
            if state.illumination > 0.995:
                self.assertGreater(state.position.elongation, 170.0)
                return
        self.fail("no full moon found in 100 days")

    def test_phase_names_cover_the_whole_cycle(self):
        names = set()
        for step in range(80):
            state = ephemeris.MoonState(
                position=ephemeris.SkyPosition("MOON", 0, 0, 0, 0, 0, 0),
                phase=step / 80.0, illumination=0.5, distance_km=384400)
            names.add(state.phase_name())
        self.assertEqual(len(names), 8, "expected all eight phase names")

    def test_observer_parses_from_environment(self):
        import os
        previous = os.environ.get("LCARCAT_OBSERVER")
        try:
            os.environ["LCARCAT_OBSERVER"] = "51.4779,-0.0015,greenwich"
            observer = ephemeris.Observer.from_environment()
            self.assertEqual(observer.name, "GREENWICH")
            self.assertAlmostEqual(observer.latitude, 51.4779)
            os.environ["LCARCAT_OBSERVER"] = "not a coordinate"
            self.assertEqual(ephemeris.Observer.from_environment().name, "NEW YORK")
        finally:
            if previous is None:
                os.environ.pop("LCARCAT_OBSERVER", None)
            else:
                os.environ["LCARCAT_OBSERVER"] = previous


class EphemerisAccuracyTest(unittest.TestCase):
    """Pin the ephemeris against astropy, when astropy happens to be installed.

    The tests above check self-consistency and agreement with facts about the
    solar system; this one checks the numbers themselves against a real
    ephemeris. It is skipped rather than required because astropy takes about
    four seconds to import -- which is the reason this module does not use it at
    runtime -- and the dashboard must stay testable without it.

        uv run --with astropy python test/unit/dashboard_test.py
    """

    #: Worst angular separation from astropy, arcminutes. Measured, then given a
    #: little headroom: these are ceilings that should fail if the method
    #: degrades, not targets to tune toward.
    TOLERANCE_ARCMINUTES = {
        "SUN": 2.0,
        "MERCURY": 5.0, "VENUS": 5.0, "MARS": 5.0, "JUPITER": 8.0,
        "SATURN": 8.0, "URANUS": 5.0, "NEPTUNE": 5.0,
        # A truncated lunar series is worth about a degree; see the module docstring.
        "MOON": 75.0,
    }

    DATES = ("2026-09-11T16:00:00", "2027-03-01T00:00:00", "2025-06-15T06:00:00")

    def test_positions_agree_with_astropy(self):
        try:
            import astropy.units as astropy_units
            from astropy.coordinates import EarthLocation, get_body
            from astropy.time import Time
        except ImportError:
            self.skipTest("astropy is not installed")

        observer = ephemeris.Observer("TEST", 40.7128, -74.0060)
        location = EarthLocation(lat=40.7128 * astropy_units.deg,
                                 lon=-74.0060 * astropy_units.deg)

        def separation_degrees(ra1, dec1, ra2, dec2):
            ra1, dec1, ra2, dec2 = map(math.radians, (ra1, dec1, ra2, dec2))
            cosine = (math.sin(dec1) * math.sin(dec2)
                      + math.cos(dec1) * math.cos(dec2) * math.cos(ra1 - ra2))
            return math.degrees(math.acos(max(-1.0, min(1.0, cosine))))

        for iso in self.DATES:
            moment = Time(iso)
            jd = moment.jd
            bodies = {p.name: p for p in ephemeris.planet_positions(observer, jd)}
            bodies["SUN"] = ephemeris.sun_position(observer, jd)
            bodies["MOON"] = ephemeris.moon_state(observer, jd).position

            for name, mine in bodies.items():
                reference = get_body(name.lower(), moment, location)
                arcminutes = 60 * separation_degrees(
                    mine.right_ascension, mine.declination,
                    reference.ra.deg, reference.dec.deg)
                self.assertLess(
                    arcminutes, self.TOLERANCE_ARCMINUTES[name],
                    "%s at %s is %.2f arcmin from astropy (limit %.1f)"
                    % (name, iso, arcminutes, self.TOLERANCE_ARCMINUTES[name]))


class LayoutSmokeTest(unittest.TestCase):
    """Every layout must compose at a range of sizes without raising or overflowing."""

    def test_layouts_compose_across_terminal_sizes(self):
        import io
        import os

        from dashboard import layouts
        from dashboard.app import Dashboard
        from dashboard.assets import CellSize

        for name in layouts.names():
            for columns, rows in ((200, 50), (120, 40), (80, 24), (60, 20), (45, 18)):
                os.environ["COLUMNS"], os.environ["LINES"] = str(columns), str(rows)
                layout = layouts.build(name)
                dashboard = Dashboard(layout, stream=io.StringIO(),
                                      cell_size=CellSize(19, 38), allow_images=False)
                dashboard.refresh(force=False)
                frame = dashboard.compose()
                self.assertIsInstance(frame, str)
                self.assertGreater(len(frame), 0,
                                   "%s produced nothing at %dx%d" % (name, columns, rows))

    def test_widget_registry_builds_every_name(self):
        from dashboard import widgets

        for name in widgets.names():
            self.assertIsNotNone(widgets.build(name))
        with self.assertRaises(KeyError):
            widgets.build("no-such-widget")


if __name__ == "__main__":
    unittest.main(verbosity=2)
