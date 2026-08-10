#!/usr/bin/env python3
# Trivial kitty graphics alignment probe.
# Generates a 1-cell (19x38px) periwinkle PNG, transmits it as image id 99
# via kitty virtual placement, then prints three rows:
#   row 1: [image cell] [plain periwinkle cell] [plain periwinkle cell]
#   row 2: [plain cell] [plain cell] [plain cell]  (reference)
#   row 3: [image cell alone at col 0]
# Screenshot the output and compare left edges to detect sub-cell inset.
import base64
from PIL import Image

cellw, cellh = 19, 38
img = Image.new("RGBA", (cellw, cellh), (153, 153, 255, 255))
png_path = "/tmp/trivial_align_1cell.png"
img.save(png_path)

b64 = base64.b64encode(png_path.encode()).decode()
transmit = f"\x1b_Ga=T,U=1,i=99,f=100,t=f,c=1,r=1,q=2;{b64}\x1b\\"

PH = "\U0010EEEE"
RD = ["̅", "̍", "̎", "̐", "̒"]
peri_bg = "\x1b[48;2;153;153;255m"
reset = "\x1b[0m"
img_cell = f"\x1b[38;5;99m{peri_bg}{PH}{RD[0]}{RD[0]}{reset}"

row1 = f"{transmit}{img_cell}{peri_bg} {reset}{peri_bg} {reset}"
row2 = f"{peri_bg} {reset}{peri_bg} {reset}{peri_bg} {reset}"
row3 = f"{img_cell}"

print(row1)
print(row2)
print(row3)
