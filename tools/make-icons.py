#!/usr/bin/env python3
"""Generates the driver's icon set. Original artwork, no third-party marks.

Run from the repo root:  python tools/make-icons.py

The motif is a monolith: an upright slab in the 1:4:9 proportions of the one in
2001, so the width is 4/9 of the height. It is a deliberate choice rather than a
decorative one -- at 16x16 an icon has roughly 200 usable pixels and anything
with detail turns to mush, whereas a bold silhouette stays legible.

Two things this has to survive that are easy to forget:

  * BOTH BACKGROUNDS. Composer's tree is light, Navigator tiles are usually
    dark. A near-black slab vanishes on the second, so the slab carries a light
    rim, and that rim -- not the fill -- is what makes it readable on dark.
  * DOWNSCALING. Everything is drawn at 8x and resampled with LANCZOS, which is
    why the edges stay clean at 16px instead of stair-stepping.

Regenerating is idempotent: same inputs, same bytes out.
"""

import os
from PIL import Image, ImageDraw

SS = 8  # supersample factor

# Composer's tree, and the Navigator ladder every first-party driver ships.
COMPOSER = [("www/icons/device_sm.png", 16), ("www/icons/device_lg.png", 32)]
NAVIGATOR = [("www/icons/device/experience_%d.png" % n, n)
             for n in (70, 90, 300, 512, 1024)]

SLAB_TOP = (0x2E, 0x34, 0x3D)     # lit top face
SLAB_BOTTOM = (0x0B, 0x0D, 0x10)  # shadowed base
# A MID grey, not a light one. The rim has to hold an edge against Composer's
# white tree AND a dark Navigator tile, and a light rim fails the first badly:
# it halos into the white and eats the silhouette, which at 16px is only about
# six pixels wide to begin with.
RIM = (0x7D, 0x85, 0x90)
SHEEN = (0xC8, 0xD2, 0xE0)        # specular highlight down the left face
ACCENT = (0x4E, 0xA8, 0xFF)       # the display, and the only colour in the mark


def slab_box(n):
    """The slab's rectangle on an n-by-n canvas, in 1:4:9 proportions."""
    height = n * 0.86
    width = height * 4.0 / 9.0
    left = (n - width) / 2.0
    top = (n - height) / 2.0
    return [left, top, left + width, top + height]


def render(n):
    canvas = n * SS
    img = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    left, top, right, bottom = [v * SS for v in slab_box(n)]

    # Vertical gradient, one scanline at a time. Cheap, and exact.
    height = max(1, int(round(bottom - top)))
    for i in range(height):
        t = i / float(height - 1) if height > 1 else 0.0
        colour = tuple(int(round(SLAB_TOP[c] + (SLAB_BOTTOM[c] - SLAB_TOP[c]) * t))
                       for c in range(3))
        y = top + i
        draw.rectangle([left, y, right, y + 1], fill=colour + (255,))

    # The rim, capped at roughly one target pixel. Letting it scale freely made
    # a 16px icon that was more rim than slab -- the outline is meant to define
    # the edge, not to become the mark.
    rim_w = min(SS * 1.0, max(SS * 0.6, n * SS * 0.012))
    draw.rectangle([left, top, right, bottom], outline=RIM + (255,),
                   width=int(round(rim_w)))

    # A sheen down the left face: what stops the slab reading as a flat bar.
    # Only where there is room for it. Below 70px the slab is under ten pixels
    # across, and a highlight there costs more legibility than it buys depth.
    #
    # COMPOSITED, NOT DRAWN. ImageDraw REPLACES pixels on an RGBA image rather
    # than blending them, so drawing a 13%-alpha rectangle straight onto the
    # slab punches a near-transparent hole through it instead of lightening it
    # -- a white gutter on Composer's tree, a dark notch on a touchscreen. It
    # has to go onto its own layer and be alpha-composited back.
    if n >= 70:
        sheen_w = (right - left) * 0.15
        layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
        ImageDraw.Draw(layer).rectangle(
            [left + rim_w, top + rim_w, left + rim_w + sheen_w, bottom - rim_w],
            fill=SHEEN + (34,))
        img = Image.alpha_composite(img, layer)
        # Rebind: the old draw still points at the pre-composite image, and
        # everything drawn through it after this would be silently discarded.
        draw = ImageDraw.Draw(img)

    # The display. Omitted below 32px, where one pixel of accent only muddies
    # the silhouette it is meant to sit on.
    if n >= 32:
        inset = (right - left) * 0.22
        band_y = top + (bottom - top) * 0.74
        band_h = max(SS, (bottom - top) * 0.035)
        draw.rectangle([left + inset, band_y, right - inset, band_y + band_h],
                       fill=ACCENT + (235,))

    return img.resize((n, n), Image.LANCZOS)


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    for path, size in COMPOSER + NAVIGATOR:
        full = os.path.join(root, path.replace("/", os.sep))
        os.makedirs(os.path.dirname(full), exist_ok=True)
        img = render(size)
        assert img.mode == "RGBA", "Control4 wants 32-bit ARGB"
        img.save(full, "PNG", optimize=True)
        print("%-44s %4dx%-4d %6d bytes" % (path, size, size, os.path.getsize(full)))


if __name__ == "__main__":
    main()
