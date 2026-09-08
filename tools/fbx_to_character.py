#!/usr/bin/env python3
"""
Mixamo's rigged FBX -> a character this app can load. The last step of the pipeline.

    python3 tools/fbx_to_character.py "Erika Archer.fbx" --key Erika_Archer
    python3 tools/fbx_to_character.py rigged/*.fbx --all          # a whole batch
    python3 tools/fbx_to_character.py hero.fbx --key Hero --format usdz

Why it cannot be skipped: `SCNScene(url:)` reads `.scn` and `.usdz`, not FBX - and Mixamo names its
bones `mixamorig:Hips`, with a **colon**, while `BoneScheme.mixamo` looks for `mixamorig_Hips`, with
an underscore. That underscore is not a convention anybody chose; it is what USD does to a colon
when it sanitises a prim name. Load Mixamo's FBX directly and `PoseRetargeter` finds zero bones and
the character stands in its bind pose for the whole dance.

So the route is FBX -> (Blender) USD -> optionally SCN, and the rename comes for free on the way.

    import_scene.fbx(automatic_bone_orientation=False)

is load-bearing: with Blender's automatic orientation on, the bone roll is rewritten and the rest
pose no longer matches what the retargeter captured from the other characters.

`.usdz` is a perfectly good final format - the catalog carried `char_vroid_4.usdz` for months - but
`.scn` is SceneKit's own archive, loads without a translation step, and is what the other eight
characters ship as, so it stays the default.

Run `tools/compress_textures.swift` next; a Mixamo download brings its textures at full size.
"""
import argparse
import glob
import os
import re
import subprocess
import sys

try:
    import bpy
    INSIDE_BLENDER = True
except ImportError:
    INSIDE_BLENDER = False

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))


# --------------------------------------------------------------------------- outer half

def find_blender():
    candidates = [os.environ.get("BLENDER"),
                  "/Applications/Blender.app/Contents/MacOS/Blender"]
    candidates += sorted(glob.glob("/Applications/Blender*.app/Contents/MacOS/Blender"), reverse=True)
    for c in candidates:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    sys.exit("Blender not found. Install it in /Applications, or set BLENDER=/path/to/Blender.")


def derive_key(path):
    """`Erika Archer.fbx` -> `Erika_Archer`, matching how make_catalog.py reads a name back out."""
    stem = os.path.splitext(os.path.basename(path))[0]
    # Mixamo appends its own suffixes to downloads.
    stem = re.sub(r"[ _-]*(mixamo|rigged|with[ _-]?skin|t[ _-]?pose)$", "", stem, flags=re.I)
    return re.sub(r"\s+", "_", stem.strip())


def main_outer():
    ap = argparse.ArgumentParser(description="Convert a Mixamo-rigged FBX into an app character.")
    ap.add_argument("inputs", nargs="+", help="rigged .fbx files (Mixamo: FBX Binary + With Skin)")
    ap.add_argument("--key", default=None,
                    help="asset key for a single input; derived from the file name otherwise")
    ap.add_argument("--out", default=os.path.join(ROOT, "assets_src", "characters"),
                    help="where the character goes; make_catalog.py reads this directory")
    ap.add_argument("--format", choices=["scn", "usdz"], default="scn")
    ap.add_argument("--keep-usdz", action="store_true",
                    help="keep the intermediate .usdz next to the output")
    ap.add_argument("--all", action="store_true", help="accept several inputs and derive every key")
    args = ap.parse_args()

    if len(args.inputs) > 1 and not args.all:
        sys.exit("several inputs: pass --all (keys are derived from the file names)")
    if args.key and len(args.inputs) > 1:
        sys.exit("--key applies to a single input only")

    blender = find_blender()
    os.makedirs(args.out, exist_ok=True)
    failures = 0

    for src in args.inputs:
        src = os.path.abspath(src)
        if not os.path.isfile(src):
            print(f"  ! no such file: {src}", file=sys.stderr)
            failures += 1
            continue
        key = args.key or derive_key(src)
        usdz = os.path.join(args.out, f"{key}.usdz")

        r = subprocess.run([blender, "-b", "--factory-startup", "--python",
                            os.path.abspath(__file__), "--", src, usdz],
                           capture_output=True, text=True)
        note = next((l[len("[fbx2char]"):].strip() for l in r.stdout.splitlines()
                     if l.startswith("[fbx2char]")), "")
        if not os.path.isfile(usdz):
            failures += 1
            print(f"  ! {key}: USD export failed", file=sys.stderr)
            for line in (r.stderr or r.stdout).strip().splitlines()[-6:]:
                print(f"      {line}", file=sys.stderr)
            continue

        final = usdz
        if args.format == "scn":
            scn = os.path.join(args.out, f"{key}.scn")
            c = subprocess.run(["xcrun", "scntool", "--convert", usdz, "--format", "scn",
                                "-o", scn], capture_output=True, text=True)
            if os.path.isfile(scn):
                final = scn
                if not args.keep_usdz:
                    os.remove(usdz)
            else:
                failures += 1
                print(f"  ! {key}: scntool failed, keeping the usdz", file=sys.stderr)
                print(f"      {(c.stderr or c.stdout).strip()[:200]}", file=sys.stderr)

        size = os.path.getsize(final) / 1e6
        print(f"  {os.path.basename(final):<34} {size:6.1f} MB   {note}")

    print()
    print("next:  swiftc -O tools/compress_textures.swift -o /tmp/compress_textures")
    print(f"       /tmp/compress_textures {args.out} {args.out}/*.scn")
    print("       swiftc -O tools/render_thumbs.swift Animo3D/PoseRetargeter.swift "
          "Animo3D/MixamoBoneMap.swift -o /tmp/render_thumbs")
    print(f"       /tmp/render_thumbs characters assets_src/thumbs {args.out}/*.scn")
    print("       python3 tools/make_catalog.py --base-url <bucket>/")
    return 1 if failures else 0


# --------------------------------------------------------------------------- Blender half

def main_inner():
    argv = sys.argv[sys.argv.index("--") + 1:]
    src, dst = argv[0], argv[1]

    bpy.ops.wm.read_factory_settings(use_empty=True)

    # automatic_bone_orientation=False is load-bearing. Blender's automatic orientation rewrites
    # bone roll, and PoseRetargeter captures each limb's rest direction from the bone's own axes -
    # so a re-rolled skeleton gives the same dance a different result on this character than on the
    # other eight.
    bpy.ops.import_scene.fbx(filepath=src, automatic_bone_orientation=False,
                             use_anim=False, ignore_leaf_bones=True)

    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    armatures = [o for o in bpy.data.objects if o.type == "ARMATURE"]
    if not meshes:
        raise SystemExit("no mesh in the FBX")
    if not armatures:
        raise SystemExit("no armature - download Mixamo's FBX with 'With Skin', not 'Without Skin'")

    skinned = [m for m in meshes if any(mod.type == "ARMATURE" for mod in m.modifiers)]
    if not skinned:
        raise SystemExit("mesh is not bound to the armature - the rig did not come through")

    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.wm.usd_export(
        filepath=dst,
        selected_objects_only=False,
        export_animation=False,          # dances are JSON takes, not baked clips
        export_textures_mode="NEW",      # write the images out beside the usdz so it is self-contained
        generate_preview_surface=True,   # without this SceneKit gets no materials at all
        convert_orientation=False,       # the FBX importer already put it Y-up
        export_materials=True,
    )

    bones = [b.name for a in armatures for b in a.data.bones]
    mixamo = [b for b in bones if b.lower().startswith("mixamorig")]
    lo = min((m.matrix_world @ v.co).z for m in meshes for v in m.data.vertices)
    hi = max((m.matrix_world @ v.co).z for m in meshes for v in m.data.vertices)
    print(f"[fbx2char] {len(meshes)} mesh ({len(skinned)} skinned), {len(bones)} bones "
          f"({len(mixamo)} mixamorig), height {hi - lo:.2f}, feet at {lo:.3f}")


if __name__ == "__main__":
    if INSIDE_BLENDER:
        main_inner()
    else:
        sys.exit(main_outer())
