"""
Blender-side half of the VRoid Hub import. Run through tools/vroid_import.py, never on its own:

    blender -b --factory-startup --python tools/vroid_to_usdz.py -- <in.glb> <out.usdz> [--downscale 2048]

A .vrm file is glTF 2.0 with a VRM extension block, so Blender's stock glTF importer reads the
mesh, the skeleton and the textures out of it without any add-on. What it cannot read is MToon,
the toon shading model VRoid writes its materials in: those come in as an unknown extension and
Blender falls back to whatever pbrMetallicRoughness data is alongside it, which for a VRoid export
is often nothing at all. Exporting that straight to USD produces a pure white character - the
material has no base colour node for the USD preview surface to translate.

So every material is rebuilt here as a plain Principled BSDF fed by the base colour image that came
in with it. The app shades VRM characters with its own cel ramp anyway (applyToonShading), so the
only thing the material has to carry across is the texture and its alpha.
"""
import os
import sys

import bpy


def argv_after_ddash():
    return sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def wipe_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def base_color_image(mat):
    """The image the material is meant to show, whatever node tree it arrived in."""
    if not mat.use_nodes or not mat.node_tree:
        return None
    # Prefer an image wired into a Principled base colour or an emission, which is where both the
    # glTF importer and the MToon fallback put the albedo.
    for node in mat.node_tree.nodes:
        if node.type != "BSDF_PRINCIPLED":
            continue
        link = next((l for l in mat.node_tree.links
                     if l.to_node == node and l.to_socket.name in ("Base Color", "Emission Color")), None)
        if link and link.from_node.type == "TEX_IMAGE" and link.from_node.image:
            return link.from_node.image
    # Otherwise take the largest image in the tree - VRoid materials that lost their wiring still
    # carry the texture as an orphan node, and the biggest one is the skin/cloth atlas.
    images = [n.image for n in mat.node_tree.nodes if n.type == "TEX_IMAGE" and n.image]
    return max(images, key=lambda i: i.size[0] * i.size[1], default=None)


def rebuild_material(mat):
    """Replace the node tree with image -> Principled -> output, keeping alpha."""
    image = base_color_image(mat)
    mat.use_nodes = True
    tree = mat.node_tree
    tree.nodes.clear()

    out = tree.nodes.new("ShaderNodeOutputMaterial")
    out.location = (400, 0)
    bsdf = tree.nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.location = (100, 0)
    # Anime skin and cloth are dielectric and matte. Any metalness here makes the character mirror
    # the stage environment map, which is exactly the blotchy look the app fights elsewhere.
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Roughness"].default_value = 0.9
    tree.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])

    if image is None:
        print(f"  ! {mat.name}: no image found, exporting flat colour")
        return False

    tex = tree.nodes.new("ShaderNodeTexImage")
    tex.location = (-300, 0)
    tex.image = image
    tex.interpolation = "Smart"
    tree.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])

    # Hair cards, eyelashes and eyebrows are cut out with the texture's alpha; without this they
    # render as opaque rectangles over the face.
    tree.links.new(tex.outputs["Alpha"], bsdf.inputs["Alpha"])
    mat.blend_method = "BLEND" if "HAIR" in mat.name.upper() else "CLIP"
    if hasattr(mat, "shadow_method"):
        mat.shadow_method = "CLIP"
    mat.use_backface_culling = False
    return True


def main():
    args = argv_after_ddash()
    if len(args) < 2:
        print("usage: ... -- <in.glb> <out.usdz> [--downscale N]")
        sys.exit(2)
    src, dst = args[0], args[1]
    downscale = "KEEP"
    if "--downscale" in args:
        downscale = args[args.index("--downscale") + 1]

    wipe_scene()
    print(f"[vroid] importing {os.path.basename(src)}")
    bpy.ops.import_scene.gltf(
        filepath=src,
        import_pack_images=True,
        merge_vertices=False,
        # Keep the bone names and the rest pose exactly as authored. The app matches VRoid bones by
        # name (J_Bip_C_Hips and friends) and the offline retargeter samples against this rest pose,
        # so anything Blender "improves" here desynchronises the two.
        bone_heuristic="BLENDER",
        guess_original_bind_pose=False,
    )

    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    armatures = [o for o in bpy.data.objects if o.type == "ARMATURE"]
    print(f"[vroid] {len(meshes)} meshes, {len(armatures)} armatures, {len(bpy.data.materials)} materials")
    if not armatures:
        print("[vroid] ERROR: no armature in this file - the app cannot pose it")
        sys.exit(3)

    bones = {b.name for a in armatures for b in a.data.bones}
    if "J_Bip_C_Hips" not in bones:
        print(f"[vroid] ERROR: no J_Bip_C_Hips bone. This does not look like a VRoid rig "
              f"(found {len(bones)} bones, e.g. {sorted(bones)[:5]})")
        sys.exit(3)

    rebuilt = sum(rebuild_material(m) for m in bpy.data.materials)
    print(f"[vroid] rebuilt {rebuilt}/{len(bpy.data.materials)} materials")

    os.makedirs(os.path.dirname(os.path.abspath(dst)), exist_ok=True)
    print(f"[vroid] exporting {os.path.basename(dst)}")
    bpy.ops.wm.usd_export(
        filepath=dst,
        export_textures=True,
        export_textures_mode="NEW",     # bake the packed images back out beside the USD
        generate_preview_surface=True,  # the shader network SceneKit actually reads
        export_materials=True,
        export_armatures=True,
        export_animation=False,         # dances are driven from JSON at runtime, not baked in
        only_deform_bones=False,
        # Blender is Z-up, USD/SceneKit are Y-up. Without this the character loads lying on its back.
        convert_orientation=True,
        export_global_up_selection="Y",
        export_global_forward_selection="NEGATIVE_Z",
        usdz_downscale_size=downscale,
        relative_paths=True,
        evaluation_mode="RENDER",
    )
    print(f"[vroid] done: {dst} ({os.path.getsize(dst) / 1e6:.1f} MB)")


main()
