// alphamine: shared code of the pack world shaders (main.glslf, translucent.glslf) -- Alpha 1.0.16 texels,
// light (modules/lightmap.lua region of the blocks atlas), fog. Needs u_texture0 (the blocks atlas).
#ifndef AM_WORLD_GLSL_
#define AM_WORLD_GLSL_

#include <am_sky>

#ifndef FOG_GLSL_
uniform float u_fogFactor;   // engine fog factor; 0 = F2F fog:false (devtools f2f_render world_uniforms)
#endif

// EntityRenderer.setupFog(0/1): GL_LINEAR, start = far*0.25, end = far (far = 256 >> renderDistance FAR);
// GL_NV_fog_distance -> GL_EYE_RADIAL_NV (the reference GPU is NVIDIA). Colour = updateFogColor at world time
// 0 (multiplayer: WorldClient never advances time), partial 0: fog colour of World.getFogColor mixed towards
// getSkyColor by 1 - 0.25^0.25, times the fog brightness (converged to 0.99999976 in float), Java float math
// (tools: agents/ALPHAMINE.md phase 3). FOG_MODE 0 = per-vertex radial, 1 = per-fragment radial, 2 = eye plane.
#define FOG_MODE 0
const vec3 ALPHA_FOG = AM_FOG_COLOR;   // lib/am_sky.glsl (tools/alphamine/gen_sky.py)
const float ALPHA_FOG_START = 64.0;
const float ALPHA_FOG_END = 256.0;

// ---------------------------------------------------------------- Alpha light (modules/lightmap.lua)
// Region of the blocks atlas at texel (2,2): 21x21 chunk slots of 64x64 texels (nibble per cell, cell index
// x<<11|z<<7|y), columns 1344.. the same slots with fluid codes, header row 1344 (chunk coords per slot),
// marker row 1345 ("AMLM"). 2688 x 1346: LMPacker's int score height^2*1000 overflows above ~1465 rows.
const ivec2 LM0 = ivec2(2, 2);
const int LM_SLOTS = 21;
const int LM_SLOT = 64;
const int LM_CODES = 1344;    // fluid-code map: same slot layout, columns 1344..2687
const int LM_HEADER = 1344;
const int LM_MARKER = 1345;

// Tessellator.setColorOpaque_F((int)(factor * World.h[level] * 255)), RenderBlocks factors
// top 1.0, bottom 0.5, +-Z 0.8, +-X 0.6; h[l] = (1-f)/(3f+1)*0.95+0.05, f = 1 - l/15 (float math as Java)
const float B_TOP[16] = float[](12., 16., 21., 26., 32., 39., 47., 56., 66., 78., 93., 111., 133., 162., 201., 255.);
const float B_BOT[16] = float[](6., 8., 10., 13., 16., 19., 23., 28., 33., 39., 46., 55., 66., 81., 100., 127.);
const float B_Z[16]   = float[](10., 13., 17., 21., 26., 31., 37., 44., 53., 63., 74., 89., 107., 130., 160., 204.);
const float B_X[16]   = float[](7., 10., 13., 16., 19., 23., 28., 33., 39., 47., 56., 66., 80., 97., 120., 153.);

ivec4 fetch8(ivec2 p) {
    return ivec4(texelFetch(u_texture0, p, 0) * 255.0 + 0.5);
}

bool lm_ready() {
    return fetch8(LM0 + ivec2(0, LM_MARKER)) == ivec4(65, 77, 76, 77);
}

int floordiv(int a, int b) {
    return int(floor(float(a) / float(b)));
}

// nibble of cell c in the slot map starting at column `cols` (0 = light, LM_CODES = fluid codes); -1 = chunk absent
int lm_nibble(ivec3 c, int cols) {
    int cx = floordiv(c.x, 16), cz = floordiv(c.z, 16);
    int sx = cx - LM_SLOTS * floordiv(cx, LM_SLOTS), sz = cz - LM_SLOTS * floordiv(cz, LM_SLOTS);
    ivec4 h = fetch8(LM0 + ivec2(sz * LM_SLOTS + sx, LM_HEADER));
    if (h.x + h.y * 256 != cx + 32768 || h.z + h.w * 256 != cz + 32768) return -1;
    int i = ((c.x - cx * 16) << 11) | ((c.z - cz * 16) << 7) | c.y;
    int j = i >> 1;
    int t = j >> 2;
    ivec4 v = fetch8(LM0 + ivec2(cols + sx * LM_SLOT + (t & 63), sz * LM_SLOT + (t >> 6)));
    int b = v[j & 3];
    return (i & 1) == 0 ? (b & 15) : (b >> 4);
}

// World.getBlockLightValue_do(x, y, z, false): y >= 128 -> 15, y < 0 -> 0, chunk not loaded (blank chunk) -> 0
int lm_level(ivec3 c) {
    if (c.y >= 128) return 15;
    if (c.y < 0) return 0;
    return max(lm_nibble(c, 0), 0);
}

// fluid code of a cell (0 = air/unknown/outside)
int lm_code(ivec3 c) {
    if (c.y >= 128 || c.y < 0) return 0;
    return max(lm_nibble(c, LM_CODES), 0);
}

// ---------------------------------------------------------------- face geometry
// Alpha texel of terrain.png (GL_NEAREST, no mipmaps, RenderEngine) for the atlas coordinate T (texels).
// RenderBlocks maps a full face onto [x0, x0 + 15.99] texels (maxX*16 - 0.01), the engine onto [x0, x0 + 16]:
// Alpha texel = floor(local * 15.99/16), local = texels from the image left/top edge of the tile.
// The tile (origin) is found from the world position: fract along the in-plane axis that the atlas axis
// follows (axis and sign from screen derivatives), origin = round(T - local); local itself = T - origin
// (the atlas coordinate is far more precise than a world coordinate of ~100).
// Atlas rows are bottom-up (png.cpp loads rows reversed), so for v the image top is the high-T side; the
// bottom faces use a vertically mirrored copy of the tile (gen_pack_blocks.py): there it is the low-T side.
// blk = the block's in-plane integer coords (A order), valid when the face spans a whole block tile.
bool face_texel(vec2 T, vec2 A, mat2 dA, mat2 dT, bool bottom, out ivec2 texel, out ivec2 blk) {
    texel = ivec2(floor(T));
    blk = ivec2(floor(A));
    float det = determinant(dA);
    if (abs(det) < 1e-12) return false;
    mat2 M = dT * inverse(dA);   // dT/dA: column j = d/dA_j
    ivec2 tx;
    ivec2 bk;
    int used = 0;
    for (int i = 0; i < 2; i++) {
        float m0 = M[0][i], m1 = M[1][i];
        int j = abs(m0) >= abs(m1) ? 0 : 1;
        float m = j == 0 ? m0 : m1;
        // the tile spans a whole block (cube faces) or 0.9 of it (renderCrossedSquares: 0.5 +- 0.45F);
        // anything else keeps the plain texel
        float ext = 16.0 / abs(m);
        if (abs(ext - 1.0) < 0.03) ext = 1.0;
        else if (abs(ext - 0.9) < 0.03) ext = 0.899999976;
        else return false;
        float inset = (1.0 - ext) * 0.5;
        used |= 1 << j;
        float f = (fract(A[j]) - inset) / ext;
        float local = m > 0.0 ? 16.0 * f : 16.0 * (1.0 - f);   // texels from the low-T edge
        float origin = floor(T[i] - local + 0.5);
        local = T[i] - origin;
        // fract(A) wraps at the block seam (A ~100 carries ~1e-5 error): the precise T says which side
        if (local < 0.0) { origin -= 16.0; local += 16.0; }
        else if (local > 16.0) { origin += 16.0; local -= 16.0; }
        int k;
        if (i == 0 || bottom) {
            k = int(floor(local * (15.99 / 16.0)));             // image left (u) / mirrored bottom tile (v)
        } else {
            k = 15 - int(floor((16.0 - local) * (15.99 / 16.0))); // image top is the high-T side
        }
        tx[i] = int(origin) + clamp(k, 0, 15);
        float fj = m > 0.0 ? local / 16.0 : 1.0 - local / 16.0;
        bk[j] = int(floor(A[j] - (inset + fj * ext) + 0.5));
    }
    if (used != 3) return false;
    texel = tx;
    blk = bk;
    return true;
}


// linear fog 64..256 on eye-radial distance c (EntityRenderer.setupFog(0), GL_NV_fog_distance); u_fogFactor 0 = off
vec3 alpha_fog(vec3 color, float c) {
    if (u_fogFactor <= 0.0) return color;
    float fog = clamp((ALPHA_FOG_END - c) / (ALPHA_FOG_END - ALPHA_FOG_START), 0.0, 1.0);
    return mix(ALPHA_FOG, color, fog);
}

#endif // AM_WORLD_GLSL_
