#!/usr/bin/env python3
"""
Scans the bundled Res/ tree and emits the remote asset catalog plus the exact list of
files to attach to a GitHub Release.

Only index.json and catalogs/*.json belong in the git repo. Every binary is a Release
attachment: GitHub flattens attachment names, so each asset gets a flat, prefixed name
(char_/mocap_/vrm_/music_) and the catalog refers to that name - no path juggling and
no chance of two assets colliding.

    python3 tools/make_catalog.py --tag assets-v1 --out ../App-Assets
"""
import argparse, hashlib, json, os, shutil, sys
from datetime import date

REPO = "gaozhongkui/Animo3D"

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def entry(path, remote_name, **extra):
    e = {"file": remote_name, "bytes": os.path.getsize(path), "sha256": sha256(path)}
    e.update(extra)
    return e

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--res", default=os.path.join(os.path.dirname(__file__), "..", "Animo3D", "Res"))
    ap.add_argument("--tag", default="assets-v1", help="GitHub Release tag holding the binaries")
    ap.add_argument("--out", default=None, help="Directory to write index.json / catalogs/ into")
    ap.add_argument("--stage", default=None, help="Copy the renamed binaries here, ready to upload")
    args = ap.parse_args()

    res = os.path.abspath(args.res)
    manifest = json.load(open(os.path.join(res, "manifest.json")))
    names = {c["key"]: c["name"] for c in manifest["characters"]}
    dance_names = {d["key"]: d["name"] for d in manifest["dances"]}

    uploads = []            # (local path, remote name)
    characters, dances, music = [], [], []

    # ---- characters: .scn or .usdz, whichever exists
    for key, name in names.items():
        for ext in ("scn", "usdz"):
            p = os.path.join(res, "characters", f"{key}.{ext}")
            if os.path.exists(p):
                remote = f"char_{key}.{ext}"
                # VRoid exports are the .usdz ones; they need the vr_* clips, not the mocap ones
                rig = "vrm" if ext == "usdz" else "mixamo"
                characters.append(entry(p, remote, key=key, name=name, rig=rig))
                uploads.append((p, remote))
                break
        else:
            print(f"  ! no model file for character {key}", file=sys.stderr)

    # ---- dances: a mocap json for Mixamo rigs, a vr_* json for VRM rigs
    for key, name in dance_names.items():
        clips = {}
        mocap = os.path.join(res, "dances", f"{key}.json")
        if os.path.exists(mocap):
            remote = f"mocap_{key}.json"
            clips["mixamo"] = entry(mocap, remote)
            uploads.append((mocap, remote))
        vrm = os.path.join(res, "anim", "vroid_clips", f"vr_{key}.json")
        if os.path.exists(vrm):
            remote = f"vrm_{key}.json"
            clips["vrm"] = entry(vrm, remote)
            uploads.append((vrm, remote))
        if clips:
            dances.append({"key": key, "name": name, "clips": clips})
        else:
            print(f"  ! no clip for dance {key}", file=sys.stderr)

    # ---- music
    mdir = os.path.join(res, "music")
    if os.path.isdir(mdir):
        for fn in sorted(os.listdir(mdir)):
            if fn.startswith("."):
                continue
            p = os.path.join(mdir, fn)
            key = os.path.splitext(fn)[0]
            remote = f"music_{fn}"
            music.append(entry(p, remote, key=key, name=key.replace("_", " ")))
            uploads.append((p, remote))

    version = date.today().isoformat()
    catalog = {"schema": 1, "version": version,
               "characters": characters, "dances": dances, "music": music}
    index = {"schema": 1,
             "catalog": f"catalogs/{version}.json",
             "baseUrl": f"https://github.com/{REPO}/releases/download/{args.tag}/",
             "minAppVersion": "1.0.0",
             "notice": None}

    total = sum(os.path.getsize(p) for p, _ in uploads)
    print(f"characters={len(characters)} dances={len(dances)} music={len(music)}")
    print(f"upload {len(uploads)} files, {total/1e6:.1f} MB total")

    if args.out:
        out = os.path.abspath(args.out)
        os.makedirs(os.path.join(out, "catalogs"), exist_ok=True)
        json.dump(index, open(os.path.join(out, "index.json"), "w"), indent=2)
        json.dump(catalog, open(os.path.join(out, "catalogs", f"{version}.json"), "w"),
                  indent=1, ensure_ascii=False)
        print("wrote", os.path.join(out, "index.json"))
        print("wrote", os.path.join(out, "catalogs", f"{version}.json"))

    if args.stage:
        stage = os.path.abspath(args.stage)
        os.makedirs(stage, exist_ok=True)
        for p, remote in uploads:
            shutil.copy2(p, os.path.join(stage, remote))
        print("staged binaries in", stage)
        print(f"upload with:  gh release create {args.tag} {stage}/* --repo {REPO} --title {args.tag}")

if __name__ == "__main__":
    main()
