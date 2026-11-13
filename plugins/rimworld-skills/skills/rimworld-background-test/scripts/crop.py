"""Crop a screenshot. Usage: uv run -q --no-project --with pillow python -I crop.py IN.png X Y W H [OUT.png]

Coordinates are screen pixels of the capture (2560x1369 with the user's Prefs). The inspect pane and
its tabs sit at the bottom left; a 620x640 tab at UI scale 1.25 is about 775x800 pixels above the pane.
"""
import sys
from PIL import Image

src, x, y, w, h = sys.argv[1], *map(int, sys.argv[2:6])
out = sys.argv[6] if len(sys.argv) > 6 else src[:-4] + "-crop.png"
Image.open(src).crop((x, y, x + w, y + h)).save(out)
print(out)
