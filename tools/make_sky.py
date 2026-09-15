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
    import numpy as np
    from PIL import Image, ImageChops, ImageFilter
except ImportError:
    sys.exit("needs Pillow and numpy:  python3 -m pip install --user Pillow numpy")


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


def assemble_sector(src, sky_end, ground_start, W, H, span_deg, centre, sun_elevation=None):
    """Lay a photograph across one sector of the dome, and fill the rest with its own sky.

    The tiling path above assumes a wide photograph of an ordinary sky: repeat it three times and
    nobody can tell. A photograph with a subject in it - a sun - cannot be repeated at all, and a
    long lens cannot be stretched to fill a turn either. This sunset frames the sun at maybe a
    dozen degrees of azimuth; opened out to 360 the disc becomes an ellipse half the sky wide and
    every cloud a horizontal smear.

    So the photograph keeps its own proportions and covers only `span_deg` of the turn, centred on
    `centre`. Behind the viewer, where the photograph has nothing to say, the sky is continued from
    the colours of its own two edges - which at sunset is what is actually there: the bright half of
    the sky is the half the sun is in, and the other half is a plain graded wash.

    Preserving the source aspect is what keeps the sun round: the equirectangular mapping is linear
    in both angles, so a strip scaled equally in x and y lands undistorted.
    """
    w, _ = src.size
    span_px = max(16, int(W * span_deg / 360.0))
    scale = span_px / w
    sky_h = int(sky_end * scale)
    tree_h = max(2, int((ground_start - sky_end) * scale))

    # The horizon is the bottom of the treeline; everything above it has to fit in the upper half.
    if sky_h + tree_h > H // 2:
        overflow = sky_h + tree_h - H // 2
        src = src.crop((0, int(overflow / scale), w, src.size[1]))
        sky_end -= int(overflow / scale)
        sky_h = H // 2 - tree_h
        print(f"span {span_deg} deg is taller than the dome; cropped {overflow} px off the top")

    strip = np.asarray(src.crop((0, 0, w, ground_start))
                          .resize((span_px, sky_h + tree_h), Image.LANCZOS), dtype=np.float32)
    band_top = H // 2 - sky_h - tree_h

    # Where the sun ends up matters more than where the photograph's horizon does.
    #
    # The stage camera is framed on a dancer, not on the sky: it sees about ten degrees above the
    # horizon, and a long lens pointed at a setting sun puts that sun a good twenty degrees up. Laid
    # out honestly, the best thing in the photograph sits above the top of the screen and the frame
    # gets the dark band underneath it. So the whole strip slides down until the sun is where it can
    # be seen. What slides below the horizon - the far shore, the water - is hidden by the stage's
    # own ground anyway.
    if sun_elevation is not None:
        sun_y = int(np.unravel_index(np.argmax(strip.mean(axis=2)), strip.shape[:2])[0])
        want = int(H / 2 - sun_elevation / 90.0 * (H / 2))
        drop = want - (band_top + sun_y)
        if drop > 0:
            band_top += drop
            print(f"sun sits {(H / 2 - band_top - sun_y) / (H / 2) * 90:.1f} deg up "
                  f"(dropped the strip {drop / (H / 2) * 90:.1f} deg to put it there)")
    band_h = sky_h + tree_h
    x0 = int((centre - span_deg / 720.0) * W) % W

    # The wash the photograph sits on: every row runs from the colours at one edge of the strip,
    # round the back, to the colours at the other. Sampled a little way inside the strip rather
    # than from its outermost column, which on this photograph is darkened by the lens.
    inset = max(1, span_px // 20)
    left, right = strip[:, inset], strip[:, -inset]
    # Position around the dome, 0 at the strip's centre, 1 directly behind it.
    x = (np.arange(W, dtype=np.float32) - (x0 + span_px / 2)) / W
    x = np.abs((x + 0.5) % 1.0 - 0.5) * 2
    t = np.clip((x - span_deg / 360.0) / max(1e-6, 1 - span_deg / 360.0), 0, 1)
    t = (t * t * (3 - 2 * t))[None, :, None]
    # Behind the viewer the two edges have met, so both sides converge on their average.
    far = (left + right)[:, None, :] / 2
    side = (((np.arange(W) - x0 - span_px // 2) % W) < W // 2)[None, :, None]
    near = np.where(side, right[:, None, :], left[:, None, :])
    band = near * (1 - t) + far * t

    # And the photograph over it, faded out across its outer eighth. A hard edge here is a vertical
    # crease down the sky - the strip has cloud in it and the wash does not, so the two never match
    # exactly however well the colours are sampled.
    feather = max(2, span_px // 8)
    mask = np.ones(span_px, dtype=np.float32)
    ramp = np.arange(feather, dtype=np.float32) / feather
    ramp = ramp * ramp * (3 - 2 * ramp)
    mask[:feather] = ramp
    mask[-feather:] = ramp[::-1]
    xs = (np.arange(span_px) + x0) % W
    band[:, xs] = band[:, xs] * (1 - mask[None, :, None]) + strip * mask[None, :, None]

    a = np.zeros((H, W, 3), dtype=np.float32)
    visible = min(H // 2, band_top + band.shape[0])
    a[band_top:visible] = band[:visible - band_top]
    out = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))

    # Above the photograph, extend its topmost row to the zenith, so the sky carries on rather than
    # ending at an edge.
    if band_top > 0:
        top = out.crop((0, band_top, W, band_top + 2)).resize((W, band_top), Image.LANCZOS)
        out.paste(top, (0, 0))

    return out, band_top


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source", help="photograph containing a sky")
    ap.add_argument("-o", "--out", required=True, help="output .jpg (2:1 equirectangular)")
    ap.add_argument("--width", type=int, default=2048)
    ap.add_argument("--sky-elevation", type=float, default=50.0,
                    help="how far up the photo's sky reaches, in degrees above the horizon")
    ap.add_argument("--quality", type=int, default=88)
    ap.add_argument("--horizon", type=int, default=None,
                    help="row where the sky ends, when the colour test cannot find it (a sunset is "
                         "not blue, so it never can)")
    ap.add_argument("--ground", type=int, default=None,
                    help="row where the horizon band ends and the foreground begins")
    ap.add_argument("--span", type=float, default=360.0,
                    help="degrees of azimuth the photograph covers. 360 tiles it three times, for "
                         "an ordinary sky; less places it once at --sun-azimuth and continues the "
                         "sky behind the viewer, which is what a photograph with a sun in it needs")
    ap.add_argument("--sun-azimuth", type=float, default=0.5,
                    help="where the centre of the photograph sits, 0..1 around the dome")
    ap.add_argument("--sun-elevation", type=float, default=None,
                    help="degrees above the horizon to put the photograph's brightest point, which "
                         "on a sunset is the sun. The stage camera sees about ten degrees of sky, "
                         "so anything higher is off the top of the screen")
    args = ap.parse_args()

    src = Image.open(args.source).convert("RGB")
    sky_end, ground_start, rows = find_bands(src)
    if args.horizon is not None:
        sky_end = args.horizon
        ground_start = args.ground if args.ground is not None else int(sky_end * 1.06)
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

    if args.span < 360:
        out, band_top = assemble_sector(src, sky_end, ground_start, W, H,
                                        args.span, args.sun_azimuth, args.sun_elevation)
        # The fog takes the colour of the sky at eye level, not of the silhouette standing in
        # front of it: the dome's last few rows are the city band, which is nearly black, and fog
        # that colour turns the ground to mud a few metres out.
        arr = np.asarray(out, dtype=np.float32)
        hz = tuple(int(c) for c in arr[H // 2 - 8:H // 2].reshape(-1, 3).mean(axis=0))
        out.paste(Image.new("RGB", (W, H - H // 2), hz), (0, H // 2))
        out = out.filter(ImageFilter.GaussianBlur(radius=W / 1400))
        os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
        out.save(args.out, quality=args.quality, optimize=True)
        print(f"sector {args.span:.0f} deg at azimuth {args.sun_azimuth}, sky top at y={band_top}")
        print(f"horizon colour: rgb{hz}  ->  ({hz[0]/255:.2f}, {hz[1]/255:.2f}, {hz[2]/255:.2f})")
        print(f"wrote {args.out}  {W}x{H}  {os.path.getsize(args.out)/1024:.0f} KB")
        return
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
