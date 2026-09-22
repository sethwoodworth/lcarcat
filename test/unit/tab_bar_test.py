"""Unit tests for kitty/tab_bar.py, run inside kitty's own Python.

The tab bar module imports kitty internals (``kitty.fast_data_types``,
``kitty.tab_bar``) that exist only inside a kitty binary, so this cannot run
under a plain interpreter:

    kitty +runpy "import runpy; runpy.run_path('test/unit/tab_bar_test.py', run_name='__main__')"

No window opens. Each case drives kitty's real ``TabBar.update`` -- the two-pass
measure-then-draw loop that decides which tabs fit -- over our ``draw_tab`` on
an off-screen ``Screen``. ``TabBar.__init__`` needs a live OS window, so the bar
is built with ``object.__new__`` and only the attributes ``update`` reads. That
leans on kitty internals: if kitty renames them, this test breaks loudly rather
than passing wrongly.

Regression covered: when the right-most tab was active it was not drawn at
all. The measuring pass counted the right-aligned status readout as part of
the last tab, kitty handed that inflated width to the active tab, and its "no
room for the next tab" check then stopped before drawing it.
"""
from __future__ import annotations

import os
import re
import runpy
import sys
import unittest
from types import SimpleNamespace

from kitty import tab_bar as kitty_tab_bar
from kitty.fast_data_types import Screen

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# LCARCAT_TAB_BAR_UNDER_TEST points the suite at another copy, e.g. an older
# revision, to check that a regression case really fails without its fix.
MODULE = runpy.run_path(os.environ.get("LCARCAT_TAB_BAR_UNDER_TEST") or os.path.join(REPO, "kitty", "tab_bar.py"))
draw_tab = MODULE["draw_tab"]

ORANGE = "255:153:0"
PERIWINKLE = "153:153:255"
GOLD = "255:204:102"
RED = "255:0:0"  # kitty's own "no room for the next tab" ellipsis

# Titles copied from a real session: short, long, and very long mixed together.
LONG_TITLES = (
    "./dashboard/run.sh",
    "◐ tab_bar",
    "Loading Email List from Text File (cortex)",
    "~/code/rbac",
    "Identifying Overlapping Salesforce Objects Across Fivetran Connectors (cortex)",
    "~/code/scratch",
    "~/code/dags",
)


def render(titles, active, columns):
    """Run kitty's update loop; return (ids of tabs drawn, the line as ANSI)."""
    bar = object.__new__(kitty_tab_bar.TabBar)
    bar.screen = screen = Screen(None, 1, columns, 0, 19, 38)
    bar.laid_out_once = True
    bar.is_vertical = False
    bar.draw_func = draw_tab
    bar.draw_data = SimpleNamespace(tab_bg=lambda tab: 0, tab_fg=lambda tab: 0, default_bg=0)
    bar.active_font_style = (True, False)
    bar.inactive_font_style = (False, False)
    bar.align = lambda: None
    bar._update_edge_defaults = lambda is_vertical: False
    tabs = [
        SimpleNamespace(title=title, is_active=(index == active), tab_id=index + 1)
        for index, title in enumerate(titles)
    ]
    bar.update(tabs)
    return [extent.tab_id for extent in bar.tab_extents], screen.line(0).as_ansi()


def pill_colors(ansi):
    """Background color of each tab pill, left to right.

    A pill's label always starts with its two-digit index (or, squeezed to one
    cell, the first digit of it), which tells it apart from the rail stub and
    the status readout.
    """
    return re.findall(r"48:2:(\d+:\d+:\d+)m\d", ansi)


class ActiveTabIsAlwaysDrawn(unittest.TestCase):
    def assert_every_tab_drawn(self, titles, columns):
        for active in range(len(titles)):
            with self.subTest(columns=columns, active=active + 1):
                drawn, ansi = render(titles, active, columns)
                self.assertEqual(drawn, list(range(1, len(titles) + 1)))
                self.assertNotIn(RED, ansi, "kitty ran out of room and stopped early")
                pills = [color for color in pill_colors(ansi) if color in (ORANGE, PERIWINKLE)]
                self.assertEqual(len(pills), len(titles))
                self.assertEqual(pills[active], ORANGE)
                self.assertEqual(pills.count(ORANGE), 1)

    def test_three_short_tabs(self):
        self.assert_every_tab_drawn(("~/code/lcarcat", "…/lcarcat/kitty", "/tmp"), 181)

    def test_long_titles_wide_strip(self):
        self.assert_every_tab_drawn(LONG_TITLES, 269)

    def test_long_titles_medium_strip(self):
        self.assert_every_tab_drawn(LONG_TITLES, 181)

    def test_long_titles_narrow_strip(self):
        self.assert_every_tab_drawn(LONG_TITLES, 60)


class StatusReadout(unittest.TestCase):
    def test_shown_when_there_is_room(self):
        for active in (0, 2):
            with self.subTest(active=active + 1):
                _, ansi = render(("~/code/lcarcat", "…/lcarcat/kitty", "/tmp"), active, 181)
                self.assertIn(GOLD, ansi)

    def test_gives_way_to_tabs(self):
        _, ansi = render(LONG_TITLES, 6, 60)
        self.assertNotIn(GOLD, ansi)


class Titles(unittest.TestCase):
    def test_first_tab_keeps_its_prefix_on_a_narrow_strip(self):
        # The rail stub is not charged to the first tab's budget.
        _, ansi = render(LONG_TITLES, 0, 60)
        self.assertIn("01-", ansi)


if __name__ == "__main__":
    result = unittest.main(argv=[sys.argv[0], "-v"], exit=False).result
    sys.stdout.flush()
    sys.exit(0 if result.wasSuccessful() else 1)
