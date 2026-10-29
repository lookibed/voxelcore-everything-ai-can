#!/usr/bin/env python3
"""AlphaMine: the developer world `devworld` (agents/F2F.md 8, agents/ALPHAMINE.md 10) -- stdlib only.

Writes the Alpha 0.1.1 SMP save format directly (World.saveLevel / ChunkLoader.storeChunkInCompound):
  level.dat                         gzip NBT {"": {Data: {RandomSeed, SpawnX/Y/Z, Time, SizeOnDisk, SnowCovered, LastPlayed}}}
  <b36(x&63)>/<b36(z&63)>/c.<b36 x>.<b36 z>.dat   gzip NBT {"": {Level: {xPos, zPos, LastUpdate, Blocks, Data,
                                     SkyLight, BlockLight, HeightMap, TerrainPopulated, Entities, TileEntities}}}
  devworld_layout.json              exhibits (every cell, id, meta), groups and viewpoints (read by am_rows.py and the
                                     scenarios); the server ignores it.

World: flat, bedrock y=0, stone 1..63, grass y=64, the exhibit plaza (stone at y=64) with groups of exhibits standing
on y=65, stone viewing towers (stand on y=71). Chunks -12..14 x -12..14 are all saved and TerrainPopulated, so the
server never generates or populates anything (spawn preload is +-10 chunks around spawn (0,0); the viewpoints at x,z <=
59 need +-10 chunks around themselves -> up to chunk 13).

Light: HeightMap, SkyLight and BlockLight are computed here as the fixpoint of MetadataChunkBlock.updateLight
(L = max(source, max(6 neighbours) - max(1, opacity)); sky source = 15 where y >= HeightMap; block source = lightValue)
-- the server does NOT relight a chunk on load when SkyLight/BlockLight are present (ChunkLoader.loadChunkIntoWorld-
FromCompound: only a missing SkyLight triggers generateHeightMap, a missing BlockLight stays 0).

Server-side stability (random ticks, World.updateBlocksAndPlayCaveSounds): see agents/ALPHAMINE.md 10. Key points: level
Time = 13100 (night on the server: skylightSubtracted >= 7 for ~8 min of server time -> crops/saplings do not grow,
mushrooms stay; the SMP client never learns the time), SnowCovered = false, exhibits on a stone plaza (grass never next
to dirt), cactus/reeds 3 high (no growth), leaves next to logs with the settled leaf meta, redstone torch 75 kept off by
a torch 76 under its block, spawner EntityId "None" (spawns nothing), no fire, no glowing redstone ore (74 reverts).
Fluids are written as sources/flowing blocks and settled by the server once (`settle` below).

  gen_devworld.py gen [--out D:/Prog/AlphaMine/golden/devworld]       generate
  gen_devworld.py finalize --from /mnt/d/Prog/AlphaMine/run/world_d    copy a server-saved (settled) world back into
                                                                       golden/devworld, Time reset, layout kept
  gen_devworld.py diff A B                                             blocks/meta/light differences of two saves
  gen_devworld.py dump X Y Z [--world W]                               id/meta/sky/block around a cell
"""
import argparse
import gzip
import io
import json
import os
import shutil
import struct
import sys
import time

ALPHA = "/mnt/d/Prog/AlphaMine"
OUT = os.path.join(ALPHA, "golden", "devworld")
CMIN, CMAX = -12, 14            # saved chunk range (both axes, inclusive): spawn (0,0) +-10 blocks random, +-10 chunks sent
GROUND = 64                     # grass / plaza top block
Y0 = 65                         # exhibits stand here
TIME = 13100                    # server night (see docstring)
SEED = 20261001

# ---------------------------------------------------------------------------------------------------- NBT
END, BYTE, SHORT, INT, LONG, FLOAT, DOUBLE, BARR, STR, LIST, COMP = range(11)


class Tag:
    def __init__(self, t, v, et=None):
        self.t, self.v, self.et = t, v, et


def _wstr(o, s):
    b = s.encode("utf-8")
    o.write(struct.pack(">H", len(b)))
    o.write(b)


def _wpay(o, tag):
    t, v = tag.t, tag.v
    if t == BYTE:
        o.write(struct.pack(">b", v))
    elif t == SHORT:
        o.write(struct.pack(">h", v))
    elif t == INT:
        o.write(struct.pack(">i", v))
    elif t == LONG:
        o.write(struct.pack(">q", v))
    elif t == FLOAT:
        o.write(struct.pack(">f", v))
    elif t == DOUBLE:
        o.write(struct.pack(">d", v))
    elif t == BARR:
        o.write(struct.pack(">i", len(v)))
        o.write(bytes(v))
    elif t == STR:
        _wstr(o, v)
    elif t == LIST:
        et = tag.et if tag.et is not None else (v[0].t if v else BYTE)   # NBTTagList: empty list -> type 1
        o.write(struct.pack(">bi", et, len(v)))
        for x in v:
            _wpay(o, x)
    elif t == COMP:
        for k, x in v.items():
            o.write(struct.pack(">b", x.t))
            _wstr(o, k)
            _wpay(o, x)
        o.write(b"\0")


def nbt_bytes(root):
    """CompressedStreamTools.writeCompressed: gzip(DataOutput(named root compound ""))."""
    o = io.BytesIO()
    o.write(struct.pack(">b", COMP))
    _wstr(o, "")
    _wpay(o, root if isinstance(root, Tag) else Tag(COMP, root))
    b = io.BytesIO()
    with gzip.GzipFile(fileobj=b, mode="wb", mtime=0) as g:
        g.write(o.getvalue())
    return b.getvalue()


def _rstr(d, p):
    n = struct.unpack_from(">H", d, p)[0]
    return d[p + 2:p + 2 + n].decode("utf-8"), p + 2 + n


def _rpay(d, p, t):
    if t == BYTE:
        return struct.unpack_from(">b", d, p)[0], p + 1
    if t == SHORT:
        return struct.unpack_from(">h", d, p)[0], p + 2
    if t == INT:
        return struct.unpack_from(">i", d, p)[0], p + 4
    if t == LONG:
        return struct.unpack_from(">q", d, p)[0], p + 8
    if t == FLOAT:
        return struct.unpack_from(">f", d, p)[0], p + 4
    if t == DOUBLE:
        return struct.unpack_from(">d", d, p)[0], p + 8
    if t == BARR:
        n = struct.unpack_from(">i", d, p)[0]
        return bytearray(d[p + 4:p + 4 + n]), p + 4 + n
    if t == STR:
        return _rstr(d, p)
    if t == LIST:
        et, n = struct.unpack_from(">bi", d, p)
        p += 5
        out = []
        for _ in range(n):
            x, p = _rpay(d, p, et)
            out.append(x)
        return out, p
    if t == COMP:
        out = {}
        while True:
            tt = d[p]
            p += 1
            if tt == END:
                return out, p
            k, p = _rstr(d, p)
            out[k], p = _rpay(d, p, tt)
    raise ValueError("NBT type %d" % t)


def nbt_read(path):
    """-> plain python value of the root compound."""
    d = gzip.open(path).read()
    assert d[0] == COMP
    _, p = _rstr(d, 1)
    v, _ = _rpay(d, p, COMP)
    return v


def b36(n):
    """Integer.toString(n, 36)."""
    if n == 0:
        return "0"
    s, neg, n = "", n < 0, abs(n)
    while n:
        n, r = divmod(n, 36)
        s = "0123456789abcdefghijklmnopqrstuvwxyz"[r] + s
    return "-" + s if neg else s


def chunk_path(root, cx, cz):
    return os.path.join(root, b36(cx & 63), b36(cz & 63), "c.%s.%s.dat" % (b36(cx), b36(cz)))


# ---------------------------------------------------------------------------------------------------- tables
def load_tables():
    with open(os.path.join(ALPHA, "tables", "blocks.json"), encoding="utf-8") as f:
        blocks = json.load(f)
    op = [0] * 256
    lv = [0] * 256
    names = {}
    for b in blocks:
        op[b["id"]] = b["light_opacity"]
        lv[b["id"]] = b["light_value"]
        names[b["id"]] = b["name"]
    return op, lv, names


# ---------------------------------------------------------------------------------------------------- layout
class World:
    def __init__(self):
        self.cells = {}      # (x,y,z) -> (id, meta)
        self.te = {}         # (x,y,z) -> {tag dict}
        self.exhibits = []
        self.cur = None

    def base(self, x, y, z):
        if y == 0:
            return 7
        if y < GROUND:
            return 1
        if y == GROUND:
            return 2
        return 0

    def get(self, x, y, z):
        return self.cells.get((x, y, z), (self.base(x, y, z), 0))

    def set(self, x, y, z, i, m=0, ex=True):
        self.cells[(x, y, z)] = (i, m)
        if ex and self.cur is not None:
            self.cur["cells"].append([x, y, z, i, m])

    def exhibit(self, name, group, **kw):
        self.cur = {"name": name, "group": group, "cells": []}
        self.cur.update(kw)
        self.exhibits.append(self.cur)
        return self.cur


def sign_te(x, y, z, lines):
    v = {"id": Tag(STR, "Sign"), "x": Tag(INT, x), "y": Tag(INT, y), "z": Tag(INT, z)}
    for i in range(4):
        v["Text%d" % (i + 1)] = Tag(STR, (lines[i] if i < len(lines) else "")[:15])
    return v


def container_te(kind, x, y, z, extra=None):
    v = {"id": Tag(STR, kind), "x": Tag(INT, x), "y": Tag(INT, y), "z": Tag(INT, z), "Items": Tag(LIST, [], COMP)}
    v.update(extra or {})
    return v


def build(w):
    """Exhibit groups (all cells listed in the layout). Plaza: stone at y=64 over x 12..68, z 12..58 (grass kept
    only where an exhibit needs it). Groups: G1 cubes (x 16.., z 18..26), G2 shapes (x 16.., z 40..52), G3 fluids
    (x 44.., z 16..30), G4 plants (x 44.., z 40..52). Towers at x 27/55, z 11/33/59 (top block y=70)."""
    for x in range(12, 69):
        for z in range(12, 59):
            w.set(x, GROUND, z, 1, 0, ex=False)
    Y = Y0

    # ---------------- G1: full cubes and meta variants of cube blocks (one per cell, 1 air between)
    rows = [
        # grass last: the Java client makes its own TileEntityMobSpawner (mob "Pig") for block 52 and spawns
        # client-side pigs on grass within +-4 of it -> no grass near the spawner (20, 65, 22)
        (18, [(1, 0, "stone"), (4, 0, "cobblestone"), (3, 0, "dirt"), (5, 0, "planks"),
              (7, 0, "bedrock"), (12, 0, "sand"), (13, 0, "gravel"), (14, 0, "oreGold"), (15, 0, "oreIron"),
              (16, 0, "oreCoal"), (2, 0, "grass")]),
        (20, [(17, 0, "wood"), (19, 0, "sponge"), (20, 0, "glass"), (35, 0, "cloth"), (41, 0, "blockGold"),
              (42, 0, "blockSteel"), (43, 0, "stairDouble"), (44, 0, "stairSingle"), (45, 0, "brick"),
              (46, 0, "tnt"), (47, 0, "bookshelf")]),
        (22, [(48, 0, "cobblestoneMossy"), (49, 0, "obsidian"), (52, 0, "mobSpawner"), (56, 0, "oreDiamond"),
              (57, 0, "blockDiamond"), (58, 0, "workbench"), (73, 0, "oreRedstone"), (82, 0, "blockClay"),
              (84, 0, "jukebox"), (80, 0, "blockSnow"), (79, 0, "ice")]),
        (24, [(61, 2, "stoneOvenIdle m2"), (61, 3, "stoneOvenIdle m3"), (61, 4, "stoneOvenIdle m4"),
              (61, 5, "stoneOvenIdle m5"), (62, 2, "stoneOvenActive m2"), (62, 3, "stoneOvenActive m3"),
              (62, 4, "stoneOvenActive m4"), (62, 5, "stoneOvenActive m5"), (54, 0, "chest")]),
    ]
    for z, items in rows:
        for k, (i, m, name) in enumerate(items):
            x = 16 + 2 * k
            w.exhibit(name, "G1", id=i, meta=m)
            w.set(x, Y, z, i, m)
            if i == 52:
                w.te[(x, Y, z)] = {"id": Tag(STR, "MobSpawner"), "x": Tag(INT, x), "y": Tag(INT, Y), "z": Tag(INT, z),
                                   "EntityId": Tag(STR, "None"), "Delay": Tag(SHORT, 20)}
            if i in (61, 62):
                w.te[(x, Y, z)] = container_te("Furnace", x, Y, z, {"BurnTime": Tag(SHORT, 0), "CookTime": Tag(SHORT, 0)})
            if i == 54:
                w.te[(x, Y, z)] = container_te("Chest", x, Y, z)
    # double chest (x 34..35, z 24), log + leaves pair, tree, slabs stacked
    w.exhibit("chest double", "G1", id=54)
    for x in (34, 35):
        w.set(x, Y, 24, 54)
        w.te[(x, Y, 24)] = container_te("Chest", x, Y, 24)
    w.exhibit("wood+leaves", "G1", id=18)
    w.set(38, Y, 24, 17)
    w.set(39, Y, 24, 18, 15)
    w.exhibit("tree", "G1", id=18)
    for y in range(Y, Y + 4):
        w.set(18, y, 26, 17)
    leaves = []
    for dx in (-1, 0, 1):
        for dz in (-1, 0, 1):
            for y in (Y + 2, Y + 3, Y + 4):
                if (dx, dz) == (0, 0) and y < Y + 4:
                    continue
                leaves.append((18 + dx, y, 26 + dz))
    for (x, y, z) in leaves:
        w.set(x, y, z, 18, 0)
    w.exhibit("slab on slab", "G1", id=44)
    w.set(22, Y, 26, 44)
    w.set(22, Y + 1, 26, 44)
    w.exhibit("glass pane row", "G1", id=20)
    for x in (25, 26, 27):
        w.set(x, Y, 26, 20)
    w.exhibit("snow layer", "G1", id=78)
    w.set(34, Y, 26, 78)
    w.exhibit("snow layer on grass", "G1", id=78)
    w.set(36, GROUND, 26, 2, 0)
    w.set(36, Y, 26, 78)

    # ---------------- G2: render shapes (z 40..52)
    # torches: pillar with 4 wall torches + standing torch; the same with redstone torches
    def pillar_with(px, pz, tid, name, top=None):
        w.exhibit(name + " pillar", "G2", id=4)
        w.set(px, Y, pz, 4)
        for m, (dx, dz) in ((1, (1, 0)), (2, (-1, 0)), (3, (0, 1)), (4, (0, -1))):
            w.exhibit("%s m%d" % (name, m), "G2", id=tid, meta=m)
            w.set(px + dx, Y, pz + dz, tid, m)
        if top:
            w.exhibit("%s m5 on pillar" % name, "G2", id=top, meta=5)
            w.set(px, Y + 1, pz, top, 5)

    w.exhibit("torch m5", "G2", id=50, meta=5)
    w.set(16, Y, 40, 50, 5)
    pillar_with(20, 40, 50, "torch")
    w.exhibit("torchRedstoneActive m5", "G2", id=76, meta=5)
    w.set(24, Y, 40, 76, 5)
    pillar_with(28, 40, 76, "torchRedstoneActive")
    # idle redstone torch 75: kept off by an active torch under its block (BlockRedstoneTorch.isIndirectlyPowered)
    w.exhibit("torchRedstoneIdle m5 (NOT gate)", "G2", id=75, meta=5)
    w.set(32, Y, 40, 76, 5)
    w.set(32, Y + 1, 40, 4)
    w.set(32, Y + 2, 40, 75, 5)
    # ladders on a pillar (meta 2: block at z+1, 3: z-1, 4: x+1, 5: x-1), 2 high
    w.exhibit("ladder pillar", "G2", id=4)
    for y in (Y, Y + 1):
        w.set(36, y, 40, 4)
    for m, (dx, dz) in ((2, (0, -1)), (3, (0, 1)), (4, (-1, 0)), (5, (1, 0))):
        w.exhibit("ladder m%d" % m, "G2", id=65, meta=m)
        for y in (Y, Y + 1):
            w.set(36 + dx, y, 40 + dz, 65, m)
    # stairs wood/stone meta 0..3 (z 43)
    for k, m in enumerate(range(4)):
        w.exhibit("stairCompactWood m%d" % m, "G2", id=53, meta=m)
        w.set(16 + 2 * k, Y, 43, 53, m)
        w.exhibit("stairCompactStone m%d" % m, "G2", id=67, meta=m)
        w.set(26 + 2 * k, Y, 43, 67, m)
    # doors (z 46): wood meta 0..3 closed, 0..3 open (+4); steel 0..3 closed; 2 high, top half meta|8
    k = 0
    for i, ms in ((64, [0, 1, 2, 3, 4, 5, 6, 7]), (71, [0, 1, 2, 3])):
        for m in ms:
            x = 16 + 2 * k
            w.exhibit("%s m%d" % ("doorWood" if i == 64 else "doorSteel", m), "G2", id=i, meta=m)
            w.set(x, Y, 46, i, m)
            w.set(x, Y + 1, 46, i, m | 8)
            k += 1
    # rails meta 0..9 (z 49); ascending ones get a step block on the high side
    for m in range(10):
        x = 16 + 2 * m
        w.exhibit("minecartTrack m%d" % m, "G2", id=66, meta=m)
        w.set(x, Y, 49, 66, m)
    # levers (walls 1..4 on a pillar, floor 5/6, on = |8), buttons (walls 1..4), pressure plates, signs (z 52)
    w.exhibit("lever pillar", "G2", id=4)
    w.set(38, Y, 43, 4)
    for m, (dx, dz) in ((1, (1, 0)), (2, (-1, 0)), (3, (0, 1)), (4, (0, -1))):
        w.exhibit("lever m%d" % m, "G2", id=69, meta=m)
        w.set(38 + dx, Y, 43 + dz, 69, m)
    for k, m in enumerate((5, 6, 5 | 8, 6 | 8)):
        w.exhibit("lever m%d" % m, "G2", id=69, meta=m)
        w.set(36 + 2 * k, Y, 49, 69, m)
    w.exhibit("button pillar", "G2", id=4)
    w.set(16, Y, 52, 4)
    for m, (dx, dz) in ((1, (1, 0)), (2, (-1, 0)), (3, (0, 1)), (4, (0, -1))):
        w.exhibit("button m%d" % m, "G2", id=77, meta=m)
        w.set(16 + dx, Y, 52 + dz, 77, m)
    w.exhibit("pressurePlateStone", "G2", id=70)
    w.set(20, Y, 52, 70)
    w.exhibit("pressurePlateWood", "G2", id=72)
    w.set(22, Y, 52, 72)
    for k, m in enumerate((0, 4, 8, 12)):
        x = 24 + 2 * k
        w.exhibit("signStanding m%d" % m, "G2", id=63, meta=m)
        w.set(x, Y, 52, 63, m)
        w.te[(x, Y, 52)] = sign_te(x, Y, 52, ["devworld", "sign", "m%d" % m])
    w.exhibit("signWall pillar", "G2", id=4)
    w.set(34, Y, 52, 4)
    for m, (dx, dz) in ((2, (0, -1)), (3, (0, 1)), (4, (-1, 0)), (5, (1, 0))):
        x, z = 34 + dx, 52 + dz
        w.exhibit("signWall m%d" % m, "G2", id=68, meta=m)
        w.set(x, Y, z, 68, m)
        w.te[(x, Y, z)] = sign_te(x, Y, z, ["wall", "m%d" % m])
    # redstone wire: a dot, a line with power 15..8, a cross (static: the wire only recomputes on neighbour change)
    w.exhibit("redstoneWire dot", "G2", id=55)
    w.set(38, Y, 52, 55, 0)
    w.exhibit("redstoneWire line", "G2", id=55)
    for k in range(4):
        w.set(40 + k, Y, 52, 55, 15 - 2 * k)
    w.exhibit("redstoneWire cross", "G2", id=55)
    for dx, dz in ((0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)):
        w.set(41 + dx, Y, 46 + dz, 55, 0)

    # ---------------- G3: fluids (x 44.., z 16..30)
    # still pools 3x3 (surface at y=64, floor y=63)
    w.exhibit("waterStill pool", "G3", id=9)
    for dx in range(3):
        for dz in range(3):
            w.set(45 + dx, GROUND, 17 + dz, 9, 0)
    w.exhibit("lavaStill pool", "G3", id=11)
    for dx in range(3):
        for dz in range(3):
            w.set(51 + dx, GROUND, 17 + dz, 11, 0)
    # level channels: source at the west end, the server spreads 1..7 (water) / 2,4,6 (lava) east
    w.exhibit("water channel (levels 0..7)", "G3", id=8)
    w.set(45, GROUND, 23, 8, 0)
    for x in range(46, 53):
        w.set(x, GROUND, 23, 0, 0)
    w.exhibit("lava channel (levels 0,2,4,6)", "G3", id=10)
    w.set(56, GROUND, 23, 10, 0)
    for x in range(57, 60):
        w.set(x, GROUND, 23, 0, 0)
    # water staircase: steps at x 45 (top y=66), 46 (y=65), 47 (y=64 plaza) then a trench (floor y=63) to x 53,
    # walls z 26/28 up to y=67, back wall x 44; source on the top step
    w.exhibit("water staircase", "G3", id=8)
    for x in range(44, 55):
        for z in (26, 28):
            for y in range(Y, Y + 3):
                w.set(x, y, z, 1)
    for y in range(Y, Y + 3):
        w.set(44, y, 27, 1)
    w.set(45, Y, 27, 1)
    w.set(45, Y + 1, 27, 1)
    w.set(46, Y, 27, 1)
    for x in range(48, 54):
        w.set(x, GROUND, 27, 0)
    w.set(45, Y + 2, 27, 8, 0)
    # ice next to water (translucent pass), away from lava/torches (ice melts at block light > 8)
    w.exhibit("ice on water", "G3", id=79)
    w.set(45, GROUND, 30, 79)
    w.set(46, GROUND, 30, 9, 0)
    w.set(47, GROUND, 30, 79)

    # ---------------- G4: plants (x 44.., z 40..52)
    # crops 0..7 on wet farmland (water in the middle of the row), crops 0/7 on dry farmland far from water
    w.exhibit("water for farmland", "G4", id=9)
    w.set(48, GROUND, 40, 9, 0)
    for m, x in zip(range(8), (44, 45, 46, 47, 49, 50, 51, 52)):    # all within 4 of the water (isWaterNearby)
        w.exhibit("crops m%d on wet farmland" % m, "G4", id=59, meta=m)
        w.set(x, GROUND, 40, 60, 7)
        w.set(x, Y, 40, 59, m)
    for k, m in enumerate((0, 7)):                                  # > 4 from any water: dry, kept by the crop
        x = 58 + 2 * k
        w.exhibit("crops m%d on dry farmland" % m, "G4", id=59, meta=m)
        w.set(x, GROUND, 40, 60, 0)
        w.set(x, Y, 40, 59, m)
    # saplings, flowers on grass; mushrooms on stone (need light <= 13: server night)
    for k, (i, name) in enumerate(((6, "sapling"), (37, "plantYellow"), (38, "plantRed"))):
        x = 44 + 2 * k
        w.exhibit(name, "G4", id=i)
        w.set(x, GROUND, 44, 2, 0)
        w.set(x, Y, 44, i, 0)
    for k, (i, name) in enumerate(((39, "mushroomBrown"), (40, "mushroomRed"))):
        x = 50 + 2 * k
        w.exhibit(name, "G4", id=i)
        w.set(x, Y, 44, i, 0)
    # cactus 3 high on sand, reeds 3 high on dirt next to water
    w.exhibit("cactus", "G4", id=81)
    w.set(56, GROUND, 44, 12)
    for y in range(Y, Y + 3):
        w.set(56, y, 44, 81, 0)
    w.exhibit("reed", "G4", id=83)
    w.set(64, GROUND, 48, 3)
    w.set(65, GROUND, 48, 9, 0)
    for y in range(Y, Y + 3):
        w.set(64, y, 48, 83, 0)
    # a single grass block with a flower on top and farmland dry without crops is NOT stable -> not placed

    # ---------------- item pit for layer_entities_dev (1x1 hole: items from /give cannot roll away)
    w.exhibit("item pit", "misc", id=0)
    w.set(27, GROUND, 8, 0)

    # ---------------- towers (stand on y=71, eyes 72.62)
    for tx in (27, 55):
        for tz in (11, 33, 59):
            w.exhibit("tower %d,%d" % (tx, tz), "tower", id=1)
            w.set(tx, GROUND, tz, 1)     # not grass: grass under an opaque block turns to dirt at night
            for y in range(Y, Y + 6):
                w.set(tx, y, tz, 1)

    # leaves meta as BlockLeaves.updateCurrentLeaves would settle it (strength from wood 16, -1 per leaf step)
    settle_leaves(w)


def settle_leaves(w):
    leaves = [p for p, (i, m) in w.cells.items() if i == 18]
    solid = {1, 2, 3, 4, 5, 7, 12, 13, 14, 15, 16, 17, 19, 20, 35, 41, 42, 43, 45, 46, 47, 48, 49, 54, 56, 57, 58,
             60, 61, 62, 73, 79, 80, 82, 84, 18}
    meta = {p: 0 for p in leaves}
    for _ in range(20):
        changed = False
        for (x, y, z) in leaves:
            s = 16 if w.get(x, y - 1, z)[0] in solid else 0
            for q in ((x, y - 1, z), (x, y, z - 1), (x, y, z + 1), (x - 1, y, z), (x + 1, y, z)):
                i = w.get(*q)[0]
                if i == 17:
                    s = max(s, 16)
                elif i == 18 and meta.get(q, 0) > s:
                    s = meta[q]
            v = s - 1
            if v < 10:
                v = 1
            if v != meta[(x, y, z)]:
                meta[(x, y, z)] = v
                changed = True
        if not changed:
            break
    for p, v in meta.items():
        if v < 10:
            raise SystemExit("leaves at %s would decay (strength %d)" % (p, v))
        w.cells[p] = (18, v)
    for ex in w.exhibits:
        for c in ex["cells"]:
            if c[3] == 18:
                c[4] = meta[tuple(c[:3])]


# ---------------------------------------------------------------------------------------------------- light
def compute_light(w, op, lv):
    """Fixpoint of MetadataChunkBlock.updateLight in a box around all non-flat cells (margin 16); outside it the
    world is flat: heightmap 65, sky 15 at y >= 65, else 0; block light 0."""
    xs = [p[0] for p in w.cells]
    zs = [p[2] for p in w.cells]
    x0, x1 = min(xs) - 16, max(xs) + 16
    z0, z1 = min(zs) - 16, max(zs) + 16
    ys = [p[1] for p in w.cells]
    y0, y1 = max(1, min(ys) - 16), 127
    NX, NY, NZ = x1 - x0 + 1, y1 - y0 + 1, z1 - z0 + 1

    def idx(x, y, z):
        return ((x - x0) * NZ + (z - z0)) * NY + (y - y0)

    ids = bytearray(NX * NY * NZ)
    for x in range(x0, x1 + 1):
        for z in range(z0, z1 + 1):
            b = ((x - x0) * NZ + (z - z0)) * NY
            for y in range(y0, min(GROUND + 1, y1 + 1)):
                ids[b + y - y0] = 1 if y < GROUND else 2
    for (x, y, z), (i, m) in w.cells.items():
        ids[idx(x, y, z)] = i
    # heightmap: lowest y with opacity 0 all the way up
    height = {}
    for x in range(x0, x1 + 1):
        for z in range(z0, z1 + 1):
            b = ((x - x0) * NZ + (z - z0)) * NY
            h = 128
            while h > 0:
                y = h - 1
                i = ids[b + y - y0] if y >= y0 else 1
                if op[i] != 0:
                    break
                h -= 1
            height[(x, z)] = h

    def solve(kind):
        L = bytearray(NX * NY * NZ)
        buckets = [[] for _ in range(16)]
        for x in range(x0, x1 + 1):
            for z in range(z0, z1 + 1):
                b = ((x - x0) * NZ + (z - z0)) * NY
                for y in range(y0, y1 + 1):
                    i = ids[b + y - y0]
                    s = (15 if y >= height[(x, z)] else 0) if kind == "sky" else lv[i]
                    if s:
                        L[b + y - y0] = s
                        buckets[s].append((x, y, z))
        # boundary cells outside the box act as fixed flat sources (sky 15 at y >= 65): the box margin makes the
        # interior near the border flat too, so they add nothing new -- ignored.
        for lvl in range(15, 0, -1):
            q = buckets[lvl]
            while q:
                x, y, z = q.pop()
                if L[idx(x, y, z)] != lvl:
                    continue
                for nx, ny, nz in ((x - 1, y, z), (x + 1, y, z), (x, y - 1, z), (x, y + 1, z), (x, y, z - 1), (x, y, z + 1)):
                    if not (x0 <= nx <= x1 and y0 <= ny <= y1 and z0 <= nz <= z1):
                        continue
                    j = idx(nx, ny, nz)
                    o = op[ids[j]]
                    if o >= 15:
                        continue
                    c = lvl - max(1, o)
                    if c > L[j]:
                        L[j] = c
                        buckets[c].append((nx, ny, nz))
        return L

    sky = solve("sky")
    blk = solve("block")
    return {"box": (x0, x1, y0, y1, z0, z1), "idx": idx, "sky": sky, "blk": blk, "height": height}


# ---------------------------------------------------------------------------------------------------- write
def write_world(w, out, op, lv):
    t0 = time.time()
    light = compute_light(w, op, lv)
    x0, x1, y0, y1, z0, z1 = light["box"]
    idx = light["idx"]
    by_chunk = {}
    for (x, y, z), v in w.cells.items():
        by_chunk.setdefault((x >> 4, z >> 4), []).append((x, y, z, v))
    if os.path.isdir(out):
        for n in os.listdir(out):
            p = os.path.join(out, n)
            shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
    os.makedirs(out, exist_ok=True)
    # flat template
    blocks = bytearray(32768)
    sky = bytearray(16384)
    for x in range(16):
        for z in range(16):
            b = x << 11 | z << 7
            blocks[b] = 7
            for y in range(1, GROUND):
                blocks[b + y] = 1
            blocks[b + GROUND] = 2
            for y in range(GROUND + 1, 128):
                i = b + y
                sky[i >> 1] |= 15 << (4 * (i & 1))
    hm = bytes([GROUND + 1]) * 256
    n = 0
    for cx in range(CMIN, CMAX + 1):
        for cz in range(CMIN, CMAX + 1):
            B = bytearray(blocks)
            D = bytearray(16384)
            S = bytearray(sky)
            L = bytearray(16384)
            H = bytearray(hm)
            tes = []

            def nib(arr, i, v):
                arr[i >> 1] = (arr[i >> 1] & (0xF0 if i & 1 == 0 else 0x0F)) | (v << (4 * (i & 1)))

            for (x, y, z, (i, m)) in by_chunk.get((cx, cz), []):
                k = (x & 15) << 11 | (z & 15) << 7 | y
                B[k] = i
                nib(D, k, m & 15)
            # light: every cell of this chunk inside the light box
            bx0, bx1 = max(cx * 16, x0), min(cx * 16 + 15, x1)
            bz0, bz1 = max(cz * 16, z0), min(cz * 16 + 15, z1)
            if bx0 <= bx1 and bz0 <= bz1:
                for x in range(bx0, bx1 + 1):
                    for z in range(bz0, bz1 + 1):
                        H[(z & 15) << 4 | (x & 15)] = light["height"][(x, z)]
                        for y in range(y0, y1 + 1):
                            k = (x & 15) << 11 | (z & 15) << 7 | y
                            j = idx(x, y, z)
                            nib(S, k, light["sky"][j])
                            nib(L, k, light["blk"][j])
            for (x, y, z), te in w.te.items():
                if (x >> 4, z >> 4) == (cx, cz):
                    tes.append(Tag(COMP, te))
            level = {"xPos": Tag(INT, cx), "zPos": Tag(INT, cz), "LastUpdate": Tag(LONG, TIME),
                     "Blocks": Tag(BARR, B), "Data": Tag(BARR, D), "SkyLight": Tag(BARR, S),
                     "BlockLight": Tag(BARR, L), "HeightMap": Tag(BARR, H), "TerrainPopulated": Tag(BYTE, 1),
                     "Entities": Tag(LIST, [], COMP), "TileEntities": Tag(LIST, tes, COMP)}
            p = chunk_path(out, cx, cz)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "wb") as f:
                f.write(nbt_bytes({"Level": Tag(COMP, level)}))
            n += 1
    write_level(out)
    print("devworld: %d chunks, %d cells, %d tile entities, light box %s -> %s (%.1f s)"
          % (n, len(w.cells), len(w.te), light["box"], out, time.time() - t0))


def write_level(out, t=TIME):
    data = {"RandomSeed": Tag(LONG, SEED), "SpawnX": Tag(INT, 0), "SpawnY": Tag(INT, GROUND), "SpawnZ": Tag(INT, 0),
            "Time": Tag(LONG, t), "SizeOnDisk": Tag(LONG, 0), "SnowCovered": Tag(BYTE, 0),
            "LastPlayed": Tag(LONG, 1790000000000)}
    with open(os.path.join(out, "level.dat"), "wb") as f:
        f.write(nbt_bytes({"Data": Tag(COMP, data)}))


# ---------------------------------------------------------------------------------------------------- layout json
VIEWPOINTS = [
    # name, tower (stand pos = tower top + 1), yaw, pitch, groups seen
    ("g1_n", (27.5, 71, 11.5), 0, 45, ["G1"]),
    ("g1_s", (27.5, 71, 33.5), 180, 45, ["G1"]),
    ("g2_n", (27.5, 71, 33.5), 0, 45, ["G2"]),
    ("g2_s", (27.5, 71, 59.5), 180, 45, ["G2"]),
    ("g3_n", (55.5, 71, 11.5), 0, 45, ["G3"]),
    ("g3_s", (55.5, 71, 33.5), 180, 45, ["G3"]),
    ("g4_n", (55.5, 71, 33.5), 0, 45, ["G4"]),
    ("g4_s", (55.5, 71, 59.5), 180, 45, ["G4"]),
]


def write_layout(w, out):
    ex = []
    for e in w.exhibits:
        ex.append(e)
    lay = {"generator": "tools/alphamine/gen_devworld.py", "ground": GROUND, "y0": Y0, "time": TIME,
           "chunks": [CMIN, CMAX], "spawn": [0, GROUND, 0],
           "viewpoints": [{"name": n, "pos": list(p), "yaw": yw, "pitch": pt, "groups": g}
                          for n, p, yw, pt, g in VIEWPOINTS],
           "exhibits": ex}
    with open(os.path.join(out, "devworld_layout.json"), "w", encoding="utf-8") as f:
        json.dump(lay, f, ensure_ascii=False, indent=0)


# ---------------------------------------------------------------------------------------------------- scenarios
SCEN_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scenarios", "alpha")
MODE = {"cmd": "mode", "args": {"fixed": True, "seed": 20260930, "clear_chat": True}}
LAYERS = {
    "layer_terrain_flat_dev": ({"terrain": True, "lighting": False, "fog": False}, "terrain без света и тумана"),
    "layer_terrain_lit_dev": ({"terrain": True, "lighting": True, "fog": False}, "terrain со светом, без тумана"),
    "layer_water_dev": ({"water": True, "lighting": True, "fog": False}, "второй проход (вода, лёд) со светом"),
}


def tp_steps(name, pos, yaw, pitch):
    x, y, z = pos
    return [
        {"cmd": "chat", "args": {"text": "/tp %s %s %s" % (x, y, z)}},
        {"cmd": "wait", "args": {"near": [x, y + 1.62, z, 1.5], "max_frames": 600}},
        {"cmd": "wait", "args": {"on_ground": True, "still": 20, "net_idle": 40, "max_frames": 2400},
         "expect": {"near": [x, y + 1.62, z, 0.01], "health": 20}},
        {"cmd": "look", "args": {"yaw": yaw, "pitch": pitch}},
        {"cmd": "step", "args": {"ticks": 2, "frames": 1}},
    ]


def vp_shots(vps, render=None):
    out = []
    for i, (n, pos, yaw, pitch, _) in enumerate(vps):
        out += tp_steps(n, pos, yaw, pitch)
        out.append(dict(MODE))
        if render and i == 0:
            out.append({"cmd": "render", "args": render})
        out.append({"cmd": "step", "args": {"ticks": 20, "frames": 1}, "expect": {"yaw": yaw, "pitch": pitch}})
        out.append({"cmd": "shot", "name": n})
    return out


def write_scenarios():
    vp_desc = "; ".join("%s: /tp %s %s %s, yaw %s pitch %s (%s)" % (n, p[0], p[1], p[2], yw, pt, ",".join(g))
                        for n, p, yw, pt, g in VIEWPOINTS)
    base = {
        "name": "dev_base",
        "description": "Общая подготовка слоёв мира разработчика (agents/ALPHAMINE.md §10): сервер с копией golden/devworld "
                       "(плоский мир, все блоки альфы рядами, генерирует tools/alphamine/gen_devworld.py), connect, 441 чанк "
                       "спавна (0,0), mode. Тела сценариев *_dev ставят игрока на башни (/tp) и снимают по видовым точкам: " + vp_desc,
        "setup": {"server": {"world": "devworld"}, "client": {"size": "854x480"}},
        "steps": [
            {"cmd": "connect"},
            {"cmd": "wait", "args": {"world": True, "max_frames": 1200}, "expect": {"screen": "ingame"}},
            {"cmd": "wait", "args": {"chunks": 441, "net_idle": 40, "max_frames": 3000}, "expect": {"health": 20}},
            dict(MODE),
            {"cmd": "state", "args": {"radius": 2}},
        ],
    }
    files = {"dev_base": base}
    for name, (layers, what) in LAYERS.items():
        render = {"all": False, "layers": layers, "clear": [0, 0, 0]}
        files[name] = {"name": name, "base": "dev_base", "base_until": "mode", "clear": [0, 0, 0],
                       "description": "Мир разработчика (dev_base): %s; %d видовых точек (башни над группами G1 кубы, G2 формы, "
                                      "G3 жидкости, G4 растения; с севера yaw 0 и с юга yaw 180, pitch 45), по снимку на точку. "
                                      "Разбор остатка по экспонатам — tools/alphamine/am_rows.py." % (what, len(VIEWPOINTS)),
                       "steps": vp_shots(VIEWPOINTS, render)}
    files["dev_full"] = {"name": "dev_full", "base": "dev_base", "base_until": "mode", "clear": [0, 0, 0],
                         "description": "Мир разработчика (dev_base): полный кадр (render all:true — небо, облака, terrain, вода, "
                                        "сущности, рука, HUD) с каждой видовой точки.",
                         "steps": vp_shots(VIEWPOINTS, {"all": True})}
    # entities: items from /give (op command -> dropPlayerItem) collected in a 1x1 pit (27,64,8) so the server's random
    # throw cannot scatter them, then thrown with Q (client motion from Entity.rand -> deterministic after mode)
    ent = [{"cmd": "chat", "args": {"text": "/tp 27.5 64 8.5"}},
           {"cmd": "wait", "args": {"near": [27.5, 65.62, 8.5, 1.5], "max_frames": 600}},
           {"cmd": "wait", "args": {"on_ground": True, "still": 20, "net_idle": 40, "max_frames": 2400},
            "expect": {"near": [27.5, 65.62, 8.5, 0.01]}},
           # dropPlayerItem throws along the view: looking straight down the item falls at the feet (pit 1x1)
           {"cmd": "look", "args": {"yaw": 0, "pitch": 90}},
           {"cmd": "step", "args": {"ticks": 2, "frames": 1}},
           {"cmd": "wait", "args": {"chat": "^never$", "max_frames": 20}, "optional": True,
            "comment": "1 с настенного времени: сервер получил взгляд вниз до первого /give"}]
    for item in (4, 50, 264, 257):
        ent += [{"cmd": "chat", "args": {"text": "/give Player %d 1" % item}},
                {"cmd": "wait", "args": {"chat": "^never$", "max_frames": 80}, "optional": True,
                 "comment": "4 с настенного времени: предмет выпал в яму и подобран (delayBeforeCanPickup 40); "
                            "net_idle тут не ждёт — он уже выполнен"}]
    ent += [{"cmd": "state", "args": {"radius": 0}},
            {"cmd": "chat", "args": {"text": "/tp 40.5 65 4.5"}},
            {"cmd": "wait", "args": {"near": [40.5, 66.62, 4.5, 1.5], "max_frames": 600}},
            {"cmd": "wait", "args": {"on_ground": True, "still": 20, "net_idle": 40, "max_frames": 2400},
             "expect": {"near": [40.5, 66.62, 4.5, 0.01]}},
            {"cmd": "look", "args": {"yaw": 0, "pitch": 0}},
            {"cmd": "step", "args": {"ticks": 1, "frames": 1}},
            dict(MODE)]
    # slots: 0 flint&steel, 1 logs, 2 dirt, 3.. given items (LWJGL key code = slot + 2). The look is applied in the
    # frame of the next step, after its tick -> one step before the key press, otherwise the throw uses the old yaw.
    for slot, turn in ((1, 0), (3, 15), (4, 30), (5, 345), (6, 330)):
        ent += [{"cmd": "look", "args": {"yaw": turn, "pitch": 0}},
                {"cmd": "step", "args": {"ticks": 1, "frames": 1}},
                {"cmd": "input", "args": {"keys": {str(slot + 2): True}}},
                {"cmd": "step", "args": {"ticks": 1, "frames": 1}},
                {"cmd": "input", "args": {"keys": {str(slot + 2): False, "Q": True}}},
                {"cmd": "step", "args": {"ticks": 1, "frames": 1}},
                {"cmd": "input", "args": {"keys": {"Q": False}}},
                {"cmd": "step", "args": {"ticks": 5, "frames": 1}}]
    ent += [{"cmd": "wait", "args": {"net_idle": 60, "max_frames": 600}},
            {"cmd": "input", "args": {"keys": {"2": True}}},
            {"cmd": "step", "args": {"ticks": 1, "frames": 1}},
            {"cmd": "input", "args": {"keys": {"2": False}}},
            {"cmd": "chat", "args": {"text": "/tp 40.5 65 3.5"}},
            {"cmd": "wait", "args": {"near": [40.5, 66.62, 3.5, 1.5], "max_frames": 600}},
            {"cmd": "wait", "args": {"on_ground": True, "still": 20, "net_idle": 40, "max_frames": 2400}},
            {"cmd": "look", "args": {"yaw": 0, "pitch": 30}},
            {"cmd": "step", "args": {"ticks": 2, "frames": 1}},
            dict(MODE),
            {"cmd": "render", "args": {"all": False, "layers": {"entities": True, "lighting": True, "fog": False},
                                       "clear": [0, 0, 0]}},
            {"cmd": "step", "args": {"ticks": 20, "frames": 1}, "expect": {"yaw": 0, "pitch": 30, "entities": 6}},
            {"cmd": "shot", "name": "items_near"},
            {"cmd": "render", "args": {"all": False, "layers": {"entities": True, "terrain": True, "lighting": True,
                                                                "fog": False}, "clear": [0, 0, 0]}},
            {"cmd": "step", "args": {"ticks": 1, "frames": 1}},
            {"cmd": "shot", "name": "items_terrain"},
            {"cmd": "state", "args": {"radius": 0}}]
    files["layer_entities_dev"] = {"name": "layer_entities_dev", "base": "dev_base", "base_until": "mode", "clear": [0, 0, 0],
                                   "description": "Мир разработчика: /give Player 4, 50, 264, 257 (яма 1x1 в (27,64,8): подбор без разлёта), "
                                                  "выброс Q пяти стаков веером (yaw 0/15/30/345/330) из (40.5, 65, 4.5), снимки с (40.5, 65, 3.5) "
                                                  "pitch 30: только entities со светом и entities+terrain.",
                                   "steps": ent}
    files["dev_settle"] = {"name": "dev_settle",
                           "description": "Служебный (не golden): оседание жидкостей мира разработчика сервером. Игрок стоит на башне "
                                          "G3 (55.5 71 11.5) 150 с (случайные такты запускают течение источников), затем ждёт 30 с "
                                          "без пакетов блоков и выполняет /stop (оператор: сервер сохраняет всё). Потом "
                                          "gen_devworld.py finalize.",
                           "setup": {"server": {"world": "devworld"}, "client": {"size": "854x480"}},
                           "steps": base["steps"][:3] + tp_steps("g3_n", (55.5, 71, 11.5), 0, 45)[:3] + [
                               {"cmd": "wait", "args": {"chat": "^never$", "max_frames": 3000}, "optional": True},
                               {"cmd": "wait", "args": {"net_idle": 600, "max_frames": 6000}},
                               {"cmd": "state", "args": {"radius": 2}},
                               {"cmd": "chat", "args": {"text": "/stop"}},
                               {"cmd": "wait", "args": {"chat": "^never$", "max_frames": 100}, "optional": True}]}
    for n, d in files.items():
        with open(os.path.join(SCEN_DIR, n + ".json"), "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False, indent=1)
    print("scenarios: %s" % ", ".join(sorted(files)))


# ---------------------------------------------------------------------------------------------------- read / diff
def read_chunk(root, cx, cz):
    p = chunk_path(root, cx, cz)
    if not os.path.exists(p):
        return None
    return nbt_read(p)["Level"]


def nib_get(arr, i):
    return (arr[i >> 1] >> (4 * (i & 1))) & 15


def cell(root, x, y, z, cache=None):
    key = (x >> 4, z >> 4)
    lvl = cache.get(key) if cache is not None and key in cache else read_chunk(root, *key)
    if cache is not None:
        cache[key] = lvl
    if lvl is None:
        return None
    k = (x & 15) << 11 | (z & 15) << 7 | y
    return lvl["Blocks"][k], nib_get(lvl["Data"], k), nib_get(lvl["SkyLight"], k), nib_get(lvl["BlockLight"], k)


def diff(a, b, names, limit=60):
    rows = []
    for cx in range(CMIN, CMAX + 1):
        for cz in range(CMIN, CMAX + 1):
            A, B = read_chunk(a, cx, cz), read_chunk(b, cx, cz)
            if A is None or B is None:
                if (A is None) != (B is None):
                    rows.append(("chunk", cx, cz, "missing in " + ("A" if A is None else "B")))
                continue
            for key in ("Blocks", "Data", "SkyLight", "BlockLight", "HeightMap"):
                if A[key] == B[key]:
                    continue
                if key == "HeightMap":
                    rows.append((key, cx, cz, "differs"))
                    continue
                n = len(A[key]) if key == "Blocks" else 32768
                for k in range(n):
                    va = A[key][k] if key == "Blocks" else nib_get(A[key], k)
                    vb = B[key][k] if key == "Blocks" else nib_get(B[key], k)
                    if va != vb:
                        x, z, y = cx * 16 + (k >> 11), cz * 16 + (k >> 7 & 15), k & 127
                        ia, ib = A["Blocks"][k], B["Blocks"][k]
                        rows.append((key, x, y, z, "%s -> %s" % (va, vb), names.get(ia, ia), names.get(ib, ib)))
            ta = sorted(json.dumps(t, sort_keys=True, default=str) for t in A.get("TileEntities", []))
            tb = sorted(json.dumps(t, sort_keys=True, default=str) for t in B.get("TileEntities", []))
            if ta != tb:
                rows.append(("TileEntities", cx, cz, len(ta), len(tb)))
    for r in rows[:limit]:
        print(*r)
    by = {}
    for r in rows:
        by[r[0]] = by.get(r[0], 0) + 1
    print("differences: %s" % (by or "none"))
    return rows


def check_light(root, op, lv):
    """Recompute HeightMap/SkyLight/BlockLight with compute_light() from the blocks of a save and compare with the
    stored light (validates the solver against the server's own relight after the settle session)."""
    w = World()
    cache = {}
    for cx in range(-1, 6):
        for cz in range(-1, 6):
            lvl = read_chunk(root, cx, cz)
            cache[(cx, cz)] = lvl
            B, D = lvl["Blocks"], lvl["Data"]
            for k in range(32768):
                x, z, y = cx * 16 + (k >> 11), cz * 16 + (k >> 7 & 15), k & 127
                i = B[k]
                if i != w.base(x, y, z):
                    w.cells[(x, y, z)] = (i, nib_get(D, k))
    light = compute_light(w, op, lv)
    x0, x1, y0, y1, z0, z1 = light["box"]
    bad = {"sky": 0, "blk": 0, "height": 0}
    ex = []
    for x in range(x0, x1 + 1):
        for z in range(z0, z1 + 1):
            lvl = cache.get((x >> 4, z >> 4)) or read_chunk(root, x >> 4, z >> 4)
            cache[(x >> 4, z >> 4)] = lvl
            if lvl["HeightMap"][(z & 15) << 4 | (x & 15)] != light["height"][(x, z)]:
                bad["height"] += 1
            for y in range(y0, y1 + 1):
                k = (x & 15) << 11 | (z & 15) << 7 | y
                j = light["idx"](x, y, z)
                for key, arr in (("sky", "SkyLight"), ("blk", "BlockLight")):
                    a, b = nib_get(lvl[arr], k), light[key][j]
                    if a != b:
                        bad[key] += 1
                        if len(ex) < 25:
                            ex.append((key, x, y, z, "saved %d computed %d" % (a, b), lvl["Blocks"][k]))
    for e in ex:
        print(*e)
    print("light check %s: box %s, mismatches %s" % (root, light["box"], bad))


def finalize(src, out):
    """Copy a server-saved world (after the settle session and /stop) back into golden/devworld: chunk files and
    level.dat with Time reset (server night again at the start of every run); the layout file is kept."""
    keep = os.path.join(out, "devworld_layout.json")
    lay = open(keep, encoding="utf-8").read() if os.path.exists(keep) else None
    for n in os.listdir(out):
        p = os.path.join(out, n)
        shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
    for n in os.listdir(src):
        p = os.path.join(src, n)
        if os.path.isdir(p):
            shutil.copytree(p, os.path.join(out, n))
    write_level(out)
    if lay:
        with open(keep, "w", encoding="utf-8") as f:
            f.write(lay)
    print("finalized %s -> %s (Time %d)" % (src, out, TIME))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["gen", "finalize", "diff", "dump", "layout", "scenarios", "checklight"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--from", dest="src", default=os.path.join(ALPHA, "run", "world_d"))
    ap.add_argument("--world", default=OUT)
    o = ap.parse_args()
    op, lv, names = load_tables()
    if o.action in ("gen", "layout"):
        w = World()
        build(w)
        if o.action == "gen":
            write_world(w, o.out, op, lv)
        else:
            os.makedirs(o.out, exist_ok=True)
        write_layout(w, o.out)
        print("layout: %d exhibits, %d viewpoints" % (len(w.exhibits), len(VIEWPOINTS)))
    elif o.action == "scenarios":
        write_scenarios()
    elif o.action == "checklight":
        check_light(o.args[0] if o.args else o.world, op, lv)
    elif o.action == "finalize":
        finalize(o.src, o.out)
    elif o.action == "diff":
        diff(o.args[0], o.args[1], names)
    elif o.action == "dump":
        x, y, z = map(int, o.args[:3])
        cache = {}
        for dy in range(-1, 3):
            print("y=%d" % (y + dy), " ".join("%s" % (cell(o.world, x + dx, y + dy, z, cache),) for dx in range(-2, 3)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
