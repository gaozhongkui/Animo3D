#!/usr/bin/env python3
"""
Builds the one and only asset config: index.json (schema 2).

Everything is derived from what is actually on disk under assets_src/ - there is no whitelist to
keep in sync, and no display-name table. The file name *is* the name: `The_Boss.scn` shows as
"The Boss". Rename the file to rename the character.

This replaces four hand-or-half-generated documents that all described the same assets and had
drifted apart: tools/manifest.json (key -> display name), dist/index.json, dist/catalogs/<date>.json
and Animo3D/Res/seed_catalog.json. There is one document now, in one schema, and the app decodes it.

Everything the index covers lives under assets_src/, and everything under assets_src/ is remote:

    assets_src/characters/<Id>.scn      the model
    assets_src/dances/<Id>.json         the sampled mocap take
    assets_src/thumbs/thumb_<Id>.png    pre-rendered character card art

Music is not in the index. All four tracks ship in Animo3D/Res/music, where the bundled copy wins
the lookup anyway, so listing them only added 14MB of upload nobody would ever download.

Dance cards are not in the index either: the app renders them on device from the built-in character
plus the dance's own clip, so there is nothing to pre-render or ship for them.

Animo3D/Res/builtin holds the one model + one clip that ship inside the app; which pair that is gets
read off that directory and written into the index as `builtin`.

The bucket keeps one folder per kind, and the index names each file by its path inside the bucket:

    <bucket>/index.json
    <bucket>/characters/char_<Id>.scn
    <bucket>/dances/mocap_<Id>.json
    <bucket>/thumbs/thumb_<Id>.png

`--stage` writes exactly that tree into dist/upload/, so it can be dropped into the bucket as-is.

Signed URLs are deliberately not supported: the token ends up inside the cache key and expires with
no way for a shipped build to recover. Use a public bucket.

    python3 tools/make_catalog.py --base-url https://<proj>.supabase.co/storage/v1/object/public/models/
"""
import argparse, json, os, shutil, sys
from datetime import date

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SCHEMA = 2


def display_name(stem):
    return stem.replace("_", " ")


# An entry is just its bucket-relative path. No size (that is Content-Length) and no digest (a file
# that fails to parse is evicted and re-fetched), so there is nothing here to keep in sync.


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True,
                    help="public bucket directory every file is uploaded into; must end in /")
    ap.add_argument("--revision", type=int, default=None,
                    help="content revision; defaults to the previous index's + 1")
    ap.add_argument("--src", default=os.path.join(ROOT, "assets_src"))
    ap.add_argument("--res", default=os.path.join(ROOT, "Animo3D", "Res"))
    ap.add_argument("--out", default=os.path.join(ROOT, "dist", "index.json"))
    ap.add_argument("--stage", default=os.path.join(ROOT, "dist", "upload"),
                    help="build the exact bucket tree here, ready to drop in as-is")
    ap.add_argument("--min-app-version", default=None)
    ap.add_argument("--notice", default=None)
    args = ap.parse_args()

    base = args.base_url
    if not base.endswith("/"):
        base += "/"
    if "[" in base or "?" in base:
        sys.exit(f"refusing a placeholder or signed base-url: {base}\n"
                 "The token in a signed URL becomes part of the cache key and expires. "
                 "Make the bucket public.")

    src, res = os.path.abspath(args.src), os.path.abspath(args.res)
    uploads = []          # (local path, bucket-relative path)
    problems = []

    # ---- characters ---------------------------------------------------------
    characters = []
    cdir = os.path.join(src, "characters")
    for fn in sorted(os.listdir(cdir)) if os.path.isdir(cdir) else []:
        if not fn.endswith(".scn") or fn.startswith("."):
            continue
        stem = fn[:-4]
        p = os.path.join(cdir, fn)
        remote = f"characters/char_{fn}"
        item = {"id": stem, "name": display_name(stem), "model": remote}
        uploads.append((p, remote))

        thumb = os.path.join(src, "thumbs", f"thumb_{stem}.png")
        if os.path.exists(thumb):
            item["thumb"] = f"thumbs/thumb_{stem}.png"
            uploads.append((thumb, item["thumb"]))
        else:
            problems.append(f"no card art for character {stem} (run tools/render_thumbs.swift)")
        characters.append(item)

    # ---- dances -------------------------------------------------------------
    dances = []
    ddir = os.path.join(src, "dances")
    for fn in sorted(os.listdir(ddir)) if os.path.isdir(ddir) else []:
        if not fn.endswith(".json") or fn.startswith("."):
            continue
        stem = fn[:-5]
        p = os.path.join(ddir, fn)
        remote = f"dances/mocap_{fn}"
        item = {"id": stem, "name": display_name(stem), "clip": remote}
        uploads.append((p, remote))

        # Duration comes out of the take itself; the app shows it on the card.
        try:
            clip = json.load(open(p))
            fps = clip.get("fps") or 30
            frames = clip.get("frames") or []
            if frames:
                item["duration"] = round(len(frames) / float(fps), 2)
        except Exception as e:                                  # noqa: BLE001
            problems.append(f"could not read {fn}: {e}")

        dances.append(item)

    # ---- built-in set -------------------------------------------------------
    # Read off Res/builtin rather than declared by hand: the two ids that used to be Swift constants
    # named a dance that was not the bundled one, so the "offline" default downloaded every time.
    builtin = {}
    bdir = os.path.join(res, "builtin")
    for fn in sorted(os.listdir(bdir)) if os.path.isdir(bdir) else []:
        if fn.startswith("char_") and fn.endswith(".scn"):
            builtin["character"] = fn[len("char_"):-4]
        elif fn.startswith("mocap_") and fn.endswith(".json"):
            builtin["dance"] = fn[len("mocap_"):-5]
    for key, pool in (("character", characters), ("dance", dances)):
        if key in builtin and not any(x["id"] == builtin[key] for x in pool):
            problems.append(f"Res/builtin holds {key} {builtin[key]}, which is not in assets_src")
            del builtin[key]
    if set(builtin) != {"character", "dance"}:
        problems.append(f"built-in set incomplete: {builtin or 'nothing in Res/builtin'}")
        builtin = None

    # ---- revision -----------------------------------------------------------
    revision = args.revision
    if revision is None:
        try:
            revision = int(json.load(open(args.out)).get("revision", 0)) + 1
        except Exception:                                       # noqa: BLE001
            revision = 1

    index = {
        "schema": SCHEMA,
        "revision": revision,
        "generated": date.today().isoformat(),
        "minAppVersion": args.min_app_version,
        "baseUrl": base,
        "notice": args.notice,
        "builtin": builtin,
        "characters": characters,
        "dances": dances,
    }

    out = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    json.dump(index, open(out, "w"), indent=1, ensure_ascii=False)

    total = sum(os.path.getsize(p) for p, _ in uploads)
    print(f"wrote {out}  (schema {SCHEMA}, revision {revision})")
    print(f"characters={len(characters)} dances={len(dances)}")
    print(f"built-in: {builtin}")
    print(f"upload {len(uploads)} files, {total/1e6:.1f} MB")
    for p in problems:
        print(f"  ! {p}", file=sys.stderr)

    if args.stage:
        stage = os.path.abspath(args.stage)
        shutil.rmtree(stage, ignore_errors=True)
        os.makedirs(stage, exist_ok=True)
        for p, remote in uploads:
            dest = os.path.join(stage, remote)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copy2(p, dest)
        shutil.copy2(out, os.path.join(stage, "index.json"))
        print(f"staged the bucket tree in {stage}")
        print(f"  upload the *contents* of that directory into the bucket root")

    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
