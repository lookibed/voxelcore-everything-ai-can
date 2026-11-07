"""model_ref, Blender side: render frames of a .blend with the camera of the engine stand, for a pixel compare.
Default "vc" shading: as the engine draws a model with fullbright light — texel * (0.8 + 0.2 * dot(face normal, SUN))
(ModelBatch::draw), no gamma: Cycles emission, 1 sample, no pixel filter, raw view transform. "flat": the texel only
(Workbench FLAT). Transparent film (alpha = the silhouette), no anti-aliasing (the engine frame has none).

  blender -b <file.blend> --python blender_frames.py -- <job.json>
job = {"out": dir, "w": 854, "h": 480, "cam": {"pos": [x,y,z], "target": [x,y,z], "fov": deg},   # VoxelCore axes
                                           # (a frame may carry its own "cam"),
       "root_y": -0.5,                     # relative to the entity: VC y of the Blender z = 0 plane
       "frames": [{"name": "walk_000", "frame": 0, "subframe": 0.0, "action": null}, ...]}   # action: put on first
VoxelCore (x, y, z) -> Blender (x, -z, y - root_y)."""
import json
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

def srgb(c):
    c = max(0.0, min(1.0, c))
    return c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def image_node(mat):                      # the same choice as blender_export.image_of
    if not (mat and mat.use_nodes and mat.node_tree):
        return None
    imgs = [n for n in mat.node_tree.nodes if n.type == "TEX_IMAGE" and n.image]
    for n in imgs:
        for link in n.outputs["Color"].links:
            if link.to_socket.name in ("Base Color", "Color"):
                return n
    return imgs[0] if imgs else None


def base_color(mat):
    if mat.use_nodes and mat.node_tree:
        for n in mat.node_tree.nodes:
            if n.type == "BSDF_PRINCIPLED":
                return tuple(n.inputs["Base Color"].default_value)
    return tuple(mat.diffuse_color)


job = json.load(open(sys.argv[sys.argv.index("--") + 1], encoding="utf-8"))
scene = bpy.context.scene
root_y = job.get("root_y", -0.5)


def b(v):
    return Vector((v[0], -v[2], v[1] - root_y))


cam = bpy.data.objects.new("model_ref_cam", bpy.data.cameras.new("model_ref_cam"))
scene.collection.objects.link(cam)
cam.data.sensor_fit = "VERTICAL"
cam.data.clip_start, cam.data.clip_end = 0.05, 2000


def set_cam(c):
    cam.location = b(c["pos"])
    cam.rotation_euler = (b(c["target"]) - cam.location).to_track_quat("-Z", "Y").to_euler()
    cam.data.angle_y = math.radians(c["fov"])


set_cam(job["cam"])
scene.camera = cam
r = scene.render
SUN = Vector((0.411934, 0.863868, -0.279161))         # ModelBatch::SUN_VECTOR (VoxelCore 0.32)
vc_shading = job.get("shading", "vc") == "vc"
meshes = [o for o in scene.objects if o.type == "MESH" and not o.hide_render]
for o in scene.objects:                               # only the model: no lights, no other cameras in the way
    if o.type in ("LIGHT", "CAMERA") and o is not cam:
        o.hide_render = True
for o in meshes:                                      # raw texels: no sRGB decode / view transform (engine: no gamma)
    for slot in o.material_slots:
        if slot.material and slot.material.use_nodes:
            for n in slot.material.node_tree.nodes:
                if n.type == "TEX_IMAGE" and n.image:
                    n.image.colorspace_settings.name = "Non-Color"
                    n.interpolation = "Closest"
            slot.material.use_backface_culling = True       # Workbench ("flat"); "vc": Backfacing in the shader
if vc_shading:
    # the engine's model shading: colour = texel * (0.8 + 0.2 * dot(world normal, SUN)) per face (ModelBatch::draw,
    # mesh.shading on: the VCM default) -> Cycles, emission = texture * per-face factor, 1 sample, no pixel filter
    r.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = 1
    scene.cycles.use_denoising = False
    scene.cycles.pixel_filter_type = "BOX"
    scene.cycles.filter_width = 0.01
    scene.cycles.max_bounces = 0
    done = set()
    for o in meshes:
        me = o.data
        if "vc_shade" not in me.color_attributes:
            me.color_attributes.new("vc_shade", "FLOAT_COLOR", "CORNER")
        for slot in o.material_slots:
            m = slot.material
            if not m or m.name in done:
                continue
            done.add(m.name)
            m.use_nodes = True
            nt = m.node_tree
            img = image_node(m)
            out = next((n for n in nt.nodes if n.type == "OUTPUT_MATERIAL"), None) or nt.nodes.new("ShaderNodeOutputMaterial")
            if img is None:                       # no texture: the exporter writes a solid PNG of the sRGB base colour
                bc = base_color(m)
                rgb = nt.nodes.new("ShaderNodeRGB")
                rgb.outputs[0].default_value = (srgb(bc[0]), srgb(bc[1]), srgb(bc[2]), 1.0)
                alpha = nt.nodes.new("ShaderNodeValue")
                alpha.outputs[0].default_value = bc[3]
                col_out, alpha_out = rgb.outputs[0], alpha.outputs[0]
            else:
                col_out, alpha_out = img.outputs["Color"], img.outputs["Alpha"]
            att = nt.nodes.new("ShaderNodeAttribute")
            att.attribute_name = "vc_shade"
            mul = nt.nodes.new("ShaderNodeMixRGB")
            mul.blend_type = "MULTIPLY"
            mul.inputs[0].default_value = 1.0
            nt.links.new(col_out, mul.inputs[1])
            nt.links.new(att.outputs["Color"], mul.inputs[2])
            em = nt.nodes.new("ShaderNodeEmission")
            nt.links.new(mul.outputs[0], em.inputs["Color"])
            tr = nt.nodes.new("ShaderNodeBsdfTransparent")
            mix = nt.nodes.new("ShaderNodeMixShader")
            geo = nt.nodes.new("ShaderNodeNewGeometry")         # the engine culls back faces
            front = nt.nodes.new("ShaderNodeMath")
            front.operation = "SUBTRACT"
            front.inputs[0].default_value = 1.0
            nt.links.new(geo.outputs["Backfacing"], front.inputs[1])
            vis = nt.nodes.new("ShaderNodeMath")
            vis.operation = "MULTIPLY"
            nt.links.new(alpha_out, vis.inputs[0])
            nt.links.new(front.outputs[0], vis.inputs[1])
            nt.links.new(vis.outputs[0], mix.inputs[0])
            nt.links.new(tr.outputs[0], mix.inputs[1])
            nt.links.new(em.outputs[0], mix.inputs[2])
            nt.links.new(mix.outputs[0], out.inputs["Surface"])


def shade_faces():
    """per-face shade factor from the face normal as posed (skinned meshes: the deformed mesh) in world space"""
    dg = bpy.context.evaluated_depsgraph_get()
    for o in meshes:
        me = o.data
        ev = o.evaluated_get(dg)
        em = ev.to_mesh()
        src = em if len(em.polygons) == len(me.polygons) else me      # topology modifiers: rest normals (approx.)
        rot = ev.matrix_world.to_3x3()
        att = me.color_attributes["vc_shade"]
        for poly, sp in zip(me.polygons, src.polygons):
            n = (rot @ sp.normal).normalized()
            d = 0.8 + 0.2 * Vector((n.x, n.z, -n.y)).dot(SUN)
            for li in poly.loop_indices:
                att.data[li].color = (d, d, d, 1.0)
        ev.to_mesh_clear()
        me.update()


if not vc_shading:
    r.engine = "BLENDER_WORKBENCH"
r.resolution_x, r.resolution_y, r.resolution_percentage = job.get("w", 854), job.get("h", 480), 100
r.film_transparent = True
r.image_settings.file_format = "PNG"
r.image_settings.color_mode = "RGBA"
scene.display.render_aa = "OFF"
sh = scene.display.shading
sh.light = "FLAT"
sh.color_type = "TEXTURE"
sh.show_shadows = False
sh.show_cavity = False
sh.show_object_outline = False
sh.show_specular_highlight = False
sh.show_backface_culling = True
scene.view_settings.view_transform = "Raw"
scene.view_settings.look = "None"
scene.view_settings.exposure = 0
scene.view_settings.gamma = 1
os.makedirs(job["out"], exist_ok=True)
INITIAL = {o.name: o.matrix_basis.copy() for o in bpy.context.scene.objects}


def reset_unkeyed():
    """before another action: channels it does not key go back to the rest (pose bones) / the stored value (objects),
    as the engine resets the pose before a track — otherwise they keep the previous action's last value"""
    for o in bpy.context.scene.objects:
        if o.type == "ARMATURE":
            for pb in o.pose.bones:
                pb.matrix_basis = Matrix.Identity(4)
        if o.animation_data and o.name in INITIAL:
            o.matrix_basis = INITIAL[o.name]


def use_action(name):                     # as blender_export.use_action
    reset_unkeyed()
    act = bpy.data.actions[name]
    arms = [o for o in scene.objects if o.type == "ARMATURE"]
    for o in arms or [o for o in scene.objects if o.animation_data and o.animation_data.action]:
        ad = o.animation_data or o.animation_data_create()
        ad.action = act
        if hasattr(ad, "action_slot") and ad.action_slot is None and getattr(ad, "action_suitable_slots", None):
            ad.action_slot = ad.action_suitable_slots[0]


def build_nla(nla):
    """animation states as NLA strips (states test): two tracks taking turns; a switch = the incoming strip on the
    upper track ramps its influence 0 -> 1, or the outgoing one on the upper track ramps 1 -> 0, over the fade; the
    ramp is smoothstep (bezier keys with handles at thirds = 3u^2 - 2u^3), as the engine side. REPLACE blending:
    every channel = lerp(lower, upper, influence)."""
    arms = [o for o in scene.objects if o.type == "ARMATURE"]
    base = {o.name: o.animation_data.action for o in scene.objects if o.animation_data and o.animation_data.action}
    states = nla["states"]
    owners = set(base)
    if any(st.get("action") for st in states):
        owners |= {o.name for o in arms} if arms else set(base)
    strips = {}
    for on in owners:
        o = scene.objects[on]
        ad = o.animation_data or o.animation_data_create()
        for t in list(ad.nla_tracks):
            t.mute = True
        ad.action = None
        tracks = [ad.nla_tracks.new(), ad.nla_tracks.new()]          # [lower, upper]
        for i, st in enumerate(states):
            act = bpy.data.actions[st["action"]] if st.get("action") else base.get(on)
            if act is None or (st.get("action") and arms and o.type != "ARMATURE"):
                continue
            sp = tracks[i % 2].strips.new("state%d" % i, int(st["start"]), act)
            sp.action_frame_start, sp.action_frame_end = st["a0"], st["a1"]
            sp.blend_type = "REPLACE"
            sp.extrapolation = "NOTHING"
            sp.use_sync_length = False
            sp.repeat = max(0.01, (st["until"] - st["start"]) / max(1e-6, st["a1"] - st["a0"]))
            strips[(on, i)] = sp

    def ramp(sp, f0, f1, v0, v1):
        if not sp.use_animated_influence:
            sp.use_animated_influence = True
        for f, v in ((f0, v0), (f1, v1)):
            sp.influence = v
            sp.keyframe_insert("influence", frame=f)
        fc = sp.fcurves.find("influence")
        for k in fc.keyframe_points:
            k.interpolation = "BEZIER"
            k.handle_left_type = k.handle_right_type = "FREE"
        d = (f1 - f0) / 3
        for k in fc.keyframe_points:
            if abs(k.co[0] - f0) < 1e-6 or abs(k.co[0] - f1) < 1e-6:
                k.handle_left = (k.co[0] - d, k.co[1])
                k.handle_right = (k.co[0] + d, k.co[1])
        fc.extrapolation = "CONSTANT"
        fc.update()

    for (on, i), sp in strips.items():
        if i % 2 == 1:
            sp.use_animated_influence = True
            sp.influence = 1.0
    for i in range(1, len(states)):
        f0 = states[i]["start"]
        f1 = f0 + max(1e-3, states[i]["fade"])
        for on in owners:
            if i % 2 == 1 and (on, i) in strips:                 # incoming on the upper track: 0 -> 1
                ramp(strips[(on, i)], f0, f1, 0.0, 1.0)
            elif i % 2 == 0 and (on, i - 1) in strips:           # outgoing on the upper track: 1 -> 0
                ramp(strips[(on, i - 1)], f0, f1, 1.0, 0.0)


SAVED = {o.name: o.animation_data.action for o in scene.objects if o.animation_data and o.animation_data.action}


def layer_basis(layer):
    """the local transforms (objects and pose bones) of one animation state at its own frame"""
    reset_unkeyed()
    for on, act in SAVED.items():
        scene.objects[on].animation_data.action = act
    if layer.get("action"):
        use_action(layer["action"])
    f = layer["frame"]
    scene.frame_set(int(math.floor(f)), subframe=f - math.floor(f))
    out = {}
    for o in scene.objects:
        if o.animation_data and o.animation_data.action:
            out[("o", o.name)] = o.matrix_basis.copy()
        if o.type == "ARMATURE":
            for pb in o.pose.bones:
                out[("b", o.name, pb.name)] = pb.matrix_basis.copy()
    return out


def blend_states(layers):
    """states test, reference "slerp": the engine's crossfade (Olife client) on Blender's own local transforms —
    rotation slerp, location / scale lerp, weight w of the second layer — then the animation off and the result set"""
    a = layer_basis(layers[0])
    res = a
    if len(layers) > 1:
        b = layer_basis(layers[1])
        w = layers[1]["w"]
        res = {}
        for k, ma in a.items():
            mb = b.get(k, ma)
            ta, ra, sa = ma.decompose()
            tb, rb, sb = mb.decompose()
            if ra.dot(rb) < 0:                                 # the shortest arc, as glm::slerp
                rb.negate()
            res[k] = Matrix.LocRotScale(ta.lerp(tb, w), ra.slerp(rb, w), sa.lerp(sb, w))
    for o in scene.objects:
        if o.animation_data:
            o.animation_data.action = None
    for k, m in res.items():
        if k[0] == "o":
            scene.objects[k[1]].matrix_basis = m
        else:
            scene.objects[k[1]].pose.bones[k[2]].matrix_basis = m
    bpy.context.view_layer.update()


if job.get("nla"):
    build_nla(job["nla"])
cur_action = None
for fr in job["frames"]:
    if fr.get("blend"):
        set_cam(fr.get("cam") or job["cam"])
        blend_states(fr["blend"])
        if vc_shading:
            shade_faces()
        r.filepath = os.path.join(job["out"], fr["name"] + ".png")
        bpy.ops.render.render(write_still=True)
        continue
    set_cam(fr.get("cam") or job["cam"])
    if fr.get("action") and fr["action"] != cur_action:
        use_action(fr["action"])
        cur_action = fr["action"]
    scene.frame_set(int(fr["frame"]), subframe=float(fr.get("subframe", 0.0)))
    if vc_shading:
        shade_faces()
    r.filepath = os.path.join(job["out"], fr["name"] + ".png")
    bpy.ops.render.render(write_still=True)
print("model_ref blender: %d frames -> %s" % (len(job["frames"]), job["out"]))
