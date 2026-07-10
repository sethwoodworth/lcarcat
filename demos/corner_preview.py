#!/usr/bin/env python3
"""Experimental: nvim-style top-left CORNER elbow, merged into a mock chrome.

Renders the `corner-tl` elbow (a 1-row bar whose left end rounds down into an
N-column stem = the number-gutter width) via kitty Unicode placeholders, over a
mocked periwinkle tabline row + gutter stem, so we can judge how the fixed corner
merges with BOTH rows without covering the pills or the number bar.

Self-sizes: queries the cell pixel size (CSI 16 t) and regenerates the corner at
exactly that size so kitty does no scaling (no 1px offset). The image is
transmitted ONCE as a virtual placement (image id); the placeholder cells then
reference it — no PNG resend.

Run inside kitty:
    python3 demos/corner_preview.py
"""
import base64
import os
import re
import select
import subprocess
import sys

DIAC = [
    0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F, 0x0346, 0x034A,
    0x034B, 0x034C, 0x0350, 0x0351, 0x0352, 0x0357, 0x035B, 0x0363, 0x0364, 0x0365,
]
PH = "\U0010EEEE"
PERI = "153;153;255"   # #9999ff periwinkle bar/stem
BLACK = "0;0;0"
SKY = "102;153;204"    # #6699cc non-selected pill
N = 4                  # stem cols (mock number-gutter width)
BAR_ROWS = 1           # nvim tabline is one row
STEM_ROWS = 1          # rows of stem shown in the image (curve); gutter continues below
IMG_ID = 4242


def query_cell_px():
    if not sys.stdin.isatty():
        return None
    import termios
    import tty
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    buf = b""
    try:
        tty.setraw(fd)
        sys.stdout.write("\x1b[16t")
        sys.stdout.flush()
        while b"t" not in buf:
            if not select.select([fd], [], [], 0.3)[0]:
                break
            buf += os.read(fd, 1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
    m = re.search(rb"\x1b\[6;(\d+);(\d+)t", buf)
    return (int(m.group(2)), int(m.group(1))) if m else None


def regen_corner(cw, ch, assets, gen):
    subprocess.run(
        ["uv", "run", "--with", "pillow", gen, "--color", "9999ff",
         "--outdir", assets, "--stem-rows", str(STEM_ROWS), "--cellw", str(cw),
         "--cellh", str(ch), "--bar-rows", str(BAR_ROWS), "--stem-cols", str(N)],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def fg_id():
    return f"\033[38;2;{(IMG_ID >> 16) & 255};{(IMG_ID >> 8) & 255};{IMG_ID & 255}m"


def corner_row(row, cols):
    """Placeholder cells for image `row`, columns 0..cols-1."""
    s = fg_id()
    for c in range(cols):
        s += PH + chr(DIAC[row]) + chr(DIAC[c])
    return s + "\033[0m"


def peri(text):
    return f"\033[48;2;{PERI}m\033[38;2;{BLACK}m{text}\033[0m"


def pill(text, bg):
    return f"\033[48;2;{bg}m\033[38;2;{BLACK}m{text}\033[0m"


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    assets = os.path.abspath(os.path.join(here, "..", "nvim", "assets"))
    gen = os.path.abspath(os.path.join(here, "..", "generate", "gen_swoops.py"))
    img = os.path.join(assets, "corner-tl.png")

    cell = query_cell_px()
    if cell:
        cw, ch = cell
        print(f"kitty cell = {cw}x{ch}px -> regenerating corner "
              f"(bar {BAR_ROWS}r, stem {N}c) at {(N + 2) * cw}x{(BAR_ROWS + STEM_ROWS) * ch}px")
        regen_corner(cw, ch, assets, gen)
    else:
        print("could not detect cell size (not a kitty tty?); using existing asset")
    if not os.path.exists(img):
        sys.exit(f"missing asset: {img}")

    W = N + 2                      # image cols (stem + fillet room)
    H = BAR_ROWS + STEM_ROWS       # image rows

    # Transmit ONCE as a virtual placement bound to IMG_ID.
    b64 = base64.standard_b64encode(img.encode()).decode()
    sys.stdout.write(
        f"\033_Ga=T,U=1,i={IMG_ID},q=2,f=100,t=f,c={W},r={H};{b64}\033\\"
    )

    # Row 0 (tabline): corner-left + periwinkle bar carrying the buffer pills.
    sys.stdout.write(
        corner_row(0, W) + peri(" ") + pill(" 01-views.py ", PERI)
        + peri(" ") + pill(" 02-other.py ", SKY) + peri("   ") + "\n"
    )
    # Row 1 (first buffer line): corner-stem+fillet on the left, code to the right.
    sys.stdout.write(corner_row(1, W) + "  import os\n")
    # Rows 2..: gutter stem (N cols periwinkle) + code; the corner has merged into
    # the flat periwinkle stem below.
    for ln, code in (("2", "def smartModelQuery(request):"),
                     ("3", "    return None"),
                     ("4", "")):
        sys.stdout.write(peri(f"{ln:>{N}}") + "  " + code + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    main()
