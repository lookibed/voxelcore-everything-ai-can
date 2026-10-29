// alphamine: res/shaders/main.glslf (VoxelCore 0.31) with Alpha 1.0.16 texels and light (phase 3).
// Pack shaders replace the engine ones by name (tools/scenarios/alpha_probes/p4_shader.lua).
layout (location = 0) out vec4 f_color;
layout (location = 1) out vec4 f_position;
layout (location = 2) out vec4 f_normal;
layout (location = 3) out vec4 f_emission;

#include <world_fragment_header>

in vec4 a_torchLight;
in float a_alphaLight;   // main.glslv: Alpha colour from the engine light (fallback without the lightmap)
in float a_fogDist;      // main.glslv: eye-radial distance of the vertex


uniform sampler2D u_texture0;
uniform vec3 u_sunDir;

// flags
uniform bool u_alphaClip;
uniform bool u_debugLights;
uniform bool u_debugNormals;

#include <am_world>

void main() {
    ivec2 texSize = textureSize(u_texture0, 0);
    vec2 T = a_texCoord * vec2(texSize);
    vec3 n = a_realnormal;
    vec3 an = abs(n);
    vec3 P = a_modelpos.xyz;

    // dominant axis of the face normal; X sprites carry n = +Y but are vertical planes
    int axis = an.y > 0.9 ? 1 : an.x > 0.9 ? 0 : an.z > 0.9 ? 2 : -1;
    vec3 dPx = dFdx(P), dPy = dFdy(P);   // derivatives in uniform control flow only
    mat2 dT = mat2(dFdx(T), dFdy(T));
    // (only +Y faces can be sprites: a horizontal plane has dP.y ~ float noise, a sprite ~ the in-plane change)
    bool planar = axis >= 0 && (axis != 1 ||
        abs(dPx.y) + abs(dPy.y) < 0.25 * (abs(dPx.x) + abs(dPx.z) + abs(dPy.x) + abs(dPy.z)));
    ivec2 texel = ivec2(floor(T));
    ivec3 cell = ivec3(floor(P));
    float factor[16] = B_TOP;
    if (planar) {
        vec2 A = axis == 1 ? P.xz : axis == 0 ? P.zy : P.xy;
        mat2 dA = axis == 1 ? mat2(dPx.xz, dPy.xz) : axis == 0 ? mat2(dPx.zy, dPy.zy) : mat2(dPx.xy, dPy.xy);
        bool bottom = axis == 1 && n.y < 0.0;
        ivec2 blk;
        face_texel(T, A, dA, dT, bottom, texel, blk);
        float pn = P[axis];
        bool boundary = abs(pn - floor(pn + 0.5)) < 1e-3;
        int cn;
        if (bottom) {
            cn = (boundary ? int(floor(pn + 0.5)) : int(floor(pn))) - 1;   // renderBottomFace: always y - 1
        } else if (boundary) {
            cn = int(floor(pn + 0.5)) + (n[axis] > 0.0 ? 0 : -1);          // the neighbour cell
        } else {
            cn = int(floor(pn));                                            // inset face: own brightness
        }
        if (axis == 1) { cell = ivec3(blk.x, cn, blk.y); factor = bottom ? B_BOT : B_TOP; }
        else if (axis == 0) { cell = ivec3(cn, blk.y, blk.x); factor = B_X; }
        else { cell = ivec3(blk.x, blk.y, cn); factor = B_Z; }
    }
    else if (axis < 0 && an.y < 0.1) {
        // renderCrossedSquares planes (models/amblk_cross.vcm): u follows x on both diagonals, v follows y;
        // brightness of the own cell without a face factor (renderBlockReed: setColorOpaque_F(b, b, b))
        ivec2 blk;
        face_texel(T, P.xy, mat2(dPx.xy, dPy.xy), dT, false, texel, blk);
    }
    vec4 texColor = texelFetch(u_texture0, clamp(texel, ivec2(0), texSize - 1), 0);
    float alpha = texColor.a;
    if (u_alphaClip) {
        if (alpha < 0.2f)
            discard;
        alpha = 1.0;
    } else {
        if (alpha < 0.002f)
            discard;
    }
    if (u_debugLights)
        texColor.rgb = u_debugNormals ? (a_normal * 0.5 + 0.5) : vec3(1.0);

    float light;
    if (a_emission > 0.5) {
        light = 1.0;   // unlit vertex (F2F lighting:false): Java lighting:false = colour 255
    } else if (lm_ready()) {
        light = factor[lm_level(cell)] / 255.0;   // sprites: own cell, no face factor (renderCrossedSquares)
    } else {
        light = a_alphaLight;
    }
    f_color = texColor;
    f_color.rgb *= light;   // GL_MODULATE with the Tessellator colour

#if FOG_MODE == 0
    f_color.rgb = alpha_fog(f_color.rgb, a_fogDist);
#elif FOG_MODE == 1
    f_color.rgb = alpha_fog(f_color.rgb, length(a_position));
#else
    f_color.rgb = alpha_fog(f_color.rgb, abs(a_position.z));
#endif
    f_color.a = alpha;
    f_position = vec4(a_position, 1.0);
    f_normal = vec4(a_normal, 1.0);
    f_emission = vec4(vec3(a_emission), 1.0);
}
