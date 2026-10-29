#!/usr/bin/env python3
"""Derive AlphaMine block/item tables from the decompiled Alpha 1.0.16 client.

Instead of pattern matching, the registrations in Block.java / Item.java are
executed by minijava.py (constructors, field initializers, static init, simple
getters), so values come out exactly as the Java code computes them. Values
that need the world (neighbour blocks) are evaluated against a mock world
(meta 0..15, every neighbour = air) and marked; anything the interpreter
cannot execute is listed in NOTES.md, never guessed.

Output (<out>, default D:\\Prog\\AlphaMine\\tables):
  blocks.json            one entry per registered block id
  items.json             Item.java items (+ ItemBlock entries for blocks)
  textures_by_block.json terrain tile index -> {name, uses:[{block, id, face, meta?, via}]}
  NOTES.md               how to read the tables + everything not derivable statically

Usage: gen_tables.py [--src DIR] [--out DIR]
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from minijava import VM, JObject, Unsupported, JavaThrow  # noqa: E402

ALPHA = "/mnt/d/Prog/AlphaMine"
# side index as used by getBlockTexture*/shouldSideBeRendered and the face
# function RenderBlocks.renderStandardBlock draws for it (MCP names of Alpha).
SIDES = [
    ("bottom", "-y", "renderBottomFace"),
    ("top", "+y", "renderTopFace"),
    ("east", "-z", "renderEastFace"),
    ("west", "+z", "renderWestFace"),
    ("north", "-x", "renderNorthFace"),
    ("south", "+x", "renderSouthFace"),
]


CONVENTIONS = """## How to read the tables

- `tiles_by_side[s]` / `tiles` = `getBlockTextureFromSideAndMetadata(s, 0)`: what the inventory/item
  renderer and every block without a `getBlockTexture(IBlockAccess,...)` override draws. Side index `s`
  is the one RenderBlocks.renderStandardBlock passes: 0 bottom (-Y), 1 top (+Y), 2 -Z (MCP
  `renderEastFace`), 3 +Z (`renderWestFace`), 4 -X (`renderNorthFace`), 5 +X (`renderSouthFace`).
  The keys of `tiles` use these **Alpha MCP names** (east = -Z, west = +Z, north = -X, south = +X),
  not modern Minecraft ones. VoxelCore `texture-faces` has bottom at index 2 and top at index 3
  (`res/content/base/blocks/grass_block.json`); its X/Z order must be checked in the engine (phase 2).
- Tile index `t` addresses terrain.png: column `t % 16`, row `t // 16`; sliced as
  `assets/tiles/terrain/<t>.png`. A **negative** tile (doors) means "draw tile `-t` mirrored in U"
  (`RenderBlocks.renderBlockDoor`: `if(tex < 0) { flipTexture = true; tex = -tex; }`).
- `tiles_by_meta` lists metadata values 1..15 whose tiles differ from meta 0. The sweep covers all
  16 values, including metadata the game never sets (crops only use 0..7, so crops m8..m15 hit tiles
  96..103 that belong to lever/doors/redstone torch; names `crops_m13..m15` for tiles 101..103 come
  only from such unused metadata).
- `world_tiles`: blocks overriding `getBlockTexture(IBlockAccess, x, y, z, side)` (grass, chest,
  furnaces, stairs) evaluated in a mock world, see the section below. In Alpha the grass **item**
  shows the side tile (3) on all faces; the world block has top 0, bottom 2, sides 3 or 68 under snow.
- `opaque_cube_lookup` is `Block.opaqueCubeLookup[id]` (what lighting and neighbour culling use),
  `is_opaque_cube` is the method result now; they differ where the Block constructor called the
  overridden method before the subclass constructor ran (see below).
- `light_value` = `Block.lightValue[id]` = `(int)(15 * f)`; `light_opacity` = `Block.lightOpacity[id]`
  (255 for opaque cubes, 0 otherwise, unless `setLightOpacity`: water/ice 3, leaves 1, farmland and
  slabs 255).
- `hardness`, `resistance` are the raw fields (`resistance` = max(3*setResistance, 5*hardness));
  `explosion_resistance` = `getExplosionResistance()` = resistance / 5.
- `step_sound.step` / `.break` are sound names without the numeric suffix (`step.grass` ->
  `sound/newsound/step/grass1..4.ogg`); `volume`/`pitch` are the StepSound constructor args.
- Items: `id` = `shiftedIndex` = 256 + index; `atlas` = terrain for ItemBlock (icon =
  `getBlockTextureFromSide(2)`), gui/items.png otherwise. `str_vs_block` = `getStrVsBlock` where != 1.0,
  `can_harvest` = block ids with `canHarvestBlock` true.

## Known facts not visible in the tables

- Leaves: `BlockLeaves.setGraphicsLevel(fancy)` is called at runtime by RenderGlobal:
  fancy -> tile 52 and isOpaqueCube() false, fast -> tile 53 and true. The table shows the state
  after construction (graphicsLevel false: tile 52, opaque). `opaqueCubeLookup[18]` stays true.
- Animated tiles are written into terrain.png at runtime by TextureFX (`Minecraft.java` 217-222),
  the atlas pixels there are placeholders: water still 205 (TextureWaterFX), water flow 206 with
  tileSize 2 (206, 207, 222, 223), lava still 237, lava flow 238 with tileSize 2 (238, 239, 254, 255),
  fire 31 and 47 (TextureFlamesFX(0), (1)). All use Math.random() -> must be ported procedurally.
- Not in a1.0.16: fence (85), pumpkin, netherrack etc. `renderBlockFence` (render type 11) exists but
  no block uses it. Colored cloth fields (ids 21-34, 36) are declared but null; only 35 `cloth`
  exists. The server (a0.1.1, `minecraft_server/src`) registers exactly the same block ids.
- Fire `render_pass` 1 comes from the user's patch in `ref/minecraft/src/BlockFire.java` (the
  reference client draws fire in the translucent pass; `src_original` inherits 0 from Block).
  The same patch removes fire particles/sounds (`randomDisplayTick` returns at once).
- Block names are MCP field names (`stoneOvenIdle`, `stairDouble`, `wood` = log); Alpha has no
  translation file, so there are no display names.

"""


def snake(name):
    s = re.sub(r"(?<=[a-z0-9])([A-Z])", r"_\1", name)
    return s.lower()


class MockWorld:
    """IBlockAccess for a block at (0,64,0) with metadata `meta`; every other cell is
    air unless listed in `cells` ({(x,y,z): block object})."""

    SELF = (0, 64, 0)

    def __init__(self, vm, meta, self_obj, cells=None):
        self.vm = vm
        self.meta = meta
        self.self_obj = self_obj
        self.cells = dict(cells or {})
        self.cells[self.SELF] = self_obj
        self.used = set()

    def _at(self, args):
        return self.cells.get(tuple(args))

    def java_call(self, name, args):
        self.used.add(name)
        b = self._at(args)
        if name == "getBlockMetadata":
            return self.meta if tuple(args) == self.SELF else 0
        if name == "getBlockId":
            return b.f["blockID"] if b is not None else 0
        if name == "getBlockMaterial":
            return b.f["material"] if b is not None else self.vm.static("Material", "air")
        if name in ("isBlockNormalCube", "isBlockOpaqueCube"):
            if b is None:
                return False
            return self.vm.static("Block", "opaqueCubeLookup")[b.f["blockID"]] and bool(
                self.vm.call_method(b, "renderAsNormalBlock", []))
        raise Unsupported("MockWorld." + name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.path.join(ALPHA, "ref", "minecraft", "src", "net", "minecraft", "src"))
    ap.add_argument("--mappings", default=os.path.join(ALPHA, "ref", "conf", "mappings.tiny"))
    ap.add_argument("--out", default=os.path.join(ALPHA, "tables"))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    # F2F* classes are the frame-to-frame instrumentation (agents/F2F.md), not game data:
    # interpret game classes only and treat F2F calls as opaque host calls.
    vm = VM(args.src, opaque_prefixes=("F2F",))
    unparsed = []   # (what, reason)
    notes_auto = []

    def attempt(what, fn, *a):
        try:
            return True, fn(*a)
        except (Unsupported, JavaThrow, RecursionError, TypeError, KeyError) as ex:
            unparsed.append((what, "%s: %s" % (type(ex).__name__, ex)))
            return False, None

    # ---- obfuscation names from mappings.tiny (client column)
    obf_class, obf_field = {}, {}
    if os.path.isfile(args.mappings):
        cur = None
        with open(args.mappings) as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if p[0] == "c":
                    cur = p[1].split("/")[-1]
                    obf_class[cur] = p[2]
                elif len(p) >= 5 and p[1] == "f" and cur in ("Block", "Item"):
                    obf_field[(cur, p[3])] = p[4]

    # ---- run static init (Block pulls in Material, StepSound, Item, ItemBlock ...)
    Block = vm.get_class("Block")
    vm.ensure_static(Block)
    Item = vm.get_class("Item")
    vm.ensure_static(Item)
    st = Block.statics
    blocks_list = st["blocksList"]

    Material = vm.get_class("Material")
    mat_name = {id(v): k for k, v in Material.statics.items() if isinstance(v, JObject)}
    sound_name = {id(v): k for k, v in st.items() if isinstance(v, JObject) and vm.is_subclass(v.cls, "StepSound")}
    block_field = {}
    for f in Block.sfields:
        v = st[f.name]
        if isinstance(v, JObject) and vm.is_subclass(v.cls, "Block"):
            block_field[id(v)] = f.name
    null_fields = [f.name for f in Block.sfields
                   if st[f.name] is None and f.type in ("Block",) or (st[f.name] is None and f.type.startswith("Block") and not f.type.endswith("[]"))]

    # renderer names per render type from RenderBlocks.renderBlockByRenderType
    rb_src = open(os.path.join(args.src, "RenderBlocks.java"), encoding="utf-8").read()
    m = re.search(r"public boolean renderBlockByRenderType\(.*?\n\t}", rb_src, re.S)
    renderers = {int(a): b for a, b in re.findall(r"var5 == (\d+) \? this\.(\w+)\(", m.group(0))}
    renderers[0] = "renderStandardBlock"

    def overrides(cls, name, nargs):
        mm = vm.find_method(cls, name, nargs)
        return mm is not None and mm.cls.name != "Block", (mm.cls.name if mm else None)

    blocks = []
    tile_uses = {}

    def use_tile(t, b, face, via, meta=None):
        if not isinstance(t, int):
            return
        ent = {"id": b["id"], "block": b["name"], "face": face, "via": via}
        if meta is not None:
            ent["meta"] = meta
        tile_uses.setdefault(abs(t), []).append(ent)

    for bid in range(256):
        obj = blocks_list[bid]
        if obj is None:
            continue
        name = block_field.get(id(obj), "?")
        cls = obj.cls
        f = obj.f
        b = {
            "id": bid,
            "name": name,
            "name_snake": snake(name),
            "class": cls.name,
            "class_chain": [c.name for c in vm.chain(cls)],
            "obf_class": obf_class.get(cls.name),
            "obf_field": obf_field.get(("Block", name)),
        }
        mat = f["material"]
        b["material"] = mat_name.get(id(mat))
        mp = {}
        for meth, key in (("getIsLiquid", "liquid"), ("isSolid", "solid"), ("getCanBlockGrass", "can_block_grass"),
                          ("getCanBurn", "can_burn")):
            ok, v = attempt("material %s.%s" % (b["material"], meth), vm.call_method, mat, meth, [])
            mp[key] = v
        b["material_props"] = mp

        ok, rt = attempt("%s.getRenderType" % name, vm.call_method, obj, "getRenderType", [])
        b["render_type"] = rt
        b["renderer"] = renderers.get(rt, "none (TileEntity renderer)" if rt == -1 else None)
        ok, v = attempt("%s.renderAsNormalBlock" % name, vm.call_method, obj, "renderAsNormalBlock", [])
        b["render_as_normal_block"] = v
        ok, v = attempt("%s.getRenderBlockPass" % name, vm.call_method, obj, "getRenderBlockPass", [])
        b["render_pass"] = v
        ok, v = attempt("%s.isOpaqueCube" % name, vm.call_method, obj, "isOpaqueCube", [])
        b["is_opaque_cube"] = v
        b["opaque_cube_lookup"] = st["opaqueCubeLookup"][bid]
        b["light_value"] = st["lightValue"][bid]
        b["light_opacity"] = st["lightOpacity"][bid]
        b["can_block_grass"] = st["canBlockGrass"][bid]
        b["tick_on_load"] = st["tickOnLoad"][bid]
        b["hardness"] = f["hardness"]
        b["resistance"] = f["resistance"]
        ok, v = attempt("%s.getExplosionResistance" % name, vm.call_method, obj, "getExplosionResistance", [None])
        b["explosion_resistance"] = v
        b["slipperiness"] = f["slipperiness"]
        b["particle_gravity"] = f["blockParticleGravity"]
        b["bounds"] = [f["minX"], f["minY"], f["minZ"], f["maxX"], f["maxY"], f["maxZ"]]
        b["block_index_in_texture"] = f["blockIndexInTexture"]
        ss = f["stepSound"]
        snd = {"field": sound_name.get(id(ss)), "name": ss.f["stepSoundName"],
               "volume": ss.f["stepSoundVolume"], "pitch": ss.f["stepSoundPitch"]}
        for meth, key in (("getStepSound", "step"), ("getBreakSound", "break")):
            ok, v = attempt("%s.%s" % (name, meth), vm.call_method, ss, meth, [])
            snd[key] = v
        b["step_sound"] = snd
        ok, v = attempt("%s.tickRate" % name, vm.call_method, obj, "tickRate", [])
        b["tick_rate"] = v
        # fields of the concrete class chain below Block (flags such as isActive, blockType, modelBlock)
        extra = {}
        for c in vm.chain(cls):
            if c.name == "Block":
                break
            for fd in c.fields:
                v = f.get(fd.name)
                if isinstance(v, (bool, int, float, str)):
                    extra[fd.name] = v
                elif isinstance(v, JObject) and vm.is_subclass(v.cls, "Block"):
                    extra[fd.name] = {"block": block_field.get(id(v)), "id": v.f["blockID"]}
                elif isinstance(v, JObject) and v.cls.name.startswith("Material"):
                    extra[fd.name] = {"material": mat_name.get(id(v))}
        if extra:
            b["class_fields"] = extra

        # ---- textures: inventory / default (meta 0), meta-dependent, world-dependent
        by_side = []
        for s in range(6):
            ok, t = attempt("%s.getBlockTextureFromSideAndMetadata(%d,0)" % (name, s), vm.call_method, obj,
                            "getBlockTextureFromSideAndMetadata", [s, 0])
            by_side.append(t)
        b["tiles_by_side"] = by_side
        b["tiles"] = {SIDES[s][0]: by_side[s] for s in range(6)}
        for s in range(6):
            use_tile(by_side[s], b, SIDES[s][0], "side")
        metas = {}
        for meta in range(1, 16):
            row = []
            for s in range(6):
                try:
                    row.append(vm.call_method(obj, "getBlockTextureFromSideAndMetadata", [s, meta]))
                except (Unsupported, JavaThrow) as ex:
                    row.append("ERR " + str(ex))
            if row != by_side:
                metas[meta] = row
        if metas:
            b["tiles_by_meta"] = {str(k): v for k, v in metas.items()}
            for meta, row in metas.items():
                for s in range(6):
                    use_tile(row[s], b, SIDES[s][0], "meta", meta)
        ov, where = overrides(cls, "getBlockTexture", 5)
        if ov:
            def run_world(variant, cells):
                rows, used = {}, set()
                for meta in range(16):
                    w = MockWorld(vm, meta, obj, cells)
                    row = []
                    for s_ in range(6):
                        ok, t = attempt("%s.getBlockTexture(world=%s,meta=%d,side=%d)" % (name, variant, meta, s_),
                                        vm.call_method, obj, "getBlockTexture", [w, 0, 64, 0, s_])
                        row.append(t)
                    used |= w.used
                    rows[meta] = row
                return rows, used
            variants = [("air", {})]
            rows, used = run_world("air", {})
            if "getBlockMaterial" in used:
                variants.append(("snow_above", {(0, 65, 0): st["snow"]}))
            if "getBlockId" in used:
                for vn, pos in (("same_x_neg", (-1, 64, 0)), ("same_x_pos", (1, 64, 0)),
                                ("same_z_neg", (0, 64, -1)), ("same_z_pos", (0, 64, 1))):
                    variants.append((vn, {pos: obj}))
            wt = {"defined_in": where, "world_calls": sorted(used), "variants": {}}
            for vn, cells in variants:
                vrows, vused = (rows, used) if vn == "air" else run_world(vn, cells)
                wt["world_calls"] = sorted(set(wt["world_calls"]) | vused)
                base = vrows[0]
                wt["variants"][vn] = {"neighbours": {"%d,%d,%d" % k: block_field.get(id(v)) for k, v in cells.items()},
                                      "meta0": base,
                                      "by_meta": {str(k): v for k, v in vrows.items() if v != base}}
                all_metas = {}
                for k, row in vrows.items():
                    for s_ in range(6):
                        all_metas.setdefault((row[s_], s_), []).append(k)
                for (t, s_), ms in all_metas.items():
                    use_tile(t, b, SIDES[s_][0], "world:" + vn, None if len(ms) == 16 else min(ms))
            b["world_tiles"] = wt
        neg = [t for t in by_side + [x for r in metas.values() for x in r] if isinstance(t, int) and t < 0]
        if neg:
            b["negative_tiles_mean"] = "mirrored U (RenderBlocks: tex < 0 -> flip, index = -tex)"
        # item form
        it = vm.static("Item", "itemsList")[bid]
        if isinstance(it, JObject):
            b["item_icon"] = it.f["iconIndex"]
        # drops (only when it does not need Random)
        rnd = type("R", (), {"java_call": lambda self, n, a: (_ for _ in ()).throw(Unsupported("Random." + n))})()
        try:
            b["id_dropped"] = vm.call_method(obj, "idDropped", [0, rnd])
        except (Unsupported, JavaThrow) as ex:
            b["id_dropped"] = None
            b["id_dropped_note"] = "needs Random or world: " + str(ex)
        blocks.append(b)

    # ---- items
    items_list = vm.static("Item", "itemsList")
    item_field = {id(Item.statics[fd.name]): fd.name for fd in Item.sfields if isinstance(Item.statics[fd.name], JObject)}
    items = []
    block_objs = [o for o in blocks_list if o is not None]
    for idx, it in enumerate(items_list):
        if it is None:
            continue
        is_block = it.cls.name == "ItemBlock"
        if is_block:
            bobj = blocks_list[idx]
            name = block_field.get(id(bobj), "?")
        else:
            name = item_field.get(id(it), "?")
        e = {
            "id": it.f["shiftedIndex"],
            "index": it.f["shiftedIndex"] - 256,
            "name": name,
            "name_snake": snake(name),
            "class": it.cls.name,
            "obf_class": obf_class.get(it.cls.name),
            "obf_field": None if is_block else obf_field.get(("Item", name)),
            "block_item": is_block,
            "atlas": "terrain" if it.f["shiftedIndex"] < 256 else "items",
            "icon_index": it.f["iconIndex"],
            "max_stack": it.f["maxStackSize"],
            "max_damage": it.f["maxDamage"],
        }
        ok, v = attempt("%s.isFull3D" % name, vm.call_method, it, "isFull3D", [])
        e["full3d"] = v
        ok, v = attempt("%s.getDamageVsEntity" % name, vm.call_method, it, "getDamageVsEntity", [None])
        e["damage_vs_entity"] = v
        extra = {}
        for c in vm.chain(it.cls):
            if c.name == "Item":
                break
            for fd in c.fields:
                v = it.f.get(fd.name)
                if isinstance(v, (bool, int, float, str)):
                    extra[fd.name] = v
                elif isinstance(v, JObject) and v.cls.name.startswith("Material"):
                    extra[fd.name] = {"material": mat_name.get(id(v))}
                elif isinstance(v, list) and v and all(isinstance(x, JObject) for x in v):
                    extra[fd.name] = [x.f.get("blockID") for x in v]
        if extra:
            e["class_fields"] = extra
        if not is_block:
            strv, harvest = {}, []
            for bo in block_objs:
                bn = block_field.get(id(bo))
                ok, v = attempt("%s.getStrVsBlock(%s)" % (name, bn), vm.call_method, it, "getStrVsBlock", [None, bo])
                if ok and v != 1.0:
                    strv[str(bo.f["blockID"])] = v
                ok, v = attempt("%s.canHarvestBlock(%s)" % (name, bn), vm.call_method, it, "canHarvestBlock", [bo])
                if ok and v:
                    harvest.append(bo.f["blockID"])
            if strv:
                e["str_vs_block"] = strv
            if harvest:
                e["can_harvest"] = harvest
        items.append(e)

    # ---- tile names
    by_id = {b["id"]: b for b in blocks}
    tiles_out = {}
    for t in sorted(tile_uses):
        uses = tile_uses[t]
        # dedupe
        seen, uu = set(), []
        for u in uses:
            key = (u["id"], u["face"], u["via"], u.get("meta"))
            if key not in seen:
                seen.add(key)
                uu.append(u)
        uses = uu
        name = None
        # 1) a block drawing this tile on >= 5 of 6 faces at meta 0 (abs: negative = mirrored) names it
        for u in sorted(uses, key=lambda u: u["id"]):
            b = by_id[u["id"]]
            if u["via"] == "side" and sum(1 for x in b["tiles_by_side"] if isinstance(x, int) and abs(x) == t) >= 5:
                name = b["name_snake"]
                break
        if name is None:
            # 2) prefer meta-0 uses, then metadata variants, then world variants; lowest block id
            rank = {"side": 0, "meta": 1}
            pool = sorted(uses, key=lambda u: (rank.get(u["via"], 2), u.get("meta") or 0, u["id"]))
            first = pool[0]
            b = by_id[first["id"]]
            same = [u for u in uses if u["id"] == first["id"] and u["via"] == first["via"]
                    and u.get("meta") == first.get("meta")]
            faces = {u["face"] for u in same}
            horiz = {"east", "west", "north", "south"}
            if faces == {"top", "bottom"}:
                suf = "end"
            elif faces == {"top"}:
                suf = "top"
            elif faces == {"bottom"}:
                suf = "bottom"
            elif len(faces) == 1 and faces <= horiz:
                suf = "front"
            elif faces <= horiz:
                suf = "side"
            else:
                suf = ""
            parts = [b["name_snake"]] + ([suf] if suf else [])
            if first.get("meta") is not None:
                parts.append("m%d" % first["meta"])
            if first["via"].startswith("world:") and first["via"] != "world:air":
                parts.append(first["via"][6:])
            name = "_".join(parts)
        tiles_out[str(t)] = {"name": name, "uses": uses}
    # make names unique
    seen = {}
    for k, v in tiles_out.items():
        n = v["name"]
        if n in seen:
            v["name"] = "%s_t%s" % (n, k)
        seen[n] = k

    with open(os.path.join(args.out, "blocks.json"), "w") as fo:
        json.dump(blocks, fo, indent=1)
    with open(os.path.join(args.out, "items.json"), "w") as fo:
        json.dump(items, fo, indent=1)
    with open(os.path.join(args.out, "textures_by_block.json"), "w") as fo:
        json.dump(tiles_out, fo, indent=1)

    # ---- NOTES.md (generated part)
    lines = []
    lines.append("# AlphaMine tables: notes (generated by tools/alphamine/gen_tables.py)\n")
    lines.append("Source: `ref/minecraft/src/net/minecraft/src` (MCP-named RetroMCP decompilation of a1.0.16).")
    lines.append("Values are produced by executing the Java registrations with `tools/alphamine/minijava.py`,")
    lines.append("not by regex. Floats are the decimal literals (Java keeps float32: 0.6F = 0.6000000238).\n")
    lines.append(CONVENTIONS)
    lines.append("## Counts\n")
    lines.append("- blocks: %d (ids %s)" % (len(blocks), ", ".join(str(b["id"]) for b in blocks)))
    lines.append("- items: %d from Item.java + %d ItemBlock entries" % (
        sum(1 for i in items if not i["block_item"]), sum(1 for i in items if i["block_item"])))
    lines.append("- terrain tiles referenced by blocks: %d of 256" % len(tiles_out))
    lines.append("- Block fields declared but null in this version: %s" % ", ".join(
        f.name for f in Block.sfields if st[f.name] is None and not f.type.endswith("[]")))
    lines.append("")
    known = {1: "stone", 2: "grass", 3: "dirt", 4: "cobblestone", 5: "planks", 6: "sapling", 7: "bedrock",
             8: "waterMoving", 9: "waterStill", 10: "lavaMoving", 11: "lavaStill", 12: "sand", 13: "gravel",
             14: "oreGold", 15: "oreIron", 16: "oreCoal", 17: "wood", 18: "leaves", 19: "sponge", 20: "glass",
             35: "cloth", 37: "plantYellow", 38: "plantRed", 46: "tnt", 50: "torch", 51: "fire", 52: "mobSpawner",
             53: "stairCompactWood", 54: "chest", 58: "workbench", 61: "stoneOvenIdle", 62: "stoneOvenActive",
             64: "doorWood", 65: "ladder", 66: "minecartTrack", 78: "snow", 79: "ice", 80: "blockSnow",
             81: "cactus", 82: "blockClay", 83: "reed", 84: "jukebox"}
    bad = ["%d: expected %s, got %s" % (k, v, by_id[k]["name"] if k in by_id else None)
           for k, v in known.items() if k not in by_id or by_id[k]["name"] != v]
    lines.append("- cross-check with known Alpha ids: %d/%d match%s; id 85 (fence) %s" % (
        len(known) - len(bad), len(known), (" - MISMATCH " + "; ".join(bad)) if bad else "",
        "present" if 85 in by_id else "absent (added in a1.0.17)"))
    g = by_id[2]["world_tiles"]["variants"]["air"]["meta0"]
    lines.append("- tile cross-check: grass world top/bottom/side = %d/%d/%d (expected 0/2/3), stone %d (1), dirt %d (2)" % (
        g[1], g[0], g[2], by_id[1]["tiles_by_side"][0], by_id[3]["tiles_by_side"][0]))
    lines.append("")
    lines.append("## Unparsed / not statically derivable (%d)\n" % len(unparsed))
    if unparsed:
        for what, why in unparsed:
            lines.append("- `%s` - %s" % (what, why))
    else:
        lines.append("- none: every queried method executed.")
    lines.append("")
    lines.append("## Render types (RenderBlocks.renderBlockByRenderType)\n")
    for k in sorted(renderers):
        users = [b["name"] for b in blocks if b["render_type"] == k]
        lines.append("- %d `%s`: %s" % (k, renderers[k], ", ".join(users) or "-"))
    users = [b["name"] for b in blocks if b["render_type"] not in renderers]
    lines.append("- other (-1 = drawn by a TileEntitySpecialRenderer, not by RenderBlocks): %s" % ", ".join(users))
    lines.append("")
    lines.append("## Blocks whose opaque_cube_lookup differs from isOpaqueCube() now\n")
    for b in blocks:
        if b["opaque_cube_lookup"] != b["is_opaque_cube"]:
            lines.append("- %d %s: lookup %s, method %s (the Block constructor calls the virtual isOpaqueCube() before the subclass constructor sets its fields)" % (
                b["id"], b["name"], b["opaque_cube_lookup"], b["is_opaque_cube"]))
    lines.append("")
    lines.append("## World-dependent textures (getBlockTexture(IBlockAccess,...) overridden)\n")
    lines.append("Evaluated with a mock world: block at (0,64,0) with meta 0..15, neighbours air, plus variants")
    lines.append("(snow above if the code asks getBlockMaterial, same block on one side if it asks getBlockId).")
    lines.append("Combinations beyond those variants (e.g. chest front choice from opaque neighbours) are NOT enumerated.\n")
    for b in blocks:
        if "world_tiles" in b:
            wt = b["world_tiles"]
            lines.append("- %d %s (%s), calls %s:" % (b["id"], b["name"], wt["defined_in"], ", ".join(wt["world_calls"])))
            for vn, v in wt["variants"].items():
                lines.append("  - %s: meta0 %s%s" % (vn, v["meta0"], ("; " + ", ".join("m%s=%s" % kv for kv in v["by_meta"].items())) if v["by_meta"] else ""))
    lines.append("")
    with open(os.path.join(args.out, "NOTES.md"), "w") as fo:
        fo.write("\n".join(lines) + "\n")

    print("blocks: %d, items: %d (%d block items), tiles named: %d, unparsed: %d" % (
        len(blocks), len(items), sum(1 for i in items if i["block_item"]), len(tiles_out), len(unparsed)))
    for what, why in unparsed[:40]:
        print("  UNPARSED %s -> %s" % (what, why))
    return 0


if __name__ == "__main__":
    sys.exit(main())
