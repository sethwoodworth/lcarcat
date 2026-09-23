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
from dashboard import labels  # noqa: E402
from dashboard.palette import CANVAS as CANVAS_COLOR  # noqa: E402
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


class LabelLadderTest(unittest.TestCase):
    """Shortening a block-letter title that will not fit its bar."""

    def test_disemvowel_keeps_the_ends_of_each_word(self):
        self.assertEqual(labels.disemvowel("PULL REQUESTS"), "PLL RQSTS")
        self.assertEqual(labels.disemvowel("SYSTEM STATUS"), "SYSTM STTS")

    def test_short_words_are_left_alone(self):
        # Nothing can come out of SKY that leaves it a word.
        self.assertEqual(labels.disemvowel("SKY"), "SKY")
        self.assertEqual(labels.disemvowel("SOL SYSTEM"), "SOL SYSTM")

    def test_initials_of_several_words_and_of_one(self):
        self.assertEqual(labels.initials("PULL REQUESTS"), "PR")
        self.assertEqual(labels.initials("CHRONOMETER"), "CHR")

    def test_ladder_is_distinct_and_widest_first(self):
        rungs = list(labels.ladder("ACTIVE WORK"))
        self.assertEqual(rungs, ["ACTIVE WORK", "ACTVE WRK", "AW"])
        self.assertEqual(list(labels.ladder("SKY")), ["SKY"])

    def test_fit_takes_the_widest_that_fits(self):
        width = len
        self.assertEqual(labels.fit("PULL REQUESTS", width, 40), "PULL REQUESTS")
        self.assertEqual(labels.fit("PULL REQUESTS", width, 10), "PLL RQSTS")
        self.assertEqual(labels.fit("PULL REQUESTS", width, 5), "PR")

    def test_fit_gives_up_rather_than_clipping(self):
        # Callers fall back to cell text; a clipped block label reads as a fault.
        self.assertIsNone(labels.fit("PULL REQUESTS", len, 1))


class RailBlockTest(unittest.TestCase):
    """Vertical chips: spaced like chips, coloured by position."""

    HEIGHT = 30

    def _column(self, blocks):
        import io

        from dashboard.assets import AssetLibrary, CellSize
        from dashboard.canvas import Canvas
        from dashboard.images import ImageTransmitter
        from dashboard.palette import PERIWINKLE
        from dashboard.segments import Painter, draw_rail

        canvas = Canvas(4, self.HEIGHT)
        painter = Painter(canvas, AssetLibrary(CellSize(19, 38)),
                          ImageTransmitter(io.StringIO()), images_enabled=False)
        draw_rail(painter, Rect(0, 0, 2, self.HEIGHT), PERIWINKLE, blocks)
        return [canvas.cell(0, y).background for y in range(self.HEIGHT)]

    def test_a_gap_at_both_ends_not_just_between(self):
        from dashboard.palette import CANVAS
        from dashboard.segments import RailBlock

        column = self._column((RailBlock("A", weight=1), RailBlock("B", weight=1)))
        self.assertEqual(column[0], CANVAS, "the rail starts with a gap")
        self.assertEqual(column[-1], CANVAS, "and ends with one")
        self.assertIn(CANVAS, column[1:-1], "with one between the blocks too")

    def test_colours_come_from_the_accent_sequence_in_order(self):
        from dashboard.palette import CANVAS, accent
        from dashboard.segments import RailBlock

        column = self._column(tuple(RailBlock("B%d" % i, weight=1) for i in range(3)))
        runs = []
        for colour in column:
            if colour != CANVAS and (not runs or runs[-1] != colour):
                runs.append(colour)
        self.assertEqual(runs, [accent(0), accent(1), accent(2)])

    def test_a_block_may_still_name_its_own_colour(self):
        from dashboard.palette import CANVAS, ORANGE, accent
        from dashboard.segments import RailBlock

        column = self._column((RailBlock("A", weight=1),
                               RailBlock("B", color=ORANGE, weight=1)))
        runs = []
        for colour in column:
            if colour != CANVAS and (not runs or runs[-1] != colour):
                runs.append(colour)
        self.assertEqual(runs, [accent(0), ORANGE],
                         "a block that carries meaning departs from the sequence")

    def test_a_rail_with_no_blocks_is_a_solid_stem(self):
        from dashboard.palette import CANVAS

        column = self._column(())
        self.assertNotIn(CANVAS, column,
                         "a plain stem is continuous with the elbows above and below")


class ChipSideTest(unittest.TestCase):
    """Chips pack against the cap side, and shed from the elbow side."""

    WIDTH = 46

    def _pattern(self, left_end, right_end, chips):
        import io

        from dashboard.assets import AssetLibrary, CellSize
        from dashboard.canvas import Canvas
        from dashboard.images import ImageTransmitter
        from dashboard.palette import CANVAS as BLACK
        from dashboard.palette import PERIWINKLE
        from dashboard.segments import Bar, Painter

        canvas = Canvas(self.WIDTH, 2)
        painter = Painter(canvas, AssetLibrary(CellSize(19, 38)),
                          ImageTransmitter(io.StringIO()), images_enabled=False)
        Bar(rect=Rect(0, 0, self.WIDTH, 2), color=PERIWINKLE, rows=2,
            left_end=left_end, right_end=right_end, chips=chips).draw(painter)
        text = "".join(
            (cell.char if (cell := canvas.cell(x, 1)) is not None else " ")
            for x in range(self.WIDTH)
        )
        return text

    def test_a_left_elbow_bar_packs_its_chips_right(self):
        from dashboard.segments import Chip, End
        from dashboard.palette import GOLD

        text = self._pattern(End.ELBOW, End.CAP, (Chip("AA", GOLD),))
        self.assertGreater(text.index("AA"), self.WIDTH // 2)

    def test_a_right_elbow_bar_packs_its_chips_left(self):
        from dashboard.segments import Chip, End
        from dashboard.palette import GOLD

        text = self._pattern(End.CAP, End.ELBOW, (Chip("AA", GOLD),))
        self.assertLess(text.index("AA"), self.WIDTH // 2)

    def test_chips_are_shed_from_the_elbow_side(self):
        from dashboard.segments import Chip, End
        from dashboard.palette import GOLD, ORANGE

        many = tuple(Chip("%02d-CHIP" % index, GOLD if index % 2 else ORANGE)
                     for index in range(6))
        # Left elbow: the cap is on the right, so the last chips survive.
        text = self._pattern(End.ELBOW, End.CAP, many)
        self.assertIn("05-CHIP", text)
        self.assertNotIn("00-CHIP", text)
        # Mirrored: the cap is on the left, so the first chips survive instead.
        text = self._pattern(End.CAP, End.ELBOW, many)
        self.assertIn("00-CHIP", text)
        self.assertNotIn("05-CHIP", text)


class BlockTitlePlacementTest(unittest.TestCase):
    """Where a block-letter title lands in its bar.

    The label sits at the end AWAY from the elbow, because the elbow is where
    the bar turns into the rest of the frame. So it follows the cap: right on a
    normal bar, left on a mirrored one.
    """

    WIDTH = 60

    def bar_cells(self, left_end, right_end, title="SOL SYSTEM", chips=()):
        import io

        from dashboard.assets import AssetLibrary, CellSize
        from dashboard.canvas import Canvas
        from dashboard.images import ImageTransmitter
        from dashboard.segments import Bar, Painter
        from dashboard.palette import PERIWINKLE

        canvas = Canvas(self.WIDTH, 2)
        assets = AssetLibrary(CellSize(19, 38))
        painter = Painter(canvas, assets, ImageTransmitter(io.StringIO()))
        label_id = painter.images.image_id(
            assets.block_text(title, CANVAS_COLOR, PERIWINKLE, rows=2)
        )
        Bar(rect=Rect(0, 0, self.WIDTH, 2), color=PERIWINKLE, rows=2,
            left_end=left_end, right_end=right_end, title=title,
            title_blocks=True, chips=chips).draw(painter)
        columns = [x for x in range(self.WIDTH)
                   if (cell := canvas.cell(x, 0)) is not None and cell.image_id == label_id]
        return columns

    def test_elbow_left_puts_the_label_at_the_right(self):
        from dashboard.segments import End

        columns = self.bar_cells(End.ELBOW, End.CAP)
        self.assertTrue(columns, "no label image was placed")
        # Two bar columns plus the cap itself sit to the right of the label.
        self.assertLess(columns[-1], self.WIDTH - 2)
        self.assertGreater(columns[0], self.WIDTH // 2)

    def test_elbow_right_puts_the_label_at_the_left(self):
        from dashboard.segments import End

        columns = self.bar_cells(End.CAP, End.ELBOW)
        self.assertTrue(columns, "no label image was placed")
        self.assertLess(columns[0], self.WIDTH // 2)
        # It clears the cap on its own side rather than butting against it.
        self.assertGreaterEqual(columns[0], 2)

    def test_the_label_is_a_contiguous_run(self):
        from dashboard.segments import End

        columns = self.bar_cells(End.CAP, End.ELBOW)
        self.assertEqual(columns, list(range(columns[0], columns[-1] + 1)))


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


class ChipLayoutTest(unittest.TestCase):
    """The gap rules from docs/lcars-design.md, asserted on real cells.

    The bug these pin: only the gaps *between* chips were drawn, so a lone chip
    had black on neither side and a group had none on its outer edges. And the
    group was consumed right-to-left, silently reversing every caller's list.
    """

    BAR = 54

    def _row(self, chips):
        """Render a bar and return (pattern, text) for its label row.

        Pattern letters: ``.`` black gap, ``-`` bar fill, ``#`` chip fill,
        ``C`` a cap image cell.
        """
        import io

        from dashboard.assets import AssetLibrary, CellSize
        from dashboard.canvas import Canvas
        from dashboard.images import ImageTransmitter
        from dashboard.palette import CANVAS as BLACK
        from dashboard.palette import PERIWINKLE
        from dashboard.segments import Bar, End, Painter

        canvas = Canvas(self.BAR, 2)
        painter = Painter(canvas, AssetLibrary(CellSize(19, 38)),
                          ImageTransmitter(io.StringIO()))
        Bar(rect=Rect(0, 0, self.BAR, 2), color=PERIWINKLE, rows=2,
            left_end=End.FLAT, right_end=End.CAP, chips=chips).draw(painter)

        pattern, text = [], []
        for x in range(self.BAR):
            cell = canvas.cell(x, 1)
            assert cell is not None
            if cell.image_id is not None:
                pattern.append("C")
            elif cell.background == BLACK:
                pattern.append(".")
            elif cell.background == PERIWINKLE:
                pattern.append("-")
            else:
                pattern.append("#")
            text.append(cell.char if cell.char.strip() else " ")
        return ("".join(pattern), "".join(text))

    def test_a_lone_colored_chip_has_black_on_both_sides(self):
        from dashboard.segments import Chip
        from dashboard.palette import SAGE

        pattern, _ = self._row((Chip("15-BODIES", SAGE),))
        self.assertIn(".###########.", pattern,
                      "a colored chip must be preceded AND followed by black")

    def test_colored_chips_are_separated_and_bounded_by_black(self):
        from dashboard.segments import Chip
        from dashboard.palette import GOLD, ORANGE

        pattern, _ = self._row((Chip("AA", ORANGE), Chip("BB", GOLD)))
        self.assertIn(".####.####.", pattern,
                      "every colored chip needs black on both sides")

    def test_chips_are_drawn_in_reading_order(self):
        from dashboard.segments import Chip
        from dashboard.palette import GOLD, ORANGE

        _, text = self._row((Chip("FIRST", ORANGE), Chip("SECOND", GOLD)))
        self.assertLess(text.index("FIRST"), text.index("SECOND"),
                        "chips must render left to right as written")

    def test_a_label_chip_goes_last_with_no_trailing_gap(self):
        from dashboard.segments import Chip, ChipStyle
        from dashboard.palette import ORANGE

        pattern, text = self._row(
            (Chip("AA", ORANGE), Chip("LABEL", style=ChipStyle.LABEL)))
        self.assertLess(text.index("AA"), text.index("LABEL"))
        # A label chip is cut INTO the bar: its own cells are black, carrying
        # accent-coloured text. So it reads as black in the pattern, and what
        # follows it before the cap is bar fill and nothing else -- no second
        # black gap, because the chip has already supplied the dark ground.
        end_of_label = text.index("LABEL") + len("LABEL")
        tail = pattern[end_of_label:pattern.index("C")]
        # One black cell -- the chip's own right padding -- then bar fill up to
        # the cap. No second gap: the chip has already supplied the dark ground.
        self.assertEqual(tail, "." + "-" * (len(tail) - 1),
                         "a label chip's padding, then bar fill to the cap")
        self.assertEqual(pattern[text.index("LABEL")], ".",
                         "a label chip sits on black")

    def test_two_bar_columns_precede_the_cap(self):
        from dashboard.segments import Chip
        from dashboard.palette import SAGE

        pattern, _ = self._row((Chip("X", SAGE),))
        before_cap = pattern[:pattern.index("C")]
        self.assertTrue(before_cap.endswith("--"),
                        "design rule 6: at least two bar-color columns before a cap")

    def test_chips_are_dropped_whole_when_the_bar_is_narrow(self):
        from dashboard.segments import Chip, chips_width
        from dashboard.palette import GOLD, ORANGE

        wide = (Chip("A-LONG-ONE", ORANGE), Chip("ANOTHER-LONG", GOLD))
        self.assertGreater(chips_width(wide), 20)
        pattern, text = self._row(wide)
        # Whatever fits, no chip may be half-drawn: every run of chip cells is
        # the full width of some chip.
        for chip in wide:
            if chip.label in text:
                self.assertIn("." + "#" * chip.width, pattern)


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

    def test_real_escape_sequences_are_recognised_as_mouse(self):
        """Drive blessed's own parser, not a stand-in.

        The bug this exists for: mouse keystrokes are built through blessed's
        DEC-mode path, which supplies no keycode, so ``Keystroke.code`` is None
        and never equals ``Terminal.KEY_MOUSE`` -- despite that constant
        existing and looking like the obvious thing to test. Keying off it made
        every click dead while the region map was provably fine, because the
        clicks never reached it.
        """
        import blessed.keyboard as keyboard
        from blessed.dec_modes import DecPrivateMode

        from dashboard.interaction import Button
        from dashboard.terminal_input import is_mouse, to_click

        enabled = {int(DecPrivateMode.MOUSE_EXTENDED_SGR): 1,
                   int(DecPrivateMode.MOUSE_REPORT_CLICK): 1}

        def parse(sequence):
            return keyboard._match_dec_event(sequence, dec_mode_cache=enabled)

        press = parse("\x1b[<0;42;13M")
        self.assertTrue(is_mouse(press))
        self.assertIsNone(press.code, "if blessed starts setting a keycode, "
                                      "is_mouse can be simplified")
        click = to_click(press)
        assert click is not None
        self.assertEqual((click.x, click.y, click.button), (41, 12, Button.LEFT))

        # Releases are mouse events but must not produce a second click.
        release = parse("\x1b[<0;42;13m")
        self.assertTrue(is_mouse(release))
        self.assertIsNone(to_click(release))

        wheel = to_click(parse("\x1b[<64;5;5M"))
        assert wheel is not None
        self.assertIs(wheel.button, Button.WHEEL_UP)

        self.assertFalse(is_mouse("q"), "a plain keypress is not a mouse event")

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
            # The rail calls each layout by its short name -- a rail is only a
            # few columns wide -- so it lists rail_name, not the full one.
            self.assertEqual(labels,
                             {layouts.build(other).rail_name for other in layouts.names()})
            self.assertIn(layout.rail_name, labels)

            # The current layout is lit and inert; every other is clickable.
            inert = [b for b in blocks if b.action is None]
            self.assertEqual([b.label for b in inert], [layout.rail_name])
            # Lit means: a different colour from every other block, which all
            # carry the frame's own.
            lit = [b for b in blocks if b.action is None][0]
            others = {b.color for b in blocks if b.action is not None}
            self.assertEqual(others, {layout.frame_color})
            self.assertNotIn(lit.color, others)
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
