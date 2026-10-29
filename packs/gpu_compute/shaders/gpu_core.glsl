// @gc program=core marker=FD codes=1-3
// Служебная программа пака gpu_compute (маркер #FD<код>FF80): проба порядка фреймов (modules/order.lua) и копии.
//   код 1 COPY — тексель источника по UV как есть, A = 1
//   код 2 INC  — 24-битное число RGB источника + 1 (цепочка проверки порядка)
//   код 3 ECHO — region="P,Q,P,Q" даёт постоянные UV (P, Q): пишет P в тексель x = 0, Q — в остальные (проба параметров)
vec4 gc_rgb24(uint v) {
    return vec4(float(v & 255u), float((v >> 8) & 255u), float((v >> 16) & 255u), 255.0) / 255.0;
}

ivec2 gc_uv_texel() {
    ivec2 size = textureSize(u_texture, 0);
    return clamp(ivec2(a_textureCoord * vec2(size)), ivec2(0), size - 1);
}

// слово u32 параметров: тексель i (строки по ширине текстуры), байты r | g << 8 | b << 16 | a << 24
uint gc_word(int i) {
    int w = textureSize(u_texture, 0).x;
    uvec4 c = uvec4(texelFetch(u_texture, ivec2(i % w, i / w), 0) * 255.0 + 0.5);
    return c.r | (c.g << 8u) | (c.b << 16u) | (c.a << 24u);
}
float gc_wordf(int i) { return uintBitsToFloat(gc_word(i)); }

void gc_main_core(int code) {
    if (code == 1) {
        f_color = vec4(texelFetch(u_texture, gc_uv_texel(), 0).rgb, 1.0);
    } else if (code == 2) {
        uvec4 c = uvec4(texelFetch(u_texture, gc_uv_texel(), 0) * 255.0 + 0.5);
        f_color = gc_rgb24((c.r | (c.g << 8) | (c.b << 16)) + 1u);
    } else {
        uint p = uint(a_textureCoord.x + 0.5), q = uint(a_textureCoord.y + 0.5);
        f_color = gc_rgb24(int(gl_FragCoord.x) == 0 ? p : q);
    }
}
