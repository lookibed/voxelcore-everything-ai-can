// alphamine: res/shaders/main.glslv (VoxelCore 0.31) with Alpha 1.0.16 lighting and projection (phase 3).
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

out vec4 a_torchLight;
out float a_alphaLight;     // Alpha vertex colour (Tessellator byte / 255), 1.0 = F2F lighting:false
out float a_fogDist;        // Alpha fog coordinate: eye-radial distance per vertex (GL_NV_fog_distance)

// EntityRenderer.setupCameraTransform: GLU.gluPerspective(70, 854/480, 0.05, 256 >> renderDistance(FAR=0)),
// LWJGL Project.gluPerspective in float (cot = (float)cos(r) / (float)sin(r), r = 70/2*PI/180):
// m00 = cot/aspect with aspect = the frame's (u_proj ratio), m11 = cot, far 256.
const float ALPHA_COT = 1.428147793;
const float ALPHA_M22 = -1.000390649;
const float ALPHA_M32 = -0.1000195369;

// BlocksRenderer: vertex light byte = uint8(level/15 * d * 255), d = 0.7 + 0.3*dot(N, SUN) (soft-lighting off)
const vec3 SUN = vec3(0.528265, 0.833149, -0.163704);

// Tessellator.setColorOpaque_F((int)(factor * World.h[level] * 255)): RenderBlocks faces
// top 1.0, bottom 0.5, +-Z 0.8, +-X 0.6; h[l] = (1-f)/(3f+1)*0.95+0.05, f = 1 - l/15 (float math as Java)
const float B_TOP[16] = float[](12., 16., 21., 26., 32., 39., 47., 56., 66., 78., 93., 111., 133., 162., 201., 255.);
const float B_BOT[16] = float[](6., 8., 10., 13., 16., 19., 23., 28., 33., 39., 46., 55., 66., 81., 100., 127.);
const float B_Z[16]   = float[](10., 13., 17., 21., 26., 31., 37., 44., 53., 63., 74., 89., 107., 130., 160., 204.);
const float B_X[16]   = float[](7., 10., 13., 16., 19., 23., 28., 33., 39., 47., 56., 66., 80., 97., 120., 153.);

float alpha_light(vec3 n) {
    if (v_normal.w > 0.5) {
        return 1.0;   // unlit vertex (F2F lighting:false or shadeless): Java lighting:false = colour 255
    }
    vec3 an = abs(n);
    vec3 N;
    int face;   // 0 top, 1 bottom, 2 z, 3 x
    if (an.y >= an.x && an.y >= an.z) { N = vec3(0.0, sign(n.y), 0.0); face = n.y > 0.0 ? 0 : 1; }
    else if (an.z >= an.x) { N = vec3(0.0, 0.0, sign(n.z)); face = 2; }
    else { N = vec3(sign(n.x), 0.0, 0.0); face = 3; }
    float d = 0.7 + 0.3 * dot(N, SUN);
    float sky = floor(v_light.a * 15.0 / d + 0.5);
    float blk = floor(max(v_light.r, max(v_light.g, v_light.b)) * 15.0 / d + 0.5);
    // Chunk.getBlockLightValue: max(sky - World.d, block); World.d = 0 in multiplayer at time 0
    int l = int(clamp(max(sky, blk), 0.0, 15.0));
    float b = face == 0 ? B_TOP[l] : face == 1 ? B_BOT[l] : face == 2 ? B_Z[l] : B_X[l];
    return b / 255.0;
}

void main() {
    a_modelpos = u_model * vec4(v_position, 1.0f);
    vec3 pos3d = a_modelpos.xyz - u_cameraPos;

    a_realnormal = v_normal.xyz * 2.0 - 1.0;
    a_normal = calc_screen_normal(a_realnormal);

    a_torchLight = vec4(calc_torch_light(
        v_light.rgb, a_realnormal, a_modelpos.xyz, u_torchlightColor, u_gamma
    ), 1.0);
    a_alphaLight = alpha_light(a_realnormal);
    a_texCoord = v_texCoord;

    a_dir = a_modelpos.xyz - u_cameraPos;
    vec3 skyLightColor = pick_sky_color(u_skybox, u_dayTime, u_minSkyLight);
    a_skyLight = skyLightColor.rgb*v_light.a;

    mat4 viewmodel = u_view * u_model;
    a_distance = length(viewmodel * vec4(pos3d, 0.0));

#ifndef ADVANCED_RENDER
    a_fog = calc_fog(length(viewmodel * vec4(pos3d * FOG_POS_SCALE, 0.0)) / 256.0);
#endif

    a_emission = v_normal.w;

    // camera-relative like Alpha (glTranslatef(chunk - camera) in float, then the rotations): the chunk
    // origin (u_model translation, whole blocks) minus the camera, plus the chunk-local vertex -> no
    // float products with world coordinates of ~100
    vec3 rel = (u_model[3].xyz - u_cameraPos) + mat3(u_model) * v_position;
    vec3 eye = mat3(u_view) * rel;
    a_position = eye;
    a_fogDist = length(eye);
    float aspect = u_proj[1][1] / u_proj[0][0];
    gl_Position = vec4(ALPHA_COT / aspect * eye.x, ALPHA_COT * eye.y,
                       ALPHA_M22 * eye.z + ALPHA_M32, -eye.z);
}
