// alphamine: RenderGlobal.renderSky of Alpha 1.0.16 per pixel (phase 3), replaces the engine sky background.
// Alpha (renderDistance FAR): clear = fog colour; glSkyList = 64x64 quads over +-384 at y = +16 (colour
// getSkyColor, GL fog LINEAR 0 .. far*0.8 = 204.8, eye-radial distance per vertex, interpolated over the
// triangles); sun (32x32 sun.png, +-30 at 100, additive ONE,ONE, no fog) and moon (+-20 at -100) rotated by
// glRotatef(celestialAngle*360, 1,0,0); glSkyList2 = the same grid at y = -16 in the dark colour, fogged. All with
// modelview T(0,0,-0.1)*R (camera rotation, no translation) and the projection of GLU.gluPerspective(70, ar,
// 0.05, 256): geometry beyond eye depth 256 is clipped (the clear colour shows). Constants: lib/am_sky.glsl
// (tools/alphamine/gen_sky.py, world time 0). The engine's sun/moon sprites are blanked by transparent
// textures/misc/{sun,moon,moon_flare}.png; its stars have NaN opacity at the pack's day time 0.5.
in vec2 v_ndc;
layout (location = 0) out vec4 f_color;
layout (location = 1) out vec4 f_position;
layout (location = 2) out vec4 f_normal;

uniform mat4 u_view;   // camera rotation (Camera::getView(false))
uniform float u_ar;    // viewport width / height

#include <am_sky>

const float COT = 1.428147793;   // GLU cot(35 deg) in float (main.glslv)
const float FAR = 256.0;
const float SKY_FOG_END = 204.8; // setupFog(-1): start 0, end far*0.8F
const float GRID = 64.0;
const float EXTENT = 384.0;      // 64 * (256/64 + 2)

mat3 R;   // world -> eye rotation

// per-vertex fog factor (clamped at the vertex, then interpolated: FOG_INTERP 1) or distance (0)
#define FOG_INTERP 0
float vdist(vec3 v) {
    float c = length(R * v + vec3(0.0, 0.0, -0.1));
#if FOG_INTERP == 1
    return clamp((SKY_FOG_END - c) / SKY_FOG_END, 0.0, 1.0);
#else
    return c;
#endif
}

float fogmix_factor(float c) {
#if FOG_INTERP == 1
    return c;
#else
    return clamp((SKY_FOG_END - c) / SKY_FOG_END, 0.0, 1.0);
#endif
}

// ray of this pixel in sky space: origin o, direction d (eye depth = parameter t)
bool plane_hit(vec3 o, vec3 d, float h, out vec3 v) {
    if (abs(d.y) < 1e-9) return false;
    float t = (h - o.y) / d.y;
    if (t <= 0.0 || t > FAR) return false;
    v = o + t * d;
    return abs(v.x) <= EXTENT && abs(v.z) <= EXTENT;
}

// per-vertex fog coordinate interpolated over the GL_QUADS triangles (0,1,2), (0,2,3) of the cell
float grid_fog(vec3 v, float h, bool top) {
    float i = floor((v.x + EXTENT) / GRID), j = floor((v.z + EXTENT) / GRID);
    float x0 = -EXTENT + GRID * i, z0 = -EXTENT + GRID * j;
    float s = (v.x - x0) / GRID, t = (v.z - z0) / GRID;
    float c00 = vdist(vec3(x0, h, z0)), c10 = vdist(vec3(x0 + GRID, h, z0));
    float c11 = vdist(vec3(x0 + GRID, h, z0 + GRID)), c01 = vdist(vec3(x0, h, z0 + GRID));
    if (top) {
        // quad (x0,z0) (x1,z0) (x1,z1) (x0,z1): diagonal (0,0)-(1,1)
        return s >= t ? c00 + s * (c10 - c00) + t * (c11 - c10)
                      : c00 + s * (c11 - c01) + t * (c01 - c00);
    }
    // quad (x1,z0) (x0,z0) (x0,z1) (x1,z1): diagonal (1,0)-(0,1)
    return s + t <= 1.0 ? c00 + s * (c10 - c00) + t * (c01 - c00)
                        : c11 + (1.0 - s) * (c01 - c11) + (1.0 - t) * (c10 - c11);
}

vec3 texel(uint rgb) {
    return vec3(float((rgb >> 16) & 255u), float((rgb >> 8) & 255u), float(rgb & 255u)) / 255.0;
}

vec3 q8(vec3 c) {   // the 8-bit framebuffer between the draw calls
    return floor(clamp(c, 0.0, 1.0) * 255.0 + 0.5) / 255.0;
}

void main() {
    R = mat3(u_view);
    mat3 RT = transpose(R);
    vec3 e = vec3(v_ndc.x * u_ar / COT, v_ndc.y / COT, -1.0);
    vec3 d = RT * e;
    vec3 o = RT * vec3(0.0, 0.0, 0.1);

    vec3 col = AM_FOG_COLOR;   // glClearColor(fog)
    vec3 v;
    if (plane_hit(o, d, 16.0, v)) {
        col = mix(AM_FOG_COLOR, AM_SKY_COLOR, fogmix_factor(grid_fog(v, 16.0, true)));
    }
    col = q8(col);
    // sun / moon in the rotated frame: v' = Rx^T v
    vec3 o2 = vec3(o.x, AM_CEL_COS * o.y + AM_CEL_SIN * o.z, -AM_CEL_SIN * o.y + AM_CEL_COS * o.z);
    vec3 d2 = vec3(d.x, AM_CEL_COS * d.y + AM_CEL_SIN * d.z, -AM_CEL_SIN * d.y + AM_CEL_COS * d.z);
    if (abs(d2.y) > 1e-9) {
        float t = (100.0 - o2.y) / d2.y;
        vec3 p = o2 + t * d2;
        if (t > 0.0 && t <= FAR && abs(p.x) <= 30.0 && abs(p.z) <= 30.0) {
            ivec2 tx = clamp(ivec2(floor(vec2((p.x + 30.0) / 60.0, (p.z + 30.0) / 60.0) * 32.0)), 0, 31);
            col = q8(col + texel(AM_SUN_TEX[tx.y * AM_SUN_SIZE + tx.x]));
        }
        t = (-100.0 - o2.y) / d2.y;
        p = o2 + t * d2;
        if (t > 0.0 && t <= FAR && abs(p.x) <= 20.0 && abs(p.z) <= 20.0) {
            ivec2 tx = clamp(ivec2(floor(vec2((20.0 - p.x) / 40.0, (p.z + 20.0) / 40.0) * 32.0)), 0, 31);
            col = q8(col + texel(AM_MOON_TEX[tx.y * AM_MOON_SIZE + tx.x]));
        }
    }
    if (plane_hit(o, d, -16.0, v)) {
        col = mix(AM_FOG_COLOR, AM_SKY2_COLOR, fogmix_factor(grid_fog(v, -16.0, false)));
    }
    f_color = vec4(col, 1.0);
    f_position = vec4(0.0, 0.0, -1e6, 1.0);
    f_normal = vec4(0.0, 0.0, 1.0, 1.0);
}
