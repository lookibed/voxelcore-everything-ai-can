#!/usr/bin/env python3
"""Extract Minecraft Alpha 1.0.16 assets for AlphaMine (stdlib only).

Sources (RetroMCP workspace copy, read-only):
  <ref>/jars/minecraft.jar                 textures, font, splashes (all non-class resources)
  <ref>/jars/assets/indexes/a1.0.14.json   sound index -> <ref>/jars/assets/objects/<hh>/<hash>

Output <out> (default <repo>\\projects\\alphamine\\external\\assets, regenerated, not tracked by git):
  <path from jar>                  e.g. terrain.png, gui/items.png, title/splashes.txt
  sound/<index name>               e.g. sound/newsound/step/grass1.ogg
  tiles/terrain/<i>.png            terrain.png 16x16 tiles, i = row*16 + col (0..255)
  tiles/items/<i>.png              gui/items.png 16x16 tiles
  named/blocks/<name>.png          only if <tables>/textures_by_block.json exists (gen_tables.py)
  named/items/<name>.png           only if <tables>/items.json exists
  manifest.json                    [{path, size, sha1, source}]

Usage: extract_assets.py [--ref DIR] [--out DIR] [--tables DIR]
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio  # noqa: E402

ALPHA = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "external"))  # было внешний каталог AlphaMine
RES_EXT = (".png", ".txt", ".gif")


def sha1(data):
    return hashlib.sha1(data).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", default=os.path.join(ALPHA, "ref"))
    ap.add_argument("--out", default=os.path.join(ALPHA, "assets"))
    ap.add_argument("--tables", default=os.path.join(ALPHA, "tables"))
    ap.add_argument("--keep", action="store_true", help="do not wipe <out> first")
    args = ap.parse_args()

    out = args.out
    if os.path.isdir(out) and not args.keep:
        shutil.rmtree(out)
    os.makedirs(out, exist_ok=True)
    manifest = []
    problems = []

    def put(rel, data, source):
        path = os.path.join(out, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
        manifest.append({"path": rel, "size": len(data), "sha1": sha1(data), "source": source})

    # 1. jar resources
    jar_path = os.path.join(args.ref, "jars", "minecraft.jar")
    jar_files = {}
    skipped = []
    with zipfile.ZipFile(jar_path) as z:
        for info in z.infolist():
            name = info.filename
            if name.endswith("/") or name.startswith("META-INF/") or name.endswith(".class"):
                continue
            if not name.lower().endswith(RES_EXT):
                skipped.append(name)
                continue
            data = z.read(name)
            jar_files[name] = data
            put(name, data, "jar")
    n_jar = len(jar_files)

    # 2. sounds from the asset index
    idx_path = os.path.join(args.ref, "jars", "assets", "indexes", "a1.0.14.json")
    with open(idx_path) as f:
        index = json.load(f)
    n_snd = 0
    missing = []
    for section in ("objects", "custom"):
        for name, meta in sorted(index.get(section, {}).items()):
            h = meta["hash"]
            obj = os.path.join(args.ref, "jars", "assets", "objects", h[:2], h)
            if not os.path.isfile(obj):
                missing.append("%s (%s, %s)" % (name, section, h))
                continue
            with open(obj, "rb") as f:
                data = f.read()
            if sha1(data) != h or len(data) != meta["size"]:
                problems.append("hash/size mismatch: " + name)
                continue
            put("sound/" + name, data, "index:" + section)
            n_snd += 1

    # 3. atlases -> tiles
    n_tiles = {}
    atlases = {}
    for atlas, src in (("terrain", "terrain.png"), ("items", "gui/items.png")):
        w, h, rows = pngio.read_rgba(jar_files[src])
        atlases[atlas] = rows
        if (w, h) != (256, 256):
            problems.append("%s is %dx%d, expected 256x256" % (src, w, h))
        cnt = 0
        for i in range(256):
            col, row = i % 16, i // 16
            tile = pngio.crop(rows, col * 16, row * 16, 16, 16)
            put("tiles/%s/%d.png" % (atlas, i), pngio.write_rgba(16, 16, tile), "slice:" + src)
            cnt += 1
        n_tiles[atlas] = cnt

    # 4. optional named layout from gen_tables.py output
    n_named = {"blocks": 0, "items": 0}
    tbb = os.path.join(args.tables, "textures_by_block.json")
    if os.path.isfile(tbb):
        with open(tbb) as f:
            tiles = json.load(f)
        for key, ent in sorted(tiles.items(), key=lambda kv: int(kv[0])):
            i = int(key)
            rows = pngio.crop(atlases["terrain"], (i % 16) * 16, (i // 16) * 16, 16, 16)
            put("named/blocks/%s.png" % ent["name"], pngio.write_rgba(16, 16, rows), "slice:terrain.png#%d" % i)
            n_named["blocks"] += 1
    itp = os.path.join(args.tables, "items.json")
    if os.path.isfile(itp):
        with open(itp) as f:
            items = json.load(f)
        for it in items:
            if it.get("atlas") != "items":
                continue
            i = it["icon_index"]
            rows = pngio.crop(atlases["items"], (i % 16) * 16, (i // 16) * 16, 16, 16)
            put("named/items/%s.png" % it["name_snake"], pngio.write_rgba(16, 16, rows), "slice:gui/items.png#%d" % i)
            n_named["items"] += 1

    manifest.sort(key=lambda e: e["path"])
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)

    print("jar resources: %d (skipped non-resource: %s)" % (n_jar, ", ".join(skipped) or "-"))
    print("sounds: %d of %d index entries" % (n_snd, len(index.get("objects", {})) + len(index.get("custom", {}))))
    for m in missing:
        print("  missing object: " + m)
    print("tiles: " + ", ".join("%s %d" % kv for kv in n_tiles.items()))
    print("named: blocks %d, items %d" % (n_named["blocks"], n_named["items"]))
    print("manifest entries: %d -> %s" % (len(manifest), os.path.join(out, "manifest.json")))
    for p in problems:
        print("PROBLEM: " + p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
