#!/usr/bin/env python3
"""Generate data/soldier_violet_front.png, the fifth seat colour.

Tribunal seats five cogs; the starter's art ships four sprites (red, blue,
green, yellow). The renderer looks a sprite up as
"soldier_" + COLORS[seat] + "_front.png" with COLORS[4] === "violet", so the
fifth seat needs a real sprite in the same style rather than a placeholder
box. This rotates the red cog's hue by a fixed +250 degrees, leaving value
and alpha untouched, which lands on the violet the palette already uses
(#a86fd6) while keeping every shadow, outline and highlight of the original.

Run once; the PNG it writes is committed.

    python3 tools/make_violet_cog.py
"""

import colorsys
import pathlib

from PIL import Image

HUE_SHIFT = 250.0 / 360.0
ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "data" / "soldier_red_front.png"
TARGET = ROOT / "data" / "soldier_violet_front.png"


def main() -> None:
    image = Image.open(SOURCE).convert("RGBA")
    pixels = list(image.getdata())
    out = []
    for r, g, b, a in pixels:
        h, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
        h = (h + HUE_SHIFT) % 1.0
        nr, ng, nb = colorsys.hsv_to_rgb(h, s, v)
        out.append((round(nr * 255), round(ng * 255), round(nb * 255), a))
    image.putdata(out)
    image.save(TARGET)
    print(f"wrote {TARGET} ({TARGET.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
