#!/usr/bin/env python3
"""Unit tests for the dashboard's pure logic.

Everything here is testable without a terminal, a network, or a PNG: rectangle
arithmetic, column-accurate text measurement, the ANSI serialiser, the data
parsers, and the ephemeris. The parts that genuinely need a screen -- whether an
elbow lines up with its bar -- are covered by ``test/captures/dashboard.sh``
instead, because no assertion available here can answer that.

Needs astropy and Pillow, the dashboard's own dependencies:

    uv run --with astropy --with pillow python test/unit/dashboard_test.py
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


class MinorPlanetTest(unittest.TestCase):
    """The minor planets are the one body class astropy cannot supply.

    Its builtin ephemeris stops at the eight planets; Ceres, Haumea, Makemake
    and Eris are in no DE kernel at all. They are propagated here from JPL
    Small-Body Database elements, so they are the part of the ephemeris that can
    still drift without anything noticing -- hence a regression pin.
    """

    OBSERVER = ephemeris.Observer("TEST", 40.7128, -74.0060)
    WHEN = datetime(2026, 9, 15, 12, 0, 0, tzinfo=timezone.utc)

    #: Right ascension and declination in degrees, cross-checked against an
    #: independent transform of the same elements through astropy's frames, which
    #: agreed to 0.01 degrees. Loose tolerance: this guards against a broken
    #: propagation, not against the method's own accuracy.
    EXPECTED = {
        "CERES": (102.29, 23.00),
        "PLUTO": (306.24, -23.69),
        "HAUMEA": (219.74, 13.82),
        "MAKEMAKE": (201.26, 19.97),
        "ERIS": (27.30, 0.01),
    }

    def test_positions_match_the_pinned_solution(self):
        jd = ephemeris.julian_day(self.WHEN)
        found = {p.name: p for p in ephemeris.planet_positions(
            self.OBSERVER, jd, ephemeris.MINOR_PLANET_ORDER)}
        for name, (right_ascension, declination) in self.EXPECTED.items():
            body = found[name]
            self.assertAlmostEqual(body.right_ascension, right_ascension, delta=0.5,
                                   msg="%s right ascension drifted" % name)
            self.assertAlmostEqual(body.declination, declination, delta=0.5,
                                   msg="%s declination drifted" % name)

    def test_each_stays_within_its_own_orbit(self):
        """Distance must lie between perihelion and aphelion, always."""
        jd = ephemeris.julian_day(self.WHEN)
        for name in ephemeris.MINOR_PLANET_ORDER:
            _, semi_major, eccentricity = ephemeris.MINOR_PLANET_ELEMENTS[name][:3]
            x, y, z = ephemeris.minor_planet_ecliptic(name, jd)
            radius = math.sqrt(x * x + y * y + z * z)
            self.assertTrue(
                semi_major * (1 - eccentricity) <= radius
                <= semi_major * (1 + eccentricity),
                "%s at %.3f au is outside its own orbit" % (name, radius))

    def test_astropy_refuses_them_so_the_keplerian_path_is_required(self):
        """Pin the reason this code exists, so nobody deletes it as redundant."""
        from astropy.coordinates import solar_system_ephemeris

        for name in ephemeris.MINOR_PLANET_ORDER:
            self.assertNotIn(name.lower(), solar_system_ephemeris.bodies,
                             "%s is now in astropy's builtin ephemeris; the "
                             "Keplerian path for it can go" % name)


class InteractionTest(unittest.TestCase):
    """The hit map and the mouse decoding, which have no visual surface."""

    def setUp(self):
        from dashboard.interaction import HitMap
        self.hits = HitMap()
        self.fired = []

    def _region(self, rect, name, **kwargs):
        from dashboard.interaction import on_click
        self.hits.add(rect, on_click(lambda: self.fired.append(name)), name,
                      **kwargs)

    def test_later_registration_wins(self):
        # Rendering nests outermost-first -- frame, panel, widget -- so a
        # widget's own region must beat the panel chrome beneath it.
        from dashboard.interaction import Click
        self._region(Rect(0, 0, 20, 10), "panel")
        self._region(Rect(5, 5, 4, 2), "widget")
        self.assertTrue(self.hits.dispatch(Click(6, 6)))
        self.assertEqual(self.fired, ["widget"])

    def test_click_outside_every_region_is_ignored(self):
        from dashboard.interaction import Click
        self._region(Rect(0, 0, 4, 4), "only")
        self.assertFalse(self.hits.dispatch(Click(99, 99)))
        self.assertEqual(self.fired, [])

    def test_wheel_reaches_only_regions_that_asked_for_it(self):
        from dashboard.interaction import Button, Click
        self._region(Rect(0, 0, 10, 10), "plain")
        self.assertFalse(self.hits.dispatch(Click(1, 1, Button.WHEEL_UP)))
        self.hits.clear()
        self.fired.clear()
        self._region(Rect(0, 0, 10, 10), "scrolls", wants_wheel=True)
        self.assertTrue(self.hits.dispatch(Click(1, 1, Button.WHEEL_UP)))

    def test_clear_leaves_nothing_behind(self):
        # A stale region from a pane that moved or vanished is the failure this
        # guards: it would make a dead area of the screen still clickable.
        self._region(Rect(0, 0, 4, 4), "gone")
        self.hits.clear()
        from dashboard.interaction import Click
        self.assertFalse(self.hits.dispatch(Click(1, 1)))
        self.assertEqual(len(self.hits), 0)

    def test_mouse_decoding(self):
        import types

        from dashboard.interaction import Button
        from dashboard.terminal_input import to_click

        def keystroke(name, xy):
            stroke = types.SimpleNamespace()
            stroke.name, stroke.mouse_xy = name, xy
            return stroke

        click = to_click(keystroke("MOUSE_LEFT", (41, 12)))
        assert click is not None
        self.assertEqual((click.x, click.y, click.button), (41, 12, Button.LEFT))

        modified = to_click(keystroke("MOUSE_CTRL_LEFT", (5, 5)))
        assert modified is not None
        self.assertTrue(modified.ctrl)

        wheel = to_click(keystroke("MOUSE_SCROLL_UP", (1, 1)))
        assert wheel is not None
        self.assertIs(wheel.button, Button.WHEEL_UP)
        self.assertTrue(wheel.is_wheel)

        # Releases and motion must not fire handlers a second time.
        self.assertIsNone(to_click(keystroke("MOUSE_LEFT_RELEASED", (41, 12))))
        self.assertIsNone(to_click(keystroke("MOUSE_RIGHT_MOTION", (3, 3))))
        self.assertIsNone(to_click(keystroke("KEY_ENTER", (-1, -1))))


class NavigationTest(unittest.TestCase):
    """Every layout must offer navigation to every other layout."""

    def test_navigation_rail_covers_all_layouts_and_lights_the_current_one(self):
        from dashboard import layouts

        for name in layouts.names():
            layout = layouts.build(name)
            chosen = []
            layout.on_navigate = lambda target: chosen.append(target) or True
            blocks = layout.frame_rail_blocks()
            labels = {block.label for block in blocks}
            self.assertEqual(len(blocks), len(layouts.names()),
                             "%s rail does not list every layout" % name)
            self.assertIn(name.upper().replace("-", " "), labels)

            # The current layout is lit and inert; every other is clickable.
            inert = [b for b in blocks if b.action is None]
            self.assertEqual([b.label for b in inert],
                             [name.upper().replace("-", " ")])
            for block in blocks:
                if block.action is not None:
                    block.action(None)  # type: ignore[arg-type]
            self.assertEqual(len(chosen), len(layouts.names()) - 1)

    def test_a_layout_that_overrides_decoration_keeps_navigation(self):
        # The trap: overriding frame_rail_blocks instead of
        # decorative_rail_blocks silently removes navigation from that layout.
        from dashboard import layouts

        for name in layouts.names():
            layout = layouts.build(name)
            layout.on_navigate = lambda target: True
            self.assertTrue(any(b.action for b in layout.frame_rail_blocks()),
                            "%s has no navigable rail block" % name)


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
