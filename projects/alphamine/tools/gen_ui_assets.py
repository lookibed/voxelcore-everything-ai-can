#!/usr/bin/env python3
"""AlphaMine phase 3: UI assets of the pack (HUD, GUI screens, font, hand, particles) from D:\\Prog\\AlphaMine\\assets.

  python3 tools/alphamine/gen_ui_assets.py        # writes into content/alphamine

Outputs (all regenerated; sources are the jar assets extracted by extract_assets.py):
  textures/gui/am_gui.png, am_icons.png, am_items.png, am_terrain.png, am_char.png, am_particles.png
      the Alpha textures with the alpha test of the Java client applied (GL_ALPHA_TEST GREATER 0.1: alpha <= 25 -> 0)
      and RGB = 0 under alpha 0 (so that any blend mode sees nothing there)
  textures/font/am_default.png          default.png (8x8 glyphs, 16x16 grid), same processing
  textures/gui/crosshair.png            the engine crosshair (Hud::draw, BlendMode::inversion) replaced by the Alpha one:
      icons.png (0,0,16,16) at scale 2, padded to 64x64 so that the engine's centring ((854-64)/2, (480-64)/2) puts the
      icon at (412, 226) = GuiIngame (w/2-7, h/2-7)*2; other frame sizes are redrawn at runtime (hud.lua)
  textures/gui/am_menu_bg.png           1x480 column of GuiScreen.drawDefaultBackground (0xC0101010 -> 0xD0101010)
  textures/gui/am_icons3d/<id>.png      Java RenderItem.renderItemIntoGUI of 3D blocks (render types 0/10/13), software
      rasterised at GUI scale 2 (ortho, RenderHelper standard item lighting, GL_MODULATE, nearest texels)
  textures/gui/am_inventory.png         gui/inventory.png (GuiInventory background), same processing
  modules/ui_tables.lua                 font widths (FontRenderer: alpha-scan of the glyph columns), item icons
      (atlas + index or 3D icon offset/size), block particle tiles
"""
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pngio  # noqa: E402

VC_ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
PACK = os.path.join(VC_ROOT, "content", "alphamine")
ASSETS = "/mnt/d/Prog/AlphaMine/assets"
TABLES = "/mnt/d/Prog/AlphaMine/tables"


def read(path):
    with open(path, "rb") as f:
        return pngio.read_rgba(f.read())


def write(path, w, h, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(pngio.write_rgba(w, h, rows))


def alpha_test(rows, w):
    out = []
    for r in rows:
        r = bytearray(r)
        for x in range(w):
            if r[x * 4 + 3] <= 25:  # GL_GREATER 0.1: 25/255 = 0.098 fails, 26/255 = 0.102 passes
                r[x * 4:x * 4 + 4] = b"\x00\x00\x00\x00"
        out.append(r)
    return out


def copy_tested(src, dst):
    w, h, rows = read(os.path.join(ASSETS, src))
    write(os.path.join(PACK, "textures", dst), w, h, alpha_test(rows, w))
    return w, h, rows


# ------------------------------------------------------------------------------------------ font widths
def font_widths(rows, w):
    widths = []
    for ch in range(256):
        cx, cy = ch % 16, ch // 16
        col = 7
        while col >= 0:
            x = cx * 8 + col
            empty = True
            for yy in range(8):
                if rows[cy * 8 + yy][x * 4 + 2] > 0:
                    # Java: BufferedImage.getRGB() & 255 = blue channel (alpha is not looked at)
                    empty = False
                    break
            if not empty:
                break
            col -= 1
        if ch == 32:
            col = 2
        widths.append(col + 2)
    return widths


# ------------------------------------------------------------------------------------------ 3D item icons
def mat_mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def mat_t(x, y, z):
    return [[1, 0, 0, x], [0, 1, 0, y], [0, 0, 1, z], [0, 0, 0, 1]]


def mat_s(s):
    return [[s, 0, 0, 0], [0, s, 0, 0], [0, 0, s, 0], [0, 0, 0, 1]]


def mat_r(deg, x, y, z):
    a = math.radians(deg)
    c, s = math.cos(a), math.sin(a)
    n = math.sqrt(x * x + y * y + z * z)
    x, y, z = x / n, y / n, z / n
    return [[x * x * (1 - c) + c, x * y * (1 - c) - z * s, x * z * (1 - c) + y * s, 0],
            [y * x * (1 - c) + z * s, y * y * (1 - c) + c, y * z * (1 - c) - x * s, 0],
            [x * z * (1 - c) - y * s, y * z * (1 - c) + x * s, z * z * (1 - c) + c, 0],
            [0, 0, 0, 1]]


def apply(m, v):
    return [m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2] + m[i][3] for i in range(3)]


def apply3(m, v):
    return [m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2] for i in range(3)]


def norm(v):
    n = math.sqrt(sum(c * c for c in v))
    return [c / n for c in v]


def f32(x):
    import struct
    return struct.unpack("f", struct.pack("f", x))[0]


def item_lights():
    # RenderHelper.enableStandardItemLighting under glRotatef(180, 1, 0, 0) (GuiIngame): eye-space directions
    l0 = norm([f32(0.2), 1.0, f32(-0.7)])
    l1 = norm([f32(-0.2), 1.0, f32(0.7)])
    r = mat_r(180, 1, 0, 0)
    return [norm(apply3(r, l0)), norm(apply3(r, l1))]


def face_quads(bounds, tiles):
    """RenderBlocks.render{Bottom,Top,East,West,North,South}Face with block bounds -> [(normal, [(x,y,z,u,v)*4])]."""
    x0, y0, z0, x1, y1, z1 = bounds
    out = []

    def uv_base(tile):
        return (tile & 15) << 4, tile & 240

    # bottom (normal 0,-1,0): u over x, v over z
    tx, ty = uv_base(tiles[0])
    u0, u1 = (tx + x0 * 16) / 256, (tx + x1 * 16 - 0.01) / 256
    v0, v1 = (ty + z0 * 16) / 256, (ty + z1 * 16 - 0.01) / 256
    out.append(((0, -1, 0), [(x0, y0, z1, u0, v1), (x0, y0, z0, u0, v0), (x1, y0, z0, u1, v0), (x1, y0, z1, u1, v1)]))
    tx, ty = uv_base(tiles[1])
    u0, u1 = (tx + x0 * 16) / 256, (tx + x1 * 16 - 0.01) / 256
    v0, v1 = (ty + z0 * 16) / 256, (ty + z1 * 16 - 0.01) / 256
    out.append(((0, 1, 0), [(x1, y1, z1, u1, v1), (x1, y1, z0, u1, v0), (x0, y1, z0, u0, v0), (x0, y1, z1, u0, v1)]))
    # east (0,0,-1): u over x, v over y
    tx, ty = uv_base(tiles[2])
    u0, u1 = (tx + x0 * 16) / 256, (tx + x1 * 16 - 0.01) / 256
    v0, v1 = (ty + y0 * 16) / 256, (ty + y1 * 16 - 0.01) / 256
    out.append(((0, 0, -1), [(x0, y1, z0, u1, v0), (x1, y1, z0, u0, v0), (x1, y0, z0, u0, v1), (x0, y0, z0, u1, v1)]))
    tx, ty = uv_base(tiles[3])
    u0, u1 = (tx + x0 * 16) / 256, (tx + x1 * 16 - 0.01) / 256
    v0, v1 = (ty + y0 * 16) / 256, (ty + y1 * 16 - 0.01) / 256
    out.append(((0, 0, 1), [(x0, y1, z1, u0, v0), (x0, y0, z1, u0, v1), (x1, y0, z1, u1, v1), (x1, y1, z1, u1, v0)]))
    # north (-1,0,0): u over z, v over y
    tx, ty = uv_base(tiles[4])
    u0, u1 = (tx + z0 * 16) / 256, (tx + z1 * 16 - 0.01) / 256
    v0, v1 = (ty + y0 * 16) / 256, (ty + y1 * 16 - 0.01) / 256
    out.append(((-1, 0, 0), [(x0, y1, z1, u1, v0), (x0, y1, z0, u0, v0), (x0, y0, z0, u0, v1), (x0, y0, z1, u1, v1)]))
    tx, ty = uv_base(tiles[5])
    u0, u1 = (tx + z0 * 16) / 256, (tx + z1 * 16 - 0.01) / 256
    v0, v1 = (ty + y0 * 16) / 256, (ty + y1 * 16 - 0.01) / 256
    out.append(((1, 0, 0), [(x1, y0, z1, u0, v1), (x1, y0, z0, u1, v1), (x1, y1, z0, u1, v0), (x1, y1, z1, u0, v0)]))
    return out


MODULATE = os.environ.get("AM_MODULATE", "round")
SCALES = (1, 2, 3, 4)  # GUI scale factors (ScaledResolution): 854x480 -> 2, 1390x855 -> 3


def modulate(t, c):
    """GL_MODULATE of texel t (0..255) by the lit vertex colour c (0..1)."""
    if MODULATE == "round":
        return int(round(t * c))
    c8 = int(round(c * 255))
    if MODULATE == "c8round":
        return int(round(t * c8 / 255.0))
    if MODULATE == "c8floor":
        return (t * c8) // 255
    if MODULATE == "c8fl":
        c8 = int(c * 255)
        return (t * c8) // 255
    if MODULATE == "c8fr":
        c8 = int(c * 255)
        return int(round(t * c8 / 255.0))
    return int(t * c)


def edge(ax, ay, bx, by, px, py):
    return (bx - ax) * (py - ay) - (by - ay) * (px - ax)


def raster_icon(block, terrain, tw, sf=2):
    """RenderItem.renderItemIntoGUI for a 3D block at slot origin (0,0), GUI scale sf -> (x0, y0, w, h, rows)."""
    rt = block["render_type"]
    tiles = block["tiles_by_side"]
    parts = []
    if rt == 10:
        parts = [[0, 0, 0, 1, 1, 0.5], [0, 0, 0.5, 1, 0.5, 1]]
    else:
        b = list(block["bounds"])
        if block["id"] == 77:
            b = [0.5 - 3 / 16, 0.5 - 2 / 16, 0.5 - 2 / 16, 0.5 + 3 / 16, 0.5 + 2 / 16, 0.5 + 2 / 16]
        elif block["id"] in (70, 72):
            b = [0, 0.5 - 2 / 16, 0, 1, 0.5 + 2 / 16, 1]
        parts = [[f32(v) for v in b]]
    # modelview in GUI units (ortho 0..w, 0..h, y down); z ignored except for depth
    m = mat_mul(mat_t(-2, 3, 0), mat_s(10))
    m = mat_mul(m, mat_t(1, 0.5, 8))
    m = mat_mul(m, mat_r(210, 1, 0, 0))
    m = mat_mul(m, mat_r(45, 0, 1, 0))
    m = mat_mul(m, mat_t(-0.5, -0.5, -0.5))
    rot = mat_mul(mat_r(210, 1, 0, 0), mat_r(45, 0, 1, 0))
    lights = item_lights()
    quads = []
    for bounds in parts:
        for n, verts in face_quads(bounds, tiles):
            if rt == 13:
                pass  # cactus: faces inset by 1/16 (setTranslationF) -- handled below
            quads.append((n, verts))
    if rt == 13:
        # BlockCactus inventory: side faces translated inwards by 1/16 along their normal
        q2 = []
        for n, verts in quads:
            if n[1] == 0:
                d = 1 / 16
                verts = [(x - n[0] * d, y, z - n[2] * d, u, v) for (x, y, z, u, v) in verts]
            q2.append((n, verts))
        quads = q2
    color = {}
    depth = {}
    for n, verts in quads:
        en = norm(apply3(rot, n))
        c = 0.4
        for l in lights:
            c += 0.6 * max(0.0, sum(a * b for a, b in zip(en, l)))
        c = min(1.0, c)
        # the ±X faces (Tessellator.setNormal packs x*128 into a byte: +1 -> -128, so both are lit as -X) come out
        # at 0.50447 in the golden frames (fit over 2 icons, range 0.50439..0.50455), the float model gives 0.50503;
        # the GPU's lighting precision is the likely cause -- use the measured factor
        if abs(c - 0.505032) < 1e-4:
            c = 0.50447
        pts = []
        for (x, y, z, u, v) in verts:
            e = apply(m, (x, y, z))
            # GUI units -> pixels at scale factor 2; GL depth: larger eye z = nearer (camera looks -z)
            pts.append((e[0] * sf, e[1] * sf, e[2], u, v))
        for tri in ((0, 1, 2), (0, 2, 3)):
            a, b, cc = pts[tri[0]], pts[tri[1]], pts[tri[2]]
            area = edge(a[0], a[1], b[0], b[1], cc[0], cc[1])
            if abs(area) < 1e-12:
                continue
            xs = [a[0], b[0], cc[0]]
            ys = [a[1], b[1], cc[1]]
            for py in range(int(math.floor(min(ys))) - 1, int(math.ceil(max(ys))) + 1):
                for px in range(int(math.floor(min(xs))) - 1, int(math.ceil(max(xs))) + 1):
                    sx, sy = px + 0.5, py + 0.5
                    w0 = edge(b[0], b[1], cc[0], cc[1], sx, sy) / area
                    w1 = edge(cc[0], cc[1], a[0], a[1], sx, sy) / area
                    w2 = edge(a[0], a[1], b[0], b[1], sx, sy) / area
                    if w0 < -1e-9 or w1 < -1e-9 or w2 < -1e-9:
                        continue
                    z = w0 * a[2] + w1 * b[2] + w2 * cc[2]
                    if (px, py) in depth and depth[(px, py)] < z - 1e-9:
                        continue
                    u = w0 * a[3] + w1 * b[3] + w2 * cc[3]
                    v = w0 * a[4] + w1 * b[4] + w2 * cc[4]
                    tx = min(255, max(0, int(math.floor(u * 256))))
                    ty = min(255, max(0, int(math.floor(v * 256))))
                    p = terrain[ty][tx * 4:tx * 4 + 4]
                    if p[3] <= 25:
                        continue  # alpha test (discarded fragments write no depth)
                    depth[(px, py)] = z
                    color[(px, py)] = (modulate(p[0], c), modulate(p[1], c), modulate(p[2], c), p[3])
    if not color:
        return None
    x0 = min(p[0] for p in color)
    y0 = min(p[1] for p in color)
    x1 = max(p[0] for p in color)
    y1 = max(p[1] for p in color)
    w, h = x1 - x0 + 1, y1 - y0 + 1
    rows = [bytearray(w * 4) for _ in range(h)]
    for (px, py), c in color.items():
        rows[py - y0][(px - x0) * 4:(px - x0) * 4 + 4] = bytes(c)
    return x0, y0, w, h, rows



# ------------------------------------------------------------------------------------------ first-person models
# VCM models of the hand skeleton (skeletons/hand.json): every face is `shading off` and textured by a per-face
# key ($f ...) that modules/hand.lua binds to a canvas texture = source texels x the face's Java light
# (RenderHelper standard item lighting x world brightness), recomputed when the view changes. Canvas data rows are
# bottom-up (row 0 = bottom texel row), so v = 1 - (row from the top) / 16.
def f6(x):
    return ("%.6f" % x).rstrip("0").rstrip(".") if abs(x) > 1e-9 else "0"


def vcm_tri(a, b, c, uva, uvb, uvc, tex):
    return "@tri a (%s) b (%s) c (%s) uv (%s) texture \"%s\" shading off" % (
        ",".join(f6(v) for v in a), ",".join(f6(v) for v in b), ",".join(f6(v) for v in c),
        ",".join(f6(v) for v in (uva + uvb + uvc)), tex)


def vcm_quad(verts, uvs, tex):
    # GL quad (0,1,2,3) -> triangles (0,1,2), (0,2,3); same winding as Java (front = CCW)
    return [vcm_tri(verts[0], verts[1], verts[2], uvs[0], uvs[1], uvs[2], tex),
            vcm_tri(verts[0], verts[2], verts[3], uvs[0], uvs[2], uvs[3], tex)]


def gl_normal(n):
    """Tessellator.setNormal: bytes (int)(x*128), (int)(y*127), (int)(z*127) packed b0 | b1<<8 | b2<<16 (bytes are
    sign-extended before the OR) -> what glNormalPointer(GL_BYTE) sees, decoded by the OpenGL 1.x/2.x rule for
    normalized signed bytes (2b + 1) / 255 (0 -> 1/255, 127 -> 1, -127 -> -0.99216, -128 -> -1); GL_RESCALE_NORMAL keeps
    that length (no renormalisation). Measured on the GuiInventory player preview (inv_preview.lua, every face of the
    model: 99.9 %; b/127 gave 99.2 %). Other rules for experiments: AM_NORMAL_RULE=b127 (max(b/127, -1)), b128,
    h ((2b+1)/255 but 0 -> 0) -- the first-person item at pitch -60 prefers 0 -> 0 (u_swing 4_equip1 100 % vs 99.21 %),
    the preview prefers gl2: not resolved."""
    def sb(v):
        v &= 0xFF
        return v - 256 if v >= 128 else v
    b0, b1, b2 = sb(int(n[0] * 128.0)), sb(int(n[1] * 127.0)), sb(int(n[2] * 127.0))
    packed = (b0 | (b1 << 8) | (b2 << 16)) & 0xFFFFFFFF
    rule = os.environ.get("AM_NORMAL_RULE", "gl2")
    if rule == "b127":
        return [max(-1.0, sb(packed >> (8 * i)) / 127.0) for i in range(3)]
    if rule == "gl2":
        return [(2 * sb(packed >> (8 * i)) + 1) / 255.0 for i in range(3)]
    if rule == "b128":
        return [sb(packed >> (8 * i)) / 128.0 for i in range(3)]
    if rule == "h":
        return [(2 * sb(packed >> (8 * i)) + 1) / 255.0 if sb(packed >> (8 * i)) != 0 else 0.0 for i in range(3)]
    return [(2 * sb(packed >> (8 * i)) + 1) / 255.0 for i in range(3)]


def item_model():
    """ItemRenderer.renderItem (flat item): object space 0..1 x 0..1, z -1/16..0; classes f b x u d."""
    lines = []
    d = 1 / 16
    uv_of = lambda x, y: (1 - x, y)
    lines += vcm_quad([(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0)],
                      [uv_of(0, 0), uv_of(1, 0), uv_of(1, 1), uv_of(0, 1)], "$f")
    lines += vcm_quad([(0, 1, -d), (1, 1, -d), (1, 0, -d), (0, 0, -d)],
                      [uv_of(0, 1), uv_of(1, 1), uv_of(1, 0), uv_of(0, 0)], "$b")
    for k in range(16):
        x = k / 16
        u = (16 - k - 0.5) / 16
        lines += vcm_quad([(x, 0, -d), (x, 0, 0), (x, 1, 0), (x, 1, -d)], [(u, 0), (u, 0), (u, 1), (u, 1)], "$x")
        x = k / 16 + 1 / 16
        lines += vcm_quad([(x, 1, -d), (x, 1, 0), (x, 0, 0), (x, 0, -d)], [(u, 1), (u, 1), (u, 0), (u, 0)], "$x")
    for k in range(16):
        v = (k + 0.5) / 16
        y = k / 16 + 1 / 16
        lines += vcm_quad([(0, y, 0), (1, y, 0), (1, y, -d), (0, y, -d)], [(1, v), (0, v), (0, v), (1, v)], "$u")
        y = k / 16
        lines += vcm_quad([(1, y, 0), (0, y, 0), (0, y, -d), (1, y, -d)], [(0, v), (1, v), (1, v), (0, v)], "$d")
    normals = {"f": gl_normal((0, 0, 1)), "b": gl_normal((0, 0, -1)), "x": gl_normal((-1, 0, 0)),
               "u": gl_normal((0, 1, 0)), "d": gl_normal((0, -1, 0))}
    return "\n".join(lines) + "\n", normals


def block_model(block):
    """RenderBlocks.renderBlockOnInventory under glTranslatef(-0.5, -0.5, -0.5): faces $0..$5 (side order)."""
    rt = block["render_type"]
    if rt == 10:
        parts = [[0, 0, 0, 1, 1, 0.5], [0, 0, 0.5, 1, 0.5, 1]]
    else:
        b = list(block["bounds"])
        if block["id"] == 77:
            b = [0.5 - 3 / 16, 0.5 - 2 / 16, 0.5 - 2 / 16, 0.5 + 3 / 16, 0.5 + 2 / 16, 0.5 + 2 / 16]
        elif block["id"] in (70, 72):
            b = [0, 0.5 - 2 / 16, 0, 1, 0.5 + 2 / 16, 1]
        parts = [[f32(v) for v in b]]
    tiles = block["tiles_by_side"]
    lines = []
    for bounds in parts:
        for side, (n, verts) in enumerate(face_quads(bounds, [0] * 6)):
            if rt == 13 and n[1] == 0:
                verts = [(x - n[0] / 16, y, z - n[2] / 16, u, v) for (x, y, z, u, v) in verts]
            pos = [(x - 0.5, y - 0.5, z - 0.5) for (x, y, z, u, v) in verts]
            # tile 0 in face_quads -> u, v are tile-local /16 already (u*16 in 0..1)
            uvs = [(u * 16, 1 - v * 16) for (x, y, z, u, v) in verts]
            lines += vcm_quad(pos, uvs, "$%d" % side)
    normals = [gl_normal(n) for n in ((0, -1, 0), (0, 1, 0), (0, 0, -1), (0, 0, 1), (-1, 0, 0), (1, 0, 0))]
    return "\n".join(lines) + "\n", normals, tiles


def arm_model():
    """ModelBiped.bipedRightArm (texture offset 40,16; box -3,-2,-2 size 4x12x4) at scale 1/16, rotation point
    applied by the caller; UV into the 16x16 crop (40..56, 16..32) of char.png. Faces $0..$5 like ModelRenderer."""
    x0, y0, z0 = -3.0, -2.0, -2.0
    w, h, dd = 4, 12, 4
    x1, y1, z1 = x0 + w, y0 + h, z0 + dd
    c = [(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0), (x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)]
    ox, oy = 40, 16
    faces = [
        ([5, 1, 2, 6], ox + dd + w, oy + dd, ox + dd + w + dd, oy + dd + h),
        ([0, 4, 7, 3], ox + 0, oy + dd, ox + dd, oy + dd + h),
        ([5, 4, 0, 1], ox + dd, oy + 0, ox + dd + w, oy + dd),
        ([2, 3, 7, 6], ox + dd + w, oy + 0, ox + dd + w + w, oy + dd),
        ([1, 0, 3, 2], ox + dd, oy + dd, ox + dd + w, oy + dd + h),
        ([4, 5, 6, 7], ox + dd + w + dd, oy + dd, ox + dd + w + dd + w, oy + dd + h),
    ]
    lines = []
    normals = []
    e6, e7 = 0.0015625, 0.003125
    for k, (idx, u0, v0, u1, v1) in enumerate(faces):
        # TexturedQuad: vertex UVs (u1-e, v0+e), (u0+e, v0+e), (u0+e, v1-e), (u1-e, v1-e) in 64x32 texture units
        tuv = [(u1 / 64 - e6, v0 / 32 + e7), (u0 / 64 + e6, v0 / 32 + e7), (u0 / 64 + e6, v1 / 32 - e7),
               (u1 / 64 - e6, v1 / 32 - e7)]
        uvs = [((tu * 64 - 40) / 16, 1 - (tv * 32 - 16) / 16) for tu, tv in tuv]
        pos = [tuple(v / 16 for v in c[i]) for i in idx]
        lines += vcm_quad(pos, uvs, "$%d" % k)
        # TexturedQuad.draw: normal = normalize((v1 - v2) x (v1 - v0))
        p = [c[i] for i in idx]
        a = [p[1][j] - p[0][j] for j in range(3)]
        b = [p[1][j] - p[2][j] for j in range(3)]
        n = norm([b[1] * a[2] - b[2] * a[1], b[2] * a[0] - b[0] * a[2], b[0] * a[1] - b[1] * a[0]])
        normals.append(gl_normal([f32(v) for v in n]))
    return "\n".join(lines) + "\n", normals


def gen_hand(blocks):
    mdir = os.path.join(PACK, "models", "am_hand")
    if os.path.isdir(mdir):
        import shutil
        shutil.rmtree(mdir)
    os.makedirs(mdir)
    out = {}
    text, normals = item_model()
    open(os.path.join(mdir, "item.vcm"), "w").write(text)
    out["item"] = {"model": "am_hand/item", "normals": normals}
    text, normals = arm_model()
    open(os.path.join(mdir, "arm.vcm"), "w").write(text)
    out["arm"] = {"model": "am_hand/arm", "normals": normals}
    out["blocks"] = {}
    for bid, b in sorted(blocks.items()):
        if b["render_type"] in (0, 10, 13):
            text, normals, tiles = block_model(b)
            open(os.path.join(mdir, "b%d.vcm" % bid), "w").write(text)
            out["blocks"][bid] = {"model": "am_hand/b%d" % bid, "tiles": tiles}
    out["block_normals"] = normals
    return out


# ------------------------------------------------------------------------------------------ main
def lua_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, list):
        return "{" + ", ".join(lua_value(x) for x in v) + "}"
    if isinstance(v, dict):
        return "{" + ", ".join(("[%d] = %s" if isinstance(k, int) else "%s = %s") % (k, lua_value(x))
                               for k, x in v.items()) + "}"
    raise TypeError(v)



# ---------------------------------------------------------------------------------------------- GuiInventory player
def preview_tables(blocks, items):
    """ModelBiped (gen_models.py runs its constructor) as quads in the Java vertex order of ModelRenderer/TexturedQuad:
    per part {name, point (pixels), quads = {x1,y1,z1 .. x4,y4,z4 (blocks), u1,v1 .. u4,v4 (texture fractions, v from
    the top), nx, ny, nz (TexturedQuad.draw normal through Tessellator.setNormal bytes)}}, in ModelBiped.render order;
    plus bounds / render type of the 3D blocks (RenderBlocks.renderBlockOnInventory) for the held item."""
    import gen_models
    parts = {p["name"]: p for p in gen_models.run_models()["ModelBiped"]}
    names = [("bipedHead", "head"), ("bipedBody", "body"), ("bipedRightArm", "rarm"), ("bipedLeftArm", "larm"),
             ("bipedRightLeg", "rleg"), ("bipedLeftLeg", "lleg"), ("bipedHeadwear", "headwear")]
    out = []
    for jname, name in names:
        p = parts[jname]
        quads = []
        for verts, uvs in gen_models.box_quads(p):
            q = []
            for x, y, z in verts:
                q += [f32(f32(x) / 16.0), f32(f32(y) / 16.0), f32(f32(z) / 16.0)]
            for u, v in uvs:
                q += [f32(u), f32(v)]
            a = [verts[1][j] - verts[0][j] for j in range(3)]
            b = [verts[1][j] - verts[2][j] for j in range(3)]
            n = norm([b[1] * a[2] - b[2] * a[1], b[2] * a[0] - b[0] * a[2], b[0] * a[1] - b[1] * a[0]])
            q += gl_normal([f32(v) for v in n])
            quads.append(q)
        out.append({"name": name, "point": list(p["point"]), "quads": quads})
    blk = {}
    for bid, b in sorted(blocks.items()):
        if b["render_type"] in (0, 10, 13):
            rt = b["render_type"]
            if rt == 10:
                bparts = [[0, 0, 0, 1, 1, 0.5], [0, 0, 0.5, 1, 0.5, 1]]
            else:
                bb = list(b["bounds"])
                if bid == 77:
                    bb = [0.5 - 3 / 16, 0.5 - 2 / 16, 0.5 - 2 / 16, 0.5 + 3 / 16, 0.5 + 2 / 16, 0.5 + 2 / 16]
                elif bid in (70, 72):
                    bb = [0, 0.5 - 2 / 16, 0, 1, 0.5 + 2 / 16, 1]
                bparts = [[f32(v) for v in bb]]
            blk[bid] = {"rt": rt, "parts": bparts, "tiles": b["tiles_by_side"]}
    full3d = {it["id"]: True for it in items if it.get("full3d")}
    return {"biped": out, "blocks": blk, "full3d": full3d,
            "block_normals": [gl_normal(n) for n in ((0, -1, 0), (0, 1, 0), (0, 0, -1), (0, 0, 1), (-1, 0, 0), (1, 0, 0))],
            "item_normals": {"f": gl_normal((0, 0, 1)), "b": gl_normal((0, 0, -1)), "l": gl_normal((-1, 0, 0)),
                             "r": gl_normal((1, 0, 0)), "u": gl_normal((0, 1, 0)), "d": gl_normal((0, -1, 0))}}


def main():
    copy_tested("gui/gui.png", "gui/am_gui.png")
    iw, ih, icons = copy_tested("gui/icons.png", "gui/am_icons.png")
    copy_tested("gui/items.png", "gui/am_items.png")
    tw, th, terrain = copy_tested("terrain.png", "gui/am_terrain.png")
    copy_tested("char.png", "gui/am_char.png")
    copy_tested("particles.png", "gui/am_particles.png")
    copy_tested("gui/inventory.png", "gui/am_inventory.png")   # GuiInventory background (176x166 at 0,0)
    fw, fh, font = copy_tested("default.png", "font/am_default.png")
    widths = font_widths(font, fw)

    # GuiIngame.renderVignette: GL_ZERO, GL_ONE_MINUS_SRC_COLOR with colour c -> dst * (1 - lum * c); the same with
    # normal alpha blending of a black image whose alpha = lum (the element colour alpha carries c)
    vw_, vh_, vig = read(os.path.join(ASSETS, "misc", "vignette.png"))
    rows = []
    for y in range(vh_):
        r = bytearray(vw_ * 4)
        for x in range(vw_):
            r[x * 4 + 3] = vig[y][x * 4]
        rows.append(r)
    write(os.path.join(PACK, "textures", "gui", "am_vignette.png"), vw_, vh_, rows)

    # crosshair: 16x16 icon at scale 2 inside 64x64 at (17, 18): the engine centres the texture ((854-64)/2,
    # (480-64)/2) = (395, 208) -> icon at (412, 226) = GuiIngame (w/2-7, h/2-7)*2. Other frame sizes: hud.lua redraws
    # the texture through assets.to_canvas for the current ScaledResolution (1390x855: 48 px icon).
    W, H, OX, OY = 64, 64, 17, 18
    rows = [bytearray(W * 4) for _ in range(H)]
    for y in range(32):
        for x in range(32):
            p = icons[y // 2][(x // 2) * 4:(x // 2) * 4 + 4]
            if p[3] > 25:
                rows[OY + y][(OX + x) * 4:(OX + x) * 4 + 4] = bytes(p)
    write(os.path.join(PACK, "textures", "gui", "crosshair.png"), W, H, rows)

    # drawDefaultBackground over a world: gradient 0xC0101010 (top) -> 0xD0101010 (bottom) at 854x480, one alpha per
    # pixel row. The golden frames switch 12 -> 13 (over black) at row 226, i.e. the GPU's interpolated alpha is
    # a(y - 0.5) rounded to 8 bits (measured: layer_gui 0_menu); the engine then blends 16 * a8 / 255 the same way.
    rows = []
    for y in range(480):
        a8 = int(math.floor(0xC0 + (0xD0 - 0xC0) * (y - 0.5) / 480.0 + 0.5))
        rows.append(bytearray([16, 16, 16, max(0xC0, min(0xD0, a8))]))
    write(os.path.join(PACK, "textures", "gui", "am_menu_bg.png"), 1, 480, rows)

    with open(os.path.join(TABLES, "blocks.json"), encoding="utf-8") as f:
        blocks = {b["id"]: b for b in json.load(f)}
    with open(os.path.join(TABLES, "items.json"), encoding="utf-8") as f:
        items = json.load(f)
    icons_tab = {}
    icon_dir = os.path.join(PACK, "textures", "gui", "am_icons3d")
    if os.path.isdir(icon_dir):
        import shutil
        shutil.rmtree(icon_dir)
    rendered = {sf: [] for sf in SCALES}
    for it in items:
        iid = it["id"]
        b = blocks.get(iid) if iid < 256 else None
        if b and b["render_type"] in (0, 10, 13):
            ent = {}
            for sf in SCALES:
                r = raster_icon(b, terrain, tw, sf)
                if r:
                    rendered[sf].append((iid, r))
                    ent[sf] = r
            if ent:
                icons_tab[iid] = {"scales": ent}
                continue
        icons_tab[iid] = {"atlas": "gui/am_terrain" if iid < 256 else "gui/am_items", "index": it["icon_index"],
                          "max_damage": it.get("max_damage", 0) if iid >= 256 else 0}
    # one atlas texture per GUI scale: textures/gui/am_icons3d_s<sf>.png, 8 cells per row
    atlas_size = {}
    for sf in SCALES:
        cw = max(r[2] for _, r in rendered[sf])
        ch = max(r[3] for _, r in rendered[sf])
        cols = 8
        nrows = (len(rendered[sf]) + cols - 1) // cols
        aw, ah = cw * cols, ch * nrows
        rows = [bytearray(aw * 4) for _ in range(ah)]
        for k, (iid, (x0, y0, w, h, irows)) in enumerate(rendered[sf]):
            ax, ay = (k % cols) * cw, (k // cols) * ch
            for y in range(h):
                rows[ay + y][ax * 4:(ax + w) * 4] = irows[y]
            icons_tab[iid]["scales"][sf] = [x0, y0, w, h, ax, ay]
        write(os.path.join(PACK, "textures", "gui", "am_icons3d_s%d.png" % sf), aw, ah, rows)
        atlas_size[sf] = [aw, ah]
    # EntityDiggingFX: texture = Block.blockIndexInTexture, colour 0.6 x brightness (engine particles multiply by
    # the engine light) -> textures/particles/am_p<tile>.png = tile x 0.6 (particles atlas), sub-UV 1/4 by the engine
    pdir = os.path.join(PACK, "textures", "particles")
    if os.path.isdir(pdir):
        for f in os.listdir(pdir):
            if f.startswith("am_p") and f.endswith(".png"):
                os.remove(os.path.join(pdir, f))
    os.makedirs(pdir, exist_ok=True)
    # particles.png (128x128, 8x8 cells): EntitySmokeFX 7 (first frame), EntityFlameFX 48, EntityBubbleFX 32,
    # EntitySplashFX 19 -> textures/particles/am_fx_<kind>.png
    pw, ph, parts = read(os.path.join(ASSETS, "particles.png"))
    for kind, idx in (("smoke", 7), ("flame", 48), ("bubble", 32), ("splash", 19)):
        cx, cy = (idx % 16) * 8, (idx // 16) * 8
        rows = [bytearray(parts[cy + y][cx * 4:(cx + 8) * 4]) for y in range(8)]
        write(os.path.join(pdir, "am_fx_%s.png" % kind), 8, 8, alpha_test(rows, 8))
    particle_tiles = {}
    for bid, b in blocks.items():
        tile = b.get("block_index_in_texture", 0)
        bx0, by0 = (tile % 16) * 16, (tile // 16) * 16
        rows = []
        for y in range(16):
            r = bytearray(64)
            for x in range(16):
                p = terrain[by0 + y][(bx0 + x) * 4:(bx0 + x) * 4 + 4]
                if p[3] > 25:
                    r[x * 4:x * 4 + 4] = bytes([int(p[0] * 0.6 + 0.5), int(p[1] * 0.6 + 0.5), int(p[2] * 0.6 + 0.5), 255])
            rows.append(r)
        write(os.path.join(pdir, "am_p%d.png" % tile), 16, 16, rows)
        bnd = list(b["bounds"])
        particle_tiles[bid] = {"tex": "particles:am_p%d" % tile, "gravity": b.get("particle_gravity", 1.0),
                               "bounds": [f32(v) for v in bnd]}

    out = ["-- generated by tools/alphamine/gen_ui_assets.py -- do not edit",
           "local M = {}",
           "-- FontRenderer.charWidth[256] (alpha scan of default.png, space = 4)",
           "M.font_widths = " + lua_value(widths),
           "-- item id -> GUI icon: 3D blocks prerendered (pixel offset/size from the slot origin at scale 2),",
           "-- other items: atlas + icon index (16x16 tiles)",
           "M.icon_atlas = " + lua_value({sf: ["gui/am_icons3d_s%d" % sf] + atlas_size[sf] for sf in SCALES}),
           "M.icons = {"]
    for iid in sorted(icons_tab):
        out.append("  [%d] = %s," % (iid, lua_value(icons_tab[iid])))
    out.append("}")
    out.append("-- block id -> digging particles (EntityDiggingFX): particle texture, blockParticleGravity, bounds")
    out.append("M.block_fx = {")
    for bid in sorted(particle_tiles):
        out.append("  [%d] = %s," % (bid, lua_value(particle_tiles[bid])))
    out.append("}")
    hand = gen_hand(blocks)
    out.append("-- first-person models (models/am_hand/*.vcm) and the GL normals of their light classes (Tessellator bytes)")
    out.append("M.hand = " + lua_value({"item": hand["item"], "arm": hand["arm"], "block_normals": hand["block_normals"]}))
    out.append("M.hand_blocks = {")
    for bid in sorted(hand["blocks"]):
        out.append("  [%d] = %s," % (bid, lua_value(hand["blocks"][bid])))
    out.append("}")
    pv = preview_tables(blocks, items)
    out.append("-- GuiInventory player preview (modules/inv_preview.lua): ModelBiped quads, 3D block items, GL normals")
    out.append("M.preview = {")
    out.append("  biped = {")
    for part in pv["biped"]:
        out.append("    {name = %s, point = %s, quads = {" % (lua_value(part["name"]), lua_value(part["point"])))
        for q in part["quads"]:
            out.append("      " + lua_value(q) + ",")
        out.append("    }},")
    out.append("  },")
    out.append("  blocks = {")
    for bid in sorted(pv["blocks"]):
        out.append("    [%d] = %s," % (bid, lua_value(pv["blocks"][bid])))
    out.append("  },")
    out.append("  full3d = " + lua_value(pv["full3d"]) + ",   -- Item.isFull3D (RenderPlayer.renderSpecials)")
    out.append("  block_normals = " + lua_value(pv["block_normals"]) + ",")
    out.append("  item_normals = " + lua_value(pv["item_normals"]) + ",")
    out.append("}")
    out.append("return M")
    with open(os.path.join(PACK, "modules", "ui_tables.lua"), "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    print("font widths:", widths[32:127])
    print("icons: %d (%d 3D)" % (len(icons_tab), sum(1 for v in icons_tab.values() if "scales" in v)))


if __name__ == "__main__":
    main()
