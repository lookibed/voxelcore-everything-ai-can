"""Sample scene "critter" (armature rig): what the walker does not cover —
  - an Armature with bones in non-trivial rest orientation (the tail points backwards, the neck has a roll), the
    armature object itself rotated and moved (static);
  - a skinned mesh (Armature modifier, vertex groups: the tail, four boxes weighted rigidly to tail1..tail4) and a
    mesh weighted to the spine;
  - a mesh parented to a bone (the head, parent_type BONE);
  - an image texture packed in the .blend (body, head) and a material without a texture (tail: solid colour);
  - quaternion pose bones, two actions ("Wag", "Nod") instead of a timeline range.

  blender -b --factory-startup --python samples/critter.py -- <out_dir>     -> <out_dir>/critter.blend
  python3 -m vclab.model_ref.model_ref --blend <out_dir>/critter.blend --anim wag=@Wag --anim nod=@Nod
"""
import math
import os
import sys

import bpy
from mathutils import Euler, Matrix, Vector

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else os.path.join(os.path.dirname(__file__), "out")
os.makedirs(OUT, exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.fps = 24

# ------------------------------------------------------------------------------------------------ texture 32x32
T = 32
img = bpy.data.images.new("critter_skin", T, T, alpha=True)
px = []
for y in range(T):              # Blender rows: bottom first
    for x in range(T):
        if y >= 16:             # upper half: body fur, stripes
            c = (0.85, 0.55, 0.20) if (x // 4) % 2 == 0 else (0.65, 0.35, 0.10)
        elif x < 16:            # lower left: head, with "eyes"
            c = (0.95, 0.80, 0.55)
            if y in (10, 11) and x in (4, 5, 10, 11):
                c = (0.05, 0.05, 0.05)
            if y == 5 and 5 <= x <= 10:
                c = (0.7, 0.2, 0.2)
        else:                   # lower right: belly
            c = (1.0, 0.95, 0.85) if (x + y) % 2 else (0.9, 0.85, 0.7)
        px += [c[0], c[1], c[2], 1.0]
img.pixels = px
img.pack()


def material(name, image=None, color=None):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    if image:
        tn = nt.nodes.new("ShaderNodeTexImage")
        tn.image = image
        tn.interpolation = "Closest"
        nt.links.new(tn.outputs["Color"], bsdf.inputs["Base Color"])
    else:
        bsdf.inputs["Base Color"].default_value = color
    return m


M_SKIN = material("skin", img)
M_TAIL = material("tail", color=(0.15, 0.35, 0.75, 1.0))


def box(verts, faces, uvs, lo, hi, region, group=None, groups=None):
    """axis-aligned box lo..hi; every face gets the uv region (u0, v0, u1, v1); CCW from outside"""
    x0, y0, z0 = lo
    x1, y1, z1 = hi
    P = [(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0), (x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)]
    base = len(verts)
    verts += P
    u0, v0, u1, v1 = region
    for q in ((0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)):
        faces.append(tuple(base + i for i in q))
        uvs.append(((u0, v0), (u1, v0), (u1, v1), (u0, v1)))
    if groups is not None:
        groups.append((group, list(range(base, base + 8))))


def mesh_object(name, verts, faces, uvs, mat):
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    uvl = me.uv_layers.new(name="UVMap")
    for poly, quv in zip(me.polygons, uvs):
        for li, uv in zip(poly.loop_indices, quv):
            uvl.data[li].uv = uv
    me.materials.append(mat)
    ob = bpy.data.objects.new(name, me)
    scene.collection.objects.link(ob)
    return ob


# ------------------------------------------------------------------------------------------------ armature
arm_data = bpy.data.armatures.new("critter_rig")
arm = bpy.data.objects.new("critter", arm_data)
scene.collection.objects.link(arm)
arm.location = (0.3, -0.2, 0.0)
arm.rotation_euler = (0, 0, math.radians(15))
bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode="EDIT")
eb = arm_data.edit_bones
spine = eb.new("spine")
spine.head, spine.tail = (0, 0.25, 0.55), (0, -0.25, 0.55)      # points backwards (-Y)
neck = eb.new("neck")
neck.head, neck.tail = (0, 0.25, 0.65), (0, 0.45, 0.85)
neck.roll = math.radians(30)
neck.parent = spine
prev, y = spine, -0.25
for i in range(1, 5):
    b = eb.new("tail%d" % i)
    b.head, b.tail = (0, y, 0.6), (0, y - 0.18, 0.6 + 0.04 * i)
    b.parent = prev
    b.use_connect = False
    prev, y = b, y - 0.18
bpy.ops.object.mode_set(mode="OBJECT")

# body (skinned to spine), tail (4 boxes, skinned rigidly), legs as part of the body mesh
V, F, U, G = [], [], [], []
box(V, F, U, (-0.18, -0.28, 0.40), (0.18, 0.28, 0.72), (0, 0.5, 1, 1), "spine", G)
for sx in (-1, 1):
    for sy in (-1, 1):
        x, yy = 0.11 * sx, 0.18 * sy
        box(V, F, U, (x - 0.05, yy - 0.05, 0.0), (x + 0.05, yy + 0.05, 0.42), (0.5, 0, 1, 0.5), "spine", G)
body = mesh_object("body", V, F, U, M_SKIN)
V, F, U, TG = [], [], [], []
y = -0.25
for i in range(1, 5):
    w = 0.07 - 0.01 * i
    z = 0.6 + 0.04 * (i - 0.5)
    box(V, F, U, (-w, y - 0.18, z - w), (w, y, z + w), (0, 0, 1, 1), "tail%d" % i, TG)
    y -= 0.18
tail = mesh_object("tail", V, F, U, M_TAIL)
for ob, groups in ((body, G), (tail, TG)):
    ob.parent = arm
    ob.parent_type = "OBJECT"
    for gname, idx in groups:
        vg = ob.vertex_groups.get(gname) or ob.vertex_groups.new(name=gname)
        vg.add(idx, 1.0, "REPLACE")
    mod = ob.modifiers.new("Armature", "ARMATURE")
    mod.object = arm

# head: parented to the neck bone (rigid)
V, F, U = [], [], []
box(V, F, U, (-0.14, -0.12, -0.12), (0.14, 0.18, 0.14), (0, 0, 0.5, 0.5))
head = mesh_object("head", V, F, U, M_SKIN)
head.parent = arm
head.parent_type = "BONE"
head.parent_bone = "neck"
bpy.context.view_layer.update()
nb = arm.data.bones["neck"]
head.matrix_world = arm.matrix_world @ Matrix.Translation(nb.tail_local + Vector((0, 0.05, 0.02)))

# ------------------------------------------------------------------------------------------------ actions
pb = arm.pose.bones
for b in pb:
    b.rotation_mode = "QUATERNION"


def keyq(bone, frame, euler_deg):
    b = pb[bone]
    b.rotation_quaternion = Euler([math.radians(a) for a in euler_deg], "XYZ").to_quaternion()
    b.keyframe_insert("rotation_quaternion", frame=frame)


arm.animation_data_create()
wag = bpy.data.actions.new("Wag")
arm.animation_data.action = wag
for f, s in ((1, 0), (7, 1), (13, 0), (19, -1), (25, 0)):
    for i in range(1, 5):
        keyq("tail%d" % i, f, (0, 0, 14 * s * (1 + 0.3 * i)))
    keyq("spine", f, (0, 4 * s, 0))
    keyq("neck", f, (0, 0, 0))
nod = bpy.data.actions.new("Nod")
arm.animation_data.action = nod
for f, k in ((1, 0), (5, 1), (9, 0), (13, -1), (17, 0)):
    keyq("neck", f, (20 * k, 0, 10 * k))
    pb["spine"].location = (0, 0.03 * abs(k), 0)
    pb["spine"].keyframe_insert("location", frame=f)
    keyq("spine", f, (0, 0, 0))
    for i in range(1, 5):
        keyq("tail%d" % i, f, (25 * abs(k), 0, 0))
for act in (wag, nod):
    act.use_fake_user = True
arm.animation_data.action = wag
scene.frame_start, scene.frame_end = 1, 25
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, "critter.blend"), compress=True)
print("critter sample: ->", os.path.join(OUT, "critter.blend"))
