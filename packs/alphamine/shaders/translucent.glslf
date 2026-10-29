// alphamine: res/shaders/translucent.glslf (VoxelCore 0.31) with Alpha 1.0.16 water (renderBlockFluids,
// animated TextureWaterFX / TextureWaterFlowFX from modules/texfx.lua), light and fog (phase 3).
layout (location = 0) out vec4 f_color;

#include <world_fragment_header>

in vec4 a_torchLight;
in float a_fogDist;
flat in ivec3 a_cell;

uniform sampler2D u_texture0;
uniform vec3 u_sunDir;

// flags
uniform bool u_alphaClip;
uniform bool u_debugLights;
uniform bool u_debugNormals;

#include <am_world>
#include <am_fluid>

// BlockFluid.getBlockBrightness(x, y, z) = max(brightness(x,y,z), brightness(x,y+1,z)) -> the larger level
int fluid_level(ivec3 c) {
    return max(lm_level(c), lm_level(c + ivec3(0, 1, 0)));
}

void main() {
    ivec2 texSize = textureSize(u_texture0, 0);
    vec2 T = a_texCoord * vec2(texSize);
    vec3 n = a_realnormal;
    vec3 an = abs(n);
    vec3 P = a_modelpos.xyz;
    vec3 dPx = dFdx(P), dPy = dFdy(P);   // derivatives in uniform control flow only
    mat2 dT = mat2(dFdx(T), dFdy(T));
    int axis = an.y >= an.x && an.y >= an.z ? 1 : an.z >= an.x ? 2 : 0;
    bool lighting = a_emission < 0.5;   // F2F lighting:false -> colour 255
    bool ready = lm_ready();
    ivec3 cell = a_cell;
    int code = ready ? lm_code(cell) : 0;

    vec4 texColor;
    float light = 1.0;
    if (is_water(code) && fx_ready()) {
        if (!is_water(lm_code(ivec3(floor(u_cameraPos)))) && water_occluded(P, u_cameraPos, cell, code))
            discard;
        vec3 f = P - vec3(cell);
        int level;
        const float[16] one = B_TOP;
        if (axis == 1 && n.y > 0.0) {
            // top: still (TextureWaterFX, u = x, v = z over the whole tile) or flowing (TextureWaterFlowFX
            // 2x2 area sampled +-8 texels around its centre, rotated by the flow direction)
            vec2 fv;
            if (flow_vector(cell, code, fv)) {
                float a = float(atan(fv.y, fv.x) - 1.5707963267948966);
                float S = mh_sin(a) * 8.0, C = mh_cos(a) * 8.0;
                float du = -C - S + 2.0 * S * f.z + 2.0 * C * f.x;
                float dv = -C + S + 2.0 * C * f.z - 2.0 * S * f.x;
                texColor = fx_texel(FX_WATER_FLOW, int(floor(16.0 + du)), int(floor(16.0 + dv)));
            } else {
                texColor = fx_texel(FX_WATER, int(floor(clamp(f.x, 0.0, 0.999999) * 16.0)),
                                    int(floor(clamp(f.z, 0.0, 0.999999) * 16.0)));
            }
            level = fluid_level(cell);
            light = B_TOP[level] / 255.0;
        } else if (axis == 1) {
            // bottom: renderBottomFace with the still tile (u = x, v = z, 15.99 texels)
            texColor = fx_texel(FX_WATER, int(floor(f.x * 15.99)), int(floor(f.z * 15.99)));
            level = fluid_level(cell - ivec3(0, 1, 0));
            light = B_BOT[level] / 255.0;
        } else {
            // sides: flow tile, u = 0..15.99 along the face, v from (1 - h) * 16 at the top to 15.99 at the
            // bottom, affine on Alpha's triangles (top0, top1, bottom1), (top0, bottom1, bottom0)
            float s;
            ivec2 c0, c1;
            if (axis == 2 && n.z < 0.0) { s = f.x; c0 = ivec2(0, 0); c1 = ivec2(1, 0); }
            else if (axis == 2) { s = 1.0 - f.x; c0 = ivec2(1, 1); c1 = ivec2(0, 1); }
            else if (n.x < 0.0) { s = 1.0 - f.z; c0 = ivec2(0, 1); c1 = ivec2(0, 0); }
            else { s = f.z; c0 = ivec2(1, 0); c1 = ivec2(1, 1); }
            float h0 = fluid_height(cell.x + c0.x, cell.y, cell.z + c0.y, code);
            float h1 = fluid_height(cell.x + c1.x, cell.y, cell.z + c1.y, code);
            float vt0 = (1.0 - h0) * 16.0, vt1 = (1.0 - h1) * 16.0;
            float y = f.y;
            float v;
            if (y >= h0 * (1.0 - s)) {
                float c = (vt1 - 15.99) / h1;
                float a0 = vt0 - c * h0;
                v = a0 + (15.99 - a0) * s + c * y;
            } else {
                v = 15.99 + (vt0 - 15.99) / h0 * y;
            }
            texColor = fx_texel(FX_WATER_FLOW, int(floor(15.99 * s)), int(floor(v)));
            ivec3 nb = cell + ivec3(round(vec3(axis == 0 ? sign(n.x) : 0.0, 0.0, axis == 2 ? sign(n.z) : 0.0)));
            level = fluid_level(nb);
            light = (axis == 2 ? B_Z[level] : B_X[level]) / 255.0;
        }
    } else {
        // ice and other translucent cubes: as main.glslf
        ivec2 texel = ivec2(floor(T));
        float factor[16] = B_TOP;
        ivec3 lc = ivec3(floor(P));
        vec2 A = axis == 1 ? P.xz : axis == 0 ? P.zy : P.xy;
        mat2 dA = axis == 1 ? mat2(dPx.xz, dPy.xz) : axis == 0 ? mat2(dPx.zy, dPy.zy) : mat2(dPx.xy, dPy.xy);
        bool bottom = axis == 1 && n.y < 0.0;
        ivec2 blk;
        face_texel(T, A, dA, dT, bottom, texel, blk);
        ivec3 nb = cell + ivec3(round(vec3(axis == 0 ? sign(n.x) : 0.0, axis == 1 ? sign(n.y) : 0.0,
                                          axis == 2 ? sign(n.z) : 0.0)));
        factor = axis == 1 ? (bottom ? B_BOT : B_TOP) : axis == 0 ? B_X : B_Z;
        texColor = texelFetch(u_texture0, clamp(texel, ivec2(0), texSize - 1), 0);
        light = ready ? factor[lm_level(nb)] / 255.0 : 1.0;
    }
    if (!lighting) light = 1.0;
    float alpha = texColor.a;
    if (alpha < 0.002)
        discard;
    if (u_debugLights)
        texColor.rgb = u_debugNormals ? (a_normal * 0.5 + 0.5) : vec3(1.0);

    f_color = vec4(texColor.rgb * light, alpha);
    f_color.rgb = alpha_fog(f_color.rgb, a_fogDist);
}
