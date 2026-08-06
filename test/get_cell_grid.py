#!/usr/bin/env python3
"""Read per-cell semantic colors from kitty's terminal grid via `kitty @ get-text --ansi`.

This gives you what *nvim told the terminal*, not what rendered on screen.
Cross-referencing with analyze_gutter_cells.py (pixel-level) lets you
distinguish a logic bug (wrong color in the cell model) from a rendering bug
(correct model, wrong pixels on screen).

Usage:
  get_cell_grid.py --socket unix:/tmp/lcarcat-test.sock --window 3
      [--col 0]               # column to inspect (0-indexed)
      [--expect-bg COLOR]     # assert all cells in that column have this bg
      [--verbose]             # print per-row color table

  COLOR values: periwinkle, orange, black, sky, or #rrggbb hex

Exit codes: 0 = pass (or no assertion), 1 = assertion failed, 2 = tool error.
"""
import sys
import argparse
import re
import subprocess

# Named LCARS colors — same as analyze_gutter_cells.py
NAMED_COLORS = {
    "periwinkle": (153, 153, 255),
    "stem":       (153, 153, 255),
    "orange":     (255, 153,   0),
    "black":      (  0,   0,   0),
    "sky":        (102, 153, 204),
    "sky-blue":   (102, 153, 204),
    "gold":       (255, 204, 102),
    "sage":       (153, 204, 153),
    "red":        (255,  51,   0),
    "lilac":      (204, 153, 204),
    "stem-dim":   ( 92,  92, 153),
}
COLOR_TOLERANCE = 12


def parse_color(s):
    s = s.lower().strip()
    if s in NAMED_COLORS:
        return NAMED_COLORS[s]
    m = re.fullmatch(r"#([0-9a-f]{6})", s)
    if m:
        h = m.group(1)
        return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))
    raise ValueError(f"Unknown color: {s!r}")


def color_label(rgb):
    if rgb is None:
        return "default"
    r, g, b = rgb
    for name, (nr, ng, nb) in NAMED_COLORS.items():
        if abs(r - nr) <= COLOR_TOLERANCE and abs(g - ng) <= COLOR_TOLERANCE and abs(b - nb) <= COLOR_TOLERANCE:
            return name
    return f"#{r:02x}{g:02x}{b:02x}"


def color_matches(rgb, target):
    if rgb is None:
        return False
    r, g, b = rgb
    tr, tg, tb = target
    return abs(r - tr) <= COLOR_TOLERANCE and abs(g - tg) <= COLOR_TOLERANCE and abs(b - tb) <= COLOR_TOLERANCE


def parse_ansi_color_param(params, idx):
    """Parse a color from SGR params starting at idx. Return (rgb_or_None, next_idx).

    Handles:
      30-37, 40-47              classic 8 colors
      90-97, 100-107            bright 8 colors
      38;2;r;g;b / 48;2;r;g;b  24-bit truecolor
      38;5;n / 48;5;n           256-color (approximated)
      39 / 49                   default color
    """
    p = params[idx]
    # Truecolor: 38;2;r;g;b or 48;2;r;g;b
    if p in (38, 48) and idx + 3 < len(params) and params[idx + 1] == 2:
        r, g, b = params[idx + 2], params[idx + 3], params[idx + 4]
        return (r, g, b), idx + 5
    # 256-color: 38;5;n or 48;5;n
    if p in (38, 48) and idx + 2 < len(params) and params[idx + 1] == 5:
        n = params[idx + 2]
        rgb = ansi256_to_rgb(n)
        return rgb, idx + 3
    # Classic 8 fg
    if 30 <= p <= 37:
        return ansi8_to_rgb(p - 30), idx + 1
    # Classic 8 bg
    if 40 <= p <= 47:
        return ansi8_to_rgb(p - 40), idx + 1
    # Bright fg
    if 90 <= p <= 97:
        return ansi8_bright_to_rgb(p - 90), idx + 1
    # Bright bg
    if 100 <= p <= 107:
        return ansi8_bright_to_rgb(p - 100), idx + 1
    # Default
    if p in (39, 49):
        return None, idx + 1
    return None, idx + 1


def ansi8_to_rgb(n):
    TABLE = [
        (0,0,0), (128,0,0), (0,128,0), (128,128,0),
        (0,0,128), (128,0,128), (0,128,128), (192,192,192),
    ]
    return TABLE[n % 8]


def ansi8_bright_to_rgb(n):
    TABLE = [
        (128,128,128), (255,0,0), (0,255,0), (255,255,0),
        (0,0,255), (255,0,255), (0,255,255), (255,255,255),
    ]
    return TABLE[n % 8]


def ansi256_to_rgb(n):
    if n < 16:
        return ansi8_to_rgb(n) if n < 8 else ansi8_bright_to_rgb(n - 8)
    if n < 232:
        n -= 16
        b = n % 6; n //= 6
        g = n % 6; r = n // 6
        def v(x): return 0 if x == 0 else 55 + 40 * x
        return (v(r), v(g), v(b))
    gray = 8 + (n - 232) * 10
    return (gray, gray, gray)


def parse_ansi_to_grid(text):
    """Parse ANSI-escaped text into a 2D grid of (char, fg_rgb, bg_rgb) tuples.

    Returns list of rows; each row is a list of (char, fg, bg) where fg/bg are
    (r,g,b) tuples or None for terminal default.
    """
    rows = []
    current_row = []
    fg = None
    bg = None

    # Split on CSI sequences: ESC[ ... m  (SGR) and literal newlines
    # Also handle ESC sequences that are NOT CSI (e.g. graphics protocol) — skip them.
    i = 0
    while i < len(text):
        ch = text[i]

        if ch == '\x1b':
            # Check next char
            if i + 1 < len(text):
                nxt = text[i + 1]
                if nxt == '[':
                    # CSI sequence: collect until final byte (0x40-0x7e)
                    j = i + 2
                    while j < len(text) and not (0x40 <= ord(text[j]) <= 0x7e):
                        j += 1
                    seq = text[i + 2:j]
                    final = text[j] if j < len(text) else ''
                    i = j + 1
                    if final == 'm':
                        # SGR — parse color params.
                        # Normalize ISO 8613-6 colon sub-parameter form to semicolons:
                        # "38:2:r:g:b" → "38;2;r;g;b" so the same parser handles both.
                        if not seq or seq == '0':
                            fg = None; bg = None
                        else:
                            seq = seq.replace(':', ';')
                            parts = [int(x) if x else 0 for x in seq.split(';')]
                            pi = 0
                            while pi < len(parts):
                                p = parts[pi]
                                if p == 0:
                                    fg = None; bg = None; pi += 1
                                elif p == 1:
                                    pi += 1  # bold — ignore
                                elif p == 3:
                                    pi += 1  # italic — ignore
                                elif p == 4:
                                    pi += 1  # underline — ignore
                                elif p == 22:
                                    pi += 1  # normal intensity — ignore
                                elif p == 23:
                                    pi += 1  # not italic — ignore
                                elif p == 24:
                                    pi += 1  # not underlined — ignore
                                elif p in (30, 31, 32, 33, 34, 35, 36, 37, 38, 39,
                                           90, 91, 92, 93, 94, 95, 96, 97):
                                    color, pi = parse_ansi_color_param(parts, pi)
                                    fg = color
                                elif p in (40, 41, 42, 43, 44, 45, 46, 47, 48, 49,
                                           100, 101, 102, 103, 104, 105, 106, 107):
                                    # shift to bg index for parse_ansi_color_param
                                    # map 40-47 → 30-37 and 48 → 38 etc.
                                    shifted = list(parts)
                                    shifted[pi] = p - 10
                                    color, next_pi = parse_ansi_color_param(shifted, pi)
                                    pi = next_pi
                                    bg = color
                                else:
                                    pi += 1
                    # other CSI sequences (cursor movement etc.) — ignore
                    continue
                elif nxt in ('_', 'G'):
                    # APC or other non-CSI — skip to ST (ESC \) or BEL
                    j = i + 2
                    while j < len(text):
                        if text[j] == '\x07':
                            j += 1; break
                        if text[j] == '\x1b' and j + 1 < len(text) and text[j+1] == '\\':
                            j += 2; break
                        j += 1
                    i = j
                    continue
                else:
                    # Other ESC sequence — skip 2 chars
                    i += 2
                    continue
            else:
                i += 1
                continue

        elif ch == '\n':
            rows.append(current_row)
            current_row = []
            i += 1

        elif ch == '\r':
            i += 1

        else:
            current_row.append((ch, fg, bg))
            i += 1

    if current_row:
        rows.append(current_row)

    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--socket",     required=True, help="kitty listen socket, e.g. unix:/tmp/lcarcat-test.sock")
    ap.add_argument("--window",     default=None,  help="kitty window id (from kitty @ ls .windows[].id)")
    ap.add_argument("--col",        type=int, default=0, help="Terminal column to inspect (0-indexed)")
    ap.add_argument("--skip-rows",  type=int, default=0, help="Skip N rows from the top")
    ap.add_argument("--skip-bottom",type=int, default=1, help="Skip N rows from the bottom (default: 1 for statusline)")
    ap.add_argument("--expect-bg",  default=None,  help="Assert this bg color in all sampled cells")
    ap.add_argument("--verbose",    action="store_true")
    args = ap.parse_args()

    # Build the kitty @ get-text command
    cmd = ["kitty", "@", "--to", args.socket, "get-text", "--ansi", "--extent", "screen"]
    if args.window is not None:
        cmd += ["--match", f"id:{args.window}"]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    except FileNotFoundError:
        print("FAIL: kitty not found in PATH", file=sys.stderr)
        sys.exit(2)
    except subprocess.TimeoutExpired:
        print("FAIL: kitty @ get-text timed out", file=sys.stderr)
        sys.exit(2)

    if result.returncode != 0:
        print(f"FAIL: kitty @ get-text exited {result.returncode}: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(2)

    grid = parse_ansi_to_grid(result.stdout)
    total_rows = len(grid)

    if total_rows == 0:
        print("FAIL: empty grid returned", file=sys.stderr)
        sys.exit(2)

    end_row = total_rows - args.skip_bottom
    sampled_rows = range(args.skip_rows, end_row)

    if args.verbose:
        print(f"Grid: {total_rows} rows x {max(len(r) for r in grid) if grid else 0} cols")
        print(f"Sampling column {args.col}, rows {args.skip_rows}..{end_row - 1}")
        print(f"\n{'row':>4}  {'char':>4}  {'fg':>18}  {'bg':>18}")

    target_rgb = parse_color(args.expect_bg) if args.expect_bg else None
    failures = []

    for row_idx in sampled_rows:
        row = grid[row_idx]
        if args.col < len(row):
            char, fg, bg = row[args.col]
        else:
            char, fg, bg = (" ", None, None)

        bg_label = color_label(bg)
        fg_label = color_label(fg)

        if args.verbose:
            print(f"{row_idx:>4}  {repr(char):>4}  {fg_label:>18}  {bg_label:>18}")

        if target_rgb is not None and not color_matches(bg, target_rgb):
            failures.append((row_idx, char, bg_label))

    if target_rgb is None:
        sys.exit(0)

    sampled_count = len(sampled_rows)
    if failures:
        print(f"FAIL: column {args.col} semantic bg — expected {args.expect_bg}, "
              f"{len(failures)}/{sampled_count} rows differ:")
        for row_idx, char, bg_label in failures[:10]:
            print(f"  row {row_idx} (char={repr(char)}): bg={bg_label}")
        if len(failures) > 10:
            print(f"  ... and {len(failures) - 10} more")
        sys.exit(1)

    print(f"PASS: column {args.col} semantic bg — all {sampled_count} rows are {args.expect_bg}")
    sys.exit(0)


if __name__ == "__main__":
    main()
