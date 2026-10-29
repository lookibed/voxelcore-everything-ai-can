#!/usr/bin/env python3
"""AlphaMine phase 2: blocks of the pack `alphamine` from the Alpha 1.0.16 tables.

Input  (<repo>\\projects\\alphamine\\external): tables/blocks.json, tables/textures_by_block.json, assets/tiles/terrain/<t>.png
Output (REPO/content/alphamine):
  blocks/<name_snake>.json      one VoxelCore block per Alpha block id, id `alphamine:<name_snake>`
  textures/blocks/am_<tile>.png  terrain.png tiles under their table names (+ `_flip` for negative tiles), prefix am_
  modules/blocks_table.lua      alpha id -> name, collision box, meta variants (read by modules/blocks.lua)
  modules/items_table.lua       item id -> name, max stack, max damage (inventory of the F2F state)
  blocks/TODO.md                what is only a placeholder (render types that VoxelCore cannot draw 1:1 yet)

Alpha meta -> VoxelCore state: meta is stored in userbits (bits 8..11 of the u16 state, i.e. the high byte of
the state), for EVERY block. Blocks whose textures depend on meta get `state-based` variants (offset 0, 4 bits),
so the variant index equals the meta. The mapping back (engine block -> alpha id + meta) is exact.

Texture faces: VoxelCore `texture-faces` order is taken from BlocksRenderer.cpp (face(..., texfaces[i]) with
normals: 0 = -X, 1 = +X, 2 = -Y, 3 = +Y, 4 = -Z, 5 = +Z). Alpha side index (RenderBlocks): 0 -Y, 1 +Y, 2 -Z,
3 +Z, 4 -X, 5 +X. So vc[i] = alpha[FACE_ORDER[i]] with FACE_ORDER = [4, 5, 0, 1, 2, 3] -- checked by running the
engine (tools/scenarios/alpha_probes/p8_faces.lua, agents/ALPHAMINE.md phase 2).

Usage: gen_pack_blocks.py [--alpha <repo>/projects/alphamine/external] [--out REPO/content/alphamine]
                          [--engine-light on|off] [--blocks-only]
--engine-light off (DEFAULT since 01.10, clean lab measurement agents/ALPHAMINE.md 9.2): every block `light-passing` and
`sky-light-passing`, no `emission` -> the engine's own light is 15 everywhere and trivial to build on every
world.set_chunk_data. The pack renders with the server's light (modules/lightmap.lua region); the engine light is
only the shader fallback before the first lightmap upload. --blocks-only writes blocks/*.json only (a variant pack
dir, tools/alphamine/perf/make_variant.py) and leaves textures/models/tables alone.
Going back to the engine's own light (opaque blocks, emission): `gen_pack_blocks.py --blocks-only --engine-light on`
(reproduces the pre-01.10 blocks/*.json byte for byte; no parity layer depends on it, agents/ALPHAMINE.md 9.2).
"""
import argparse
import json
import math
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))  # корень репозитория (было: рабочий каталог движка)
ALPHA = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "external"))  # было внешний каталог AlphaMine
FACE_ORDER = [4, 5, 0, 1, 2, 3]  # VoxelCore face i <- Alpha side FACE_ORDER[i]
TEX_PREFIX = "am_"               # texture names in the shared "blocks" atlas

# classes whose getCollisionBoundingBoxFromPool returns null (no collision in Alpha)
NO_COLLISION = {"BlockButton", "BlockFire", "BlockFlower", "BlockFluid", "BlockLever", "BlockMinecartTrack",
                "BlockPressurePlate", "BlockRedstoneWire", "BlockReed", "BlockSign", "BlockSnow", "BlockTorch"}

TODO = []  # (id, name, what)
ENGINE_LIGHT_OFF = True   # --engine-light off (default); --engine-light on = the engine's own light

# Alpha light for the pack shaders (phase 3, modules/lightmap.lua): a region of the "blocks" atlas that Lua
# rewrites through assets.to_canvas("blocks:am_lightmap"). 21x21 chunk slots of 64x64 texels (8 cells per
# texel, 4 bits = max(sky, block) per cell, cell index x<<11|z<<7|y), the same slots again (to the right) with fluid codes,
# a header row (chunk coords per slot) and a marker row. The tallest texture of the atlas -> LMPacker (sorted by height) puts it at (0,0)+extrusion,
# i.e. at atlas texel (2,2); shaders/main.glslf checks the marker before trusting that.
LIGHTMAP = "am_lightmap"

# Block models (models/amblk_*.vcm; not am_*: tools/alphamine/gen_models.py deletes am_*.vcm). Model space is
# the block cell [0,1]^3; uv (0..1 of the tile) with v = 1 at the image top (atlas rows are bottom-up). The
# 15.99/16 texel inset of RenderBlocks is applied by shaders/main.glslf, so the tiles are mapped whole here.
MODEL_CROSS = "amblk_cross"


def vcm_quad(verts, uvs, texture="$0"):
    """Tessellator quad (GL_QUADS, vertices in Alpha order) -> two @tri (0,1,2), (0,2,3): same winding."""
    out = []
    for a, b, c in ((0, 1, 2), (0, 2, 3)):
        pts = " ".join("%s (%s)" % (k, ",".join(repr(round(v, 9)) for v in verts[i])) for k, i in zip("abc", (a, b, c)))
        uv = ",".join(repr(round(x, 9)) for i in (a, b, c) for x in uvs[i])
        out.append('@tri %s uv (%s) texture "%s"' % (pts, uv, texture))
    return out


def model_cross():
    """RenderBlocks.renderCrossedSquares: two diagonal planes inset by 0.45F from the centre, each drawn in both
    windings; u0/u1 = image left/right, v0 = image top (y + 1), v1 = bottom (y + 0)."""
    import numpy as np
    k = float(np.float32(0.45))
    d, e = 0.5 - k, 0.5 + k
    T, B = 1.0, 0.0   # uv v of the image top / bottom
    lines = ["# GENERATED by tools/alphamine/gen_pack_blocks.py: Alpha RenderBlocks.renderCrossedSquares"]
    for (x0, z0), (x1, z1) in (((d, d), (e, e)), ((d, e), (e, d))):
        lines += vcm_quad([(x0, 1, z0), (x0, 0, z0), (x1, 0, z1), (x1, 1, z1)],
                          [(0, T), (0, B), (1, B), (1, T)])
        lines += vcm_quad([(x1, 1, z1), (x1, 0, z1), (x0, 0, z0), (x0, 1, z0)],
                          [(0, T), (0, B), (1, B), (1, T)])
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------------------------------- render types
# Alpha RenderBlocks geometry as VCM triangles (devworld, agents/ALPHAMINE.md 10). Coordinates: block cell [0,1]^3;
# UVs are given in Alpha tile texels (u right, v down from the tile top, 0..16; the 15.99 / -0.01 insets are left to
# shaders/main.glslf) and converted to VCM (v = 1 at the image top). Vertex order = Tessellator order (the winding
# gives the outward normal, cross(b - a, c - a)). Texture slots "$i" = the variant's texture-faces in VoxelCore order
# [-X, +X, -Y, +Y, -Z, +Z] = Alpha sides [4, 5, 0, 1, 2, 3].
F32 = lambda v: float(__import__("numpy").float32(v))
SLOT = {0: "$2", 1: "$3", 2: "$4", 3: "$5", 4: "$0", 5: "$1"}
MODELS = {}      # model name -> VCM text (written by write_models)


def q(verts, uvs_px, tex="$0"):
    return vcm_quad(verts, [(u / 16.0, 1.0 - v / 16.0) for u, v in uvs_px], tex)


def std_face(side, box, tex, flip=False):
    """RenderBlocks.render{Bottom,Top,East,West,North,South}Face for block bounds `box` (Alpha side index)."""
    x0, y0, z0, x1, y1, z1 = box
    if side == 0:
        return q([(x0, y0, z1), (x0, y0, z0), (x1, y0, z0), (x1, y0, z1)],
                 [(x0 * 16, z1 * 16), (x0 * 16, z0 * 16), (x1 * 16, z0 * 16), (x1 * 16, z1 * 16)], tex)
    if side == 1:
        return q([(x1, y1, z1), (x1, y1, z0), (x0, y1, z0), (x0, y1, z1)],
                 [(x1 * 16, z1 * 16), (x1 * 16, z0 * 16), (x0 * 16, z0 * 16), (x0 * 16, z1 * 16)], tex)
    va, vb = y0 * 16, y1 * 16                      # v at the face top = minY * 16 (Alpha quirk kept)
    if side in (2, 3):
        ua, ub = x0 * 16, x1 * 16
    else:
        ua, ub = z0 * 16, z1 * 16
    if flip:
        ua, ub = ub, ua
    if side == 2:
        return q([(x0, y1, z0), (x1, y1, z0), (x1, y0, z0), (x0, y0, z0)], [(ub, va), (ua, va), (ua, vb), (ub, vb)], tex)
    if side == 3:
        return q([(x0, y1, z1), (x0, y0, z1), (x1, y0, z1), (x1, y1, z1)], [(ua, va), (ua, vb), (ub, vb), (ub, va)], tex)
    if side == 4:
        return q([(x0, y1, z1), (x0, y1, z0), (x0, y0, z0), (x0, y0, z1)], [(ub, va), (ua, va), (ua, vb), (ub, vb)], tex)
    return q([(x1, y0, z1), (x1, y0, z0), (x1, y1, z0), (x1, y1, z1)], [(ua, vb), (ub, vb), (ub, va), (ua, va)], tex)


def box_faces(box, slots=None, flips=None):
    lines = []
    for side in range(6):
        lines += std_face(side, box, (slots or SLOT)[side], bool(flips and flips[side]))
    return lines


def torch_lines(meta):
    """RenderBlocks.renderBlockTorch -> renderTorchAtAngle (meta 1..4 on walls, else standing)."""
    k8, k12 = F32(0.4), F32(0.2)
    k10 = 0.5 - k8
    bx, by, bz, a, b = 0.0, 0.0, 0.0, 0.0, 0.0
    if meta == 1:
        bx, by, a = -k10, k12, -k8
    elif meta == 2:
        bx, by, a = k10, k12, k8
    elif meta == 3:
        bz, by, b = -k10, k12, -k8
    elif meta == 4:
        bz, by, b = k10, k12, k8
    X, Z = bx + 0.5, bz + 0.5
    x0, x1, z0, z1 = X - 0.5, X + 0.5, Z - 0.5, Z + 0.5
    d, h = 1.0 / 16.0, 0.625
    tx, tz, ty = X + a * (1 - h), Z + b * (1 - h), by + h
    L = q([(tx - d, ty, tz - d), (tx - d, ty, tz + d), (tx + d, ty, tz + d), (tx + d, ty, tz - d)],
          [(7, 6), (7, 8), (9, 8), (9, 6)])
    T, B = by + 1.0, by
    full = [(0, 0), (0, 16), (16, 16), (16, 0)]
    L += q([(X - d, T, z0), (X - d + a, B, z0 + b), (X - d + a, B, z1 + b), (X - d, T, z1)], full)
    L += q([(X + d, T, z1), (X + d + a, B, z1 + b), (X + d + a, B, z0 + b), (X + d, T, z0)], full)
    L += q([(x0, T, Z + d), (x0 + a, B, Z + d + b), (x1 + a, B, Z + d + b), (x1, T, Z + d)], full)
    L += q([(x1, T, Z - d), (x1 + a, B, Z - d + b), (x0 + a, B, Z - d + b), (x0, T, Z - d)], full)
    return L


def ladder_lines(meta):
    e = F32(0.05)
    if meta == 5:
        return q([(e, 1, 1), (e, 0, 1), (e, 0, 0), (e, 1, 0)], [(0, 0), (0, 16), (16, 16), (16, 0)])
    if meta == 4:
        return q([(1 - e, 0, 1), (1 - e, 1, 1), (1 - e, 1, 0), (1 - e, 0, 0)], [(16, 16), (16, 0), (0, 0), (0, 16)])
    if meta == 3:
        return q([(1, 0, e), (1, 1, e), (0, 1, e), (0, 0, e)], [(16, 16), (16, 0), (0, 0), (0, 16)])
    if meta == 2:
        return q([(1, 1, 1 - e), (1, 0, 1 - e), (0, 0, 1 - e), (0, 1, 1 - e)], [(0, 0), (0, 16), (16, 16), (16, 0)])
    return []


def rails_lines(meta):
    """RenderBlocks.renderBlockMinecartTrack: one quad at y = 1/16 (both windings), corners by meta, slopes 2..5."""
    c = [(1, 0), (1, 1), (0, 1), (0, 0)]                           # default (meta 0, 4, 5, 6)
    if meta in (1, 2, 3, 7):
        c = [(1, 1), (0, 1), (0, 0), (1, 0)]
    elif meta == 8:
        c = [(0, 1), (0, 0), (1, 0), (1, 1)]
    elif meta == 9:
        c = [(0, 0), (1, 0), (1, 1), (0, 1)]
    y = [1.0 / 16.0] * 4
    if meta in (2, 4):
        y[0] += 1
        y[3] += 1
    elif meta in (3, 5):
        y[1] += 1
        y[2] += 1
    v = [(c[i][0], y[i], c[i][1]) for i in range(4)]
    uv = [(16, 0), (16, 16), (0, 16), (0, 0)]
    return q(v, uv) + q(v[::-1], uv[::-1])


def stairs_lines(meta):
    boxes = {0: [(0, 0, 0, .5, .5, 1), (.5, 0, 0, 1, 1, 1)], 1: [(0, 0, 0, .5, 1, 1), (.5, 0, 0, 1, .5, 1)],
             2: [(0, 0, 0, 1, .5, .5), (0, 0, .5, 1, 1, 1)], 3: [(0, 0, 0, 1, 1, .5), (0, 0, .5, 1, .5, 1)]}[meta & 3]
    return [l for bx in boxes for l in box_faces(bx)]


def cactus_lines():
    """renderBlockCactusImpl: full top/bottom, side faces translated 1/16 inwards (full UVs)."""
    e = 1.0 / 16.0
    slots = dict(SLOT)
    L = std_face(0, (0, 0, 0, 1, 1, 1), slots[0]) + std_face(1, (0, 0, 0, 1, 1, 1), slots[1])
    L += std_face(2, (0, 0, e, 1, 1, 1), slots[2]) + std_face(3, (0, 0, 0, 1, 1, 1 - e), slots[3])
    L += std_face(4, (e, 0, 0, 1, 1, 1), slots[4]) + std_face(5, (0, 0, 0, 1 - e, 1, 1), slots[5])
    return L


def crops_lines():
    """renderBlockCropsImpl at y - 1/16: planes x = 0.25 / 0.75 and z = 0.25 / 0.75, both windings."""
    y0, y1 = -1.0 / 16.0, 1 - 1.0 / 16.0
    uv = [(0, 0), (0, 16), (16, 16), (16, 0)]
    L = []
    for x in (0.25, 0.75):
        L += q([(x, y1, 0), (x, y0, 0), (x, y0, 1), (x, y1, 1)], uv) + q([(x, y1, 1), (x, y0, 1), (x, y0, 0), (x, y1, 0)], uv)
    for z in (0.25, 0.75):
        L += q([(0, y1, z), (0, y0, z), (1, y0, z), (1, y1, z)], uv) + q([(1, y1, z), (1, y0, z), (0, y0, z), (0, y1, z)], uv)
    return L


def door_box(meta):
    s = (meta - 1) & 3 if (meta & 4) == 0 else meta & 3          # BlockDoor.getState
    t = 3.0 / 16.0
    return {0: (0, 0, 0, 1, 1, t), 1: (1 - t, 0, 0, 1, 1, 1), 2: (0, 0, 1 - t, 1, 1, 1), 3: (0, 0, 0, t, 1, 1)}[s]


def button_box(meta):
    a, b, c = 6.0 / 16.0, 10.0 / 16.0, 3.0 / 16.0
    d = 1.0 / 16.0 if meta & 8 else 2.0 / 16.0
    m = meta & 7
    return {1: (0, a, .5 - c, d, b, .5 + c), 2: (1 - d, a, .5 - c, 1, b, .5 + c),
            3: (.5 - c, a, 0, .5 + c, b, d), 4: (.5 - c, a, 1 - d, .5 + c, b, 1)}.get(m, (.3125, .375, .875, .6875, .625, 1.0))


def _mh_sin(f, cos=False):
    """MathHelper.sin/cos: 65536-entry float table."""
    import numpy as np
    i = int(np.float32(np.float32(f) * np.float32(10430.378)) + (np.float32(16384.0) if cos else 0)) & 65535
    return float(np.float32(math.sin(i * math.pi * 2.0 / 65536.0)))


def lever_lines(meta, base_tex):
    """RenderBlocks.renderBlockLever: cobblestone base box by meta (renderStandardBlock with the texture override) +
    the handle: 8 corners rotated with Vec3D.rotateAroundX/Y (MathHelper tables), UV u 7..9, v 6..8 / 6..16."""
    import numpy as np
    m, on = meta & 7, bool(meta & 8)
    if m not in (1, 2, 3, 4, 5, 6):
        m = 5
    a, b, c = 0.25, 3.0 / 16.0, 3.0 / 16.0
    box = {5: (.5 - b, 0, .5 - a, .5 + b, c, .5 + a), 6: (.5 - a, 0, .5 - b, .5 + a, c, .5 + b),
           4: (.5 - b, .5 - a, 1 - c, .5 + b, .5 + a, 1), 3: (.5 - b, .5 - a, 0, .5 + b, .5 + a, c),
           2: (1 - c, .5 - a, .5 - b, 1, .5 + a, .5 + b), 1: (0, .5 - a, .5 - b, c, .5 + a, .5 + b)}[m]
    box = tuple(float(np.float32(v)) for v in box)
    L = box_faces(box, {k: base_tex for k in range(6)})
    d, h = 1.0 / 16.0, float(np.float32(10.0 / 16.0))
    P = [[-d, 0.0, -d], [d, 0.0, -d], [d, 0.0, d], [-d, 0.0, d], [-d, h, -d], [d, h, -d], [d, h, d], [-d, h, d]]

    def rx(p, f):
        cs, sn = _mh_sin(f, True), _mh_sin(f)
        return [p[0], p[1] * cs + p[2] * sn, p[2] * cs - p[1] * sn]

    def ry(p, f):
        cs, sn = _mh_sin(f, True), _mh_sin(f)
        return [p[0] * cs + p[2] * sn, p[1], p[2] * cs - p[0] * sn]

    PI = float(np.float32(math.pi))
    for i, p in enumerate(P):
        if on:
            p[2] -= 1.0 / 16.0
            p = rx(p, float(np.float32(PI * 2.0 / 9.0)))
        else:
            p[2] += 1.0 / 16.0
            p = rx(p, -float(np.float32(PI * 2.0 / 9.0)))
        if m == 6:
            p = ry(p, float(np.float32(PI * 0.5)))
        if m < 5:
            p[1] -= 0.375
            p = rx(p, float(np.float32(PI * 0.5)))
            p = ry(p, {4: 0.0, 3: PI, 2: float(np.float32(PI * 0.5)), 1: float(np.float32(PI * -0.5))}[m])
            p = [p[0] + 0.5, p[1] + 0.5, p[2] + 0.5]
        else:
            p = [p[0] + 0.5, p[1] + float(np.float32(2.0 / 16.0)), p[2] + 0.5]
        P[i] = p
    quads = [(0, 1, 2, 3), (7, 6, 5, 4), (1, 0, 4, 5), (2, 1, 5, 6), (3, 2, 6, 7), (0, 3, 7, 4)]
    for k, qd in enumerate(quads):
        v1 = 8 if k < 2 else 16
        L += q([tuple(P[i]) for i in qd], [(7, v1), (9, v1), (9, 6), (7, 6)])
    return L


def write_models(out):
    d = os.path.join(out, "models")
    os.makedirs(d, exist_ok=True)
    for fn in os.listdir(d):
        if fn.startswith("amblk_") and fn.endswith(".vcm"):
            os.remove(os.path.join(d, fn))
    models = {MODEL_CROSS: model_cross()}
    models.update(MODELS)
    for name, text in models.items():
        with open(os.path.join(d, name + ".vcm"), "w", encoding="utf-8") as f:
            f.write(text)
    return len(models)
LIGHTMAP_W, LIGHTMAP_H = 2 * 21 * 64, 21 * 64 + 2   # height <= ~1465: LMPacker int score h*h*1000
# animated terrain textures (modules/texfx.lua): the second tallest atlas texture -> atlas texel (2694, 2)
FX = "am_fx"
FX_W, FX_H = 64, 1024


def tile_names(tex_table):
    return {int(k): v["name"] for k, v in tex_table.items()}


def load_tile(alpha, t):
    with open(os.path.join(alpha, "assets", "tiles", "terrain", "%d.png" % t), "rb") as f:
        return f.read()


def flip_u(png):
    w, h, rows = pngio.read_rgba(png)
    out = []
    for r in rows:
        o = bytearray(len(r))
        for x in range(w):
            o[x * 4:x * 4 + 4] = r[(w - 1 - x) * 4:(w - x) * 4]
        out.append(o)
    return pngio.write_rgba(w, h, out)


class Textures:
    def __init__(self, alpha, out, names):
        self.alpha, self.out, self.names = alpha, out, names
        self.used = {}

    def name(self, t):
        """terrain tile (negative = mirrored in U) -> texture name in the pack atlas."""
        flip = t < 0
        t = abs(t)
        # prefix: the "blocks" atlas is shared by all packs, base has leaves/grass/dirt/sand/... and
        # leaves_opaque (picked by ContentGfxCache as the opaque variant of "leaves" -> dark solid leaves)
        base = TEX_PREFIX + self.names.get(t, "tile_%d" % t)
        name = base + ("_flip" if flip else "")
        if name not in self.used:
            png = load_tile(self.alpha, t)
            self.used[name] = flip_u(png) if flip else png
        return name

    def bottom(self, t):
        name = self.name(t) + "_bottom"
        if name not in self.used:
            self.used[name] = flip_v(self.used[self.name(t)])
        return name

    def write(self):
        d = os.path.join(self.out, "textures", "blocks")
        if os.path.isdir(d):
            shutil.rmtree(d)
        os.makedirs(d)
        for name, png in sorted(self.used.items()):
            with open(os.path.join(d, name + ".png"), "wb") as f:
                f.write(png)
        return len(self.used)


def flip_v(png):
    w, h, rows = pngio.read_rgba(png)
    return pngio.write_rgba(w, h, [bytearray(r) for r in reversed(rows)])


def vc_faces(tex, alpha_sides):
    """6 texture names in VoxelCore order. The bottom face gets a vertically flipped tile: VoxelCore maps the
    image up along +Z on -Y faces (BlocksRenderer face(X, Z, -Y)), Alpha renderBottomFace along -Z; the other
    five faces have the same U/V directions in both (RenderBlocks.render*Face vs BlocksRenderer)."""
    names = [tex.name(alpha_sides[FACE_ORDER[i]]) for i in range(6)]
    names[2] = tex.bottom(alpha_sides[FACE_ORDER[2]])
    return names


def _world_air(b):
    return ((b.get("world_tiles") or {}).get("variants") or {}).get("air")


def base_sides(b):
    """Textures of meta 0 as the world renderer draws them (world_tiles 'air' variant when the block overrides
    getBlockTexture(IBlockAccess...): grass top/bottom/side, chest, furnace)."""
    air = _world_air(b)
    return air["meta0"] if air else b["tiles_by_side"]


def meta_sides(b):
    """{meta: sides} for metas whose textures differ from meta 0 (tiles_by_meta, or world_tiles by_meta for
    blocks with a world texture override)."""
    air = _world_air(b)
    if air:
        return {int(k): v for k, v in (air.get("by_meta") or {}).items()}
    return {int(k): v for k, v in (b.get("tiles_by_meta") or {}).items()}


def hitbox(bounds):
    x0, y0, z0, x1, y1, z1 = bounds
    r = lambda v: round(v, 6)
    return [r(x0), r(y0), r(z0), r(x1 - x0), r(y1 - y0), r(z1 - z0)]


def make_block(b, tex):
    rt = b["render_type"]
    cls = b["class"]
    chain = set(b.get("class_chain") or [cls])
    name = b["name_snake"]
    full = b["bounds"] == [0.0, 0.0, 0.0, 1.0, 1.0, 1.0]
    lo = b["light_opacity"]
    j = {"caption": b["name"]}
    sides = base_sides(b)
    metas = meta_sides(b)
    model = "block"
    faces = None

    per_meta = None   # meta -> custom model name (render types drawn by RenderBlocks geometry, see torch_lines ...)
    if rt == 2:
        per_meta = lambda m: ("m%d" % (m if 1 <= m <= 4 else 5), torch_lines(m if 1 <= m <= 4 else 5),
                              "RenderBlocks.renderBlockTorch")
        TODO.append((b["id"], name, "torch: geometry exact (renderTorchAtAngle per meta); Alpha draws blocks with lightValue > 0 at brightness 1.0, the pack shader uses the cell light (lit layer: shaders, not blocks)"))
    elif rt == 8:
        per_meta = lambda m: ("m%d" % (m if 2 <= m <= 5 else 2), ladder_lines(m if 2 <= m <= 5 else 2),
                              "RenderBlocks.renderBlockLadder")
    elif rt == 9:
        per_meta = lambda m: ("m%d" % (m if m <= 9 else 0), rails_lines(m if m <= 9 else 0),
                              "RenderBlocks.renderBlockMinecartTrack")
    elif rt == 10:
        per_meta = lambda m: ("m%d" % (m & 3), stairs_lines(m & 3), "RenderBlocks.renderBlockStairs")
    elif rt == 13:
        per_meta = lambda m: ("m0", cactus_lines(), "RenderBlocks.renderBlockCactusImpl")
    elif rt == 6:
        per_meta = lambda m: ("m0", crops_lines(), "RenderBlocks.renderBlockCropsImpl")
    elif rt == 7:
        door_meta = {int(k): v for k, v in (b.get("tiles_by_meta") or {}).items()}
        def per_meta(m, door_meta=door_meta):
            t = door_meta.get(m, b["tiles_by_side"])
            return ("m%d" % m, box_faces(door_box(m), flips=[v < 0 for v in t]),
                    "RenderBlocks.renderBlockDoor (BlockDoor.getState bounds, mirrored tiles)")
        TODO.append((b["id"], name, "door: geometry exact (3/16 panel by getState, mirrored tiles by meta); faces against solid blocks are culled by the engine (Alpha draws all six)"))
    elif rt == 12:
        base = "blocks:" + tex.name(16)
        per_meta = lambda m: ("m%d" % m, lever_lines(m, base), "RenderBlocks.renderBlockLever")
    elif cls == "BlockButton":
        per_meta = lambda m: ("m%d" % m, box_faces(button_box(m)), "BlockButton bounds by meta")
    if per_meta:
        def unflipped(sd):
            return [tex.name(abs(sd[FACE_ORDER[i]])) for i in range(6)]
        made = {}

        def emit(m, faces6):
            """VCM of meta m with the texture slots resolved to atlas names: the runtime (454aa205)
            ModelsGenerator::prepare resolves "$i" only for the DEFAULT variant, so a "$0" in a state variant's
            model stays unresolved and its UVs are never mapped into the atlas (garbage texels)."""
            key, lines, what = per_meta(m)
            text = "\n".join(lines)
            for i in range(6):
                text = text.replace('texture "$%d"' % i, 'texture "blocks:%s"' % faces6[i])
            if text not in made:
                nm = "amblk_%s_%s" % (name, key)
                while nm in MODELS and MODELS[nm].split("\n", 1)[1] != text + "\n":
                    nm += "x"
                MODELS[nm] = "# GENERATED by tools/alphamine/gen_pack_blocks.py: Alpha %s\n" % what + text + "\n"
                made[text] = nm
            return made[text]
        j["model"] = "custom"
        j["model-name"] = emit(0, unflipped(b["tiles_by_side"] if rt == 7 else sides))
        f0 = unflipped(b["tiles_by_side"] if rt == 7 else sides)
        if len(set(f0)) == 1:
            j["texture"] = f0[0]
        else:
            j["texture-faces"] = f0
        variants = []
        for m in range(1, 16):
            if m == 15:
                # VoxelCore 0.31 runtime (454aa205) ContentGfxCache::refresh loops `i < variants.size() - 1`: the
                # last variant (index 15; the vector is a fixed 16) never gets its model or UVs -> a custom model
                # there throws "model not found" in every frame. Meta 15 draws nothing instead (only the top half of
                # an open door in state 3 needs it; torches/rails/stairs/ladders/levers/buttons/crops never use it).
                variants.append({"model": "none"})
                if rt == 7:
                    TODO.append((b["id"], name, "door meta 15 (top half, open, state 3) is not drawn: the runtime never prepares state variant 15 (ContentGfxCache::refresh off-by-one)"))
                continue
            sd = metas.get(m, b["tiles_by_side"] if rt == 7 else sides)
            fm = unflipped(sd)
            v = {"model": "custom", "model-name": emit(m, fm)}
            if len(set(fm)) == 1:
                v["texture"] = fm[0]
            else:
                v["texture-faces"] = fm
            variants.append(v)
        if rt != 13:   # cactus: one model, meta = growth counter (reaches 15) -> no variants at all
            j["state-based"] = {"offset": 0, "bits": 4, "variants": variants}
        j["hitbox"] = hitbox(b["bounds"]) if rt not in (2, 8) else ([0.4375, 0.0, 0.4375, 0.125, 0.625, 0.125] if rt == 2 else [0.0, 0.0, 0.0, 1.0, 1.0, 0.125])
        faces = f0
        metas = {}
    elif rt == 0:
        faces = vc_faces(tex, sides)
        if not full:
            model = "aabb"
    elif rt == 1 and not metas:  # renderCrossedSquares / renderBlockReed: exact Alpha planes (model file)
        model = "custom"
        j["model-name"] = MODEL_CROSS
        faces = [tex.name(sides[0])] * 6
    elif rt in (1, 3, 6):  # fire, crops (and crosses with meta textures)
        model = "X"
        faces = [tex.name(sides[0])] * 6
        if rt == 3:
            TODO.append((b["id"], name, "fire: renderBlockFire (slanted planes + animated TextureFlamesFX) -> X placeholder, static tile"))
        if rt == 6:
            TODO.append((b["id"], name, "crops: renderBlockCrops draws 4 planes '#' -> X placeholder"))
    elif rt == 4:  # fluids
        faces = vc_faces(tex, sides)
        if b["material"] == "water":
            TODO.append((b["id"], name, "water: engine cube, Alpha look done in shaders (translucent.glsl*: corner heights, flow direction, animated TextureWaterFX/FlowFX from modules/texfx.lua, fluid light); open: non-planar tops use the engine's other triangle diagonal, tops under a solid block are culled by the engine (Alpha draws them)"))
        else:
            TODO.append((b["id"], name, "lava: plain full block with the static tile; TextureLavaFX/LavaFlowFX are simulated (modules/texfx.lua, am_fx) but main.glslf does not apply them or the fluid heights yet"))
    elif rt == 2:  # torches
        model = "aabb"
        faces = [tex.name(sides[0])] * 6
        j["hitbox"] = [0.4375, 0.0, 0.4375, 0.125, 0.625, 0.125]
        TODO.append((b["id"], name, "torch: aabb stick placeholder; Alpha renderBlockTorch (tilted on walls by meta 1..4, top 2x2 texels)"))
    elif rt == 5:  # redstone wire
        model = "aabb"
        faces = [tex.name(sides[1])] * 6
        j["hitbox"] = [0.0, 0.0, 0.0, 1.0, 0.015625, 1.0]
        TODO.append((b["id"], name, "redstone wire: flat aabb placeholder; Alpha picks tile by connections, colour by power"))
    elif rt == 7:  # doors
        faces = vc_faces(tex, sides)
        TODO.append((b["id"], name, "door: full block placeholder; Alpha renderBlockDoor 3/16 panel by meta, mirrored tiles"))
    elif rt == 8:  # ladder
        model = "X"
        faces = [tex.name(sides[0])] * 6
        TODO.append((b["id"], name, "ladder: X placeholder; Alpha renderBlockLadder = plane at the wall by meta 2..5"))
    elif rt == 9:  # rails
        model = "aabb"
        faces = [tex.name(sides[1])] * 6
        j["hitbox"] = [0.0, 0.0, 0.0, 1.0, 0.0625, 1.0]
        TODO.append((b["id"], name, "rails: flat aabb placeholder; Alpha renderBlockMinecartTrack rotated/sloped by meta"))
    elif rt == 10:  # stairs
        faces = vc_faces(tex, sides)
        TODO.append((b["id"], name, "stairs: full block placeholder; Alpha renderBlockStairs = two boxes by meta"))
    elif rt == 12:  # lever
        model = "aabb"
        faces = [tex.name(sides[0])] * 6
        j["hitbox"] = [0.3125, 0.0, 0.3125, 0.375, 0.375, 0.375]
        TODO.append((b["id"], name, "lever: small aabb placeholder; Alpha renderBlockLever (base + tilted handle by meta)"))
    elif rt == 13:  # cactus
        model = "aabb"
        faces = vc_faces(tex, sides)
        j["hitbox"] = [0.0625, 0.0, 0.0625, 0.875, 1.0, 0.875]
        TODO.append((b["id"], name, "cactus: aabb inset 1/16 on all sides; Alpha insets only the side faces (top/bottom full)"))
    elif rt == -1:  # signs (TileEntitySpecialRenderer)
        model = "aabb"
        faces = [tex.name(sides[0])] * 6
        j["hitbox"] = [0.25, 0.0, 0.4375, 0.5, 1.0, 0.125]
        TODO.append((b["id"], name, "sign: aabb placeholder; Alpha TileEntitySignRenderer (model + text)"))
    else:
        faces = vc_faces(tex, sides)
        TODO.append((b["id"], name, "render type %d: full block placeholder" % rt))

    if per_meta:
        model = "custom"
    if model == "aabb" and "hitbox" not in j:
        j["hitbox"] = hitbox(b["bounds"])
    if model != "block" and not per_meta:
        j["model"] = model
    if not per_meta:
        if len(set(faces)) == 1:
            j["texture"] = faces[0]
        else:
            j["texture-faces"] = faces

    # meta variants (state-based, userbits = meta): only texture changes, same model
    if metas and rt not in (7,):
        top = max(metas)
        variants = []
        for m in range(1, top + 1):
            s = metas.get(m, sides)
            if model == "X" or rt in (5, 9):
                pick = s[1] if rt in (5, 9) else s[0]
                variants.append({"texture": tex.name(pick)})
            else:
                variants.append({"texture-faces": vc_faces(tex, s)})
        j["state-based"] = {"offset": 0, "bits": 4, "variants": variants}
    elif metas and rt == 7:
        TODO.append((b["id"], name, "door meta tiles (upper half tile 81/82, mirrored) not applied"))

    # light
    if ENGINE_LIGHT_OFF:
        j["light-passing"] = True
        j["sky-light-passing"] = True
    elif b["light_value"]:
        lv = b["light_value"]
        j["emission"] = [lv, lv, lv]
    if ENGINE_LIGHT_OFF:
        pass
    elif lo == 0:
        j["light-passing"] = True
        j["sky-light-passing"] = True
    elif lo < 255:
        j["light-passing"] = True
        j["sky-light-passing"] = False
        TODO.append((b["id"], name, "light opacity %d: engine light has no partial opacity -- rendering uses the server's light (modules/lightmap.lua); blocks changed after the MapChunk are not relit (Alpha's client relights)" % lo))
    elif model != "block" or not b["is_opaque_cube"]:
        # not a cube but blocks light in Alpha (slabs, farmland, lava): VoxelCore treats such models as
        # non-solid for meshing; light is stopped as in Alpha
        j["light-passing"] = False
    # render pass / transparency
    if b["render_pass"] == 1:
        j["draw-group"] = 3 if b["material"] == "water" else 2
        if name != "fire":
            j["translucent"] = True
    if name == "glass":
        j["draw-group"] = 2
    if name == "leaves":
        j["draw-group"] = 5
        j["culling"] = "disabled"  # fancy leaves: faces between leaves are drawn (BlockLeavesBase)
    if b["material"] in ("water", "lava"):
        j["selectable"] = False
        j["replaceable"] = True
    # physics
    if cls in NO_COLLISION or chain & NO_COLLISION:
        j["obstacle"] = False
    if model == "X":
        j["replaceable"] = False
    # the world belongs to the server: the engine's own player controller must not break blocks locally
    j["breakable"] = False
    j["alphamine:id"] = b["id"]
    return j


def collision_box(b):
    """Alpha collision box of meta 0 in block coordinates (None = no collision)."""
    cls = b["class"]
    chain = set(b.get("class_chain") or [cls])
    if cls in NO_COLLISION or chain & NO_COLLISION:
        return None
    if cls == "BlockCactus":
        e = 1.0 / 16.0
        return [e, 0.0, e, 1 - e, 1 - e, 1 - e]
    if cls == "BlockFarmland":
        return [0.0, 0.0, 0.0, 1.0, 1.0, 1.0]
    return list(b["bounds"])


def lua_value(v):
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(float(v)) if isinstance(v, float) else str(v)
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, (list, tuple)):
        return "{" + ", ".join(lua_value(x) for x in v) + "}"
    if isinstance(v, dict):
        return "{" + ", ".join("%s = %s" % (k, lua_value(x)) for k, x in v.items()) + "}"
    raise TypeError(type(v))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--alpha", default=ALPHA)
    ap.add_argument("--out", default=os.path.join(REPO, "packs", "alphamine"))
    ap.add_argument("--engine-light", choices=["on", "off"], default="off")
    ap.add_argument("--blocks-only", action="store_true")
    opts = ap.parse_args()
    global ENGINE_LIGHT_OFF
    ENGINE_LIGHT_OFF = opts.engine_light == "off"
    with open(os.path.join(opts.alpha, "tables", "blocks.json")) as f:
        blocks = json.load(f)
    with open(os.path.join(opts.alpha, "tables", "textures_by_block.json")) as f:
        names = tile_names(json.load(f))
    tex = Textures(opts.alpha, opts.out, names)
    bdir = os.path.join(opts.out, "blocks")
    if os.path.isdir(bdir):
        shutil.rmtree(bdir)
    os.makedirs(bdir)
    table = []
    for b in blocks:
        j = make_block(b, tex)
        with open(os.path.join(bdir, b["name_snake"] + ".json"), "w", encoding="utf-8") as f:
            json.dump(j, f, indent=4, ensure_ascii=False)
            f.write("\n")
        table.append((b["id"], {
            "name": b["name_snake"],
            "box": collision_box(b),
            "variants": "state-based" in j,
            "opaque": bool(b["opaque_cube_lookup"]),
            "liquid": bool(b["material_props"].get("liquid")),
            "solid": bool(b["material_props"].get("solid")),   # Material.isSolid (fluid heights, flow)
            "material": b["material"],
        }))
    if ENGINE_LIGHT_OFF:
        open(os.path.join(bdir, ".engine_light_off"), "w").write("gen_pack_blocks.py --engine-light off\n")
    if opts.blocks_only:
        print("blocks only: %d block JSONs -> %s (engine light %s)" % (len(blocks), bdir, opts.engine_light))
        return
    tex.used[LIGHTMAP] = pngio.write_rgba(LIGHTMAP_W, LIGHTMAP_H,
                                          [bytearray(LIGHTMAP_W * 4) for _ in range(LIGHTMAP_H)])
    tex.used[FX] = pngio.write_rgba(FX_W, FX_H, [bytearray(FX_W * 4) for _ in range(FX_H)])
    ntex = tex.write()
    nmodels = write_models(opts.out)
    with open(os.path.join(opts.alpha, "tables", "items.json")) as f:
        items = json.load(f)
    with open(os.path.join(opts.out, "modules", "items_table.lua"), "w", encoding="utf-8") as f:
        f.write("-- GENERATED by tools/alphamine/gen_pack_blocks.py from tables/items.json -- do not edit.\n"
                "-- item id -> {name, max_stack, max_damage}\nreturn {\n")
        for it in items:
            f.write("    [%d] = {name = %s, max_stack = %d, max_damage = %d},\n"
                    % (it["id"], json.dumps(it["name_snake"]), it["max_stack"], it["max_damage"]))
        f.write("}\n")
    lines = ["-- GENERATED by tools/alphamine/gen_pack_blocks.py from <repo>\\projects\\alphamine\\external\\tables\\blocks.json -- do not edit.",
             "-- alpha id -> {name (VoxelCore id alphamine:<name>), box (Alpha collision box of meta 0, nil = none),",
             "--   variants (meta selects a state-based variant), opaque (Block.opaqueCubeLookup), liquid,",
             "--   solid (Material.isSolid), material (Material name)}",
             "return {"]
    for bid, e in table:
        lines.append("    [%d] = %s," % (bid, lua_value(e)))
    lines.append("}")
    with open(os.path.join(opts.out, "modules", "blocks_table.lua"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(bdir, "..", "BLOCKS_TODO.md"), "w", encoding="utf-8") as f:
        f.write("# alphamine: block placeholders (generated by tools/alphamine/gen_pack_blocks.py)\n\n")
        f.write("Blocks whose Alpha render type VoxelCore cannot draw 1:1 yet. Standard cubes (texel inset, light, fog in\n"
                "shaders/), renderCrossedSquares (models/amblk_cross.vcm: saplings, flowers, mushrooms, reeds), meta texture\n"
                "variants and the RenderBlocks geometry of torches, ladders, rails, stairs, doors, levers, buttons, cactus and\n"
                "crops (models/amblk_<block>_m<meta>.vcm, one per state variant, textures baked in) are exact in the flat\n"
                "layer (devworld, agents/ALPHAMINE.md 10: 97-100 % per exhibit). Lit layer: the pack shader multiplies\n"
                "axis-aligned planes by the face factor 0.6/0.8 -- Alpha draws torches, ladders, crops unshaded (and blocks with\n"
                "lightValue > 0 at brightness 1.0); that is shaders/main.glslf, not these files.\n\n"
                "Runtime limits (VoxelCore 0.31 = 454aa205): ModelsGenerator::prepare resolves \"$i\" textures only for the\n"
                "default variant (state variants must name atlas textures); ContentGfxCache::refresh skips the last variant\n"
                "(index 15): meta 15 of a state-based block has no UVs/model (custom models: drawn as 'none').\n\n")
        for bid, name, what in TODO:
            f.write("- %d `%s`: %s\n" % (bid, name, what))
    print("blocks: %d, textures: %d, models: %d, todo: %d -> %s" % (len(table), ntex, nmodels, len(TODO), opts.out))


if __name__ == "__main__":
    main()
