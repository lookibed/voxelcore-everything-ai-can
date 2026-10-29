// wasmrt: кадр с палитрой (vc_gfx_present_indexed) при графике 'posteffect'. Весь кадр идёт
// через uniform-массив (лимит драйвера ~1000 vec4), поэтому он уменьшен до u_size (по
// умолчанию 120x90): 3 индекса в числе (24 бита, точно в float), 12 в vec4 — 900 vec4;
// палитра — 256 цветов по одному в числе (0xRRGGBB) — 64 vec4. Цвет подставляет шейдер.
#param vec4 u_pix[900]
#param vec4 u_pal[64]
#param vec2 u_size = [120, 90]
#param float u_screenFill = 0.9

vec4 effect() {
    vec4 world = texture(u_screen, v_uv);
    vec2 screen = vec2(u_screenSize);
    float scale = min(screen.x / u_size.x, screen.y / u_size.y) * u_screenFill;
    vec2 origin = (screen - u_size * scale) * 0.5;
    vec2 p = (gl_FragCoord.xy - origin) / scale;
    if (p.x < 0.0 || p.y < 0.0 || p.x >= u_size.x || p.y >= u_size.y) {
        return world;
    }
    int x = int(p.x);
    int y = int(u_size.y - p.y);
    int i = y * int(u_size.x) + x;
    int f = i / 3;
    int lane = i - f * 3;
    int word = int(u_pix[f / 4][f - (f / 4) * 4]);
    int index = (word >> (8 * lane)) & 255;
    int color = int(u_pal[index / 4][index - (index / 4) * 4]);
    return vec4(float((color >> 16) & 255), float((color >> 8) & 255), float(color & 255), 255.0) / 255.0;
}
