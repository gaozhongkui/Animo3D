#!/usr/bin/env python3
"""
Builds the sky dome texture for the outdoor background from a photograph.

    python3 tools/make_sky.py data/sky_source.jpg -o Animo3D/Res/sky_dome.jpg

Why: `scene.background.contents` treats a single image as **equirectangular** - x is a full turn of
azimuth, y is latitude, so it must be 2:1 and must wrap at the seam. The photo that used to be set
there directly was 704x1503, a portrait shot of a plaza with a park behind it, and SceneKit stretched
the whole thing - paving included - around the dome. The sky in that photo was good; the ground in it
was the problem, and so was the aspect ratio.

So this takes the photo apart and keeps what belongs on a dome:

  - **sky band** -> the upper dome, placed at the elevation a camera actually saw it (roughly the
    lower 50 degrees) with its topmost colour extended to the zenith above that
  - **treeline band** -> a thin strip right at the equator, which is where the eye expects distance
  - **the paving** -> discarded. The app draws its own plaza plane; a second one painted on the sky
    is what made the horizon read as two mismatched halves
  - **below the equator** -> faded to the horizon colour, sampled from the photo itself, so the
    plaza's far edge dissolves into the sky instead of ending in a hard line. The app sets its fog
    to that same value.

Horizontal wrap: the sky band is made seamless in itself - blended with a half-turn-rolled copy of
itself through a mask that is only open at the edges - and then repeated. Mirror-tiling was tried
first and rejected: it joins perfectly but leaves the cloud field bilaterally symmetric about the
centre, with the photo's corner sun-glow duplicated into a bright vertical spine down the middle.
Repetition reads as sky; symmetry reads as a mistake.
"""
import argparse
import os
import sys

try:
    from PIL import Image, ImageChops, ImageFilter
except ImportError:
    sys.exit("needs Pillow:  python3 -m pip install --user Pillow")


def find_bands(im):
    """Split the photo into sky / treeline / ground by colour.

    Sky is strongly blue (blue channel well above red). Foliage and distant ground break that.
    Paving is neutral and bright. Measured on the original: b-r runs +135 at the top down to +31 at
    y=720, goes negative through the trees, and the paving sits at r=g=b=205.
    """
    w, h = im.size
    px = im.load()
    step = max(1, w // 44)

    rows = []
    for y in range(h):
        n = 0
        r = g = b = 0
        for x in range(0, w, step):
            p = px[x, y]
            r += p[0]; g += p[1]; b += p[2]
            n += 1
        rows.append((r / n, g / n, b / n))

    sky_end = 0
    for y, (r, g, b) in enumerate(rows):
        if b - r > 25:
            sky_end = y
        elif y > h * 0.1:
            break

    # The treeline runs from the end of the sky until the image turns neutral and bright (paving).
    ground_start = sky_end
    for y in range(sky_end, h):
        r, g, b = rows[y]
        if abs(b - r) < 20 and (r + g + b) / 3 > 170:
            ground_start = y
            break
    else:
        ground_start = min(h, sky_end + int(h * 0.06))

    return sky_end, ground_start, rows


def make_seamless(img, blend=0.16):
    """Make `img` tile left-to-right without a visible join, and without mirroring.

    Blends the image with a copy rolled by half its width, through a mask that is opaque only near
    the two edges. At x=0 the result comes from the middle of the original, and at x=w-1 from the
    pixel just before it - so the wrap is continuous - while the centre is untouched.
    """
    w, h = img.size
    b = max(2, int(w * blend))
    rolled = ImageChops.offset(img, w // 2, 0)
    mask = Image.new("L", (w, 1), 0)
    mpx = mask.load()
    for x in range(w):
        d = min(x, w - 1 - x)            # distance to the nearer edge
        mpx[x, 0] = 255 if d == 0 else (int(255 * (1 - d / b)) if d < b else 0)
    return Image.composite(rolled, img, mask.resize((w, h)))


def tile_across(strip, total_w, y, out):
    """Repeat a seamless strip across the full dome width."""
    x = 0
    while x < total_w:
        out.paste(strip, (x, y))
        x += strip.size[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source", help="photograph containing a sky")
    ap.add_argument("-o", "--out", required=True, help="output .jpg (2:1 equirectangular)")
    ap.add_argument("--width", type=int, default=2048)
    ap.add_argument("--sky-elevation", type=float, default=50.0,
                    help="how far up the photo's sky reaches, in degrees above the horizon")
    ap.add_argument("--quality", type=int, default=88)
    args = ap.parse_args()

    src = Image.open(args.source).convert("RGB")
    sky_end, ground_start, rows = find_bands(src)
    w, h = src.size
    print(f"source {w}x{h}: sky 0..{sky_end}, treeline {sky_end}..{ground_start}, "
          f"ground {ground_start}..{h} (discarded)")

    # Horizon colour: the last few rows of sky, which is also what the app's fog is set to.
    hz = [0.0, 0.0, 0.0]
    band = rows[max(0, sky_end - 12):sky_end + 1] or [rows[sky_end]]
    for r, g, b in band:
        hz[0] += r; hz[1] += g; hz[2] += b
    hz = tuple(int(c / len(band)) for c in hz)
    print(f"horizon colour: rgb{hz}  ->  ({hz[0]/255:.2f}, {hz[1]/255:.2f}, {hz[2]/255:.2f})")

    W = args.width
    H = W // 2
    # Three repeats keeps the clouds near their photographed scale while making any single repeat
    # unlikely to be in frame at once (a 62-degree camera sees about a sixth of the azimuth).
    tile = W // 3
    out = Image.new("RGB", (W, H), hz)

    # --- sky ---------------------------------------------------------------
    # The photo's sky covers 0..sky-elevation degrees. On the dome, y=H/2 is the horizon and y=0 is
    # the zenith, so that band lands between those two.
    frac = min(1.0, max(0.05, args.sky_elevation / 90.0))
    sky_top_y = int(H / 2 * (1 - frac))
    sky_h = H // 2 - sky_top_y
    sky = make_seamless(src.crop((0, 0, w, sky_end)).resize((tile, sky_h), Image.LANCZOS))

    # Above the photo's reach, extend its topmost row so the zenith is a continuation rather than a
    # hard edge.
    if sky_top_y > 0:
        top_row = sky.crop((0, 0, tile, 2)).resize((tile, sky_top_y), Image.LANCZOS)
        tile_across(top_row, W, 0, out)
    tile_across(sky, W, sky_top_y, out)

    # --- treeline ----------------------------------------------------------
    tree_h = max(4, int(H * 0.022))
    trees = make_seamless(src.crop((0, sky_end, w, ground_start)).resize((tile, tree_h), Image.LANCZOS))
    tile_across(trees, W, H // 2 - tree_h // 2, out)

    # --- below the horizon -------------------------------------------------
    # Never the photo's paving: the app has a plaza plane, and the fog is what has to meet this.
    lower = Image.new("RGB", (W, H - (H // 2 + tree_h // 2)), hz)
    out.paste(lower, (0, H // 2 + tree_h // 2))

    # A light blur over the whole thing hides both the resample steps and the treeline's edge; the
    # dome is far away and slightly soft reads as atmosphere.
    out = out.filter(ImageFilter.GaussianBlur(radius=W / 1400))

    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    out.save(args.out, quality=args.quality, optimize=True)
    print(f"wrote {args.out}  {W}x{H}  {os.path.getsize(args.out)/1024:.0f} KB")
    print("set CharacterSceneView.skyHorizon to the normalised colour above so the fog matches.")


if __name__ == "__main__":
    main()
