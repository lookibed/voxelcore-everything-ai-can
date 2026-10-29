// alphamine: Alpha 1.0.16 fluids for the pack shaders (RenderBlocks.renderBlockFluids, BlockFluid), reading the
// fluid-code map of the lightmap region (lib/am_world.glsl) and the animated textures (modules/texfx.lua, am_fx).
#ifndef AM_FLUID_GLSL_
#define AM_FLUID_GLSL_

// am_fx region (modules/texfx.lua): image k at columns 16k.., rows 0..15 from the PNG top; marker row 1023
const ivec2 FX0 = ivec2(2694, 2);   // right of am_lightmap (2688 + 2*2 extrusion + 2)
const int FX_WATER = 0, FX_WATER_FLOW = 1, FX_LAVA = 2, FX_LAVA_FLOW = 3;

bool fx_ready() {
    return fetch8(FX0 + ivec2(0, 1023)) == ivec4(65, 77, 70, 88);
}

vec4 fx_texel(int k, int x, int y) {
    return texelFetch(u_texture0, FX0 + ivec2(16 * k + (x & 15), y & 15), 0);
}

bool is_water(int code) { return code >= 2 && code <= 9; }
bool is_lava(int code) { return code >= 10 && code <= 13; }
bool same_fluid(int a, int b) { return (is_water(a) && is_water(b)) || (is_lava(a) && is_lava(b)); }
bool code_solid(int code) { return code == 1 || code == 14; }
// BlockFluid.getEffectiveFlowDecay: -1 other material, else meta (>= 8 -> 0); lava levels are 0,2,4,6
int flow_decay(int code, int fluid) {
    if (!same_fluid(code, fluid)) return -1;
    return is_water(code) ? code - 2 : (code - 10) * 2;
}

// RenderBlocks.getFluidHeight(x, y, z, material): corner (x, z) of the row y
float fluid_height(int x, int y, int z, int fluid) {
    int cnt = 0;
    float sum = 0.0;
    for (int k = 0; k < 4; k++) {
        int bx = x - (k & 1), bz = z - ((k >> 1) & 1);
        if (same_fluid(lm_code(ivec3(bx, y + 1, bz)), fluid)) return 1.0;
        int c = lm_code(ivec3(bx, y, bz));
        if (!same_fluid(c, fluid)) {
            if (!code_solid(c)) { sum += 1.0; cnt += 1; }
        } else {
            int e = flow_decay(c, fluid);
            float p = float(e + 1) / 9.0;   // BlockFluid.getFluidHeightPercent
            if (e == 0) { sum += p * 10.0; cnt += 10; }
            sum += p;
            cnt += 1;
        }
    }
    return 1.0 - sum / float(cnt);
}

// BlockFluid.getFlowVector (x, z only: y does not change atan2); false = no flow
bool flow_vector(ivec3 c, int fluid, out vec2 v) {
    int own = flow_decay(lm_code(c), fluid);
    v = vec2(0.0);
    ivec2 d[4] = ivec2[](ivec2(-1, 0), ivec2(0, -1), ivec2(1, 0), ivec2(0, 1));
    for (int k = 0; k < 4; k++) {
        ivec3 n = c + ivec3(d[k].x, 0, d[k].y);
        int e = flow_decay(lm_code(n), fluid);
        if (e < 0) {
            if (!code_solid(lm_code(n))) {
                e = flow_decay(lm_code(n - ivec3(0, 1, 0)), fluid);
                if (e >= 0) v += vec2(d[k]) * float(e - (own - 8));
            }
        } else {
            v += vec2(d[k]) * float(e - own);
        }
    }
    return v.x != 0.0 || v.y != 0.0;
}

// MathHelper.sin/cos: 65536-entry table, index (int)(f * 10430.378F) & 65535
float mh_sin(float f) { return sin(float(int(f * 10430.378) & 65535) * (6.283185307179586 / 65536.0)); }
float mh_cos(float f) { return sin(float(int(f * 10430.378 + 16384.0) & 65535) * (6.283185307179586 / 65536.0)); }

// EntityRenderer.renderWorld (fancy): pass 1 is drawn twice, first depth only (glColorMask false), then colour
// with depth test -> only the nearest water fragment of each pixel is visible. The engine blends every sorted
// face instead, so a water fragment is dropped when the ray from it back to the eye crosses a water face that
// Alpha renders (DDA over the fluid-code map): the surface of a water cell whose upper neighbour is not water
// (at the average corner height), or a side/bottom boundary between water and a non-solid, non-ice cell below
// the surface (BlockFluid.shouldSideBeRendered; Material.isSolid stands in for isOpaqueCube).
float cell_surface(ivec3 c, int fluid) {
    return float(c.y) + 0.25 * (fluid_height(c.x, c.y, c.z, fluid) + fluid_height(c.x + 1, c.y, c.z, fluid)
                              + fluid_height(c.x, c.y, c.z + 1, fluid) + fluid_height(c.x + 1, c.y, c.z + 1, fluid));
}

bool water_occluded(vec3 P, vec3 eye, ivec3 own, int fluid) {
    vec3 d = eye - P;
    float len = length(d);
    if (len < 1e-4) return false;
    d /= len;
    vec3 p = P + d * 1e-3;
    ivec3 c = ivec3(floor(p));
    ivec3 st = ivec3(sign(d));
    vec3 tMax = (vec3(c) + max(vec3(st), 0.0) - p) / d;
    tMax = mix(tMax, vec3(1e9), lessThan(abs(d), vec3(1e-9)));
    vec3 tDelta = 1.0 / max(abs(d), vec3(1e-9));
    float t = 0.0;
    int prev = -1;          // code of the previous cell (-1: the own cell side)
    float prevSurf = 0.0;
    for (int k = 0; k < 64; k++) {
        if (t > len) break;
        int code = lm_code(c);
        bool w = same_fluid(code, fluid) && c != own;
        float tn = min(min(tMax.x, tMax.y), min(tMax.z, len));
        float y0 = p.y + d.y * t, y1 = p.y + d.y * tn;
        float surf = 0.0;
        if (w) {
            surf = cell_surface(c, fluid);
            if (!same_fluid(lm_code(c + ivec3(0, 1, 0)), fluid) && min(y0, y1) < surf && max(y0, y1) > surf)
                return true;                                         // crosses the top face
            if (prev >= 0 && !same_fluid(prev, fluid) && !code_solid(prev) && y0 < surf)
                return true;                                         // enters through a rendered side
        } else if (prev >= 0 && same_fluid(prev, fluid) && !code_solid(code) && code != 14 && y0 < prevSurf) {
            return true;                                             // leaves water through a rendered side
        }
        prev = (c == own) ? -1 : code;
        prevSurf = surf;
        t = tn;
        if (tMax.x < tMax.y && tMax.x < tMax.z) { tMax.x += tDelta.x; c.x += st.x; }
        else if (tMax.y < tMax.z) { tMax.y += tDelta.y; c.y += st.y; }
        else { tMax.z += tDelta.z; c.z += st.z; }
    }
    return false;
}

#endif // AM_FLUID_GLSL_
