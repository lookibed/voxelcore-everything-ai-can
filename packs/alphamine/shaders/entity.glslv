// AlphaMine (phase 3): entity vertex shader = engine res/shaders/entity.glslv with the Alpha entity light.
// Alpha draws entities with RenderHelper.enableStandardItemLighting (set after the camera transform, so the
// two light directions are fixed in the world): colour = clamp(C * (0.4 + 0.6*max(0,n.L0) + 0.6*max(0,n.L1)))
// with C = glColor = World.getBrightness at the entity (Render.doRender / RenderLiving) — the pack computes C in
// Lua from the server light (modules/physics.lua entity_brightness) and passes it as the skeleton tint
// (v_color). The engine's own vertex light (v_light, sampled at the model origin) is not used.
// Meshes with `shading off` (flat item sprites, v_normal.w = 1) get factor 1: Alpha sets their normal (0,1,0),
// which under the two lights gives 0.4 + 0.6*(0.808+0.808) > 1 -> clamped to 1.
#include <commons>

layout (location = 0) in vec3 v_position;
layout (location = 1) in vec2 v_texCoord;
layout (location = 2) in vec3 v_color;
layout (location = 3) in vec4 v_light;
layout (location = 4) in vec4 v_normal;

#include <world_vertex_header>
#include <lighting>
#include <fog>
#include <sky>

out vec4 a_color;

uniform float u_dayTime;

// Vec3D.createVector((double)0.2F, 1.0D, (double)-0.7F).normalize(), the same for LIGHT1 with signs flipped
const vec3 AM_LIGHT0 = vec3(0.16169041669088866, 0.8084520834544432, -0.5659164584181102);
const vec3 AM_LIGHT1 = vec3(-0.16169041669088866, 0.8084520834544432, 0.5659164584181102);

void main() {
    a_modelpos = u_model * vec4(v_position, 1.0);
    vec3 pos3d = a_modelpos.xyz - u_cameraPos;

    a_realnormal = v_normal.xyz * 2.0 - 1.0;
    a_normal = calc_screen_normal(a_realnormal);

    float shade = 1.0;
    if (v_normal.w < 0.5) {
        vec3 n = normalize(a_realnormal);
        shade = min(1.0, 0.4 + 0.6 * max(0.0, dot(n, AM_LIGHT0)) + 0.6 * max(0.0, dot(n, AM_LIGHT1)));
    }
    a_color = vec4(clamp(v_color * shade, 0.0, 1.0), u_opacity);
    a_texCoord = v_texCoord;

    a_dir = a_modelpos.xyz - u_cameraPos;

    mat4 viewmodel = u_view * u_model;
    a_distance = length(viewmodel * vec4(pos3d, 0.0));
    a_fog = calc_fog(length(viewmodel * vec4(pos3d * FOG_POS_SCALE, 0.0)) / 256.0);
    a_emission = 0.0;

    vec4 viewmodelpos = u_view * a_modelpos;
    a_position = viewmodelpos.xyz;
    gl_Position = u_proj * viewmodelpos;
}
