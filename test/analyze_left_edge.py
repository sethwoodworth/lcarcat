#!/usr/bin/env python3
"""Analyze the left edge of the LCARS prompt for pixel-level alignment.

Reads a full screenshot PNG (Retina 2x, so 1 terminal pixel = 2 device pixels),
crops the leftmost columns, and reports:
  - The first non-black device pixel in each row (to find where image content starts)
  - Whether the STARDATE bg cell starts at device x=0 or x>0
  - The gap in device pixels between the terminal left edge and the image stem
"""
import sys
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/lcarcat-screenshots/prompt-left-edge.png"
img = Image.open(path).convert("RGBA")
W, H = img.size
print(f"Full image: {W}x{H} device pixels")

# The terminal window may have a border/chrome at the top; find the first row
# where we see a non-transparent, non-white pixel (the kitty tab bar chrome).
# We'll scan from the left edge across the middle of the image height.

# Crop: leftmost 80 device pixels, full height.
CROP_W = 80
crop = img.crop((0, 0, CROP_W, H))

# Find terminal content rows by scanning for the first row with a black background
# (terminal background = #000000) — that's where the shell window starts.
print(f"\nScanning left {CROP_W}px wide strip...")

# Collect per-row: first non-black x, color at x=0, color at x=2
BLACK = (0, 0, 0, 255)
PERIWINKLE = (153, 153, 255, 255)
SKY = (102, 153, 204, 255)

def color_label(px):
    r, g, b, a = px
    if a == 0:
        return "transparent"
    if r == 0 and g == 0 and b == 0:
        return "black"
    if abs(r - 153) < 10 and abs(g - 153) < 10 and abs(b - 255) < 10:
        return "periwinkle"
    if abs(r - 102) < 15 and abs(g - 153) < 15 and abs(b - 204) < 15:
        return "sky-blue"
    if r > 200 and g > 200 and b > 200:
        return "white/chrome"
    return f"rgb({r},{g},{b})"

# Find terminal top (first row with black px at x=0..5)
terminal_top = None
for y in range(H):
    px = img.getpixel((0, y))
    if px == BLACK or (px[0] < 20 and px[1] < 20 and px[2] < 20 and px[3] > 200):
        terminal_top = y
        break

print(f"Terminal content starts at y={terminal_top} (device px from image top)")

if terminal_top is None:
    print("Could not find terminal top — dumping first 20 rows x=0:")
    for y in range(20):
        print(f"  y={y}: {img.getpixel((0,y))}")
    sys.exit(1)

# Scan rows in the terminal area, reporting every row's left-edge profile.
# Focus on the top ~250 device pixels (covers ~6 rows at 38px/row * 2x = ~76 device px per row).
SCAN_ROWS = min(terminal_top + 300, H)

print(f"\nRow-by-row left-edge scan (y={terminal_top}..{SCAN_ROWS}):")
print(f"{'y':>5}  {'x=0':>12}  {'first non-black x':>18}  {'color at first':>18}")

prev_label = None
run_start = terminal_top
for y in range(terminal_top, SCAN_ROWS):
    px0 = img.getpixel((0, y))
    label0 = color_label(px0)
    # Find first non-black pixel
    first_nb_x = None
    first_nb_color = None
    for x in range(CROP_W):
        px = img.getpixel((x, y))
        if color_label(px) not in ("black", "transparent"):
            first_nb_x = x
            first_nb_color = color_label(px)
            break
    summary = f"x=0:{label0:12s}  first_nonblack_x={str(first_nb_x):>4}  ({first_nb_color})"
    if summary != prev_label:
        if prev_label is not None:
            print(f"  y={run_start:4d}..{y-1:4d}  {prev_label}")
        prev_label = summary
        run_start = y

if prev_label:
    print(f"  y={run_start:4d}..{SCAN_ROWS-1:4d}  {prev_label}")

# Specifically find the STARDATE row: first row where x=0 is sky-blue
print("\nLooking for STARDATE row (x=0 = sky-blue):")
for y in range(terminal_top, SCAN_ROWS):
    px = img.getpixel((0, y))
    if color_label(px) == "sky-blue":
        print(f"  Found sky-blue at y={y}, x=0: {px}")
        # Report x=0..10 for this row
        print(f"  Row profile x=0..20: {[color_label(img.getpixel((x,y))) for x in range(21)]}")
        break
else:
    print("  No sky-blue found at x=0 in scanned range.")
    # Try searching at x=2 in case there's a 1px border
    for y in range(terminal_top, SCAN_ROWS):
        px = img.getpixel((2, y))
        if color_label(px) == "sky-blue":
            print(f"  Found sky-blue at y={y}, x=2: {px}")
            print(f"  Row profile x=0..20: {[color_label(img.getpixel((x,y))) for x in range(21)]}")
            break

# Report the periwinkle stem rows: where does periwinkle start at x=0 vs x=2?
print("\nLooking for periwinkle at x=0 (elbow stem/bar rows):")
peri_rows = []
for y in range(terminal_top, SCAN_ROWS):
    px = img.getpixel((0, y))
    if color_label(px) == "periwinkle":
        peri_rows.append(y)

if peri_rows:
    print(f"  Periwinkle at x=0: y={peri_rows[0]}..{peri_rows[-1]} ({len(peri_rows)} device rows)")
else:
    print("  No periwinkle found at x=0 — checking x=1, x=2:")
    for x_check in [1, 2, 3, 4]:
        for y in range(terminal_top, SCAN_ROWS):
            px = img.getpixel((x_check, y))
            if color_label(px) == "periwinkle":
                print(f"  First periwinkle at x={x_check}, y={y}: {px}")
                break
