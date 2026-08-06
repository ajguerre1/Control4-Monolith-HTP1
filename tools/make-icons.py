#!/usr/bin/env python3
"""Generates the driver's icon set from the Monolith brand mark.

Run from the repo root:  python tools/make-icons.py

Source is assets/monolith-logo.png -- the manufacturer's own logo, used to
identify the manufacturer's own product. Replacing the icons is a matter of
replacing that one file; nothing below hardcodes the artwork.

Three things this has to get right, all of which bite silently:

  * THE WORDMARK CANNOT COME ALONG. "MONOLITH" set under the glyph is
    unreadable below about 90px and turns to grey mush at 16px, where the icon
    has roughly 200 pixels to work with. The glyph is cropped out on its own,
    and the crop is DERIVED from the image rather than hardcoded, so a
    re-exported logo at a different size still works.

  * THE BRAND IS WHITE-ON-DARK AND COMPOSER'S TREE IS WHITE. Dropping a white
    mark onto transparency would make it invisible in exactly the place it is
    meant to appear. The mark therefore sits on its own dark tile, which is how
    the brand presents it anyway, and that tile is what makes the icon legible
    on a light tree and a dark touchscreen alike.

  * DOWNSCALING. The mark is composited at full resolution and the whole tile
    is resampled once with LANCZOS, rather than scaling the mark first, so the
    thin gaps between the glyph's slabs stay open as far down as they can.

Regenerating is idempotent: same source, same bytes out.
"""

import os
from PIL import Image, ImageDraw, ImageFilter

SOURCE = "assets/monolith-logo.png"

COMPOSER = [("www/icons/device_sm.png", 16), ("www/icons/device_lg.png", 32)]
NAVIGATOR = [("www/icons/device/experience_%d.png" % n, n)
             for n in (70, 90, 300, 512, 1024)]

TILE = (0x17, 0x1A, 0x1C)   # the logo's own near-black, sampled from its corners
MARK = (0xFF, 0xFF, 0xFF)   # the mark is pure white in the source
SS = 4                      # supersample factor for the tile geometry

# Fraction of the tile the mark occupies. Generous, because the glyph is the
# only thing here -- there is no wordmark to leave room for. Tighter below 32px,
# where every pixel given to margin is one taken from the glyph's open gaps.
INSET = 0.16
INSET_SMALL = 0.10
# Corner rounding, as a fraction of the tile. Enough to read as deliberate at
# 32px and above; squared off at 16px, where a radius eats the silhouette.
RADIUS = 0.16
# Below this, the glyph is thinned before it is scaled. The mark is four slabs
# separated by gaps thinner than the slabs themselves; shrink it to sixteen
# pixels untouched and those gaps close, leaving a white blob with a notch.
# Eroding the mask widens the gaps at the cost of slab weight, which is the
# right trade when the alternative is no gaps at all. Expressed as a fraction
# of the mark's own width so a logo re-exported at another size still works.
THIN_BELOW = 32
THIN_FRACTION = 0.021


def bright_row_bands(gray, threshold=150):
    """Contiguous runs of rows containing any pixel brighter than `threshold`."""
    bands, start = [], None
    for y in range(gray.height):
        row = gray.crop((0, y, gray.width, y + 1))
        lit = row.getextrema()[1] > threshold
        if lit and start is None:
            start = y
        elif not lit and start is not None:
            bands.append((start, y - 1))
            start = None
    if start is not None:
        bands.append((start, gray.height - 1))
    return bands


def extract_mark(path):
    """The glyph alone, as an alpha mask, cropped tight.

    The logo is glyph, then a rule under it, then the wordmark. Those are three
    bands of lit rows separated by two gaps, and the gap under the rule is the
    larger of the two -- the wordmark is set further away than the rule is.
    Splitting on the LARGEST gap is therefore what separates mark from wordmark,
    and it holds at any export size because it is a comparison, not a constant.
    """
    src = Image.open(path).convert("RGBA")
    gray = src.convert("L")

    bands = bright_row_bands(gray)
    if len(bands) < 2:
        raise SystemExit("%s: expected a glyph and a wordmark, found %d band(s)"
                         % (path, len(bands)))

    gaps = [(bands[i + 1][0] - bands[i][1], i) for i in range(len(bands) - 1)]
    _, split = max(gaps)
    bottom = bands[split][1]

    # Luminance IS the alpha here: the mark is white, the background near-black,
    # so the grey ramp at the mark's edges is exactly its antialiasing.
    mask = gray.crop((0, 0, src.width, bottom + 1))
    mask = mask.point(lambda v: 255 if v > 245 else (0 if v < 60 else
                                                    int((v - 60) * 255 / 185)))
    return mask.crop(mask.getbbox())


def thin(mark):
    """Erodes the mask by a kernel proportional to the mark's own width."""
    kernel = int(round(mark.width * THIN_FRACTION))
    kernel = max(3, kernel + 1 - kernel % 2)   # MinFilter needs an odd size
    return mark.filter(ImageFilter.MinFilter(kernel))


def render(mark, n):
    if n < THIN_BELOW:
        mark = thin(mark)
        mark = mark.crop(mark.getbbox())
    inset = INSET_SMALL if n < THIN_BELOW else INSET

    canvas = n * SS
    tile = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))

    # The tile. Square at 16px: a radius there costs more corner than it buys
    # polish, and the icon is only sixteen pixels of silhouette to begin with.
    plate = ImageDraw.Draw(tile)
    if n >= 32:
        plate.rounded_rectangle([0, 0, canvas - 1, canvas - 1],
                                radius=int(canvas * RADIUS), fill=TILE + (255,))
    else:
        plate.rectangle([0, 0, canvas - 1, canvas - 1], fill=TILE + (255,))

    # The mark, fitted inside the inset and centred.
    box = int(canvas * (1 - 2 * inset))
    scale = min(box / float(mark.width), box / float(mark.height))
    size = (max(1, int(round(mark.width * scale))),
            max(1, int(round(mark.height * scale))))
    fitted = mark.resize(size, Image.LANCZOS)

    layer = Image.new("L", tile.size, 0)
    layer.paste(fitted, ((canvas - size[0]) // 2, (canvas - size[1]) // 2))
    ink = Image.new("RGBA", tile.size, MARK + (255,))
    ink.putalpha(layer)

    return Image.alpha_composite(tile, ink).resize((n, n), Image.LANCZOS)


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    mark = extract_mark(os.path.join(root, SOURCE.replace("/", os.sep)))
    print("mark extracted: %dx%d" % (mark.width, mark.height))

    for path, size in COMPOSER + NAVIGATOR:
        full = os.path.join(root, path.replace("/", os.sep))
        os.makedirs(os.path.dirname(full), exist_ok=True)
        img = render(mark, size)
        assert img.mode == "RGBA", "Control4 wants 32-bit ARGB"
        img.save(full, "PNG", optimize=True)
        print("%-44s %4dx%-4d %6d bytes" % (path, size, size, os.path.getsize(full)))


if __name__ == "__main__":
    main()
