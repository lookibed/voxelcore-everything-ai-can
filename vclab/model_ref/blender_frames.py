"""model_ref, Blender side: render frames of a .blend with the camera of the engine stand, for a pixel compare.
Default "vc" shading: as the engine draws a model with fullbright light — texel * (0.8 + 0.2 * dot(face normal, SUN))
(ModelBatch::draw), no gamma: Cycles emission, 1 sample, no pixel filter, raw view transform. "flat": the texel only
(Workbench FLAT). Transparent film (alpha = the silhouette), no anti-aliasing (the engine frame has none).

  blender -b <file.blend> --python blender_frames.py -- <job.json>
job = {"out": dir, "w": 854, "h": 480, "cam": {"pos": [x,y,z], "target": [x,y,z], "fov": deg},   # VoxelCore axes,
       "root_y": -0.5,                     # relative to the entity: VC y of the Blender z = 0 plane
       "frames": [{"name": "walk_000", "frame": 0, "subframe": 0.0, "action": null}, ...]}   # action: put on first
VoxelCore (x, y, z) -> Blender (x, -z, y - root_y)."""
import json
import math
import os
import sys

import bpy
from mathutils import Vector

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
cam.location = b(job["cam"]["pos"])
cam.rotation_euler = (b(job["cam"]["target"]) - cam.location).to_track_quat("-Z", "Y").to_euler()
cam.data.sensor_fit = "VERTICAL"
cam.data.angle_y = math.radians(job["cam"]["fov"])
cam.data.clip_start, cam.data.clip_end = 0.05, 500
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
def use_action(name):                     # as blender_export.use_action
    act = bpy.data.actions[name]
    arms = [o for o in scene.objects if o.type == "ARMATURE"]
    for o in arms or [o for o in scene.objects if o.animation_data and o.animation_data.action]:
        ad = o.animation_data or o.animation_data_create()
        ad.action = act
        if hasattr(ad, "action_slot") and ad.action_slot is None and getattr(ad, "action_suitable_slots", None):
            ad.action_slot = ad.action_suitable_slots[0]


cur_action = None
for fr in job["frames"]:
    if fr.get("action") and fr["action"] != cur_action:
        use_action(fr["action"])
        cur_action = fr["action"]
    scene.frame_set(int(fr["frame"]), subframe=float(fr.get("subframe", 0.0)))
    if vc_shading:
        shade_faces()
    r.filepath = os.path.join(job["out"], fr["name"] + ".png")
    bpy.ops.render.render(write_still=True)
print("model_ref blender: %d frames -> %s" % (len(job["frames"]), job["out"]))
