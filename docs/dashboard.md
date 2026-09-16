# LCARS Dashboard

A landing page for a kitty pane: work queues on one side, the solar system on the
other. Built on the same rule as the rest of lcarcat — flat chrome is terminal
cells, curves are small PNGs placed with the kitty graphics protocol.

```
dashboard/run.sh                      # default layout, redrawing once a second
dashboard/run.sh --layout stellar-cartography
dashboard/run.sh --once               # paint one frame and leave it
dashboard/run.sh --list-layouts
```

Bound to `ctrl+a>d` (and `ctrl+a>shift+d` for the ambient layout) in
`kitty/lcarcat.keybindings.conf`.

---

## Layers

Each layer knows only about the one below it. That is the whole design: a widget
cannot reach the terminal, a segment cannot reach a data source, and a layout
cannot reach a widget's internals.

| Module | Holds | Knows nothing about |
|--------|-------|---------------------|
| `palette.py` | the LCARS colors | everything else |
| `geometry.py` | `Rect`, splits, terminal measurement | colors, cells |
| `canvas.py` | the cell grid and its ANSI serialiser | LCARS, widgets |
| `diacritics.py` | kitty's row/column placeholder table | everything else |
| `assets.py` | curve PNGs at the probed cell size | what they are used for |
| `images.py` | kitty transmission, image ids | shapes, layout |
| `segments.py` | bar, elbow, cap, chip, rail, panel, meter | what goes inside them |
| `sources/` | Jira, GitHub, ephemeris, system telemetry | colors, layout, drawing |
| `widgets/` | what fills a panel | where the panel is |
| `layouts.py` | which widgets exist and where they go | how they draw |
| `app.py` | the render loop and CLI | all of the above, individually |

### Why a canvas rather than printed lines

The dashboard is absolutely positioned — widgets write cells at screen
coordinates instead of printing in order. Two things fall out of that:

- **One write per frame.** A dashboard painted pane by pane tears visibly. The
  canvas serialises once, so a redraw lands as a single `write`.
- **Images and cells interleave correctly.** Image escapes must reach kitty
  before the placeholder cells that reference them. Batching both into one string
  makes the ordering a property of the string, not of terminal scheduling.

---

## Interaction

Clicks are dispatched against a **hit map** rebuilt every frame. Anything that
draws may claim a rectangle:

```python
painter.claim(rect, handler, label="WHAT IT IS")
```

Segments already do it where it makes sense — `RailBlock`, `Chip` and
`draw_pill` all take an `action`, so a rail block, a header chip or a pill
becomes a button by passing one. A widget wanting something finer (a single row
of a list, a marker on a plot) calls `painter.claim` directly.

Two properties worth relying on:

- **Later registration wins.** Rendering nests outermost-first — frame, panel,
  widget — so a widget's own regions beat the chrome underneath them, matching
  what is visually on top.
- **Regions never outlive a frame.** The map is cleared and rebuilt rather than
  diffed, so a pane that moved, shrank or vanished cannot leave a stale
  clickable rectangle behind.

Navigation is the first use: `Layout.navigation_blocks()` returns one rail block
per layout with the current one lit and inert. It is deliberately **not** tied to
the outer frame — if the frame goes away, those blocks move elsewhere unchanged.
Layouts customise `decorative_rail_blocks()`, *not* `frame_rail_blocks()`;
overriding the latter would silently drop navigation, and a test pins that.

Keyboard: `q` quits, `r` forces a refresh, digits `1`–`n` select a layout in the
same order the rail draws them.

### What mouse reporting costs

Turning on SGR mouse mode means kitty sends clicks to the dashboard instead of
selecting text. **Hold shift** for the terminal's own behaviour, or run with
`--no-mouse`.

The modes must be turned off again or the shell is left emitting escapes on every
mouse movement. `blessed`'s context managers cover the ordinary paths and
`TerminalInput` adds SIGTERM/SIGHUP handlers for the ones they cannot reach — a
context manager does not run on a signal. Interactive mode is off automatically
for `--once`, `--frames` and `--hold`, where there is nobody to click and the
terminal should not be touched.

---

## Segments

The reusable vocabulary, following `docs/lcars-design.md`. Segments enforce the
design laws so callers cannot break them: bars meet stems only through two-sided
elbows, caps appear only where a bar terminates, and at least two bar-color
columns precede every cap.

| Segment | What it is | Cells or image |
|---------|-----------|----------------|
| `Bar` | a horizontal accent band with terminators and chips | cells + 2 images |
| `Chip` | a labeled segment in a bar (color / hole / notch) | cells |
| `draw_rail` | a vertical stem, optionally split into labeled blocks | cells |
| `Panel` | header bar + rail + footer bar, returning a content `Rect` | composite |
| `draw_meter` | a segmented LCARS bar meter | cells |
| `draw_sparkline` | one row of block glyphs tracking a series | cells |
| `draw_pill` | a segment capped at both ends; optionally a button | cells + 2 images |

Chip gaps follow `docs/lcars-design.md`: a colored chip carries a black column
on **both** sides, a hole chip goes rightmost with `[1 black][1 bar]` before it
and nothing after, and two bar-color columns always precede a cap. `chips_width`
and `draw_chips` share that arithmetic, so the size a group reserves and the
size it draws cannot drift apart. Chips are given in reading order, left to
right, and the group is right-aligned as a whole.

`Panel` is the unit a widget actually meets. It paints the chrome and hands back
the rectangle to draw inside, so no widget computes a chrome offset. Styles:

- `BRACKET` — elbow, rail down the left, footer elbow, caps on both bars. A C
  opening to the right, which is the classic LCARS pane and has no T junctions.
- `HEADER` — a header bar only, for panes too short to carry a rail.
- `PLAIN` — no chrome; the widget owns every cell.

**The outer frame is a `Panel` too.** There is no separate frame concept — the
screen is a panel whose content area contains more panels. That is what keeps the
elbow, rail and cap rules identical at both levels.

---

## Widgets

A widget renders into a `Rect` and knows nothing about its neighbours. `refresh`
talks to data sources and may be slow; `render` is pure drawing. The loop calls
them on different schedules, so a slow Jira query cannot stall the clock. A
failing `refresh` marks that widget, and only that widget, offline.

| Name | Shows |
|------|-------|
| `jira` | assigned work items, in-flight and blocked ranked above the backlog |
| `pull-requests` | my open PRs and PRs awaiting my review, with CI and review state |
| `orrery` | the planets plotted top-down on their orbits |
| `sky` | where each body is from the ground, and whether it is up |
| `moon` | NASA's hourly Dial-A-Moon frame, with libration and eclipse data |
| `sol` | SDO's latest solar disc (AIA 304Å + PFSS field lines by default) with NOAA space weather |
| `orrery-key` | legend for the orrery: symbol, name and distance for every body |
| `stardate` | local time in block digits, date, stardate |
| `telemetry` | load, memory, disk, battery as LCARS meters |

Negative space is left empty. There is no background layer and no decorative
fill: LCARS reads as flat shapes on black, and anything painted into the gaps
competes with the chrome that is supposed to carry the design.

---

## Layouts

| Name | Shape |
|------|-------|
| `bridge` | *(default)* orrery and sky across the top, work column on the right |
| `operations` | work only, holodeck-panel style — Jira as a three-column catalogue, PRs as capped pills |
| `astrometrics` | facing frames — large orrery left with a right-facing elbow, key/moon/sun right |
| `stellar-cartography` | the sky alone — full-height orrery, sky readout, moon, clock; no work panes |
| `viewscreen` | ambient — an oversized clock with sky and queue counts |

A layout is the only place that decides which widgets exist, where they go, and
what color their chrome is. Adding a fifth layout means adding a class; it does
not mean touching a widget.

---

## Data sources

Every source tries live access, falls back to a cache, and reports the cache's
age so the pane can mark itself stale rather than quietly showing yesterday's
work. None of them raise into the render loop.

### GitHub

One `gh api graphql` call covering both queues. GraphQL rather than two
`gh search prs` calls because the REST search `gh` exposes through `--json`
cannot report a review decision or a CI rollup, and those are the two facts that
decide whether a pull request needs attention. `gh` owns authentication, so there
is nothing to configure.

### Jira

Two ways in, tried in order:

1. **`acli`** — Atlassian's CLI. The live path. Needs a one-time login:

   ```
   acli jira auth login
   ```

2. **Cache** — `~/.cache/lcarcat/dashboard/jira-work-items.json`. An agent with
   Jira access (or any script) can fill this without a credential ever reaching
   the terminal:

   ```
   dashboard/tools/refresh_jira_cache.py search-result.json
   some-command-producing-json | dashboard/tools/refresh_jira_cache.py -
   ```

The parser accepts the REST `/search` shape, the MCP server's shape, a bare list,
and its own cache format — producers spell the same field three different ways
(`issuetype`, `issueType`, `issue_type`) and a dashboard pane is not worth
breaking over which one wrote the file.

Set a different query with `JiraWidget(jql=...)` in a layout; the default is
everything assigned to you that is not Done, freshest first.

### The sun

No NASA SVS equivalent of Dial-A-Moon exists — `/api/dialamoon/` is the only
endpoint of that shape; `dialasun`, `sun` and `solar` all 404. So the sun pane
pairs two sources:

- **SDO** publishes its latest frames as plain JPEGs at fixed URLs
  (`sdo.gsfc.nasa.gov/assets/img/latest/latest_1024_<channel>.jpg`). No key, no
  metadata, and Pillow reads them directly. SDO publishes **33** channels; half
  carry a `pfss` suffix, meaning the frame includes a Potential Field Source
  Surface overlay — the computed coronal magnetic field lines drawn arcing off
  the limb. Default is `0304pfss`: AIA 304Å chromosphere plus field lines.
  `SolWidget(channel=...)` takes any key from `CHANNELS`, so different layouts
  can show different views.
- **NOAA SWPC** publishes the numbers as small JSON documents: X-ray flare
  class, F10.7 radio flux, solar wind speed, planetary K index, and the R/S/G
  severity scales.

Helioviewer offers a genuine timestamped API over the same imagery and is the
better source for a *specific moment* — but `getJP2Image` returns JPEG 2000,
which Pillow cannot decode without OpenJPEG, and its PNG path goes through a
heavy screenshot call. Worth revisiting to flip between AIA wavelengths.

### Ephemeris

`astropy` supplies the sun, the moon and the eight planets.

An earlier version computed them from Keplerian elements, justified by astropy's
import cost. That justification did not survive being measured properly:

| | |
|---|---|
| warm import | 0.30–0.50 s, once |
| first query | 0.34 s, once |
| **nine bodies, subsequently** | **0.02–0.04 s per refresh** |

The figure that drove the original decision — 3.8 s — came from
`uv run --with astropy`, which folds environment resolution into the
measurement, taken once on cold bytecode. Four hundredths of a second per
refresh on a background thread is not worth trading accuracy for.

**Minor planets are still computed locally**, because no ephemeris astropy can
reach contains them. Its `builtin` covers the sun, the moon and the eight
planets and nothing else — not even Pluto — and Ceres, Haumea, Makemake and Eris
appear in no DE kernel at all. Those five use osculating elements from JPL's
Small-Body Database with a two-body propagation.

Their *frame* conversions still go through astropy. One trap worth knowing:
convert to `ICRS` rather than `GCRS` and Ceres lands 22° wrong, because ICRS is
barycentric and a body at 2.7 au has a large parallax from Earth's 1 au offset.

`astropy.utils.iers.conf.auto_download` is switched **off**. Earth-orientation
data is fetched on demand by default, which makes the first query depend on the
network and can stall startup; the bundled table is far better than anything
this dashboard displays.

Set the observing site — altitude and azimuth are meaningless without one:

```
export LCARCAT_OBSERVER="40.7128,-74.0060,new york"
```

The default is New York, labeled on screen so it is obvious when it is wrong.

---

## The tab bar

`kitty/tab_bar.py`, loaded by `tab_bar_style custom` in `kitty/lcars.conf`,
deployed to `~/.config/kitty/tab_bar.py`.

A title template describes **one tab**. The LCARS strip needs a left rail stub, a
right-aligned stardate and clock, and titles rewritten into chip form — all
properties of the whole bar, none expressible in a template. The custom hook gets
every cell of the strip.

The strip is one row, so it follows one-row bar rules: flat runs are colored
cells, the rounded ends are the powerline half-circle glyphs (the graphics
protocol is not available on that strip), and pills are separated by explicit
black columns. Tab backgrounds stay black in the config so the cap glyphs render
on black — a cap drawn over a colored background fills its own rounded notch and
squares the corner.

> **If it breaks, the tab bar disappears in every window.** A `tab_bar.py` that
> raises takes the strip down everywhere. Test with
> `test/captures/tab_bar.sh`, which builds an isolated kitty config directory
> from the repo rather than touching `~/.config`.

---

## Testing

| Question | Run |
|----------|-----|
| Does the arithmetic hold — splits, truncation, parsing, ephemeris? | `uv run --with astropy --with pillow python test/unit/dashboard_test.py` |
| Do the elbows meet their bars? Does it look right? | `bash test/captures/dashboard.sh` |
| Does the tab bar render? | `bash test/captures/tab_bar.sh` |

The split is the usual one for this repo: anything with a computable answer is a
unit test, and anything whose answer is "does this look right" is a capture
evaluated by eye (or by the `visual-inspector` subagent). Screenshots land in
`test/screenshots/dashboard/` and `test/screenshots/tab_bar/`.

`--size COLUMNSxROWS` renders at a fixed geometry without resizing a window, and
`--frames N` exits after N frames, which is what the capture scripts use.
`--offline` renders from cache only, for testing without touching the network.
