#!/usr/bin/env python3
"""
Mixamo animation FBX -> `.vrma` (the `VRMC_vrm_animation` glTF extension).

    python3 tools/fbx_to_vrma.py "Flair.fbx"                       # -> assets_src/dances/Flair.vrma
    python3 tools/fbx_to_vrma.py ~/Downloads/fbx/*.fbx             # a whole batch
    python3 tools/fbx_to_vrma.py take.fbx --name "Hip Hop Dancing"
    python3 tools/fbx_to_vrma.py --check assets_src/dances/*.vrma

This is the full-skeleton counterpart of `fbx_to_mocap.py`. That one writes 12 joint world
positions for `PoseRetargeter` to fit 8 limb bones to; this one writes every humanoid bone's local
rotation, so the spine chain, neck, toes and all thirty finger joints survive. One file drives both
VRM and Mixamo characters: `VRMAnimationPlayer` re-expresses each rotation between the take's rest
pose and the model's, so nothing about the take is tied to the rig it was authored on.

Most of the work is Blender's. Its glTF exporter already samples the action, converts Blender's
Z-up world to glTF's Y-up and writes one node per bone; what a `.vrma` adds on top is a single
table naming which node is which humanoid bone, so this script exports a `.glb` and patches that
table into its JSON chunk.

Notes measured off the takes in `/Volumes/SD/Downloads/fbx`, not assumed:

  - **"Without Skin" is fine here**, contrary to what a `.vrma` normally demands. The worry is that
    an animation-only FBX has no bind pose and rests flat, which would leave the retarget with no
    rest to measure against - true of glTF/three.js loaders, but Blender's FBX importer rebuilds
    the rest from the node transforms: `Flair.fbx` comes in with 61 of its 65 bones carrying a
    non-identity rest rotation and the hips resting at 1.06m. Download either way.
  - **Facing lands on its own.** A Mixamo rig faces Blender -Y, the exporter maps that to glTF +Z,
    and VRM 1.0 states a model faces +Z. No rotation is applied here.
  - **The root motion stays in**, as in `fbx_to_mocap.py`: the hips translation is the one
    translation a `.vrma` carries, and the player scales it by the two rigs' rest hip heights.
  - **Download at 30fps with keyframe reduction off.** The exporter bakes whatever it is given.
"""
import argparse
import glob
import json
import os
import re
import struct
import subprocess
import sys

try:
    import bpy
    INSIDE_BLENDER = True
except ImportError:
    INSIDE_BLENDER = False

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
FPS = 30

# Mixamo bone (prefix stripped) -> VRM humanoid bone, named as VRM 1.0 names it - which is what a
# `.vrma` is read as. The thumb is the one place the two VRM versions disagree: 1.0 counts the same
# three joints metacarpal / proximal / distal where 0.x counts proximal / intermediate / distal.
BONES = {
    "Hips": "hips",
    "Spine": "spine", "Spine1": "chest", "Spine2": "upperChest",
    "Neck": "neck", "Head": "head",
}
for side, vrm in (("Left", "left"), ("Right", "right")):
    BONES.update({
        f"{side}Shoulder": f"{vrm}Shoulder",
        f"{side}Arm": f"{vrm}UpperArm",
        f"{side}ForeArm": f"{vrm}LowerArm",
        f"{side}Hand": f"{vrm}Hand",
        f"{side}UpLeg": f"{vrm}UpperLeg",
        f"{side}Leg": f"{vrm}LowerLeg",
        f"{side}Foot": f"{vrm}Foot",
        f"{side}ToeBase": f"{vrm}Toes",
    })
    for finger, vrm_finger in (("Thumb", "Thumb"), ("Index", "Index"), ("Middle", "Middle"),
                               ("Ring", "Ring"), ("Pinky", "Little")):
        joints = (("Metacarpal", "Proximal", "Distal") if finger == "Thumb"
                  else ("Proximal", "Intermediate", "Distal"))
        for n, joint in enumerate(joints, start=1):
            BONES[f"{side}Hand{finger}{n}"] = f"{vrm}{vrm_finger}{joint}"

# The bones a take is not worth shipping without.
REQUIRED = {"hips", "spine", "head", "leftUpperArm", "rightUpperArm",
            "leftUpperLeg", "rightUpperLeg", "leftFoot", "rightFoot"}


def canonical(bone_name):
    """`mixamorig9:LeftArm` / `mixamorig_LeftArm` / `LeftArm` -> `LeftArm`."""
    return re.sub(r"^mixamorig[:_]?\d*[:_]?", "", bone_name)


def take_name(path):
    """`Hip Hop Dancing (7).fbx` -> `Hip_Hop_Dancing_7`, the way the shipped dances are named."""
    stem = os.path.splitext(os.path.basename(path))[0]
    stem = re.sub(r"\s*\((\d+)\)\s*$", r" \1", stem)
    return re.sub(r"[^A-Za-z0-9]+", "_", stem).strip("_")


# --------------------------------------------------------------------------- GLB

def read_glb(path):
    data = open(path, "rb").read()
    if len(data) < 20 or data[:4] != b"glTF":
        raise SystemExit(f"{path} is not a GLB")
    chunks, offset = {}, 12
    while offset + 8 <= len(data):
        length, kind = struct.unpack_from("<II", data, offset)
        body = data[offset + 8:offset + 8 + length]
        chunks[kind] = body
        offset += 8 + length
    return json.loads(chunks[0x4E4F534A]), chunks.get(0x004E4942, b"")


def write_glb(path, gltf, binary):
    js = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    js += b" " * (-len(js) % 4)                     # chunks are 4-byte aligned
    binary += b"\0" * (-len(binary) % 4)
    body = struct.pack("<II", len(js), 0x4E4F534A) + js
    if binary:
        body += struct.pack("<II", len(binary), 0x004E4942) + binary
    with open(path, "wb") as fh:
        fh.write(struct.pack("<4sII", b"glTF", 2, 12 + len(body)) + body)


# --------------------------------------------------------------------------- the check

def check(paths):
    ok = True
    for path in paths:
        name = os.path.basename(path)
        try:
            gltf, binary = read_glb(path)
        except Exception as exc:
            print(f"  ! {name}: unreadable ({exc})")
            ok = False
            continue
        problems = []
        vrma = (gltf.get("extensions") or {}).get("VRMC_vrm_animation")
        bones = ((vrma or {}).get("humanoid") or {}).get("humanBones") or {}
        if not vrma:
            problems.append("no VRMC_vrm_animation extension")
        missing = REQUIRED - set(bones)
        if missing:
            problems.append(f"humanoid is missing {', '.join(sorted(missing))}")

        animations = gltf.get("animations") or []
        if not animations:
            problems.append("no animation")
        else:
            animation = animations[0]
            nodes = {b["node"] for b in bones.values()}
            rotated = {c["target"]["node"] for c in animation["channels"]
                       if c["target"].get("path") == "rotation"}
            if not rotated & nodes:
                problems.append("no humanoid bone is animated")
            hips = bones.get("hips", {}).get("node")
            moved = {c["target"]["node"] for c in animation["channels"]
                     if c["target"].get("path") == "translation"}
            if hips is not None and hips not in moved:
                problems.append("the hips carry no translation (root motion was dropped)")
            # Duration and rate come off the shared input accessor.
            sampler = animation["samplers"][animation["channels"][0]["sampler"]]
            times = read_accessor(gltf, binary, sampler["input"], 1)
            seconds = times[-1] if times else 0
            rate = (len(times) - 1) / seconds if seconds else 0
            if abs(rate - FPS) > 1:
                problems.append(f"{rate:.1f} fps, expected {FPS}")
            if not 1.0 <= seconds <= 120.0:
                problems.append(f"{seconds:.1f}s long")
            print(f"  {'!' if problems else 'ok'} {name}: {len(bones)} bones, "
                  f"{len(times)} frames / {seconds:.1f}s @ {rate:.0f}fps")
        for problem in problems:
            print(f"      - {problem}")
            ok = False
    return ok


def read_accessor(gltf, binary, index, components):
    accessor = gltf["accessors"][index]
    view = gltf["bufferViews"][accessor["bufferView"]]
    start = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
    return list(struct.unpack_from(f"<{accessor['count'] * components}f", binary, start))


# --------------------------------------------------------------------------- outside Blender

def find_blender():
    candidates = [os.environ.get("BLENDER"),
                  "/Applications/Blender.app/Contents/MacOS/Blender",
                  "blender"]
    for candidate in candidates:
        if candidate and (os.path.exists(candidate) or shutil_which(candidate)):
            return candidate
    sys.exit("Blender not found. Install it in /Applications, or set BLENDER=/path/to/Blender.")


def shutil_which(name):
    from shutil import which
    return which(name)


def outer():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="+", help="Mixamo .fbx files, or .vrma files with --check")
    parser.add_argument("--name", help="output name (single input only)")
    parser.add_argument("--out", default=os.path.join(ROOT, "assets_src", "dances"))
    parser.add_argument("--check", action="store_true", help="validate produced .vrma files")
    args = parser.parse_args()

    paths = [p for pattern in args.paths for p in (glob.glob(pattern) or [pattern])]
    if args.check:
        return 0 if check(paths) else 1
    if args.name and len(paths) > 1:
        sys.exit("--name takes a single input")

    blender = find_blender()
    os.makedirs(args.out, exist_ok=True)
    failed = 0
    for path in paths:
        if not os.path.exists(path):
            print(f"[fbx2vrma] ! {path}: no such file", file=sys.stderr)
            failed += 1
            continue
        destination = os.path.join(args.out, (args.name or take_name(path)) + ".vrma")
        print(f"[fbx2vrma] {os.path.basename(path)} -> {os.path.relpath(destination, ROOT)}")
        result = subprocess.run([blender, "-b", "--factory-startup", "--python",
                                 os.path.abspath(__file__), "--", path, destination],
                                capture_output=True, text=True)
        for line in result.stdout.splitlines():
            if line.startswith("[fbx2vrma]"):
                print("  " + line[len("[fbx2vrma] "):])
        if result.returncode != 0 or not os.path.exists(destination):
            print(result.stdout[-2000:], file=sys.stderr)
            print(result.stderr[-2000:], file=sys.stderr)
            failed += 1
    return 1 if failed else 0


# --------------------------------------------------------------------------- inside Blender

def inner():
    source, destination = sys.argv[sys.argv.index("--") + 1:sys.argv.index("--") + 3]

    bpy.ops.wm.read_factory_settings(use_empty=True)
    # `automatic_bone_orientation=False` keeps the FBX's own bone axes, which is what the rest
    # rotations the retarget measures against are expressed in.
    bpy.ops.import_scene.fbx(filepath=source, automatic_bone_orientation=False)
    armatures = [o for o in bpy.data.objects if o.type == "ARMATURE"]
    if not armatures:
        raise SystemExit("no armature in this FBX")
    armature = armatures[0]

    scene = bpy.context.scene
    source_fps = scene.render.fps / max(1e-6, scene.render.fps_base)
    if abs(source_fps - FPS) > 0.5:
        print(f"[fbx2vrma] ! {source_fps:g} fps; download at {FPS} or it plays at the wrong speed")

    action = armature.animation_data.action if armature.animation_data else None
    if action is None:
        raise SystemExit("this FBX carries no animation")
    low, high = action.frame_range
    scene.frame_start, scene.frame_end = int(round(low)), int(round(high))

    temporary = destination + ".glb"
    bpy.ops.export_scene.gltf(
        filepath=temporary,
        export_format="GLB",
        export_animations=True,
        export_frame_range=True,
        export_force_sampling=True,          # bake, rather than hand over f-curves as they are
        export_optimize_animation_size=False,  # dropping "redundant" keys resamples the timing
        export_current_frame=False,
        export_yup=True,                     # Blender Z-up -> glTF Y-up, and -Y forward -> +Z
        export_apply=False,
        export_skins=True,
        export_morph=False,
        export_materials="NONE",
        export_cameras=False,
        export_lights=False,
    )

    gltf, binary = read_glb(temporary)
    os.remove(temporary)

    # Bone name -> node index. The exporter writes one node per bone, named after it.
    wanted = {}
    for index, node in enumerate(gltf.get("nodes", [])):
        vrm_bone = BONES.get(canonical(node.get("name", "")))
        if vrm_bone and vrm_bone not in wanted:
            wanted[vrm_bone] = index

    missing = REQUIRED - set(wanted)
    if missing:
        raise SystemExit("the take is missing bones this needs: " + ", ".join(sorted(missing)))

    gltf.setdefault("extensionsUsed", [])
    if "VRMC_vrm_animation" not in gltf["extensionsUsed"]:
        gltf["extensionsUsed"].append("VRMC_vrm_animation")
    gltf.setdefault("extensions", {})["VRMC_vrm_animation"] = {
        "specVersion": "1.0",
        "humanoid": {"humanBones": {bone: {"node": node} for bone, node in wanted.items()}},
    }
    write_glb(destination, gltf, binary)

    animation = gltf["animations"][0]
    sampler = animation["samplers"][animation["channels"][0]["sampler"]]
    times = read_accessor(gltf, binary, sampler["input"], 1)
    hips = wanted["hips"]
    has_root_motion = any(c["target"]["node"] == hips and c["target"]["path"] == "translation"
                          for c in animation["channels"])
    fingers = sum(1 for b in wanted if "Proximal" in b or "Intermediate" in b
                  or "Distal" in b or "Metacarpal" in b)
    print(f"[fbx2vrma] {len(wanted)} humanoid bones ({fingers} finger joints), "
          f"{len(times)} frames / {times[-1]:.1f}s, "
          f"root motion {'kept' if has_root_motion else 'MISSING'}, "
          f"{os.path.getsize(destination) / 1024:.0f} KB")


if __name__ == "__main__":
    if INSIDE_BLENDER:
        inner()
    else:
        sys.exit(outer())
