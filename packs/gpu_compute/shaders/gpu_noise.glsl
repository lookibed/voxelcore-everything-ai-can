// @gc program=noise marker=FD codes=auto
// Пример-клиент API (modules/examples/noise.lua): 3D value-noise fbm в текстуру прохода.
// Параметры — страница gc.params (слова u32/f32): 0 serial, 1 octaves, 2 f32 масштаб, 3 f32 z (срез), 4 seed,
//   5 f32 время (анимация), 6 ширина прохода. Выход: R,G,B = шум (0..255) трёх срезов z, z+0.33, z+0.66; строка 0 тексель 0..
//   Пиксель (W-1, H-1) хранит serial (эхо пакета для конвейера чтения).
uint nz_hash(ivec3 p, uint seed) {
    uint h = uint(p.x) * 374761393u + uint(p.y) * 668265263u + uint(p.z) * 2147483647u + seed * 144665u;
    h = (h ^ (h >> 13u)) * 1274126177u;
    return h ^ (h >> 16u);
}
float nz_val(ivec3 p, uint seed) { return float(nz_hash(p, seed) & 65535u) / 65535.0; }

float nz_noise(vec3 x, uint seed) {
    vec3 f = floor(x);
    ivec3 i = ivec3(f);
    vec3 t = x - f;
    vec3 u = t * t * (3.0 - 2.0 * t);
    float a = mix(nz_val(i, seed), nz_val(i + ivec3(1, 0, 0), seed), u.x);
    float b = mix(nz_val(i + ivec3(0, 1, 0), seed), nz_val(i + ivec3(1, 1, 0), seed), u.x);
    float c = mix(nz_val(i + ivec3(0, 0, 1), seed), nz_val(i + ivec3(1, 0, 1), seed), u.x);
    float d = mix(nz_val(i + ivec3(0, 1, 1), seed), nz_val(i + ivec3(1, 1, 1), seed), u.x);
    return mix(mix(a, b, u.y), mix(c, d, u.y), u.z);
}

float nz_fbm(vec3 x, int oct, uint seed) {
    float s = 0.0, a = 0.5, n = 0.0;
    for (int o = 0; o < oct; o++) {
        s += nz_noise(x, seed + uint(o)) * a;
        n += a;
        a *= 0.5;
        x *= 2.0;
    }
    return s / n;
}

void gc_main_noise(int code) {
    ivec2 p = ivec2(gl_FragCoord.xy);
    uint serial = gc_word(0);
    int oct = int(gc_word(1));
    float sc = gc_wordf(2), z = gc_wordf(3), tm = gc_wordf(5);
    uint seed = gc_word(4);
    ivec2 sz = ivec2(int(gc_word(6)), int(gc_word(7)));
    if (p.x == sz.x - 1 && p.y == sz.y - 1) { f_color = gc_rgb24(serial & 16777215u); return; }
    vec3 q = vec3(vec2(p) * sc, z + tm);
    float r = nz_fbm(q, oct, seed);
    float g = nz_fbm(q + vec3(0.0, 0.0, 0.33), oct, seed);
    float b = nz_fbm(q + vec3(0.0, 0.0, 0.66), oct, seed);
    f_color = vec4(floor(vec3(r, g, b) * 255.0 + 0.5) / 255.0, 1.0);
}
