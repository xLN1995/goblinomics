#!/usr/bin/env python3
"""Draw the smooth shape textures (white with soft alpha edges, tinted where used;
Theme.DOT, Theme.RING and Theme.STROKE in Core/UI/Theme.lua).

  hud_dot.tga    64 x 64   filled circle            dots: chart points, nodes, stops
  hud_ring.tga  512 x 512  thin circle outline      the farm HUD radar's edge
  hud_line.tga   64 x 16   soft stroke profile      lines: charts, routes, chevrons (CreateLine stretches it)

Run from the repository root: python3 tools/make_hud_media.py
"""
import math
from PIL import Image

SS = 4  # supersampling per axis for smooth edges


def render(width, height, alpha_at, path):
    big = Image.new("RGBA", (width * SS, height * SS))
    px = big.load()
    for y in range(height * SS):
        for x in range(width * SS):
            a = alpha_at((x + 0.5) / SS, (y + 0.5) / SS)
            px[x, y] = (255, 255, 255, int(round(max(0.0, min(1.0, a)) * 255)))
    img = big.resize((width, height), Image.LANCZOS)
    img.save(path, compression=None)


def dot(x, y):
    r = math.hypot(x - 32, y - 32)
    return 1.0 if r <= 28 else 0.0


def ring(x, y):
    r = math.hypot(x - 256, y - 256)
    return 1.0 if 246 <= r <= 252 else 0.0


def line(_, y):
    # opaque core, edges fading out across the stroke's width
    d = abs(y - 8) / 8
    return 1.0 if d <= 0.35 else max(0.0, 1 - (d - 0.35) / 0.65) ** 1.5


render(64, 64, dot, "Media/hud_dot.tga")
render(512, 512, ring, "Media/hud_ring.tga")
render(64, 16, line, "Media/hud_line.tga")
