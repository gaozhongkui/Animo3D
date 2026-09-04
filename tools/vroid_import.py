#!/usr/bin/env python3
"""
Turn a VRoid Hub download into a character this app can actually use.

    python3 tools/vroid_import.py ~/Downloads/1234567890.vrm --key girl_d --name "Girl D"

What comes out the other end:

    assets_src/characters/<key>.usdz      the model, the form make_catalog.py expects
    Animo3D/Res/thumbs/thumb_<key>.png    the grid card, so a cold launch is not a spinner
    tools/manifest.json                   the key/name entry, appended

and nothing else has to change: dance data for VRoid characters is per-dance, not per-character.
The `vr_*.json` clips are lists of bone rotations against the shared VRoid skeleton, so every
existing dance already works on the new character the moment it is registered.

Why a script and not "export from Blender": three things have to be true at once or the character
arrives broken in a way that only shows up in SceneKit, and each of them has bitten this project.
  1. MToon materials have to be rebuilt as Principled + base colour, or USD export writes a model
     with no textures and the character renders pure white.
  2. Blender is Z-up and USD is Y-up, so the export needs an explicit orientation conversion or
     the character loads lying on its back.
  3. The rig has to keep VRoid's own bone names (J_Bip_*) untouched - both the runtime clip player
     and the offline retargeter address bones by those names.
tools/vroid_to_usdz.py does 1-3; this driver runs it and then checks the result really is usable
before anything is registered.

Requires Blender (any 4.x) at /Applications/Blender.app, or --blender <path>.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BLENDER_DEFAULT = "/Applications/Blender.app/Contents/MacOS/Blender"


def run(cmd, **kw):
    print(f"$ {' '.join(str(c) for c in cmd)}")
    return subprocess.run(cmd, **kw)


def build_swift_tool(name):
    """swiftc the helper into a temp dir, returning its path. Cheap enough to redo every run."""
    src = os.path.join(REPO, "tools", f"{name}.swift")
    out = os.path.join(tempfile.gettempdir(), f"animo3d_{name}")
    if not os.path.exists(src):
        return None
    if not os.path.exists(out) or os.path.getmtime(src) > os.path.getmtime(out):
        r = run(["swiftc", "-O", src, "-o", out])
        if r.returncode != 0:
            return None
    return out


def convert(blender, src_vrm, dst_usdz, downscale):
    # Blender's glTF importer dispatches on the file extension and does not know .vrm, so the file
    # is handed over as .glb. The bytes are unchanged - a .vrm *is* a .glb with an extra extension
    # block in its JSON chunk.
    with tempfile.TemporaryDirectory() as tmp:
        staged = os.path.join(tmp, "model.glb")
        shutil.copy(src_vrm, staged)
        cmd = [blender, "-b", "--factory-startup",
               "--python", os.path.join(REPO, "tools", "vroid_to_usdz.py"),
               "--", staged, dst_usdz]
        if downscale != "KEEP":
            cmd += ["--downscale", downscale]
        r = run(cmd, capture_output=True, text=True)
        for line in r.stdout.splitlines():
            if line.startswith("[vroid]") or line.startswith("  !"):
                print(line)
        if r.returncode != 0 or not os.path.exists(dst_usdz):
            print("\n--- blender output ---")
            print(r.stdout[-3000:])
            print(r.stderr[-2000:], file=sys.stderr)
            return False
        return True


def register(key, name):
    """Append the character to tools/manifest.json, which make_catalog.py reads."""
    path = os.path.join(REPO, "tools", "manifest.json")
    manifest = json.load(open(path))
    chars = manifest.setdefault("characters", [])
    if any(c["key"] == key for c in chars):
        print(f"  manifest already lists {key}, leaving it alone")
        return
    chars.append({"key": key, "name": name})
    with open(path, "w") as f:
        json.dump(manifest, f, indent=1, ensure_ascii=False)
        f.write("\n")
    print(f"  manifest.json += {key} ({name})")


def main():
    ap = argparse.ArgumentParser(description="VRoid Hub .vrm -> app-ready .usdz")
    ap.add_argument("model", help="the .vrm (or .glb) downloaded from VRoid Hub")
    ap.add_argument("--key", help="asset key, e.g. girl_d. Defaults to the file name, sanitised.")
    ap.add_argument("--name", help="display name shown in the app. Defaults to the key.")
    ap.add_argument("--downscale", default="2048",
                    choices=["KEEP", "256", "512", "1024", "2048", "4096"],
                    help="cap texture size in the usdz. VRoid ships 2048/4096 atlases and the "
                         "whole model is downloaded before the stage can open, so 2048 is the "
                         "default and 1024 is worth trying if the file lands over ~30 MB.")
    ap.add_argument("--blender", default=BLENDER_DEFAULT)
    ap.add_argument("--no-thumb", action="store_true", help="skip the grid thumbnail")
    ap.add_argument("--no-register", action="store_true", help="do not touch tools/manifest.json")
    args = ap.parse_args()

    if not os.path.exists(args.model):
        sys.exit(f"no such file: {args.model}")
    if not os.path.exists(args.blender):
        sys.exit(f"Blender not found at {args.blender} (pass --blender)")

    key = args.key or re.sub(r"[^A-Za-z0-9_]+", "_", os.path.splitext(os.path.basename(args.model))[0]).strip("_")
    if not key:
        sys.exit("could not derive a key from the file name; pass --key")
    name = args.name or key.replace("_", " ").title()
    dst = os.path.join(REPO, "assets_src", "characters", f"{key}.usdz")

    print(f"\n== converting {os.path.basename(args.model)} -> {key}.usdz")
    if not convert(args.blender, os.path.abspath(args.model), dst, args.downscale):
        sys.exit("conversion failed")

    print("\n== checking the result loads in SceneKit")
    inspector = build_swift_tool("inspect_model")
    if inspector:
        if run([inspector, dst]).returncode != 0:
            sys.exit("the converted model is not usable - see the FAIL lines above. Nothing was registered.")
    else:
        print("  ! tools/inspect_model.swift missing, skipping the check")

    if not args.no_thumb:
        print("\n== rendering the grid thumbnail")
        renderer = build_swift_tool("render_thumbs")
        if renderer:
            run([renderer, os.path.join(REPO, "Animo3D", "Res", "thumbs"), dst])
        else:
            print("  ! tools/render_thumbs.swift missing, skipping")

    if not args.no_register:
        print("\n== registering")
        register(key, name)

    print(f"""
Done. {key} is in place. To ship it:

    python3 tools/make_catalog.py --tag <release-tag> --out <upload-dir>

then attach that directory's files to the release. Existing dances need no work: vr_*.json clips
are shared by every VRoid character.
""")


if __name__ == "__main__":
    main()
