#!/usr/bin/env python3
"""
Scans the Res/ tree and emits the remote asset catalog plus the exact list of files to
attach to a GitHub Release.

Two derived artefacts are generated here rather than shipped by hand:
  - `pose_<dance>.json` - a single frame lifted out of each mocap clip. A dance card only needs
    the character to strike one pose, and pulling the whole ~750KB clip for that made the 44-card
    grid cost 21MB. The extract is ~2KB.
  - `seed_catalog.json` - written into Res/ and bundled with the app, so a cold, offline first
    launch still shows a full character and dance list instead of empty grids.

Pre-rendered character art (`thumb_<key>.png`, from tools/render_thumbs.swift) is picked up from
Res/thumbs when present and referenced from the catalog.

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

SIGNATURE_FRAME = 0.45      # the frame a card poses on, matching ThumbRenderer


def write_pose(mocap_path, out_path):
    """One frame of a mocap clip, in the same shape MocapClip.load already parses."""
    try:
        clip = json.load(open(mocap_path))
        frames = clip.get("frames") or []
        if not frames:
            return None
        frame = frames[min(len(frames) - 1, int(len(frames) * SIGNATURE_FRAME))]
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        json.dump({"fps": clip.get("fps", 30), "frames": [frame]}, open(out_path, "w"))
        return out_path
    except Exception as e:                                  # noqa: BLE001 - a bad clip must not stop the build
        print(f"  ! pose extract failed for {os.path.basename(mocap_path)}: {e}", file=sys.stderr)
        return None


def entry(path, remote_name, **extra):
    e = {"file": remote_name, "bytes": os.path.getsize(path), "sha256": sha256(path)}
    e.update(extra)
    return e

def main():
    ap = argparse.ArgumentParser()
    # Heavy source assets live outside the app target (assets_src/), so nothing can accidentally be
    # bundled by Xcode's synchronized folder just by existing. Res/ only holds what ships.
    ap.add_argument("--src", default=os.path.join(os.path.dirname(__file__), "..", "assets_src"),
                    help="source assets: characters/, dances/, anim/, music/")
    ap.add_argument("--res", default=os.path.join(os.path.dirname(__file__), "..", "Animo3D", "Res"),
                    help="bundled resources: thumbs/ is read from here, seed_catalog.json written here")
    ap.add_argument("--tag", default="assets-v1", help="GitHub Release tag holding the binaries")
    ap.add_argument("--out", default=None, help="Directory to write index.json / catalogs/ into")
    ap.add_argument("--stage", default="releases", help="Copy the renamed binaries here, ready to upload")
    args = ap.parse_args()

    res = os.path.abspath(args.res)
    src = os.path.abspath(args.src)
    # manifest.json lives next to this script, not in Res/: it is a build input (key -> display name
    # plus the whitelist of what to publish), never an app resource.
    manifest = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "manifest.json")))
    names = {c["key"]: c["name"] for c in manifest["characters"]}
    dance_names = {d["key"]: d["name"] for d in manifest["dances"]}

    uploads = []            # (local path, remote name)
    characters, dances, music = [], [], []
    pose_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "poses")
    pose_dir = os.path.abspath(pose_dir)

    # ---- characters: .scn or .usdz, whichever exists
    for key, name in names.items():
        for ext in ("scn", "usdz"):
            p = os.path.join(src, "characters", f"{key}.{ext}")
            if os.path.exists(p):
                remote = f"char_{key}.{ext}"
                # VRoid exports are the .usdz ones; they need the vr_* clips, not the mocap ones
                rig = "vrm" if ext == "usdz" else "mixamo"
                item = entry(p, remote, key=key, name=name, rig=rig)
                # Pre-rendered card art: the app shows this instead of downloading the model just
                # to fill a grid cell (nine characters used to mean 191MB before anything appeared).
                thumb = os.path.join(res, "thumbs", f"thumb_{key}.png")
                if os.path.exists(thumb):
                    item["thumb"] = entry(thumb, f"thumb_{key}.png")
                    uploads.append((thumb, f"thumb_{key}.png"))
                else:
                    print(f"  ! no thumbnail for {key} (run tools/render_thumbs.swift)", file=sys.stderr)
                characters.append(item)
                uploads.append((p, remote))
                break
        else:
            print(f"  ! no model file for character {key}", file=sys.stderr)

    # ---- dances: a mocap json for Mixamo rigs, a vr_* json for VRM rigs
    for key, name in dance_names.items():
        clips = {}
        mocap = os.path.join(src, "dances", f"{key}.json")
        if os.path.exists(mocap):
            remote = f"mocap_{key}.json"
            clips["mixamo"] = entry(mocap, remote)
            uploads.append((mocap, remote))
        vrm = os.path.join(src, "anim", "vroid_clips", f"vr_{key}.json")
        if os.path.exists(vrm):
            remote = f"vrm_{key}.json"
            clips["vrm"] = entry(vrm, remote)
            uploads.append((vrm, remote))
        if not clips:
            print(f"  ! no clip for dance {key}", file=sys.stderr)
            continue
        d = {"key": key, "name": name, "clips": clips}
        if os.path.exists(mocap):
            pose_path = write_pose(mocap, os.path.join(pose_dir, f"pose_{key}.json"))
            if pose_path:
                remote = f"pose_{key}.json"
                d["pose"] = entry(pose_path, remote)
                uploads.append((pose_path, remote))
        dances.append(d)

    # ---- music
    mdir = os.path.join(src, "music")
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

    # Bundled seed: the app decodes this at startup so the lists are populated before - and without -
    # any network call. It carries no binaries, only what exists and where to get it.
    seed_path = os.path.join(res, "seed_catalog.json")
    json.dump(catalog, open(seed_path, "w"), ensure_ascii=False, separators=(",", ":"))
    print(f"wrote {seed_path} ({os.path.getsize(seed_path)/1024:.0f} KB)")

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
