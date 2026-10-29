#!/usr/bin/env python3
"""AlphaMine phase 3: VCM models + entity textures for the pack `alphamine` from the Alpha 1.0.16 Java model classes.

Model parts are *executed*, not transcribed: ModelBiped / ModelMinecart / ModelBoat (+ ModelBase) are run by
tools/alphamine/minijava.py with a recording ModelRenderer (same fields; addBox/setRotationPoint store their
arguments), so every box, texture offset, mirror flag, inflation and rotation point is what the Java constructor
produces. `(float)Math.PI` is replaced by its value before interpretation (minijava has no java.lang.Math.PI).
The quads are then built exactly like ModelRenderer.addBox + TexturedQuad (corner order, per-face UV rectangles,
the 0.0015625 / 0.003125 UV insets, mirror swap + flipFace), scaled by 1/16 (ModelRenderer.render(1/16F)),
in the part's local space (origin = rotation point). The runtime (content/alphamine/modules/entities.lua) poses
every part with the Java render transform: T(pos) Ry(180-yaw) S(-1,-1,1) [S(15/16) player] T(0,-24/16-1/128,0)
T(rotationPoint/16) Rz Ry Rx.

Also generated (texture "entities/am_terrain" = terrain.png; texel-exact UV like RenderBlocks):
  * am_bi_<id>.vcm   block items (RenderBlocks.renderBlockOnInventory, render types 0/10/13), unit cube centred
                     at 0 (the runtime scales by 0.25 / 0.5 like RenderItem);
  * am_sp_<id>.vcm   flat sprites of the other items (RenderItem quad 1x1 at (-0.5,-0.25), texture am_items /
                     am_terrain), shading off (Alpha: normal (0,1,0) under the two lights = full brightness);
  * am_shadow.vcm    unit quad for Render.renderShadow (texture am_shadow).
Textures copied from <repo>\\projects\\alphamine\\external\\assets: char.png, item/cart.png, item/boat.png, terrain.png,
gui/items.png, misc/shadow.png -> textures/entities/am_*.png.

VCM tri: uv are texture fractions; the engine's v = 0 is the bottom row of the PNG (checked by running), Alpha's
v = 0 is the top row -> written as 1 - v - 1e-6 (exact texel, see Writer.uv); --no-vflip writes Alpha uv as is.
  python3 tools/alphamine/gen_models.py
"""
import argparse
import json
import math
import os
import re
import shutil
import struct
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))  # корень репозитория (было: рабочий каталог движка)
PACK = os.path.join(REPO, "packs", "alphamine")
ALPHA = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "external"))  # было внешний каталог AlphaMine
SRC = os.path.join(ALPHA, "ref", "minecraft", "src", "net", "minecraft", "src")
sys.path.insert(0, HERE)
from minijava import VM  # noqa: E402


def f32(x):
    return struct.unpack("f", struct.pack("f", x))[0]


RECORDING_RENDERER = """package net.minecraft.src;
public class ModelRenderer {
	public int textureOffsetX; public int textureOffsetY;
	public float rotationPointX; public float rotationPointY; public float rotationPointZ;
	public float rotateAngleX; public float rotateAngleY; public float rotateAngleZ;
	public boolean mirror = false; public boolean showModel = true;
	public float boxX; public float boxY; public float boxZ; public int boxW; public int boxH; public int boxD;
	public float boxInflate; public boolean boxMirror;
	public ModelRenderer(int var1, int var2) { this.textureOffsetX = var1; this.textureOffsetY = var2; }
	public void addBox(float var1, float var2, float var3, int var4, int var5, int var6) { this.addBox(var1, var2, var3, var4, var5, var6, 0.0F); }
	public void addBox(float var1, float var2, float var3, int var4, int var5, int var6, float var7) {
		this.boxX = var1; this.boxY = var2; this.boxZ = var3; this.boxW = var4; this.boxH = var5; this.boxD = var6;
		this.boxInflate = var7; this.boxMirror = this.mirror;
	}
	public void setRotationPoint(float var1, float var2, float var3) { this.rotationPointX = var1; this.rotationPointY = var2; this.rotationPointZ = var3; }
}
"""


def run_models():
    tmp = tempfile.mkdtemp(prefix="am_models_")
    for n in ("ModelBase", "ModelBiped", "ModelMinecart", "ModelBoat"):
        with open(os.path.join(SRC, n + ".java"), encoding="utf-8") as f:
            t = f.read()
        t = t.replace("(float)Math.PI", "3.1415927410125732F")
        with open(os.path.join(tmp, n + ".java"), "w", encoding="utf-8") as f:
            f.write(t)
    with open(os.path.join(tmp, "ModelRenderer.java"), "w", encoding="utf-8") as f:
        f.write(RECORDING_RENDERER)
    vm = VM(tmp)
    out = {}
    for cls, fields in (("ModelBiped", ["bipedHead", "bipedHeadwear", "bipedBody", "bipedRightArm", "bipedLeftArm",
                                        "bipedRightLeg", "bipedLeftLeg"]),
                        ("ModelMinecart", "sideModels"), ("ModelBoat", "boatSides")):
        obj = vm.new_object(vm.get_class(cls), [])
        parts = []
        if isinstance(fields, str):
            arr = obj.f[fields]
            items = [(fields + str(i), p) for i, p in enumerate(arr.v if hasattr(arr, "v") else arr) if p is not None]
        else:
            items = [(n, obj.f[n]) for n in fields]
        for name, r in items:
            g = r.f
            parts.append({
                "name": name, "tex": (g["textureOffsetX"], g["textureOffsetY"]),
                "box": (g["boxX"], g["boxY"], g["boxZ"], g["boxW"], g["boxH"], g["boxD"]),
                "inflate": g["boxInflate"], "mirror": bool(g["boxMirror"]),
                "point": (g["rotationPointX"], g["rotationPointY"], g["rotationPointZ"]),
                "rot": (g["rotateAngleX"], g["rotateAngleY"], g["rotateAngleZ"]),
            })
        out[cls] = parts
    shutil.rmtree(tmp, ignore_errors=True)
    return out


def box_quads(part, tw=64.0, th=32.0):
    """ModelRenderer.addBox + TexturedQuad: 6 quads [(4 corners (x,y,z) in pixels), (4 uv)]."""
    x1, y1, z1, w, h, d = part["box"]
    inf = part["inflate"]
    ox, oy = part["tex"]
    x2, y2, z2 = f32(x1 + w), f32(y1 + h), f32(z1 + d)
    x1, y1, z1 = f32(x1 - inf), f32(y1 - inf), f32(z1 - inf)
    x2, y2, z2 = f32(x2 + inf), f32(y2 + inf), f32(z2 + inf)
    if part["mirror"]:
        x1, x2 = x2, x1
    v = [(x1, y1, z1), (x2, y1, z1), (x2, y2, z1), (x1, y2, z1),
         (x1, y1, z2), (x2, y1, z2), (x2, y2, z2), (x1, y2, z2)]
    V20, V12, V13, V14, V15, V16, V17, V18 = v
    faces = [
        ([V16, V12, V13, V17], (ox + d + w, oy + d, ox + d + w + d, oy + d + h)),
        ([V20, V15, V18, V14], (ox + 0, oy + d, ox + d, oy + d + h)),
        ([V16, V15, V20, V12], (ox + d, oy + 0, ox + d + w, oy + d)),
        ([V13, V14, V18, V17], (ox + d + w, oy + 0, ox + d + w + w, oy + d)),
        ([V12, V20, V14, V13], (ox + d, oy + d, ox + d + w, oy + d + h)),
        ([V15, V16, V17, V18], (ox + d + w + d, oy + d, ox + d + w + d + w, oy + d + h)),
    ]
    e1, e2 = f32(0.0015625), f32(0.003125)
    quads = []
    for verts, (u1, v1, u2, v2) in faces:
        uv = [(f32(u2 / tw) - e1, f32(v1 / th) + e2), (f32(u1 / tw) + e1, f32(v1 / th) + e2),
              (f32(u1 / tw) + e1, f32(v2 / th) - e2), (f32(u2 / tw) - e1, f32(v2 / th) - e2)]
        if part["mirror"]:
            verts, uv = verts[::-1], uv[::-1]
        quads.append((verts, uv))
    return quads


def fmt(x):
    s = ("%.9g" % x)
    return "0" if s in ("-0", "0") else s


class Writer:
    def __init__(self, vflip):
        self.vflip = vflip

    def uv(self, u, v):
        # the engine samples model textures with v = 0 at the bottom row of the PNG (checked by running: the
        # log item showed terrain.png row 224+ instead of 16+). 1 - v - 1e-6 keeps the Alpha texel exactly:
        # floor((1 - v - eps) * H) = H - 1 - floor(v * H), also for v exactly on a texel edge.
        return (u, 1.0 - v - 1e-6) if self.vflip else (u, v)

    def tri(self, a, b, c, ua, ub, uc, tex, shading=True):
        ua, ub, uc = self.uv(*ua), self.uv(*ub), self.uv(*uc)
        s = "@tri a (%s) b (%s) c (%s) uv (%s) texture \"%s\"" % (
            ",".join(fmt(t) for t in a), ",".join(fmt(t) for t in b), ",".join(fmt(t) for t in c),
            ",".join(fmt(t) for t in ua + ub + uc), tex)
        if not shading:
            s += " shading off"
        return s

    def quad(self, verts, uvs, tex, outward=None, shading=True):
        """Two triangles; winding chosen so that cross(b-a, c-a) points along `outward` (engine front face)."""
        a, b, c, d = verts
        n = cross(sub(b, a), sub(c, a))
        if outward is not None and dot(n, outward) < 0:
            verts, uvs = verts[::-1], uvs[::-1]
            a, b, c, d = verts
        ua, ub, uc, ud = uvs
        return [self.tri(a, b, c, ua, ub, uc, tex, shading), self.tri(a, c, d, ua, uc, ud, tex, shading)]


def sub(p, q):
    return (p[0] - q[0], p[1] - q[1], p[2] - q[2])


def cross(p, q):
    return (p[1] * q[2] - p[2] * q[1], p[2] * q[0] - p[0] * q[2], p[0] * q[1] - p[1] * q[0])


def dot(p, q):
    return p[0] * q[0] + p[1] * q[1] + p[2] * q[2]


def part_vcm(W, part, tex):
    """Quads of a ModelRenderer box in blocks (x/16), origin = the part's rotation point."""
    lines = []
    quads = box_quads(part)
    xs = [c[0] for q in quads for c in q[0]]
    ys = [c[1] for q in quads for c in q[0]]
    zs = [c[2] for q in quads for c in q[0]]
    ctr = ((min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2, (min(zs) + max(zs)) / 2)
    for verts, uvs in quads:
        vb = [(x / 16.0, y / 16.0, z / 16.0) for x, y, z in verts]
        fc = tuple(sum(c[i] for c in verts) / 4.0 for i in range(3))
        lines += W.quad(vb, uvs, tex, outward=sub(fc, ctr))
    return lines


def block_item_quads(W, tiles, bounds, rtype):
    """RenderBlocks.renderBlockOnInventory (+ face renderers): unit block translated by -0.5."""
    out = []

    def uvtile(t):
        return (t & 15) << 4, t & 240

    def boxfaces(b, inset=None):
        x0, y0, z0, x1, y1, z1 = b
        res = []
        for side in range(6):
            tu, tv = uvtile(tiles[side])
            if side == 0:     # bottom (renderBottomFace)
                u1, u2 = (tu + x0 * 16) / 256, (tu + x1 * 16 - 0.01) / 256
                v1, v2 = (tv + z0 * 16) / 256, (tv + z1 * 16 - 0.01) / 256
                q = [((x0, y0, z1), (u1, v2)), ((x0, y0, z0), (u1, v1)), ((x1, y0, z0), (u2, v1)), ((x1, y0, z1), (u2, v2))]
                n = (0, -1, 0)
            elif side == 1:   # top
                u1, u2 = (tu + x0 * 16) / 256, (tu + x1 * 16 - 0.01) / 256
                v1, v2 = (tv + z0 * 16) / 256, (tv + z1 * 16 - 0.01) / 256
                q = [((x1, y1, z1), (u2, v2)), ((x1, y1, z0), (u2, v1)), ((x0, y1, z0), (u1, v1)), ((x0, y1, z1), (u1, v2))]
                n = (0, 1, 0)
            elif side == 2:   # east (z min)
                u1, u2 = (tu + x0 * 16) / 256, (tu + x1 * 16 - 0.01) / 256
                v1, v2 = (tv + y0 * 16) / 256, (tv + y1 * 16 - 0.01) / 256
                zz = z0 + (inset or 0)
                q = [((x0, y1, zz), (u2, v1)), ((x1, y1, zz), (u1, v1)), ((x1, y0, zz), (u1, v2)), ((x0, y0, zz), (u2, v2))]
                n = (0, 0, -1)
            elif side == 3:   # west (z max)
                u1, u2 = (tu + x0 * 16) / 256, (tu + x1 * 16 - 0.01) / 256
                v1, v2 = (tv + y0 * 16) / 256, (tv + y1 * 16 - 0.01) / 256
                zz = z1 - (inset or 0)
                q = [((x0, y1, zz), (u1, v1)), ((x0, y0, zz), (u1, v2)), ((x1, y0, zz), (u2, v2)), ((x1, y1, zz), (u2, v1))]
                n = (0, 0, 1)
            elif side == 4:   # north (x min)
                u1, u2 = (tu + z0 * 16) / 256, (tu + z1 * 16 - 0.01) / 256
                v1, v2 = (tv + y0 * 16) / 256, (tv + y1 * 16 - 0.01) / 256
                xx = x0 + (inset or 0)
                q = [((xx, y1, z1), (u2, v1)), ((xx, y1, z0), (u1, v1)), ((xx, y0, z0), (u1, v2)), ((xx, y0, z1), (u2, v2))]
                n = (-1, 0, 0)
            else:             # south (x max)
                u1, u2 = (tu + z0 * 16) / 256, (tu + z1 * 16 - 0.01) / 256
                v1, v2 = (tv + y0 * 16) / 256, (tv + y1 * 16 - 0.01) / 256
                xx = x1 - (inset or 0)
                q = [((xx, y0, z1), (u1, v2)), ((xx, y0, z0), (u2, v2)), ((xx, y1, z0), (u2, v1)), ((xx, y1, z1), (u1, v1))]
                n = (1, 0, 0)
            verts = [(p[0] - 0.5, p[1] - 0.5, p[2] - 0.5) for p, _ in q]
            res += W.quad(verts, [t for _, t in q], "entities/am_terrain", outward=n)
        return res

    if rtype == 10:   # stairs: two boxes (RenderBlocks.renderBlockOnInventory type 10)
        out += boxfaces((0, 0, 0, 1, 1, 0.5))
        out += boxfaces((0, 0, 0.5, 1, 0.5, 1))
    elif rtype == 13:  # cactus: sides inset by 1/16
        out += boxfaces(tuple(bounds), inset=1.0 / 16)
    else:
        out += boxfaces(tuple(bounds))
    return out


def sprite_quad(W, icon, tex):
    """RenderItem flat item: 1x1 quad at x -0.5..0.5, y -0.25..0.75, z 0, facing +Z (the runtime rotates it)."""
    u1, u2 = (icon % 16 * 16) / 256.0, (icon % 16 * 16 + 16) / 256.0
    v1, v2 = (icon // 16 * 16) / 256.0, (icon // 16 * 16 + 16) / 256.0
    q = [((-0.5, -0.25, 0), (u1, v2)), ((0.5, -0.25, 0), (u2, v2)), ((0.5, 0.75, 0), (u2, v1)), ((-0.5, 0.75, 0), (u1, v1))]
    return W.quad([p for p, _ in q], [t for _, t in q], tex, outward=(0, 0, 1), shading=False)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-vflip", dest="vflip", action="store_false")
    o = ap.parse_args()
    W = Writer(o.vflip)
    models = os.path.join(PACK, "models")
    os.makedirs(models, exist_ok=True)
    for fn in os.listdir(models):  # only this generator's files (models/am_hand/ etc. belong to others)
        if fn.endswith(".vcm") and fn.startswith(("am_player_", "am_cart_", "am_boat_", "am_bi_", "am_sp_",
                                                    "am_shadow", "am_items", "am_font")):
            os.remove(os.path.join(models, fn))
    tex = os.path.join(PACK, "textures", "entities")
    os.makedirs(tex, exist_ok=True)
    assets = os.path.join(ALPHA, "assets")
    for src, dst in (("char.png", "am_char.png"), ("item/cart.png", "am_cart.png"), ("item/boat.png", "am_boat.png"),
                     ("terrain.png", "am_terrain.png"), ("gui/items.png", "am_items.png"), ("misc/shadow.png", "am_shadow.png")):
        p = os.path.join(assets, src)
        if not os.path.exists(p):
            p = os.path.join(assets, os.path.basename(src))
        shutil.copy(p, os.path.join(tex, dst))

    parts = run_models()
    meta = {"generated_by": "tools/alphamine/gen_models.py", "vflip": o.vflip, "parts": {}}
    names = {"ModelBiped": ("am_player", "entities/am_char",
                            ["head", "headwear", "body", "rarm", "larm", "rleg", "lleg"]),
             "ModelMinecart": ("am_cart", "entities/am_cart", None), "ModelBoat": ("am_boat", "entities/am_boat", None)}
    count = 0
    for cls, plist in parts.items():
        base, texname, pn = names[cls]
        meta["parts"][base] = []
        for i, p in enumerate(plist):
            pname = pn[i] if pn else str(i)
            mname = "%s_%s" % (base, pname)
            with open(os.path.join(models, mname + ".vcm"), "w", encoding="utf-8") as f:
                f.write("# GENERATED by tools/alphamine/gen_models.py from %s.%s (Alpha 1.0.16)\n" % (cls, p["name"]))
                f.write("\n".join(part_vcm(W, p, texname)) + "\n")
            count += 1
            meta["parts"][base].append({"model": mname, "java": p["name"], "point": p["point"], "rot": p["rot"],
                                        "box": p["box"], "tex": p["tex"], "inflate": p["inflate"],
                                        "mirror": p["mirror"]})
    # block items and sprites
    with open(os.path.join(ALPHA, "tables", "blocks.json"), encoding="utf-8") as f:
        blocks = {b["id"]: b for b in json.load(f)}
    with open(os.path.join(ALPHA, "tables", "items.json"), encoding="utf-8") as f:
        items = json.load(f)
    meta["items"] = {}
    item_lines = ["# GENERATED by tools/alphamine/gen_models.py: dropped/held item models, one bone per Alpha item id",
                  "# (the engine splits a VCM with named bones into models am_items.i<id>)"]
    for it in items:
        iid = it["id"]
        b = blocks.get(iid) if iid < 256 else None
        if b and b["render_type"] in (0, 10, 13):
            mname = "am_bi_%d" % iid
            lines = block_item_quads(W, b["tiles_by_side"], b["bounds"], b["render_type"])
            scale = 0.25 if (b["render_as_normal_block"] or iid == 44) else 0.5
            meta["items"][iid] = {"model": mname, "kind": "block", "scale": scale}
        else:
            icon = it.get("icon_index")
            if icon is None or icon < 0:
                continue
            mname = "am_sp_%d" % iid
            lines = sprite_quad(W, icon, "entities/am_terrain" if iid < 256 else "entities/am_items")
            meta["items"][iid] = {"model": mname, "kind": "sprite", "icon": icon}
        meta["items"][iid]["model"] = "am_items.i%d" % iid
        item_lines.append("@bone name \"i%d\" {  # %s" % (iid, it["name"]))
        item_lines += ["    " + l for l in lines]
        item_lines.append("}")
        count += 1
    with open(os.path.join(models, "am_items.vcm"), "w", encoding="utf-8") as f:
        f.write("\n".join(item_lines) + "\n")
    # font (FontRenderer: default.png 128x128, 8x8 cells, glyph quad 7.99 x 7.99, widths from the alpha of the
    # texture) -> am_font.vcm, one bone per char code: models am_font.c<code> (RenderPlayer name tag)
    import pngio
    fw, fh, frows = pngio.read_rgba(open(os.path.join(assets, "default.png"), "rb").read())
    # Java: rightmost column with (ARGB pixel & 255) > 0 — the BLUE channel, not alpha; space = 2; width + 2
    widths = []
    for ch in range(256):
        cx, cy = ch % 16, ch // 16
        col = 7
        while col >= 0:
            x = cx * 8 + col
            if any(frows[cy * 8 + r][x * 4 + 2] > 0 for r in range(8)):
                break
            col -= 1
        if ch == 32:
            col = 2
        widths.append(col + 2)
    shutil.copy(os.path.join(assets, "default.png"), os.path.join(tex, "am_font.png"))
    font_lines = ["# GENERATED by tools/alphamine/gen_models.py: FontRenderer glyphs (default.png), bone c<code>"]
    e799 = f32(7.99)
    for ch in range(32, 256):
        u0, v0 = (ch % 16) * 8, (ch // 16) * 8
        q = [((0, e799, 0), (u0 / 128.0, (v0 + e799) / 128.0)), ((e799, e799, 0), ((u0 + e799) / 128.0, (v0 + e799) / 128.0)),
             ((e799, 0, 0), ((u0 + e799) / 128.0, v0 / 128.0)), ((0, 0, 0), (u0 / 128.0, v0 / 128.0))]
        font_lines.append("@bone name \"c%d\" {" % ch)
        # the tag is drawn with glScalef(-s, -s, s): seen from the front its quad faces -Z in font space
        font_lines += ["    " + l for l in W.quad([p for p, _ in q], [t for _, t in q], "entities/am_font",
                                                  outward=(0, 0, -1), shading=False)]
        font_lines.append("}")
    with open(os.path.join(models, "am_font.vcm"), "w", encoding="utf-8") as f:
        f.write("\n".join(font_lines) + "\n")
    meta["font_widths"] = widths
    # shadow quad (Render.renderShadow): unit square on y=0, uv 0..1
    with open(os.path.join(models, "am_shadow.vcm"), "w", encoding="utf-8") as f:
        f.write("# GENERATED by tools/alphamine/gen_models.py: Render.renderShadow quad\n")
        q = [((0, 0, 0), (0, 0)), ((0, 0, 1), (0, 1)), ((1, 0, 1), (1, 1)), ((1, 0, 0), (1, 0))]
        f.write("\n".join(W.quad([p for p, _ in q], [t for _, t in q], "entities/am_shadow", outward=(0, 1, 0),
                                 shading=False)) + "\n")
    count += 1
    # runtime table
    lua = ["-- GENERATED by tools/alphamine/gen_models.py -- do not edit.",
           "-- parts: model name, rotation point (pixels), fixed rotation (rad, as the Java constructor sets it);",
           "-- items: alpha item id -> {model, kind = block|sprite, scale}", "return {", "    parts = {"]
    for base, pl in meta["parts"].items():
        lua.append("        %s = {" % base)
        for p in pl:
            lua.append("            {model = \"%s\", point = {%s}, rot = {%s}}," % (
                p["model"], ", ".join(fmt(v) for v in p["point"]), ", ".join(fmt(v) for v in p["rot"])))
        lua.append("        },")
    lua.append("    },")
    lua.append("    items = {")
    for iid in sorted(meta["items"]):
        m = meta["items"][iid]
        lua.append("        [%d] = {model = \"%s\", kind = \"%s\"%s}," % (
            iid, m["model"], m["kind"], ", scale = %s" % m["scale"] if "scale" in m else ""))
    lua.append("    },")
    lua.append("    font_widths = {[0] = %s}," % ", ".join(str(w) for w in meta["font_widths"]))
    lua.append("    vflip = %s," % ("true" if o.vflip else "false"))
    lua.append("}")
    with open(os.path.join(PACK, "modules", "models_table.lua"), "w", encoding="utf-8") as f:
        f.write("\n".join(lua) + "\n")
    # preload.json: the item models are only referenced from Lua (set_model) -> must be preloaded; the file is
    # shared with other generators (hand models, GUI textures) -> only our entries are added/refreshed
    pre_path = os.path.join(PACK, "preload.json")
    pre = {}
    if os.path.exists(pre_path):
        with open(pre_path, encoding="utf-8") as f:
            pre = json.load(f)
    mods = [m for m in pre.get("models", []) if not (isinstance(m, str) and m.startswith(("am_items", "am_shadow", "am_font")))]
    pre["models"] = mods + ["am_items", "am_shadow", "am_font"]
    # textures of preloaded models are not loaded with them (only skeleton models pull their textures)
    ours = ["entities/am_terrain", "entities/am_items", "entities/am_shadow", "entities/am_char", "entities/am_cart",
            "entities/am_boat", "entities/am_font"]
    pre["textures"] = [t for t in pre.get("textures", []) if t not in ours] + ours
    with open(pre_path, "w", encoding="utf-8") as f:
        json.dump(pre, f, indent=4, ensure_ascii=False)
        f.write("\n")
    print("gen_models: %d models, parts %s, items %d" % (count, {k: len(v) for k, v in meta["parts"].items()},
                                                          len(meta["items"])))
    for base, pl in meta["parts"].items():
        for p in pl:
            print("  %-16s %-22s box %s tex %s inflate %s mirror %s point %s rot %s" % (
                p["model"], p["java"], p["box"], p["tex"], p["inflate"], p["mirror"], p["point"],
                tuple(round(r, 6) for r in p["rot"])))


if __name__ == "__main__":
    main()
