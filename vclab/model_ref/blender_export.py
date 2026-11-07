"""Blender -> VoxelCore exporter: any .blend -> VCM (named @bone tree, @tri with UVs) + PNG textures + VCA per animation.

  blender -b <file.blend> --python blender_export.py -- <job.json>
job = {"out": dir,                    # written: <name>.vcm, textures, <anim>.vca, export.json (+ <name>_poses.json)
       "name": "model",               # default: the .blend file name
       "anims": [{"name": "walk", "start": 0, "end": 24},       # frame range of the scene (end inclusive)
                 {"name": "run", "action": "Run"}],             # an action: put on the armature(s) / animated objects
                                      # none: timeline markers (a segment per marker up to the next one; markers
                                      # "_..." / "end" only end a segment) or the scene range, if animated
       "rest_frame": null,            # frame whose object transforms form the rest pose (default scene.frame_start)
       "rest": "identity",            # animated objects: rotation dropped from the rest ("frame": kept as at rest_frame)
       "root_y": -0.5,                # VoxelCore y of the Blender z = 0 plane (entity origin convention)
       "scale": 1.0,                  # Blender metres -> blocks
       "poses": false}                # + <name>_poses.json: every bone's pose per frame and half frame (VC axes)

Rigs: (1) object hierarchy — every animated object (empty, mesh, ...) is a bone, static meshes join the bone they
hang on; (2) armature — bones are bones; meshes parented to a bone are rigid, skinned meshes (Armature modifier) are
split per triangle by the dominant vertex group (VCM has no skinning: mixed weights are reported). Bones that carry
no geometry anywhere below are dropped. Engine conventions (VoxelCore 0.32, checked by tools model_ref):
VC (x, y, z) = (x, z, -y) of Blender; a bone's pose is translate(t) * Rx Ry Rz (VCA rotation order XYZ, degrees),
pivot = the bone origin; @bone move is relative to the parent bone, @tri points to the bone; triangle front = CCW;
tri uv = Blender uv. Every frame is baked (curve linear): Blender's interpolation is reproduced exactly at frames.
Materials: the image texture of the material (Base Color input preferred) -> PNG `$<i>`; no image -> a solid PNG of
the base colour (sRGB). Texture filtering in the engine is nearest."""
import json
import math
import os
import re
import struct
import sys
import zlib

import bpy
from mathutils import Matrix, Vector

job = json.load(open(sys.argv[sys.argv.index("--") + 1], encoding="utf-8"))
scene = bpy.context.scene
OUT = job["out"]
os.makedirs(OUT, exist_ok=True)
NAME = job.get("name") or os.path.splitext(os.path.basename(bpy.data.filepath))[0] or "model"
ROOT_Y = float(job.get("root_y", -0.5))
SCALE = float(job.get("scale", 1.0))
FPS = scene.render.fps / scene.render.fps_base
REST_FRAME = job.get("rest_frame")
REST_FRAME = scene.frame_start if REST_FRAME is None else int(REST_FRAME)
REST_MODE = job.get("rest", "identity")
WARN = []

# Blender world -> VC: C = T(0, root_y, 0) * S * P
P4 = Matrix(((1, 0, 0, 0), (0, 0, 1, 0), (0, -1, 0, 0), (0, 0, 0, 1)))
C = Matrix.Translation((0, ROOT_Y, 0)) @ Matrix.Diagonal((SCALE, SCALE, SCALE, 1)) @ P4
CI = C.inverted()


def fmt(x):
    s = ("%.5f" % x).rstrip("0").rstrip(".")
    return "0" if s in ("-0", "", "-") else s


def vec(v):
    return "(%s)" % ", ".join(fmt(c) for c in v)


def animated(o):
    ad = o.animation_data
    return bool(ad and (ad.action or len(ad.drivers) or len(ad.nla_tracks))) or len(o.constraints) > 0


# ------------------------------------------------------------------------------------------------ nodes (bones)
class Node:
    def __init__(self, name, parent, kind, obj, bone=None):
        self.name, self.parent, self.kind, self.obj, self.bone = name, parent, kind, obj, bone
        self.tris = []          # (world rest points x3, uv x3, texture index)
        self.keep = False


nodes, by_key, names = [], {}, set()


def unique(n):
    base, i = re.sub(r'[\s"]+', "_", n) or "bone", 1
    n = base
    while n in names:
        i += 1
        n = "%s_%d" % (base, i)
    names.add(n)
    return n


def node_for(key, make):
    if key not in by_key:
        by_key[key] = make()
        nodes.append(by_key[key])
    return by_key[key]


def obj_node(o):
    def make():
        parent = parent_node(o)
        return Node(unique(o.name), parent, "obj", o)
    return node_for(("o", o.name), make)


def bone_node(arm, bname):
    def make():
        b = arm.data.bones[bname]
        parent = bone_node(arm, b.parent.name) if b.parent else obj_node(arm)
        return Node(unique(bname), parent, "bone", arm, bname)
    return node_for(("b", arm.name, bname), make)


def parent_node(o):
    if not o.parent:
        return None
    if o.parent_type == "BONE" and o.parent.type == "ARMATURE" and o.parent_bone:
        return bone_node(o.parent, o.parent_bone)
    return obj_node(o.parent)


# ------------------------------------------------------------------------------------------------ world matrices
def world(n):
    """world matrix of a node at the current frame (Blender axes)"""
    if n.kind == "bone":
        return n.obj.matrix_world @ n.obj.pose.bones[n.bone].matrix
    return n.obj.matrix_world.copy()


REST = {}       # node or object key -> rest world matrix (Blender axes)


def parent_world_now(o):
    if o.parent and o.parent_type == "BONE" and o.parent.type == "ARMATURE" and o.parent_bone:
        return o.parent.matrix_world @ o.parent.pose.bones[o.parent_bone].matrix
    return o.parent.matrix_world if o.parent else Matrix.Identity(4)


def rest_obj(o):
    k = ("o", o.name)
    if k in REST:
        return REST[k]
    if o.parent and o.parent_type == "BONE" and o.parent.type == "ARMATURE" and o.parent_bone:
        pr = rest_bone(o.parent, o.parent_bone)
    else:
        pr = rest_obj(o.parent) if o.parent else Matrix.Identity(4)
    local = parent_world_now(o).inverted() @ o.matrix_world      # at REST_FRAME
    if REST_MODE == "identity" and animated(o) and o.type != "ARMATURE":
        t, _r, s = local.decompose()
        local = Matrix.Translation(t) @ Matrix.Diagonal((s.x, s.y, s.z, 1))
    REST[k] = pr @ local
    return REST[k]


def rest_bone(arm, bname):
    k = ("b", arm.name, bname)
    if k not in REST:
        REST[k] = rest_obj(arm) @ arm.data.bones[bname].matrix_local
    return REST[k]


def rest_of(n):
    return rest_bone(n.obj, n.bone) if n.kind == "bone" else rest_obj(n.obj)


# ------------------------------------------------------------------------------------------------ textures
TEXTURES, MAT_TEX, used_files = [], {}, set()


def srgb(c):
    c = max(0.0, min(1.0, c))
    return c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def write_png(path, w, h, rgba_rows):
    raw = b"".join(b"\x00" + bytes(row) for row in rgba_rows)

    def chunk(t, data):
        return struct.pack(">I", len(data)) + t + data + struct.pack(">I", zlib.crc32(t + data) & 0xffffffff)
    with open(path, "wb") as fo:
        fo.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) +
                 chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def file_name(base):
    base = re.sub(r"[^\w.-]+", "_", os.path.splitext(base)[0]) or "tex"
    n, i = base + ".png", 1
    while n in used_files:
        i += 1
        n = "%s_%d.png" % (base, i)
    used_files.add(n)
    return n


def save_image(img, path):
    """the image's stored texels -> PNG (byte images: exactly the file's bytes; no colour management)"""
    if not img.has_data and not img.packed_file:
        alt = os.path.join(os.path.dirname(bpy.data.filepath), os.path.basename(bpy.path.abspath(img.filepath)))
        if os.path.isfile(alt):
            img.filepath = alt
        img.reload()
    w, h = img.size
    if not w or not h:
        raise SystemExit("model_ref export: image %r has no data (file %s missing?)" % (img.name, img.filepath))
    px = img.pixels[:]
    rows = []
    for y in range(h - 1, -1, -1):                  # Blender: bottom row first
        row = px[y * w * 4:(y + 1) * w * 4]
        rows.append([max(0, min(255, int(round(v * 255)))) for v in row])
    write_png(path, w, h, rows)


def image_of(mat):
    if not (mat and mat.use_nodes and mat.node_tree):
        return None
    imgs = [n for n in mat.node_tree.nodes if n.type == "TEX_IMAGE" and n.image]
    for n in imgs:
        for link in n.outputs["Color"].links:
            if link.to_socket.name in ("Base Color", "Color"):
                return n.image
    return imgs[0].image if imgs else None


def base_color(mat):
    if mat and mat.use_nodes and mat.node_tree:
        for n in mat.node_tree.nodes:
            if n.type == "BSDF_PRINCIPLED":
                return tuple(n.inputs["Base Color"].default_value)
    return tuple(mat.diffuse_color) if mat else (0.8, 0.8, 0.8, 1.0)


def tex_index(mat):
    key = mat.name if mat else ""
    if key in MAT_TEX:
        return MAT_TEX[key]
    img = image_of(mat)
    if img is not None:
        same = next((i for i, t in enumerate(TEXTURES) if t.get("image") == img.name), None)
        if same is not None:
            MAT_TEX[key] = same
            TEXTURES[same]["materials"].append(key)
            return same
        fn = file_name(img.name)
        save_image(img, os.path.join(OUT, fn))
        TEXTURES.append({"file": fn, "image": img.name, "size": list(img.size), "materials": [key]})
    else:
        c = base_color(mat)
        px = [int(round(srgb(c[0]) * 255)), int(round(srgb(c[1]) * 255)), int(round(srgb(c[2]) * 255)),
              int(round(max(0, min(1, c[3])) * 255))]
        fn = file_name((key or "default") + "_color")
        write_png(os.path.join(OUT, fn), 2, 2, [px * 2, px * 2])
        TEXTURES.append({"file": fn, "color": px, "materials": [key]})
    MAT_TEX[key] = len(TEXTURES) - 1
    return MAT_TEX[key]


# ------------------------------------------------------------------------------------------------ geometry
def skin_armature(o):
    for m in o.modifiers:
        if m.type == "ARMATURE" and m.object and m.show_render:
            return m.object
    if o.parent and o.parent.type == "ARMATURE" and o.parent_type == "ARMATURE":
        return o.parent
    return None


scene.frame_set(REST_FRAME)
arms = [o for o in scene.objects if o.type == "ARMATURE"]
saved_pos = {a.name: a.data.pose_position for a in arms}
for a in arms:
    a.data.pose_position = "REST"
scene.frame_set(REST_FRAME)
dg = bpy.context.evaluated_depsgraph_get()
meshes = [o for o in scene.objects if o.type == "MESH" and not o.hide_render]
mixed = 0
for o in meshes:
    arm = skin_armature(o)          # skinned: triangles go to bones; unweighted ones and rigid meshes to `owner`
    owner = parent_node(o) if (o.parent and not animated(o)) else obj_node(o)
    ev = o.evaluated_get(dg)
    me = ev.to_mesh()
    me.calc_loop_triangles()
    W = rest_obj(o)
    uvl = me.uv_layers.active
    if uvl is None:
        WARN.append("%s: no UV map, uv = 0" % o.name)
    if me.shape_keys and me.shape_keys.animation_data:
        WARN.append("%s: animated shape keys are not exported (VCM has no morphs)" % o.name)
    gnames = {g.index: g.name for g in o.vertex_groups}
    for tri in me.loop_triangles:
        target = owner
        if arm is not None:
            acc = {}
            for vi in tri.vertices:
                for g in me.vertices[vi].groups:
                    bn = gnames.get(g.group)
                    if bn and bn in arm.data.bones and g.weight > 0:
                        acc[bn] = acc.get(bn, 0) + g.weight
            if acc:
                bn = max(acc, key=acc.get)
                target = bone_node(arm, bn)
                if len(acc) > 1 and sorted(acc.values())[-2] > 0.05 * acc[bn]:
                    mixed += 1
        slot = o.material_slots[tri.material_index].material if tri.material_index < len(o.material_slots) else None
        pts = [W @ me.vertices[vi].co for vi in tri.vertices]
        uv = [tuple(uvl.data[li].uv) if uvl else (0.0, 0.0) for li in tri.loops]
        target.tris.append((pts, uv, tex_index(slot)))
    ev.to_mesh_clear()
if mixed:
    WARN.append("%d triangles span several bones (smooth skinning): rigid per triangle in VCM, may tear when posed"
                % mixed)

# keep the nodes with geometry in their subtree; collapse static object nodes without geometry
for n in nodes:
    if n.tris:
        p = n
        while p:
            p.keep = True
            p = p.parent


def eng_parent(n):
    p = n.parent
    while p and (not p.keep or (p.kind == "obj" and not p.tris and not animated(p.obj))):
        p = p.parent
    return p


bones = [n for n in nodes if n.keep and not (n.kind == "obj" and not n.tris and not animated(n.obj))]
for n in bones:
    n.ep = eng_parent(n)
    n.rest = rest_of(n)
    n.h = (C @ n.rest).to_translation()                 # pivot, VC axes, entity space
if not bones:
    raise SystemExit("model_ref export: no visible mesh in the scene")
for n in bones:                                         # rest geometry of the bone in VC entity space: bbox, centroid
    pts = [(C @ p.to_4d()).to_3d() for tri in n.tris for p in tri[0]]
    if pts:
        lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
        hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
        n.cen = sum(pts, Vector((0, 0, 0))) / len(pts)
        n.corners = [Vector((x, y, z)) for x in (lo.x, hi.x) for y in (lo.y, hi.y) for z in (lo.z, hi.z)]
    else:
        n.cen, n.corners = n.h.copy(), []
BBOX = [[1e9] * 3, [-1e9] * 3]


def grow(p):
    for i in range(3):
        BBOX[0][i] = min(BBOX[0][i], p[i])
        BBOX[1][i] = max(BBOX[1][i], p[i])


for n in bones:
    for c in n.corners:
        grow(c)

# ------------------------------------------------------------------------------------------------ VCM
def vc_point(p):
    return (C @ p.to_4d()).to_3d()


def bone_block(n, indent):
    move = n.h - (n.ep.h if n.ep else Vector((0, 0, 0)))
    lines = ['%s@bone name "%s" move %s {' % (indent, n.name, vec(move))]
    for pts, uv, ti in n.tris:
        a, b, c = (vc_point(p) - n.h for p in pts)
        if (b - a).cross(c - a).length < 1e-12:
            continue
        lines.append('%s    @tri a %s b %s c %s uv (%s) texture "$%d"' % (
            indent, vec(a), vec(b), vec(c), ", ".join(fmt(x) for x in uv[0] + uv[1] + uv[2]), ti))
    for ch in bones:
        if ch.ep is n:
            lines += bone_block(ch, indent + "    ")
    lines.append(indent + "}")
    return lines


vcm_name = NAME + ".vcm"
with open(os.path.join(OUT, vcm_name), "w", newline="\n") as fo:
    fo.write("# %s: exported from %s by vclab/model_ref/blender_export.py (Blender %s)\n" % (
        NAME, os.path.basename(bpy.data.filepath), bpy.app.version_string))
    for n in bones:
        if n.ep is None:
            fo.write("\n".join(bone_block(n, "")) + "\n")

for a in arms:
    a.data.pose_position = saved_pos[a.name]


# ------------------------------------------------------------------------------------------------ animations
def deform_now():
    """per bone: its world transform now relative to the rest, VC entity space"""
    return {n.name: C @ world(n) @ n.rest.inverted() @ CI for n in bones}


def pose_now():
    """per bone: (translation, 3x3 rotation, scale) of the engine pose, VC axes"""
    D = deform_now()
    out = {}
    for n in bones:
        rel = D[n.ep.name].inverted() @ D[n.name] if n.ep else D[n.name]
        M = Matrix.Translation(-n.h) @ rel @ Matrix.Translation(n.h)
        t, q, s = M.decompose()
        out[n.name] = (t, q, s)
    return out


def anim_specs():
    specs = job.get("anims") or []
    if specs:
        return specs
    ms = sorted(scene.timeline_markers, key=lambda m: m.frame)     # a marker "_..." / "end" only ends a segment
    if ms:
        return [{"name": m.name, "start": m.frame, "end": (ms[i + 1].frame if i + 1 < len(ms) else scene.frame_end)}
                for i, m in enumerate(ms) if not (m.name.startswith("_") or m.name.lower() == "end")]
    if any(animated(o) for o in scene.objects):
        return [{"name": "anim", "start": scene.frame_start, "end": scene.frame_end}]
    return []


def use_action(name):
    act = bpy.data.actions.get(name)
    if act is None:
        raise SystemExit("model_ref export: no action %r (have %s)" % (name, [a.name for a in bpy.data.actions]))
    targets = arms or [o for o in scene.objects if o.animation_data and o.animation_data.action]
    for o in targets:
        ad = o.animation_data or o.animation_data_create()
        ad.action = act
        if hasattr(ad, "action_slot") and ad.action_slot is None and getattr(ad, "action_suitable_slots", None):
            ad.action_slot = ad.action_suitable_slots[0]
    fr = act.frame_range
    return int(round(fr[0])), int(round(fr[1]))


def safe(n):
    return re.sub(r"[^\w.-]+", "_", n) or "anim"


anims_out, poses, TRACK = {}, {}, {}
for spec in anim_specs():
    name = safe(spec["name"])
    if spec.get("action"):
        start, end = use_action(spec["action"])
        start, end = spec.get("start", start), spec.get("end", end)
    else:
        start, end = int(spec["start"]), int(spec["end"])
    chans = {n.name: {"t": [], "r": [], "s": []} for n in bones}
    prev = {}
    samples = []
    pts_frames = []
    for fi in range(start, end + 1):
        for sub in ((0.0, 0.5) if (job.get("poses") and fi < end) else (0.0,)):
            scene.frame_set(fi, subframe=sub)
            ps = pose_now()
            if sub == 0.0:                               # where every bone is (pivot, geometry centre) + the bbox
                D = deform_now()
                row = []
                for n in bones:
                    d = D[n.name]
                    pv, cn = d @ n.h, d @ n.cen
                    row.append([round(x, 4) for x in tuple(pv) + tuple(cn)])
                    for c in n.corners:
                        grow(d @ c)
                pts_frames.append(row)
            rec = {"t": round((fi - start + sub) / FPS, 6), "bones": {}}
            for bn, (t, q, s) in ps.items():
                if sub == 0.0:
                    eu = q.to_matrix().to_euler("ZYX", prev[bn]) if bn in prev else q.to_matrix().to_euler("ZYX")
                    prev[bn] = eu
                    chans[bn]["t"].append(tuple(t))
                    chans[bn]["r"].append([math.degrees(x) for x in eu])
                    chans[bn]["s"].append(tuple(s))
                rec["bones"][bn] = {"t": [round(x, 6) for x in t], "q": [round(x, 7) for x in (q.w, q.x, q.y, q.z)]}
            samples.append(rec)
    dur = (end - start) / FPS
    lines = ["@configure fps %s duration %s" % (fmt(FPS), fmt(dur)), ""]
    for n in bones:
        d = chans[n.name]
        for ch, vals, rest in (("move", d["t"], 0.0), ("rotate", d["r"], 0.0), ("scale", d["s"], 1.0)):
            for ai, ax in enumerate("xyz"):
                col = [v[ai] for v in vals]
                if max(abs(x - rest) for x in col) < 1e-6:
                    continue
                if ch == "scale":
                    WARN.append("%s: scale animated on bone %s (engine order T*R*S assumed)" % (name, n.name))
                lines.append("@%s bone %s by %s curve linear {" % (ch, n.name, ax))
                lines += ["    @key frame %d value %s" % (i, fmt(x)) for i, x in enumerate(col)]
                lines += ["}", ""]
    fn = name + ".vca"
    with open(os.path.join(OUT, fn), "w", newline="\n") as fo:
        fo.write("\n".join(lines).rstrip() + "\n")
    anims_out[name] = {"file": fn, "start": start, "end": end, "fps": FPS, "duration": dur, "keys": end - start + 1,
                       "action": spec.get("action")}
    poses[name] = {"duration": dur, "samples": samples}
    TRACK[name] = pts_frames

if job.get("poses"):
    with open(os.path.join(OUT, NAME + "_poses.json"), "w", newline="\n") as fo:
        json.dump({"version": 1, "fps": FPS, "units": {"move": "blocks", "rotate": "deg"}, "rotation_order": "XYZ",
                   "bones": [n.name for n in bones], "anims": poses}, fo, indent=0)

# model_ref: bone pivots / geometry centres per frame (which bone a pixel difference belongs to) and the bbox over all
# frames (the camera framing), VC entity space
TRACK["_rest"] = [[[round(x, 4) for x in tuple(n.h) + tuple(n.cen)] for n in bones]]
with open(os.path.join(OUT, "track.json"), "w", newline="\n") as fo:
    json.dump({"bones": [n.name for n in bones], "points": "pivot xyz, geometry centre xyz", "anims": TRACK,
               "bbox": BBOX}, fo)

manifest = {"name": NAME, "source": bpy.data.filepath, "blender": bpy.app.version_string, "vcm": vcm_name,
            "textures": [dict(t, slot="$%d" % i) for i, t in enumerate(TEXTURES)], "anims": anims_out,
            "bones": [{"name": n.name, "parent": n.ep.name if n.ep else None, "kind": n.kind,
                       "tris": len(n.tris), "pivot": [round(x, 5) for x in n.h]} for n in bones],
            "root_y": ROOT_Y, "scale": SCALE, "rest_frame": REST_FRAME, "rest": REST_MODE, "fps": FPS,
            "tris": sum(len(n.tris) for n in bones), "bbox": [[round(x, 4) for x in v] for v in BBOX],
            "warnings": WARN}
with open(os.path.join(OUT, "export.json"), "w", newline="\n") as fo:
    json.dump(manifest, fo, indent=1)
print("model_ref export: %s -> %s (%d bones, %d tris, %d textures, anims %s)%s" % (
    os.path.basename(bpy.data.filepath), OUT, len(bones), manifest["tris"], len(TEXTURES), list(anims_out),
    "".join("\n  warning: " + w for w in WARN)))
