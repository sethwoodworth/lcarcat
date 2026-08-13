#!/usr/bin/env python3
"""Print alternating black/red columns across the terminal width.

Each character cell gets a solid background (no text), alternating between
black (#000000) and red (#ff0000) every column. One row of cells per line,
filling the terminal width. Run this in the test kitty shell then capture
a screenshot to measure exact cell width, height, and terminal origin.

Usage:
  python3 test/fixtures/calibration_cells.py [--rows N] [--cols N]

Defaults to 40 rows x 200 cols — enough to cover a 900-wide window at any
reasonable cell size. The actual terminal will clip to its own dimensions.
"""
import sys
import argparse

BLACK = "\x1b[48;2;0;0;0m"
RED   = "\x1b[48;2;255;0;0m"
RESET = "\x1b[0m"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rows", type=int, default=40, help="Rows to fill (default 40)")
    ap.add_argument("--cols", type=int, default=200, help="Cols per row (default 200)")
    args = ap.parse_args()

    # Move cursor to top-left, clear screen
    sys.stdout.write("\x1b[H\x1b[2J")

    for _ in range(args.rows):
        row = ""
        for c in range(args.cols):
            row += (BLACK if c % 2 == 0 else RED) + " "
        row += RESET + "\n"
        sys.stdout.write(row)

    sys.stdout.flush()


if __name__ == "__main__":
    main()
