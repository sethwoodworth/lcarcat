#!/usr/bin/env python3
"""Experimental: render an LCARS elbow via kitty's UNICODE PLACEHOLDER protocol.

Instead of cursor-anchored direct placement (a=T,C=1 — what the other demos and
the zsh prompt use), this binds the image to *text cells*: you transmit the image
once as a "virtual placement" (U=1) tied to an image id, then print placeholder
cells (U+10EEEE) wherever you want it drawn. Each cell carries:

  * the image id in its FOREGROUND COLOR   (low 24 bits -> R;G;B)
  * a row diacritic and a column diacritic (which slice of the image goes here)

This is the mechanism we want for neovim: the image sticks to the cells we
control (tabline / statusline strings), so it survives redraw and scroll.

SELF-SIZING: a virtual placement is scaled by kitty to fit c x r cells. If the
PNG's pixel size doesn't match c*cellw x r*cellh for THIS kitty, kitty resamples
and you get a ~1px offset. So we first ask kitty for its real cell pixel size
(CSI 16 t) and regenerate the elbow at exactly that size -> no scaling, no offset.
This is also the primitive for generating elbows sized to the number-gutter and
bar widths dynamically.

Run inside kitty:
    python3 demos/placeholder_preview.py
"""
import base64
import os
import re
import select
import subprocess
import sys

# kitty rowcolumn-diacritics, index 0.. (kitty/gen/rowcolumn-diacritics.txt).
DIAC = [
    0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F, 0x0346, 0x034A,
    0x034B, 0x034C, 0x0350, 0x0351, 0x0352, 0x0357, 0x035B, 0x0363, 0x0364, 0x0365,
    0x0366, 0x0367, 0x0368, 0x0369, 0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F,
]
PLACEHOLDER = "\U0010EEEE"
COLS, ROWS = 5, 3  # elbow-top = elbow-cols(5) x (bar 2 + stem 1)


def query_cell_px():
    """Ask kitty for cell size in pixels: CSI 16 t -> CSI 6 ; height ; width t."""
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
                break  # no/again response -> give up
            buf += os.read(fd, 1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
    m = re.search(rb"\x1b\[6;(\d+);(\d+)t", buf)
    return (int(m.group(2)), int(m.group(1))) if m else None  # (width, height)


def regen_elbow(cellw, cellh, assets, gen):
    """Regenerate the periwinkle elbow at exactly COLS*cellw x ROWS*cellh px."""
    subprocess.run(
        ["uv", "run", "--with", "pillow", gen, "--color", "9999ff",
         "--outdir", assets, "--stem-rows", "1", "--elbow-cols", str(COLS),
         "--cellw", str(cellw), "--cellh", str(cellh)],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def place(path, img_id, cols, rows):
    """Transmit `path` as a virtual placement and draw it with placeholder cells."""
    b64_path = base64.standard_b64encode(path.encode()).decode()
    sys.stdout.write(
        f"\033_Ga=T,U=1,i={img_id},q=2,f=100,t=f,c={cols},r={rows};{b64_path}\033\\"
    )
    r8, g8, b8 = (img_id >> 16) & 0xFF, (img_id >> 8) & 0xFF, img_id & 0xFF
    for r in range(rows):
        sys.stdout.write(f"\033[38;2;{r8};{g8};{b8}m")  # fg = image id
        for c in range(cols):
            sys.stdout.write(PLACEHOLDER + chr(DIAC[r]) + chr(DIAC[c]))
        sys.stdout.write("\033[0m\n")
    sys.stdout.flush()


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    assets = os.path.abspath(os.path.join(here, "..", "nvim", "assets"))
    gen = os.path.abspath(os.path.join(here, "..", "generate", "gen_swoops.py"))
    sys.path.insert(0, os.path.dirname(gen))
    from gen_swoops import asset_name  # reuse the generator's naming so we read the right file

    cell = query_cell_px()
    if cell:
        cw, ch = cell
        print(f"kitty cell = {cw}x{ch}px -> regenerating elbow at {COLS * cw}x{ROWS * ch}px")
        regen_elbow(cw, ch, assets, gen)
    else:
        cw, ch = 19, 40
        print("could not detect cell size (not a kitty tty?); using existing 19x40 asset")
    # Top-left elbow (no mirror), periwinkle, no baked background.
    img = os.path.join(assets, asset_name(
        "elbow", "9999ff", COLS, ROWS, cw, ch, orient="top", facing="left"))
    if not os.path.exists(img):
        sys.exit(f"missing asset: {img}")
    place(img, img_id=1234, cols=COLS, rows=ROWS)
