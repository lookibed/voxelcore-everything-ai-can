#!/usr/bin/env python3
"""AlphaMine phase 3: engine items for the Alpha items (content/alphamine/items/*.json + textures/items/am_*.png).

From D:\\Prog\\AlphaMine\\tables\\items.json (Item.java executed by minijava) and assets\\named\\items\\<name>.png:
  items/item_<name_snake>.json  {"icon-type": "sprite", "icon": "items:am_<name>", "stack-size": maxStackSize,
                            "caption": <Alpha item name>}
Block items (ItemBlock, id < 256) are not generated: the engine creates `alphamine:<block>.item` for every block
(icon = block preview); alphamine:inventory maps Alpha id -> engine item by these names.
Content names are shared by blocks and items (`alphamine:brick` is the block, the clay brick item is
`alphamine:item_brick`) -> the `item_` prefix.
The textures/items atlas is shared by all packs -> `am_` prefix (same reason as the blocks, agents/LESSONS.md).
  python3 tools/alphamine/gen_pack_items.py
"""
import json
import os
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
VC_ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
PACK = os.path.join(VC_ROOT, "content", "alphamine")
ALPHA = "/mnt/d/Prog/AlphaMine"


def main():
    with open(os.path.join(ALPHA, "tables", "items.json"), encoding="utf-8") as f:
        items = json.load(f)
    idir = os.path.join(PACK, "items")
    tdir = os.path.join(PACK, "textures", "items")
    os.makedirs(idir, exist_ok=True)
    os.makedirs(tdir, exist_ok=True)
    for d in (idir, tdir):
        for fn in os.listdir(d):
            if fn.endswith((".json", ".png")) and (d == idir or fn.startswith("am_")):
                os.remove(os.path.join(d, fn))
    n = 0
    for it in items:
        if it["block_item"]:
            continue
        name = it["name_snake"]
        shutil.copy(os.path.join(ALPHA, "assets", "named", "items", name + ".png"), os.path.join(tdir, "am_" + name + ".png"))
        with open(os.path.join(idir, "item_" + name + ".json"), "w", encoding="utf-8") as f:
            json.dump({"icon-type": "sprite", "icon": "items:am_" + name, "stack-size": it["max_stack"],
                       "caption": it["name"]}, f, indent=4)
            f.write("\n")
        n += 1
    print("gen_pack_items: %d items -> %s" % (n, idir))


if __name__ == "__main__":
    main()
