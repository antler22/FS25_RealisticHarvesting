"""
Generates placeholder corner-post icons as DXT5 .dds, matching the format of the icons
already in textures/ (128x128, DXT5, white glyph on transparent).

These are PLACEHOLDERS. They exist so the panel is readable and correctly laid out while
the real artwork is drawn; every one is meant to be overwritten. Because they are ordinary
128x128 DDS files with an alpha channel, replacing one is just dropping a new file over it —
no code change, no atlas coordinates, no rebuild.

Only the icons that did not already exist are generated. Anything present in textures/ is
left alone, so re-running this can never clobber real artwork.

Usage:  python tools/make_icons.py [--force]
"""

import os
import sys
import math

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
TEX = os.path.join(os.path.dirname(HERE), "textures")

SIZE = 128
W = (255, 255, 255, 255)      # opaque white glyph
LW = 9                        # stroke width, tuned to read at ~20px on screen


def canvas():
    im = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 0))
    return im, ImageDraw.Draw(im)


# --- DDS with a full mipmap chain -------------------------------------------------------
# PIL writes a single-level DDS. The icons already in textures/ carry 8 mip levels, and a
# HUD icon without mips aliases badly when the panel is scaled down. So each level is
# encoded separately and the chain is spliced together with a corrected header, which keeps
# these files structurally identical to the hand-made ones alongside them.

import io
import struct

DDSD_MIPMAPCOUNT = 0x20000
DDSCAPS_COMPLEX  = 0x8
DDSCAPS_MIPMAP   = 0x400_000 >> 12 | 0x400000  # 0x400000
DDSCAPS_TEXTURE  = 0x1000


def _dxt5_level(im):
    """Encode one image as a single-level DXT5 DDS and return just its pixel data."""
    buf = io.BytesIO()
    im.save(buf, format="DDS", pixel_format="DXT5")
    return buf.getvalue()[128:]      # strip magic + 124-byte header


def save_dds_mipmapped(im, path):
    levels = []
    cur = im
    while True:
        levels.append(_dxt5_level(cur))
        if cur.width <= 1 and cur.height <= 1:
            break
        # Continue all the way to 1x1, matching the 8-level chains on the existing icons.
        # DXT5 stores 4x4 blocks, so levels below 4px still occupy one block each.
        cur = cur.resize((max(1, cur.width // 2), max(1, cur.height // 2)), Image.LANCZOS)

    # Start from PIL's own header so every format field is already correct, then patch in
    # the mip count and caps rather than hand-rolling all 124 bytes.
    buf = io.BytesIO()
    im.save(buf, format="DDS", pixel_format="DXT5")
    header = bytearray(buf.getvalue()[:128])

    flags = struct.unpack_from("<I", header, 8)[0] | DDSD_MIPMAPCOUNT
    struct.pack_into("<I", header, 8, flags)
    struct.pack_into("<I", header, 28, len(levels))          # dwMipMapCount
    caps = struct.unpack_from("<I", header, 108)[0] | DDSCAPS_COMPLEX | 0x400000 | DDSCAPS_TEXTURE
    struct.pack_into("<I", header, 108, caps)

    with open(path, "wb") as f:
        f.write(header)
        for lv in levels:
            f.write(lv)
    return len(levels)


def fuel(d):
    """Fuel pump: body, nozzle, hose."""
    d.rounded_rectangle([22, 30, 74, 104], radius=7, outline=W, width=LW)
    d.rectangle([34, 44, 62, 62], outline=W, width=6)          # window
    d.line([74, 56, 96, 56], fill=W, width=LW)                 # arm out
    d.line([96, 56, 96, 88], fill=W, width=LW)                 # down
    d.arc([84, 30, 108, 58], start=270, end=90, fill=W, width=LW)  # nozzle hook
    d.line([16, 104, 80, 104], fill=W, width=LW)               # base


def define(d):
    """DEF: droplet outline with a bar through it, distinct from plain fuel."""
    d.polygon([(64, 20), (98, 66), (64, 104), (30, 66)], outline=W, width=LW)
    d.line([44, 74, 84, 74], fill=W, width=LW)
    d.line([52, 88, 76, 88], fill=W, width=LW)


def coolant(d):
    """Coolant temperature: thermometer with bulb, plus heat waves."""
    d.rounded_rectangle([40, 16, 62, 84], radius=11, outline=W, width=LW)
    d.ellipse([32, 78, 70, 116], outline=W, width=LW)
    d.ellipse([44, 90, 58, 104], fill=W)
    for i, y in enumerate((32, 48, 64)):                       # scale ticks
        d.line([66, y, 78, y], fill=W, width=5)
    for x in (94, 112):                                        # heat waves
        for seg in range(3):
            y0 = 30 + seg * 24
            d.arc([x - 10, y0, x + 10, y0 + 24], start=270, end=90, fill=W, width=5)


def tailings(d):
    """Tailings return: inclined auger with a return arrow."""
    d.line([20, 104, 92, 34], fill=W, width=LW)
    d.line([34, 112, 106, 42], fill=W, width=LW)
    for i in range(5):                                         # flighting
        t = i / 4.0
        x = 24 + t * 74
        y = 108 - t * 70
        d.line([x, y, x + 10, y + 8], fill=W, width=4)
    d.polygon([(96, 24), (116, 40), (92, 50)], fill=W)         # arrow head


def total(d):
    """Total: sigma, with two arrows converging into it."""
    # sigma
    d.line([44, 34, 92, 34], fill=W, width=LW)
    d.line([44, 34, 68, 64], fill=W, width=LW)
    d.line([68, 64, 44, 96], fill=W, width=LW)
    d.line([44, 96, 92, 96], fill=W, width=LW)
    # converging feeds
    d.line([12, 20, 30, 46], fill=W, width=6)
    d.polygon([(26, 34), (34, 52), (18, 48)], fill=W)
    d.line([116, 20, 98, 46], fill=W, width=6)
    d.polygon([(102, 34), (110, 48), (94, 52)], fill=W)


ICONS = {
    "icon_fuel":     fuel,
    "icon_def":      define,
    "icon_coolant":  coolant,
    "icon_tailings": tailings,
    "icon_total":    total,
}


def main():
    force = "--force" in sys.argv
    if not os.path.isdir(TEX):
        print("textures/ not found at", TEX)
        return 1

    made, kept = [], []
    for name, fn in sorted(ICONS.items()):
        path = os.path.join(TEX, name + ".dds")
        if os.path.exists(path) and not force:
            kept.append(name)
            continue
        im, d = canvas()
        fn(d)
        # DXT5 with mipmaps, matching the icons already in textures/
        save_dds_mipmapped(im, path)
        made.append(name)

    for n in made:
        print("  generated  textures/%s.dds" % n)
    for n in kept:
        print("  kept       textures/%s.dds  (already exists — use --force to overwrite)" % n)
    print("\n%d generated, %d left untouched" % (len(made), len(kept)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
