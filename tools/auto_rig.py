#!/usr/bin/env python3
"""
VRM / VRoid model -> Mixamo-named rigged FBX, offline. Replaces the manual mixamo.com round trip
for models that already carry a humanoid rig.

    python3 tools/auto_rig.py tools/glb/model.vrm -o rigged/Girl_D.fbx
    python3 tools/auto_rig.py tools/glb/*.glb -o rigged/            # batch
    blender -b -P tools/auto_rig.py -- model.glb rigged/Girl_D.fbx  # the Blender half, direct

The input is the **source model**, not the bare FBX that `glb_to_fbx.py` writes. That file has its
armature and its skin weights deliberately removed (Mixamo skips rigging when it finds a skeleton),
so nothing offline can rig it without inventing both - measured on out/24386148582032405.fbx:
3 meshes, 0 armatures, 0 vertex groups. What this script does instead is *keep* the rig the model
shipped with. So it replaces steps 1 and 2 together, not step 2 alone.

Why a rename is all it takes: VRM's humanoid skeleton is a fixed standard, and every bone
`BoneScheme.mixamo` asks for has exactly one counterpart in it (`J_Bip_C_Hips` -> `mixamorig_Hips`,
`J_Bip_L_UpperArm` -> `mixamorig_LeftArm`, ...). `PoseRetargeter` reads each limb's rest direction
from the bone-to-child world positions and applies `delta * restWorldOrient`, so bone roll, bone
length and the A-pose-vs-T-pose rest never enter the result - only the names have to line up.

What this keeps that Mixamo cannot: the author's own skin weights. Mixamo re-solves the weights
from scratch, which is why its rig sometimes drags the skirt with the thigh.

What this does NOT do: rig a mesh that has no skeleton. Tripo3D output, a scanned mesh, or anything
from `glb_to_fbx.py` still has to go to mixamo.com. This script refuses those rather than guessing.

Everything geometric matches glb_to_fbx.py exactly - the same material rebuild, the same 180-degree
turn, the same grounding, the same FBX axes - so a character produced here and one produced through
Mixamo arrive in the same place, facing the same way. The next step is unchanged:

    python3 tools/fbx_to_character.py rigged/Girl_D.fbx --key Girl_D
"""
import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

try:
    import bpy
    INSIDE_BLENDER = True
except ImportError:
    INSIDE_BLENDER = False


# --------------------------------------------------------------------------- the bone map

# VRM's humanoid skeleton is a fixed standard, so this is a table and not a heuristic.
_SPINE = {"Hips": "Hips", "Spine": "Spine", "Chest": "Spine1", "UpperChest": "Spine2",
          "Neck": "Neck", "Head": "Head"}
_LIMB = {"Shoulder": "Shoulder", "UpperArm": "Arm", "LowerArm": "ForeArm", "Hand": "Hand",
         "UpperLeg": "UpLeg", "LowerLeg": "Leg", "Foot": "Foot", "ToeBase": "ToeBase"}
_FINGER = {"Thumb": "HandThumb", "Index": "HandIndex", "Middle": "HandMiddle",
           "Ring": "HandRing", "Little": "HandPinky"}

# Underscore, not the colon Mixamo itself writes: `fbx_to_character.py` goes through USD, and USD
# sanitises a colon out of a prim name - which is where `mixamorig_Hips` comes from in the first
# place. Writing the underscore here lands on the same name by a shorter road.
PREFIX = "mixamorig_"

# What BoneScheme.mixamo looks up. Missing any one of these means a character that stands still
# through the whole dance, so it is checked here rather than discovered on device.
REQUIRED = ["Hips", "Spine", "Head",
            "LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand",
            "RightShoulder", "RightArm", "RightForeArm", "RightHand",
            "LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase",
            "RightUpLeg", "RightLeg", "RightFoot", "RightToeBase"]


def mixamo_name(vrm_bone):
    """`J_Bip_L_Index2` -> `mixamorig_LeftHandIndex2`; None for a bone Mixamo has no name for."""
    m = re.match(r"^J_Bip_([CLR])_(.+)$", vrm_bone)
    if not m:
        return None
    side_code, part = m.group(1), m.group(2)
    if side_code == "C":
        core = _SPINE.get(part)
        return PREFIX + core if core else None
    side = "Left" if side_code == "L" else "Right"
    f = re.match(r"^(Thumb|Index|Middle|Ring|Little)([123])$", part)
    if f:
        return PREFIX + side + _FINGER[f.group(1)] + f.group(2)
    core = _LIMB.get(part)
    return PREFIX + side + core if core else None


# --------------------------------------------------------------------------- outer half

def find_blender():
    candidates = [os.environ.get("BLENDER"),
                  "/Applications/Blender.app/Contents/MacOS/Blender"]
    candidates += sorted(glob.glob("/Applications/Blender*.app/Contents/MacOS/Blender"), reverse=True)
    for c in candidates:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    sys.exit("Blender not found. Install it in /Applications, or set BLENDER=/path/to/Blender.")


def outer():
    ap = argparse.ArgumentParser(
        description="Rename a VRM humanoid rig to Mixamo's names and write a rigged FBX.")
    ap.add_argument("inputs", nargs="+", help=".vrm / .glb / .gltf models that already carry a rig")
    ap.add_argument("-o", "--out", default=None,
                    help="output .fbx, or a directory when converting several files")
    ap.add_argument("--no-ground", action="store_true", help="do not drop the model onto y=0")
    ap.add_argument("--no-rebuild-materials", action="store_true",
                    help="do not rewire non-Principled materials (VRM/MToon export untextured)")
    ap.add_argument("--albedo-gain", type=float, default=1.0,
                    help="multiply base colour by this in linear light; MToon art is painted with "
                         "the shading baked in and clips under a PBR rig (1.0 = leave alone)")
    face = ap.add_mutually_exclusive_group()
    face.add_argument("--face-flip", action="store_true", help="force the 180-degree turn")
    face.add_argument("--no-face-flip", action="store_true", help="never turn the model")
    args = ap.parse_args()

    blender = find_blender()
    many = len(args.inputs) > 1
    failures = 0

    for src in args.inputs:
        src = os.path.abspath(src)
        if not os.path.isfile(src):
            print(f"  ! no such file: {src}", file=sys.stderr)
            failures += 1
            continue
        if args.out and (many or args.out.endswith(os.sep) or os.path.isdir(args.out)):
            os.makedirs(args.out, exist_ok=True)
            dst = os.path.join(args.out, os.path.splitext(os.path.basename(src))[0] + ".fbx")
        elif args.out:
            dst = os.path.abspath(args.out)
            os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
        else:
            dst = os.path.splitext(src)[0] + "_rigged.fbx"

        cmd = [blender, "-b", "--factory-startup", "--python", os.path.abspath(__file__), "--",
               src, dst, "--albedo-gain", str(args.albedo_gain)]
        for flag in ("no_ground", "no_rebuild_materials", "face_flip", "no_face_flip"):
            if getattr(args, flag):
                cmd.append("--" + flag.replace("_", "-"))

        r = subprocess.run(cmd, capture_output=True, text=True)
        if os.path.isfile(dst):
            note = next((l[len("[autorig]"):].strip() for l in r.stdout.splitlines()
                         if l.startswith("[autorig]")), "")
            print(f"  {os.path.basename(dst):<34} {os.path.getsize(dst)/1e6:6.1f} MB   {note}")
        else:
            failures += 1
            print(f"  ! failed: {os.path.basename(src)}", file=sys.stderr)
            for line in (r.stderr or r.stdout).strip().splitlines()[-8:]:
                print(f"      {line}", file=sys.stderr)

    if not failures:
        print()
        print("next:  python3 tools/fbx_to_character.py <the .fbx above> --key <Name>")
    return 1 if failures else 0


# --------------------------------------------------------------------------- Blender half

def _load_shared():
    """Borrow glb_to_fbx.py's material rebuild and turn, so the two paths cannot drift apart."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import glb_to_fbx
    return glb_to_fbx


def scale_albedo(gain):
    """Multiply every base colour map by `gain` in linear light. Returns how many were rewritten.

    VRoid textures are painted for MToon, an unlit shader: the shading is already in the picture,
    so the values sit where a PBR renderer expects a *reflectance* and there is nothing above them.
    Measured on this model, the face skin map averages 0.913 with 99.8% of its pixels at or above
    0.85 - no real surface reflects that much; plaster is about 0.9 - while the eight Mixamo
    characters run 0.22 to 0.49 average with 0-10% up there. The character therefore clips before a
    single light is switched on, and no exposure setting can bring it back: the headroom is missing
    from the asset, not from the grade.

    Two details that are easy to get wrong:

    - **Scaled in linear light, not on the stored bytes.** Halving an sRGB value is not halving the
      light it stands for. (Blender hands back `pixels` in the image's own encoding here - probed:
      the face map reads 0.904 through `foreach_get`, matching its sRGB mean, not its linear 0.81.)
    - **Written into a fresh image datablock.** Writing `pixels` on an image whose data came from a
      file leaves `save()` serialising the original bytes - measured, the exported PNG was
      unchanged. An image created by `images.new` has its buffer as the only source, so it saves
      what it was given.
    """
    import numpy as np
    replacements, done = {}, 0
    for mat in bpy.data.materials:
        if not mat.use_nodes or not mat.node_tree:
            continue
        for node in mat.node_tree.nodes:
            if node.type != "BSDF_PRINCIPLED":
                continue
            for link in node.inputs["Base Color"].links:
                src = getattr(link.from_node, "image", None)
                if not src or not src.size[0]:
                    continue
                if src.name not in replacements:
                    w, h, ch = src.size[0], src.size[1], src.channels
                    buf = np.empty(w * h * ch, dtype=np.float32)
                    src.pixels.foreach_get(buf)
                    px = buf.reshape(-1, ch)
                    rgb = px[:, :3]
                    lin = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
                    lin = np.clip(lin * gain, 0.0, 1.0)
                    px[:, :3] = np.where(lin <= 0.0031308, lin * 12.92,
                                         1.055 * lin ** (1 / 2.4) - 0.055)
                    dst = bpy.data.images.new(src.name + "_t", w, h, alpha=(ch == 4))
                    dst.colorspace_settings.name = src.colorspace_settings.name
                    if ch == 4:
                        dst.pixels.foreach_set(px.reshape(-1))
                    else:
                        rgba = np.ones((px.shape[0], 4), dtype=np.float32)
                        rgba[:, :3] = px[:, :3]
                        dst.pixels.foreach_set(rgba.reshape(-1))
                    dst.update()
                    replacements[src.name] = dst
                    done += 1
                link.from_node.image = replacements[src.name]
    # The originals are unreferenced now; dropping them keeps the export from writing them out too.
    for name in list(replacements):
        old = bpy.data.images.get(name)
        if old and old.users == 0:
            bpy.data.images.remove(old)
    return done


def rename_rig(armature, meshes):
    """VRM bone names -> Mixamo bone names, vertex groups along with them.

    Blender renames a mesh's vertex group when the bone it is bound to is renamed, but only for
    meshes it can see through the armature modifier; the groups are swept explicitly afterwards so
    a mesh parented some other way cannot end up with weights bound to a name nothing looks for.
    """
    plan = {}
    for b in armature.data.bones:
        new = mixamo_name(b.name)
        if new:
            plan[b.name] = new
    for old, new in plan.items():
        armature.data.bones[old].name = new
    for m in meshes:
        for vg in m.vertex_groups:
            if vg.name in plan:
                vg.name = plan[vg.name]
    return plan


def inner():
    argv = sys.argv[sys.argv.index("--") + 1:]
    src, dst = argv[0], argv[1]
    no_ground = "--no-ground" in argv
    rebuild = "--no-rebuild-materials" not in argv
    force_flip = "--face-flip" in argv
    forbid_flip = "--no-face-flip" in argv
    gain = float(argv[argv.index("--albedo-gain") + 1]) if "--albedo-gain" in argv else 1.0

    shared = _load_shared()
    bpy.ops.wm.read_factory_settings(use_empty=True)

    # A .vrm is a .glb byte for byte, but the importer dispatches on the extension and refuses the
    # name. Copy rather than rename, so the download is left untouched.
    load_path, tmp_copy = src, None
    if os.path.splitext(src)[1].lower() not in (".glb", ".gltf"):
        fd, tmp_copy = tempfile.mkstemp(suffix=".glb")
        os.close(fd)
        shutil.copyfile(src, tmp_copy)
        load_path = tmp_copy
    try:
        # bone_heuristic="BLENDER" keeps the authored bone names - the whole point here - and
        # guess_original_bind_pose=False keeps the rest pose the weights were painted against.
        bpy.ops.import_scene.gltf(filepath=load_path, bone_heuristic="BLENDER",
                                  guess_original_bind_pose=False)
    finally:
        if tmp_copy:
            os.unlink(tmp_copy)

    # The VRoid helper Icosphere goes before anything measures the model: it is centred on the
    # origin with radius 1, so it owns the bounding box and grounding measured from it lifts the
    # character a metre into the air.
    helpers = [o for o in bpy.data.objects
               if o.type == "MESH" and not [m for m in o.data.materials if m]]
    for o in helpers:
        bpy.data.objects.remove(o, do_unlink=True)

    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    armatures = [o for o in bpy.data.objects if o.type == "ARMATURE"]
    if not meshes:
        raise SystemExit("no renderable mesh in the imported file")
    if not armatures:
        raise SystemExit("no armature in the source model - there is no rig here to rename. "
                         "A bare mesh (glb_to_fbx.py output, Tripo3D, a scan) still needs "
                         "mixamo.com; this script does not invent a skeleton.")
    if len(armatures) > 1:
        raise SystemExit(f"{len(armatures)} armatures in the source model, expected one")
    arm = armatures[0]

    skinned = [m for m in meshes if any(mod.type == "ARMATURE" for mod in m.modifiers)]
    if not skinned:
        raise SystemExit("the meshes are not bound to the armature - the model carries a skeleton "
                         "but no skin weights, so there is nothing to keep")

    rebuilt = shared.rebuild_materials() if rebuild else 0
    toned = scale_albedo(gain) if abs(gain - 1.0) > 1e-6 else 0

    bone_names = [b.name for b in arm.data.bones]
    if not any(b.startswith("J_Bip") for b in bone_names):
        raise SystemExit("this is not a VRM humanoid rig (no J_Bip_* bones); "
                         "nothing here knows how to rename it")

    plan = rename_rig(arm, meshes)
    have = {b.name for b in arm.data.bones}
    missing = [n for n in REQUIRED if PREFIX + n not in have]
    if missing:
        raise SystemExit("the rig is missing bones the retargeter needs: "
                         + ", ".join(PREFIX + m for m in missing))

    # Animation on a character is dead weight here - dances are JSON takes - and a stray action
    # leaves the export frozen in frame 1 rather than the bind pose the weights belong to.
    for o in bpy.data.objects:
        o.animation_data_clear()
    for a in list(bpy.data.actions):
        bpy.data.actions.remove(a)

    # A VRM faces glTF +Z, which arrives as Blender +Y and exports as FBX -Z. The eight Mixamo
    # characters face FBX +Z, so the turn is what puts this one on the stage alongside them facing
    # the same way. Same rule, same pivot, as glb_to_fbx.py.
    flip = force_flip or not forbid_flip
    bpy.context.view_layer.update()
    if flip:
        shared.turn_to_face_camera(meshes)
        bpy.context.view_layer.update()

    if not no_ground:
        lowest = min((m.matrix_world @ v.co).z for m in meshes for v in m.data.vertices)
        if abs(lowest) > 1e-5:
            for o in bpy.data.objects:
                if o.parent is None:
                    o.location.z -= lowest

    # Every image that came out of the glTF importer is packed with an EMPTY filepath, and the FBX
    # exporter names each embedded texture after its filepath's basename. Empty basenames all
    # collide, so the 15 maps of a VRoid model were written as one file and every material came out
    # pointing at whichever image won - measured on the first run: 31 images in the FBX, all
    # resolving to `_10`, the 2048 body atlas, with the face and the hair rendering the body's UVs.
    # Giving each image a real, unique path first is what keeps them apart. (Blender's own image
    # names are already unique, so they are what the files are named after.)
    tex_dir = tempfile.mkdtemp(prefix="autorig_tex_")
    written = 0
    for img in bpy.data.images:
        if not (img.has_data or img.packed_file) or img.size[0] == 0:
            continue
        safe = re.sub(r"[^A-Za-z0-9_.-]", "_", img.name) or f"tex{written}"
        img.file_format = "PNG"
        img.filepath_raw = os.path.join(tex_dir, f"{safe}.png")
        img.save()
        written += 1

    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.fbx(
        filepath=dst,
        use_selection=False,
        apply_unit_scale=True,
        apply_scale_options="FBX_SCALE_ALL",   # glTF is metres, FBX centimetres
        axis_forward="-Z",
        axis_up="Y",
        object_types={"MESH", "ARMATURE"},
        use_mesh_modifiers=False,              # the armature modifier is the rig, not a bake
        mesh_smooth_type="FACE",
        path_mode="COPY",
        embed_textures=True,
        # True, unlike glb_to_fbx.py. A VRM rig ends at ToeBase and at each fingertip, and
        # fbx_to_character.py imports with ignore_leaf_bones=True - so without a written-out
        # `_end` below them those bones are the leaves that get dropped, and BoneScheme's
        # leftToe/rightToe go missing, which is the foot planting. Mixamo's own rig has a
        # Toe_End for the same reason. The `_end` bones are stripped again on the way in.
        add_leaf_bones=True,
        primary_bone_axis="Y",
        secondary_bone_axis="X",
        bake_anim=False,
    )

    shutil.rmtree(tex_dir, ignore_errors=True)

    tris = sum(len(m.data.loop_triangles) for m in meshes
               if (m.data.calc_loop_triangles() or True))
    images = len([i for i in bpy.data.images if i.has_data or i.packed_file])
    lo = min((m.matrix_world @ v.co).z for m in meshes for v in m.data.vertices)
    hi = max((m.matrix_world @ v.co).z for m in meshes for v in m.data.vertices)
    print(f"[autorig] {len(meshes)} mesh ({len(skinned)} skinned), {tris} tris, {images} textures, "
          f"{rebuilt} mats rebuilt, {written} maps written, "
          f"albedo x{gain:g} on {toned}, {len(helpers)} helpers dropped, "
          f"{len(plan)}/{len(bone_names)} bones renamed, all {len(REQUIRED)} required present, "
          f"height {hi - lo:.2f}, feet at {lo:.3f}, faced={'turned' if flip else 'as-is'}")


if __name__ == "__main__":
    if INSIDE_BLENDER:
        inner()
    else:
        sys.exit(outer())
