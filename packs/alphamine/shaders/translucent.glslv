// alphamine: res/shaders/translucent.glslv (VoxelCore 0.31) with Alpha 1.0.16 projection and fluid surfaces.
// The translucent pass draws sorted per-block cube faces (BlocksRenderer::renderTranslucent: water, ice) as plain
// triangle lists, 6 vertices per face in the order (0,1,2,0,2,3) of BlocksRenderer::face -> gl_VertexID % 6
// gives the face corner and so the block cell. Water: the top corners are lowered to
// RenderBlocks.getFluidHeight (top face and the upper edge of the side faces).
#include <commons>

layout (location = 0) in vec3 v_position;
layout (location = 1) in vec2 v_texCoord;
layout (location = 2) in vec4 v_light;
layout (location = 3) in vec4 v_normal;

#include <world_vertex_header>
#include <lighting>
#include <fog>
#include <sky>

uniform float u_dayTime;
uniform sampler2D u_texture0;

#include <am_world>
#include <am_fluid>

out vec4 a_torchLight;
out float a_fogDist;
flat out ivec3 a_cell;

const float ALPHA_COT = 1.428147793;
const float ALPHA_M22 = -1.000390649;
const float ALPHA_M32 = -0.1000195369;

void main() {
    vec3 n = v_normal.xyz * 2.0 - 1.0;
    vec3 N = vec3(0.0);
    vec3 X, Y;
    vec3 an = abs(n);
    if (an.y >= an.x && an.y >= an.z) {
        N.y = sign(n.y);
        X = vec3(1.0, 0.0, 0.0);
        Y = n.y > 0.0 ? vec3(0.0, 0.0, -1.0) : vec3(0.0, 0.0, 1.0);
    } else if (an.z >= an.x) {
        N.z = sign(n.z);
        X = vec3(sign(n.z), 0.0, 0.0);
        Y = vec3(0.0, 1.0, 0.0);
    } else {
        N.x = sign(n.x);
        X = vec3(0.0, 0.0, -sign(n.x));
        Y = vec3(0.0, 1.0, 0.0);
    }
    int corner = int[](0, 1, 2, 0, 2, 3)[gl_VertexID % 6];
    float sx = (corner == 1 || corner == 2) ? 1.0 : -1.0;
    float sy = corner >= 2 ? 1.0 : -1.0;
    vec3 off = (sx * X + sy * Y + N) * 0.5;
    vec3 wpos = (u_model * vec4(v_position, 1.0)).xyz;
    ivec3 cell = ivec3(floor(wpos - off));
    a_cell = cell;

    vec3 pos = v_position;
    int code = lm_ready() ? lm_code(cell) : 0;
    if (is_water(code) && off.y > 0.0) {
        int cx = cell.x + (off.x > 0.0 ? 1 : 0), cz = cell.z + (off.z > 0.0 ? 1 : 0);
        float h = fluid_height(cx, cell.y, cz, code);
        pos.y += float(cell.y) + h - wpos.y;
    }

    a_modelpos = u_model * vec4(pos, 1.0f);
    vec3 pos3d = a_modelpos.xyz - u_cameraPos;
    a_realnormal = n;
    a_normal = calc_screen_normal(a_realnormal);
    a_torchLight = vec4(calc_torch_light(v_light.rgb, a_realnormal, a_modelpos.xyz, u_torchlightColor, u_gamma), 1.0);
    a_texCoord = v_texCoord;
    a_dir = pos3d;
    vec3 skyLightColor = pick_sky_color(u_skybox, u_dayTime, u_minSkyLight);
    a_skyLight = skyLightColor.rgb * v_light.a;
    a_emission = v_normal.w;

    vec3 rel = (u_model[3].xyz - u_cameraPos) + mat3(u_model) * pos;
    vec3 eye = mat3(u_view) * rel;
    a_position = eye;
    a_distance = length(eye);
    a_fog = 0.0;
    a_fogDist = length(eye);
    float aspect = u_proj[1][1] / u_proj[0][0];
    gl_Position = vec4(ALPHA_COT / aspect * eye.x, ALPHA_COT * eye.y, ALPHA_M22 * eye.z + ALPHA_M32, -eye.z);
}
