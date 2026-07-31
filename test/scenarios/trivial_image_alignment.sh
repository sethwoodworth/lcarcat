#!/usr/bin/env bash
# Trivial alignment test: single-cell image vs plain bg cell side by side.
# Transmits a 1x1 periwinkle PNG via kitty graphics protocol, then renders:
#   [image cell] [plain periwinkle bg cell] [plain periwinkle bg cell]
# If image placement is flush with cell column 0, all three should have the
# same left edge. If the image is inset, the plain cells will appear wider.

set -euo pipefail

H="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/screenshot_harness.sh"
ASSETS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lcarcat/assets"

mkdir -p /tmp/lcarcat-screenshots
trap '"$H" teardown >/dev/null 2>&1 || true' EXIT INT TERM

"$H" launch
sleep 1.5

# Write a test script into the shell that:
# 1. Generates a 1-cell (19x38px) solid periwinkle PNG
# 2. Transmits it as image id 99 via kitty virtual placement
# 3. Prints: [image placeholder] [plain bg cell] [plain bg cell] [newline]
# 4. Prints: [plain bg cell] [plain bg cell] [plain bg cell] for comparison
"$H" send-text 'python3 /tmp/trivial_align_test.py'$'\n'
sleep 0.3

# Write the test script first, then trigger it
SCRIPT=$(cat <<'PYEOF'
import os, base64, subprocess
from PIL import Image

# Create a 19x38px solid periwinkle PNG (1 cell at cellw=19, cellh=38)
cellw, cellh = 19, 38
color = (153, 153, 255, 255)
img = Image.new("RGBA", (cellw, cellh), color)
png_path = "/tmp/trivial_align_1cell.png"
img.save(png_path)

# Transmit as virtual placement id=99
b64 = base64.b64encode(png_path.encode()).decode()
transmit = f"\x1b_Ga=T,U=1,i=99,f=100,t=f,c=1,r=1,q=2;{b64}\x1b\\"

# Build placeholder cell for image id 99, row 0, col 0
PH = "\U0010EEEE"
RD = ["̅", "̍", "̎", "̐", "̒"]
peri_bg = "\x1b[48;2;153;153;255m"
reset = "\x1b[0m"
img_cell = f"\x1b[38;5;99m{peri_bg}{PH}{RD[0]}{RD[0]}{reset}"

# Row 1: image cell | plain cell | plain cell
row1 = f"{transmit}{img_cell}{peri_bg} {reset}{peri_bg} {reset}"
# Row 2: three plain cells (reference — should all have identical left edges)
row2 = f"{peri_bg} {reset}{peri_bg} {reset}{peri_bg} {reset}"
# Row 3: image cell alone at col 0 (check absolute left edge)
row3 = f"{img_cell}"

print(row1)
print(row2)
print(row3)
PYEOF
)

# Write the script to /tmp and run it
cat > /tmp/trivial_align_test.py << 'EOF'
import os, base64
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
EOF

"$H" send-text 'python3 /tmp/trivial_align_test.py'$'\n'
sleep 1.5
"$H" snapshot "trivial-image-alignment"
