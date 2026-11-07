"""Sample scene "walker" (object rig): an original blocky humanoid (head 8, body 8x12x4, limbs 4x12x4 texture pixels,
1.85 m) — empties as bones (body > head, arm_l, arm_r, leg_l, leg_r), a mesh box under each, a 64x64 skin packed
into the .blend (asymmetric: red band on the RIGHT sleeve, so a mirror shows), a walk cycle (frames 0-24) and an idle
(100-148), bezier keys. Timeline markers walk@0, _@24, idle@100, _@148 -> the exporter finds both animations.

  blender -b --factory-startup --python samples/walker.py -- <out_dir>      -> <out_dir>/walker.blend
  python3 -m vclab.model_ref.model_ref --blend <out_dir>/walker.blend       -> export + pixel compare

The reference of the model_ref tool: export == the hand-written VCM/VCA of the first version (to 1e-5), engine vs
Blender IoU >= 0.9999 on 72 frames.
"""
import math
import os
import struct
import sys
import zlib

import bpy
from mathutils import Matrix, Vector

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else os.path.join(os.path.dirname(__file__), "out")
os.makedirs(OUT, exist_ok=True)

PX = 1.85 / 32.0          # one texture pixel of the model in metres
TEX = 64
FPS = 24
ROOT_Y = -0.5             # entity origin convention (as the bench / voxelbench entity models): feet at y = -0.5

# ----------------------------------------------------------------------------------------------- skin (64x64)
SKIN, HAIR = (224, 172, 128), (92, 58, 30)
SHIRT, SHIRT_D = (38, 150, 140), (26, 110, 102)
PANTS, SHOES = (44, 58, 120), (80, 50, 28)
img = [[(255, 0, 255, 0)] * TEX for _ in range(TEX)]


def fill(x, y, w, h, c):
    for j in range(y, y + h):
        for i in range(x, x + w):
            img[j][i] = c + (255,) if len(c) == 3 else c


# box unwrap at (u, v) for size (w, h, d): top, bottom on the first row; +X, front(+Y), -X, back(-Y) on the second
def unwrap(u, v, w, h, d):
    return {"top": (u + d, v, w, d), "bottom": (u + d + w, v, w, d), "+x": (u, v + d, d, h),
            "+y": (u + d, v + d, w, h), "-x": (u + d + w, v + d, d, h), "-y": (u + 2 * d + w, v + d, w, h)}


PARTS = {   # name: (atlas u, v), size (w, h, d) in texture px, box min corner relative to the bone origin (px)
    "head": ((0, 0), (8, 8, 8), (-4, -4, 0)),
    "body": ((32, 0), (8, 12, 4), (-4, -2, 0)),
    "arm_r": ((32, 16), (4, 12, 4), (-2, -2, -10)),
    "arm_l": ((48, 16), (4, 12, 4), (-2, -2, -10)),
    "leg_r": ((0, 16), (4, 12, 4), (-2, -2, -12)),
    "leg_l": ((16, 16), (4, 12, 4), (-2, -2, -12)),
}
BONES = {   # name: (parent, rest location relative to the parent, px, Blender axes)
    "body": (None, (0, 0, 12)),
    "head": ("body", (0, 0, 12)),
    "arm_r": ("body", (6, 0, 10)),
    "arm_l": ("body", (-6, 0, 10)),
    "leg_r": ("body", (2, 0, 0)),
    "leg_l": ("body", (-2, 0, 0)),
}
ORDER = ["body", "head", "arm_r", "arm_l", "leg_r", "leg_l"]

for name, ((u, v), (w, h, d), _) in PARTS.items():
    f = unwrap(u, v, w, h, d)
    if name == "head":
        for k in f:
            fill(*f[k][:4], SKIN)
        fill(*f["top"], HAIR)
        for k in ("+x", "-x", "-y"):
            x, y, ww, hh = f[k]
            fill(x, y, ww, 3, HAIR)
        x, y, _, _ = f["+y"]
        fill(x, y, 8, 2, HAIR)                         # fringe
        fill(x + 1, y + 3, 2, 1, (250, 250, 250)); fill(x + 2, y + 3, 1, 1, (40, 70, 160))     # eyes
        fill(x + 5, y + 3, 2, 1, (250, 250, 250)); fill(x + 5, y + 3, 1, 1, (40, 70, 160))
        fill(x + 3, y + 4, 2, 1, (200, 140, 100))      # nose
        fill(x + 2, y + 6, 4, 1, (150, 60, 60))        # mouth
    elif name == "body":
        for k in f:
            fill(*f[k][:4], SHIRT)
        x, y, _, _ = f["+y"]
        fill(x + 3, y + 1, 2, 9, SHIRT_D)              # placket
        fill(x + 1, y + 2, 2, 2, (240, 200, 40))       # badge on the wearer's right (image left = +X = right)
        for k in ("+x", "+y", "-x", "-y"):
            x, y, ww, hh = f[k]
            fill(x, y + 10, ww, 2, (60, 40, 20))       # belt
    elif name.startswith("arm"):
        for k in f:
            fill(*f[k][:4], SKIN)
        fill(*f["top"], SHIRT)
        for k in ("+x", "+y", "-x", "-y"):
            x, y, ww, hh = f[k]
            fill(x, y, ww, 4, SHIRT)
            if name == "arm_r":
                fill(x, y + 4, ww, 1, (200, 30, 30))   # red band: right sleeve only
    else:
        for k in f:
            fill(*f[k][:4], PANTS)
        fill(*f["bottom"], SHOES)
        for k in ("+x", "+y", "-x", "-y"):
            x, y, ww, hh = f[k]
            fill(x, y + 10, ww, 2, SHOES)


def write_png(path):
    raw = b"".join(b"\x00" + b"".join(struct.pack("4B", *p) for p in row) for row in img)

    def chunk(t, data):
        return struct.pack(">I", len(data)) + t + data + struct.pack(">I", zlib.crc32(t + data) & 0xffffffff)
    with open(path, "wb") as fo:
        fo.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", TEX, TEX, 8, 6, 0, 0, 0)) +
                 chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


png_path = os.path.join(OUT, "walker.png")
write_png(png_path)

# ----------------------------------------------------------------------------------------------- scene
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.fps = FPS
image = bpy.data.images.load(png_path)
mat = bpy.data.materials.new("walker")
mat.use_nodes = True
nt = mat.node_tree
bsdf = nt.nodes["Principled BSDF"]
texn = nt.nodes.new("ShaderNodeTexImage")
texn.image = image
texn.interpolation = "Closest"
nt.links.new(texn.outputs["Color"], bsdf.inputs["Base Color"])
nt.links.new(texn.outputs["Alpha"], bsdf.inputs["Alpha"])

empties, faces_out = {}, {}
for name in ORDER:
    parent, loc = BONES[name]
    e = bpy.data.objects.new(name, None)
    scene.collection.objects.link(e)
    if parent:
        e.parent = empties[parent]
        e.matrix_parent_inverse = Matrix.Identity(4)
    e.location = Vector(loc) * PX
    e.rotation_mode = "ZYX"            # R = Rx @ Ry @ Rz: the engine's VCA rotation order XYZ
    empties[name] = e

for name in ORDER:
    (u, v), (w, h, d), mn = PARTS[name]
    size = Vector((w, d, h))           # Blender: x = width, y = depth, z = height
    lo = Vector(mn)
    c = lo + size / 2
    rects = unwrap(u, v, w, h, d)
    verts, polys, uvs = [], [], []
    for key, n, r, up in (("+y", (0, 1, 0), (-1, 0, 0), (0, 0, 1)), ("-y", (0, -1, 0), (1, 0, 0), (0, 0, 1)),
                          ("+x", (1, 0, 0), (0, 1, 0), (0, 0, 1)), ("-x", (-1, 0, 0), (0, -1, 0), (0, 0, 1)),
                          ("top", (0, 0, 1), (-1, 0, 0), (0, -1, 0)), ("bottom", (0, 0, -1), (-1, 0, 0), (0, 1, 0))):
        n, r, up = Vector(n), Vector(r), Vector(up)
        half = Vector((size.x / 2, size.y / 2, size.z / 2))
        hn = abs(n.dot(half)); hr = abs(r.dot(half)); hu = abs(up.dot(half))
        fc = c + n * hn
        rx, ry, rw, rh = rects[key]
        quad = []
        for s, t in ((-1, -1), (1, -1), (1, 1), (-1, 1)):        # CCW seen from outside
            p = fc + r * (s * hr) + up * (t * hu)
            quad.append(len(verts))
            verts.append(p * PX)
            uvs.append(((rx + (s + 1) / 2 * rw) / TEX, 1 - (ry + (1 - t) / 2 * rh) / TEX))
        polys.append(quad)
    me = bpy.data.meshes.new(name + "_mesh")
    me.from_pydata([tuple(p) for p in verts], [], polys)
    uvl = me.uv_layers.new(name="UVMap")
    for poly in me.polygons:
        for li in poly.loop_indices:
            uvl.data[li].uv = uvs[me.loops[li].vertex_index]
    me.materials.append(mat)
    ob = bpy.data.objects.new(name + "_geo", me)
    scene.collection.objects.link(ob)
    ob.parent = empties[name]
    ob.matrix_parent_inverse = Matrix.Identity(4)
    faces_out[name] = (verts, polys, uvs)


# ----------------------------------------------------------------------------------------------- animation
def key(name, frame, rot=None, loc=None):
    e = empties[name]
    if rot is not None:
        e.rotation_euler = [math.radians(a) for a in rot]
        e.keyframe_insert("rotation_euler", frame=frame)
    if loc is not None:
        e.location = Vector(BONES[name][1]) * PX + Vector(loc) * PX
        e.keyframe_insert("location", frame=frame)


ANIMS = {"walk": (0, 24), "idle": (100, 148)}
# walk, 1 s: contact (0, 12), passing (6, 18); +X rotation swings a limb forward (+Y)
SW, AS = 32, 28
for f, s in ((0, 1), (6, 0), (12, -1), (18, 0), (24, 1)):
    key("leg_l", f, rot=(SW * s, 0, 0)); key("leg_r", f, rot=(-SW * s, 0, 0))
    key("arm_l", f, rot=(-AS * s, 0, -3)); key("arm_r", f, rot=(AS * s, 0, 3))
    key("body", f, rot=(4, 0, -5 * s), loc=(0, 0, 0.0 if s else 0.6))      # lean, hip twist, bob up when passing
    key("head", f, rot=(-4 + (1.5 if s == 0 else 0), 0, 4 * s))           # counter-twist, small nod
# idle, 2 s: breathing, arms sway, a look around
for f, k in ((100, 0), (112, 1), (124, 0), (136, -1), (148, 0)):
    key("body", f, rot=(0, 0, 0), loc=(0, 0, 0.25 * abs(k)))
    key("arm_l", f, rot=(0, 2 * k, -4 - 2 * abs(k))); key("arm_r", f, rot=(0, -2 * k, 4 + 2 * abs(k)))
    key("leg_l", f, rot=(0, 0, 0)); key("leg_r", f, rot=(0, 0, 0))
    key("head", f, rot=(3 * abs(k), 0, 25 * k))
for e in empties.values():
    ad = e.animation_data
    if ad and ad.action:
        fcs = getattr(ad.action, "fcurves", None)
        if fcs is None:                                  # Blender 4.4+: layered actions
            fcs = [fc for layer in ad.action.layers for strip in layer.strips
                   for bag in strip.channelbags for fc in bag.fcurves]
        for fc in fcs:
            for kp in fc.keyframe_points:
                kp.interpolation = "BEZIER"
                kp.handle_left_type = kp.handle_right_type = "AUTO_CLAMPED"
            fc.update()




scene.frame_start, scene.frame_end = 0, 148
for name, f in (("walk", 0), ("_", 24), ("idle", 100), ("_end", 148)):
    scene.timeline_markers.new(name, frame=f)
image.pack()
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, "walker.blend"), compress=True)
print("walker sample: ->", os.path.join(OUT, "walker.blend"))
