#!/usr/bin/env python3
"""
Mixamo animation FBX -> the mocap JSON a dance ships as. The missing half of "adding a dance".

    python3 tools/fbx_to_mocap.py "Salsa Dancing.fbx"                    # -> assets_src/dances/Salsa_Dancing.json
    python3 tools/fbx_to_mocap.py downloads/*.fbx                        # a whole batch
    python3 tools/fbx_to_mocap.py take.fbx --name "Hip Hop Dancing"      # name it explicitly

A dance in this project is not an animation clip. It is 33 joint world positions per frame:

    {"fps": 30, "frames": [ [[x, y, z], ... 33 ], ... ]}

`PoseRetargeter` maps those onto whichever character is performing, which is why one file serves
every character. `MocapClip.swift` says why it is positions and not a baked clip: it sidesteps
Apple's animation import and reuses the same body-frame retargeting the live camera path uses.

The script that produced the 44 takes in the repository was lost, so this is a rewrite. Everything
it has to match was measured off those 44 files rather than guessed:

  - **fps is 30** in all 44. Download at 30, with keyframe reduction off.
  - **Only 12 of the 33 slots are ever non-zero** - 11..16 and 23..28, the shoulders, elbows,
    wrists, hips, knees and ankles. The other 21 are zero padding, present only because the
    landmark numbering comes from BlazePose, whose camera path fills them all. Checked across
    every frame of eight takes: no other index is ever anything but zero.
  - **Z is up.** In the corpus an ankle sits at z 0.15, the hips at 0.84 and the shoulders at 1.45,
    while x and y straddle zero. That is Blender's own world frame, which is what the FBX importer
    produces, so nothing has to be rotated on the way out.
  - **Metres.** Mixamo writes centimetres and Blender's importer scales by 0.01.
  - **The root motion stays in.** Median horizontal hip travel across the corpus is 0.52m and the
    widest take moves 2.28m, so these were not downloaded "In Place" and a new one should not be
    either - the retargeter measures hip displacement from the take's own opening frame.

Two traps the old script's notes warned about, both handled here:

  - Mixamo does not always name its bones the same way. `mixamorig:Hips`, `mixamorigHips` and
    `mixamorig9Hips` all occur, so the prefix is stripped with `^mixamorig[:_]?\\d*` before matching.
  - An FBX downloaded "Without Skin" carries no bind pose. This script never needs one - it reads
    the posed skeleton's world positions frame by frame - but if a take ever does come in with a
    flat rest, "With Skin" is the download that avoids the question entirely.

Verify a new take against the existing 44 before shipping it:

    python3 tools/fbx_to_mocap.py --check assets_src/dances/Salsa_Dancing.json
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys

try:
    import bpy
    from mathutils import Vector
    INSIDE_BLENDER = True
except ImportError:
    INSIDE_BLENDER = False

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

# BlazePose slot -> the Mixamo bone whose head sits on that joint. A limb bone's head is the joint
# it rotates about, so the elbow is the forearm's head, not the upper arm's tail.
LANDMARKS = {
    11: "LeftArm",      12: "RightArm",       # shoulders
    13: "LeftForeArm",  14: "RightForeArm",   # elbows
    15: "LeftHand",     16: "RightHand",      # wrists
    23: "LeftUpLeg",    24: "RightUpLeg",     # hips
    25: "LeftLeg",      26: "RightLeg",       # knees
    27: "LeftFoot",     28: "RightFoot",      # ankles
}
SLOTS = 33
FPS = 30


def canonical(bone_name):
    """`mixamorig9:LeftArm` / `mixamorig_LeftArm` / `LeftArm` -> `LeftArm`."""
    return re.sub(r"^mixamorig[:_]?\d*[:_]?", "", bone_name)


# --------------------------------------------------------------------------- the check

def check(paths):
    """Compare produced takes against the shape of the 44 that already ship."""
    ok = True
    for p in paths:
        try:
            d = json.load(open(p))
        except Exception as e:
            print(f"  ! {os.path.basename(p)}: unreadable ({e})")
            ok = False
            continue
        problems = []
        frames = d.get("frames") or []
        if d.get("fps") != FPS:
            problems.append(f"fps {d.get('fps')}, corpus is {FPS}")
        if not frames:
            problems.append("no frames")
        else:
            if any(len(f) != SLOTS for f in frames):
                problems.append(f"not every frame has {SLOTS} slots")
            filled = {i for f in frames for i, v in enumerate(f) if any(abs(c) > 1e-9 for c in v)}
            if filled != set(LANDMARKS):
                extra = sorted(filled - set(LANDMARKS))
                missing = sorted(set(LANDMARKS) - filled)
                problems.append(f"populated slots off (extra {extra}, missing {missing})")
            hip = [((f[23][2] + f[24][2]) / 2) for f in frames if len(f) == SLOTS]
            sho = [((f[11][2] + f[12][2]) / 2) for f in frames if len(f) == SLOTS]
            if hip and sho:
                # Corpus: hips near 0.85, shoulders near 1.45, and shoulders always above hips.
                if not 0.5 < sum(hip) / len(hip) < 1.3:
                    problems.append(f"mean hip height {sum(hip)/len(hip):.2f}, corpus ~0.85 "
                                    "(wrong scale, or z is not up)")
                if sum(sho) / len(sho) <= sum(hip) / len(hip):
                    problems.append("shoulders are not above the hips (axes are wrong)")
            lx = [f[11][0] for f in frames]
            rx = [f[12][0] for f in frames]
            if sum(lx) / len(lx) < sum(rx) / len(rx):
                problems.append("left shoulder is not on +x (left and right are swapped)")
        secs = len(frames) / FPS
        if problems:
            ok = False
            print(f"  ! {os.path.basename(p)}  {len(frames)} frames / {secs:.1f}s")
            for pr in problems:
                print(f"      {pr}")
        else:
            print(f"  ok {os.path.basename(p)}  {len(frames)} frames / {secs:.1f}s")
    return 0 if ok else 1


# --------------------------------------------------------------------------- outer half

def find_blender():
    candidates = [os.environ.get("BLENDER"),
                  "/Applications/Blender.app/Contents/MacOS/Blender"]
    candidates += sorted(glob.glob("/Applications/Blender*.app/Contents/MacOS/Blender"), reverse=True)
    for c in candidates:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    sys.exit("Blender not found. Install it in /Applications, or set BLENDER=/path/to/Blender.")


def derive_name(path):
    """`Salsa Dancing (1).fbx` -> `Salsa_Dancing_1`; the file name becomes the dance's display name.

    The browser's duplicate suffix becomes the corpus's own: the repository already carries
    `Dancing_1`, `Jazz_Dancing_2`, `Swing_Dancing_4`. Dropping the number instead would have every
    `Hip Hop Dancing (n)` in a download folder overwrite the one before it.
    """
    stem = os.path.splitext(os.path.basename(path))[0]
    stem = re.sub(r"[ _-]*(mixamo|with[ _-]?skin|without[ _-]?skin|animation)$", "", stem, flags=re.I)
    stem = re.sub(r"\s*\((\d+)\)$", r"_\1", stem.strip())
    return re.sub(r"\s+", "_", stem.strip())


def outer():
    ap = argparse.ArgumentParser(description="Sample a Mixamo animation FBX into a dance JSON.")
    ap.add_argument("inputs", nargs="+", help="Mixamo .fbx takes, or .json takes with --check")
    ap.add_argument("--name", default=None, help="dance name for a single input (default: file name)")
    ap.add_argument("--out", default=os.path.join(ROOT, "assets_src", "dances"),
                    help="where the JSON goes; make_catalog.py reads this directory")
    ap.add_argument("--check", action="store_true",
                    help="validate existing .json takes against the shipped corpus instead")
    args = ap.parse_args()

    if args.check:
        return check([os.path.abspath(p) for p in args.inputs])
    if args.name and len(args.inputs) > 1:
        sys.exit("--name applies to a single input only")

    blender = find_blender()
    os.makedirs(args.out, exist_ok=True)
    written, failures = [], 0

    for src in args.inputs:
        src = os.path.abspath(src)
        if not os.path.isfile(src):
            print(f"  ! no such file: {src}", file=sys.stderr)
            failures += 1
            continue
        name = re.sub(r"\s+", "_", args.name.strip()) if args.name else derive_name(src)
        dst = os.path.join(args.out, f"{name}.json")

        r = subprocess.run([blender, "-b", "--factory-startup", "--python",
                            os.path.abspath(__file__), "--", src, dst],
                           capture_output=True, text=True)
        if os.path.isfile(dst):
            note = next((l[len("[fbx2mocap]"):].strip() for l in r.stdout.splitlines()
                         if l.startswith("[fbx2mocap]")), "")
            print(f"  {name + '.json':<40} {os.path.getsize(dst)/1e3:6.0f} KB   {note}")
            written.append(dst)
        else:
            failures += 1
            print(f"  ! {name}: sampling failed", file=sys.stderr)
            for line in (r.stderr or r.stdout).strip().splitlines()[-8:]:
                print(f"      {line}", file=sys.stderr)

    if written:
        print()
        print("checking against the shipped corpus:")
        failures += check(written)
        print()
        print("next:  python3 tools/make_catalog.py --base-url <bucket>/")
    return 1 if failures else 0


# --------------------------------------------------------------------------- Blender half

def inner():
    argv = sys.argv[sys.argv.index("--") + 1:]
    src, dst = argv[0], argv[1]

    bpy.ops.wm.read_factory_settings(use_empty=True)
    # automatic_bone_orientation=False for the same reason fbx_to_character.py uses it: Blender's
    # automatic orientation rewrites bone roll. It does not change a bone's head position, which is
    # all this reads, but keeping both importers identical means a take and a character can never
    # disagree about where a joint is.
    bpy.ops.import_scene.fbx(filepath=src, automatic_bone_orientation=False,
                             use_anim=True, ignore_leaf_bones=True)

    armatures = [o for o in bpy.data.objects if o.type == "ARMATURE"]
    if not armatures:
        raise SystemExit("no armature in the FBX - this is not a Mixamo take")
    if len(armatures) > 1:
        raise SystemExit(f"{len(armatures)} armatures, expected one")
    arm = armatures[0]

    by_joint = {}
    for pb in arm.pose.bones:
        by_joint.setdefault(canonical(pb.name), pb)
    missing = [b for b in LANDMARKS.values() if b not in by_joint]
    if missing:
        raise SystemExit("the take is missing bones this needs: " + ", ".join(missing)
                         + f" (saw: {', '.join(sorted(by_joint)[:12])} ...)")

    action = arm.animation_data.action if arm.animation_data else None
    if action is None:
        # A rigged-but-static FBX still samples, as one frame - useful for checking the mapping.
        first, last = 1, 1
    else:
        lo, hi = action.frame_range
        first, last = int(round(lo)), int(round(hi))

    scene = bpy.context.scene
    src_fps = scene.render.fps / max(1e-6, scene.render.fps_base)
    if abs(src_fps - FPS) > 0.5:
        print(f"[fbx2mocap] ! the take is {src_fps:g} fps; download at {FPS} so it plays at the "
              f"right speed", file=sys.stderr)

    zero = [0.0, 0.0, 0.0]
    frames = []
    for f in range(first, last + 1):
        scene.frame_set(f)
        row = [list(zero) for _ in range(SLOTS)]
        for slot, joint in LANDMARKS.items():
            # The bone's head in world space. `matrix` is the pose bone's armature-space matrix, so
            # the object transform still has to be applied - a Mixamo take carries a 0.01 scale on
            # the armature object and skipping this is how a dance comes out 100x too big.
            world = arm.matrix_world @ by_joint[joint].matrix @ Vector((0.0, 0.0, 0.0))
            row[slot] = [round(world.x, 5), round(world.y, 5), round(world.z, 5)]
        frames.append(row)

    with open(dst, "w") as fh:
        json.dump({"fps": FPS, "frames": frames}, fh, separators=(",", ":"))

    hips = [(f[23][2] + f[24][2]) / 2 for f in frames]
    sho = [(f[11][2] + f[12][2]) / 2 for f in frames]
    trav = max(abs(f[23][0] - frames[0][23][0]) for f in frames)
    print(f"[fbx2mocap] {len(frames)} frames / {len(frames)/FPS:.1f}s, "
          f"hips z {min(hips):.2f}..{max(hips):.2f}, shoulders z {sum(sho)/len(sho):.2f}, "
          f"hip travel {trav:.2f}m, "
          f"rig={'anim' if action else 'STATIC (no animation in this file)'}")


if __name__ == "__main__":
    if INSIDE_BLENDER:
        inner()
    else:
        sys.exit(outer())
