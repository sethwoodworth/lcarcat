"""lcarcat dashboard -- an LCARS landing page rendered into a kitty pane.

Flat chrome is terminal cells, curves are small PNGs placed with the kitty
graphics protocol, and the whole screen is painted as one frame from an
absolutely-positioned cell grid.

Layers, bottom to top:

``palette``   the LCARS colors, mirroring docs/palette.md
``geometry``  rectangles and terminal measurement
``canvas``    the cell grid and its ANSI serialiser
``assets``    curve PNGs generated at the probed cell size
``images``    kitty transmission and placeholder ids
``segments``  reusable LCARS pieces -- bar, elbow, cap, chip, rail, panel, meter
``widgets``   what goes inside a panel; each knows only its own Rect
``layouts``   named arrangements of widgets into panels
``app``       the render loop and CLI
"""
