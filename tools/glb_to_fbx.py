#!/usr/bin/env python3
"""
GLB / glTF / VRM -> FBX, via Blender headless. One file: run it with python3 and it re-executes
itself inside Blender.

    python3 tools/glb_to_fbx.py model.glb                      # -> model.fbx next to the input
    python3 tools/glb_to_fbx.py avatar.vrm -o out/Hero.fbx      # VRoid Hub download, straight in
    python3 tools/glb_to_fbx.py *.glb -o out/                   # batch into a directory
    python3 tools/glb_to_fbx.py model.glb --keep-animation      # bake the glTF animation into the FBX

A `.vrm` is a `.glb` with a different name - byte for byte identical - but Blender's glTF importer
dispatches on the extension and refuses the name, so it is copied to a temporary `.glb` first.

Why this exists: the character pipeline needs FBX. Mixamo's auto-rigger only accepts FBX (and OBJ/
ZIP), Tripo3D hands back GLB, and most free character assets are GLB too - so every new character
starts with this conversion.

Defaults are chosen for **uploading to Mixamo's auto-rigger**:

  - **No rig, no animation.** The auto-rigger wants a bare mesh; an existing armature makes it skip
    rigging, and animation data is dead weight. `--keep-rig` / `--keep-animation` override this.
  - **Y-up, -Z forward**, Mixamo's own convention, so a model does not arrive lying on its back.
  - **Turned to face the camera when the source faces away.** Mixamo previews and rigs a character
    that faces FBX **+Z**. A VRM faces glTF +Z, which Blender's glTF importer maps to Blender +Y,
    which the standard FBX export maps to **-Z** - exactly backwards, so every VRoid upload showed
    Mixamo its back and the six rigger markers would have gone on the wrong side. Mixamo's own
    characters already face the right way and are left alone.

    The decision is made from the **bone names** (`J_Bip_*` = VRM, `mixamorig*` = Mixamo), read
    before the armature is removed. Geometry cues do not work here: "the toes point forward" holds
    for a T-pose and breaks on a posed model - measured, a dancing Mixamo GLB and a T-posed Mixamo
    FBX disagree about which way is forward. Use `--face-flip` / `--no-face-flip` to override, which
    is what an unrecognised rig needs.
  - **Textures embedded** (`path_mode='COPY'`, `embed_textures=True`). Mixamo takes a single file;
    an FBX referencing textures beside it uploads as an untextured grey mesh.
  - **Materials rebuilt as Principled BSDF** when they do not already have one. VRM/MToon materials
    import as `Emission + Transparent + Mix Shader` with the base colour wired into `Emission.Color`
    and no Principled node anywhere - and the FBX exporter finds textures by walking back from a
    Principled (or diffuse-like) node, so it exported *zero* of the 15 maps and the upload would
    have arrived as a grey mesh. Verified on a VRoid GLB: 0 embedded images before, 15 after.
    `--no-rebuild-materials` leaves them alone.
  - **Scale baked into the mesh** (`apply_scale_options='FBX_SCALE_ALL'`). glTF is metres and FBX is
    centimetres, and a mismatch here is what makes a character come back 100x too large - the same
    trap the Mixamo animation clips fell into.
  - **+Y translation so the feet sit on the origin.** Mixamo rigs from the ground plane up; a model
    floating above or sunk below it gets a skeleton in the wrong place.
  - **Material-less helper meshes dropped.** Every VRoid export carries an `Icosphere` - 42 verts,
    no material, radius 1 at the origin - a spring-bone/look-at helper that never renders. It
    dominates the bounding box, so grounding measured from it lifted the character a full metre off
    the floor and would have had Mixamo fit a skeleton to thin air. A mesh with no material assigned
    cannot render anything, so dropping those is safe in general, not just for VRM.

After this, the round trip is: upload the FBX to mixamo.com -> auto-rig -> download the rigged FBX
(and any dances) -> tools/ for the .scn conversion.
"""
import argparse
import os
import subprocess
import sys

try:
    import bpy
    import mathutils
    INSIDE_BLENDER = True
except ImportError:
    INSIDE_BLENDER = False


# --------------------------------------------------------------------------- outer half

def find_blender():
    candidates = [
        os.environ.get("BLENDER"),
        "/Applications/Blender.app/Contents/MacOS/Blender",
    ]
    import glob
    candidates += sorted(glob.glob("/Applications/Blender*.app/Contents/MacOS/Blender"), reverse=True)
    for c in candidates:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    sys.exit("Blender not found. Install it in /Applications, or set BLENDER=/path/to/Blender.")


def outer():
    ap = argparse.ArgumentParser(description="Convert GLB/glTF to FBX using Blender.")
    ap.add_argument("inputs", nargs="+", help=".glb / .gltf / .vrm files")
    ap.add_argument("-o", "--out", default=None,
                    help="output .fbx, or a directory when converting several files")
    ap.add_argument("--keep-rig", action="store_true",
                    help="keep the armature (skip only if you are NOT using Mixamo's auto-rigger)")
    ap.add_argument("--keep-animation", action="store_true", help="bake glTF animation into the FBX")
    ap.add_argument("--no-ground", action="store_true", help="do not drop the model onto y=0")
    ap.add_argument("--no-rebuild-materials", action="store_true",
                    help="do not rewire non-Principled materials (VRM/MToon export untextured)")
    face = ap.add_mutually_exclusive_group()
    face.add_argument("--face-flip", action="store_true",
                      help="force the 180-degree turn (source faces away from Mixamo's camera)")
    face.add_argument("--no-face-flip", action="store_true",
                      help="never turn the model, whatever its rig looks like")
    ap.add_argument("--scale", type=float, default=1.0, help="uniform scale before export")
    args = ap.parse_args()

    blender = find_blender()
    failures = 0
    many = len(args.inputs) > 1

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
            dst = os.path.splitext(src)[0] + ".fbx"

        cmd = [blender, "-b", "--factory-startup", "--python", os.path.abspath(__file__), "--",
               src, dst, str(args.scale)]
        if args.keep_rig:
            cmd.append("--keep-rig")
        if args.keep_animation:
            cmd.append("--keep-animation")
        if args.no_ground:
            cmd.append("--no-ground")
        if args.no_rebuild_materials:
            cmd.append("--no-rebuild-materials")
        if args.face_flip:
            cmd.append("--face-flip")
        if args.no_face_flip:
            cmd.append("--no-face-flip")

        r = subprocess.run(cmd, capture_output=True, text=True)
        ok = os.path.isfile(dst)
        if ok:
            size = os.path.getsize(dst) / 1e6
            # The inner half prints a one-line summary; surface it rather than Blender's noise.
            note = ""
            for line in r.stdout.splitlines():
                if line.startswith("[glb2fbx]"):
                    note = line[len("[glb2fbx]"):].strip()
            print(f"  {os.path.basename(dst)}  {size:6.1f} MB   {note}")
        else:
            failures += 1
            tail = (r.stderr or r.stdout).strip().splitlines()[-6:]
            print(f"  ! failed: {os.path.basename(src)}", file=sys.stderr)
            for line in tail:
                print(f"      {line}", file=sys.stderr)

    return 1 if failures else 0


# --------------------------------------------------------------------------- Blender half

def base_color_image(mat):
    """The image a material's base colour comes from, whatever shader it was authored for.

    Preference order matters: MToon wires base colour into `Emission.Color`, so that link is the
    reliable signal. Falling back to "the largest image in the tree" catches materials whose links
    the importer did not reproduce at all.
    """
    if not mat.node_tree:
        return None
    tex_nodes = [n for n in mat.node_tree.nodes if n.type == "TEX_IMAGE" and n.image]
    if not tex_nodes:
        return None
    for n in tex_nodes:
        for out in n.outputs:
            if out.name != "Color":
                continue
            for link in out.links:
                if link.to_node.type in {"EMISSION", "BSDF_DIFFUSE", "BSDF_PRINCIPLED"}:
                    return n.image
    # Mix nodes sit between the texture and the shader on some materials (the eye iris does).
    return max(tex_nodes, key=lambda n: n.image.size[0] * n.image.size[1]).image


def turn_to_face_camera(meshes):
    """Rotate 180 degrees about the model's own vertical axis.

    About the body's horizontal centre rather than the world origin: a model that is not centred
    would otherwise be mirrored across the origin and end up standing somewhere else.
    """
    import math
    xs, ys = [], []
    for m in meshes:
        for v in m.data.vertices:
            w = m.matrix_world @ v.co
            xs.append(w.x); ys.append(w.y)
    cx = (min(xs) + max(xs)) / 2
    cy = (min(ys) + max(ys)) / 2

    pivot = mathutils.Matrix.Translation((cx, cy, 0))
    turn = mathutils.Matrix.Rotation(math.radians(180), 4, "Z")
    xform = pivot @ turn @ pivot.inverted()
    for o in bpy.data.objects:
        if o.parent is None:
            o.matrix_world = xform @ o.matrix_world


def rebuild_materials():
    """Give every material a Principled BSDF driven by an Image Texture.

    Materials that already have a Principled with a connected base colour are left untouched, so a
    standard PBR glTF (Tripo3D, Sketchfab) passes through unchanged.
    """
    rebuilt = 0
    for mat in bpy.data.materials:
        if not mat.use_nodes or not mat.node_tree:
            continue
        principled = next((n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
        if principled and principled.inputs["Base Color"].links:
            continue
        img = base_color_image(mat)
        if img is None:
            continue

        nt = mat.node_tree
        nt.nodes.clear()
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.image = img
        tex.location = (-400, 0)
        bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
        bsdf.location = (0, 0)
        out = nt.nodes.new("ShaderNodeOutputMaterial")
        out.location = (300, 0)
        nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
        if "Alpha" in bsdf.inputs:
            nt.links.new(tex.outputs["Alpha"], bsdf.inputs["Alpha"])
        nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
        rebuilt += 1
    return rebuilt


def inner():
    argv = sys.argv[sys.argv.index("--") + 1:]
    src, dst, scale = argv[0], argv[1], float(argv[2])
    keep_rig = "--keep-rig" in argv
    keep_anim = "--keep-animation" in argv
    no_ground = "--no-ground" in argv
    rebuild = "--no-rebuild-materials" not in argv
    force_flip = "--face-flip" in argv
    forbid_flip = "--no-face-flip" in argv

    bpy.ops.wm.read_factory_settings(use_empty=True)

    # glTF import is dispatched by extension, and a .vrm - byte-identical to a .glb - is refused on
    # the name alone. Copy rather than rename, so the original download is left untouched.
    import shutil
    import tempfile
    load_path = src
    tmp_copy = None
    if os.path.splitext(src)[1].lower() not in (".glb", ".gltf"):
        fd, tmp_copy = tempfile.mkstemp(suffix=".glb")
        os.close(fd)
        shutil.copyfile(src, tmp_copy)
        load_path = tmp_copy

    # bone_heuristic="BLENDER" and guess_original_bind_pose=False keep the source bone names and the
    # rest pose exactly as authored. That matters when --keep-rig is used; with the default the
    # armature is discarded anyway, but the mesh still has to arrive in its bind pose rather than
    # posed, or the auto-rigger fits a skeleton to the wrong shape.
    try:
        bpy.ops.import_scene.gltf(filepath=load_path, bone_heuristic="BLENDER",
                                  guess_original_bind_pose=False)
    finally:
        if tmp_copy:
            os.unlink(tmp_copy)

    # Helper geometry first: it has to go before anything measures the model.
    helpers = [o for o in bpy.data.objects
               if o.type == "MESH" and not [m for m in o.data.materials if m]]
    for o in helpers:
        bpy.data.objects.remove(o, do_unlink=True)

    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    armatures = [o for o in bpy.data.objects if o.type == "ARMATURE"]
    if not meshes:
        raise SystemExit("no renderable mesh in the imported file")

    rebuilt = rebuild_materials() if rebuild else 0

    # Read the rig's identity while the armature is still here - this is the only reliable signal
    # for which way the model faces, and the next step deletes it.
    bone_names = [b.name for a in armatures for b in a.data.bones]
    if any(b.startswith("J_Bip") for b in bone_names):
        rig_kind = "vrm"
    elif any("mixamorig" in b.lower() for b in bone_names):
        rig_kind = "mixamo"
    else:
        rig_kind = "unknown"

    flip = force_flip or (rig_kind == "vrm" and not forbid_flip)

    if not keep_anim:
        # Animation on a model heading for the auto-rigger is dead weight, and a stray action can
        # leave the exported mesh frozen in a pose from frame 1 rather than its bind pose.
        for o in bpy.data.objects:
            o.animation_data_clear()
        for a in list(bpy.data.actions):
            bpy.data.actions.remove(a)

    if not keep_rig and armatures:
        # Mixamo's auto-rigger skips rigging when the FBX already has an armature. Unparent the
        # meshes first (keeping their current transform) so removing the armature cannot move them,
        # then drop the modifiers that now point at nothing.
        for m in meshes:
            world = m.matrix_world.copy()
            m.parent = None
            m.matrix_world = world
            for mod in [mm for mm in m.modifiers if mm.type == "ARMATURE"]:
                m.modifiers.remove(mod)
        for a in armatures:
            bpy.data.objects.remove(a, do_unlink=True)
        armatures = []

    if scale != 1.0:
        for o in bpy.data.objects:
            if o.parent is None:
                o.scale = [s * scale for s in o.scale]

    bpy.context.view_layer.update()

    if flip:
        turn_to_face_camera(meshes)
        bpy.context.view_layer.update()

    if not no_ground:
        # Feet on the origin: Mixamo builds the skeleton from the ground plane up.
        lowest = None
        for m in meshes:
            for v in m.data.vertices:
                y = (m.matrix_world @ v.co).z
                lowest = y if lowest is None else min(lowest, y)
        if lowest is not None and abs(lowest) > 1e-5:
            for o in bpy.data.objects:
                if o.parent is None:
                    o.location.z -= lowest

    bpy.ops.object.select_all(action="SELECT")

    bpy.ops.export_scene.fbx(
        filepath=dst,
        use_selection=False,
        apply_unit_scale=True,
        # Bake the scale into the vertices. glTF is metres, FBX is centimetres, and leaving the
        # factor on the object is how a character arrives 100x too big.
        apply_scale_options="FBX_SCALE_ALL",
        axis_forward="-Z",
        axis_up="Y",
        object_types={"MESH", "ARMATURE"} if armatures else {"MESH"},
        use_mesh_modifiers=True,
        mesh_smooth_type="FACE",
        # A single self-contained file: Mixamo accepts one upload, and an FBX that merely references
        # its textures arrives as an untextured grey mesh.
        path_mode="COPY",
        embed_textures=True,
        add_leaf_bones=False,
        primary_bone_axis="Y",
        secondary_bone_axis="X",
        bake_anim=keep_anim,
        bake_anim_use_all_actions=False,
        bake_anim_simplify_factor=0.0,
    )

    tris = sum(len(m.data.loop_triangles) for m in meshes
               if (m.data.calc_loop_triangles() or True))
    images = len([i for i in bpy.data.images if i.has_data or i.packed_file])
    lo = min((m.matrix_world @ v.co).z for m in meshes for v in m.data.vertices)
    hi = max((m.matrix_world @ v.co).z for m in meshes for v in m.data.vertices)
    print(f"[glb2fbx] {len(meshes)} mesh, {tris} tris, {images} textures, "
          f"{rebuilt} mats rebuilt, {len(helpers)} helpers dropped, "
          f"height {hi - lo:.2f}, feet at {lo:.3f}, "
          f"src rig={rig_kind}, faced={'turned' if flip else 'as-is'}, "
          f"rig={'kept' if armatures else 'removed'}, anim={'kept' if keep_anim else 'stripped'}")
    if rig_kind == "unknown" and not force_flip and not forbid_flip:
        print("[glb2fbx] ! unrecognised rig: check Mixamo's preview, and re-run with --face-flip "
              "if it shows the model's back", file=sys.stderr)


if __name__ == "__main__":
    if INSIDE_BLENDER:
        inner()
    else:
        sys.exit(outer())
