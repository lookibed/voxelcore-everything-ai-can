#extension GL_ARB_gpu_shader_fp64 : enable
// СОБРАНО tools/gpu_compute_build.py — не править руками: тела программ лежат в content/<пак>/shaders/gpu_*.glsl.
// Пак gpu_compute: UI-шейдер движка (res/shaders/ui.glslf 0.31 = 0.32.1) + диспетчер вычислительных программ.
// Обычная картинка — как в движке: цвет вершины * текстура. Картинка с цветом #RRGGBB80, где B = 255, A = 128, —
// вызов программы: R — банк, G — код (таблица ниже и data/programs.json). Выход фрейма — RGBA8 со смешиванием
// SRC_ALPHA: программы пишут A = 1, данные несёт RGB.
//   core           пак gpu_compute  банк R=253 (#FD)  коды G=1..3  (gpu_compute/shaders/gpu_core.glsl)
//   noise          пак gpu_compute  банк R=253 (#FD)  коды G=4..4  (gpu_compute/shaders/gpu_noise.glsl)
//   gpu_worldgen   пак gpu_worldgen банк R=254 (#FE)  коды G=3..9  (gpu_worldgen/shaders/gpu_worldgen.glsl)
//   smollm_gpu     пак smollm_gpu   банк R=255 (#FF)  коды G=0..255  (smollm_gpu/shaders/gpu_smollm.glsl)

in vec2 a_textureCoord;
in vec4 a_color;
out vec4 f_color;

uniform sampler2D u_texture;

// ======== программа core (gpu_compute/shaders/gpu_core.glsl, sha1 45ddc8f2db15)
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

// ======== программа noise (gpu_compute/shaders/gpu_noise.glsl, sha1 68dd32b5927c)
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

// ======== программа gpu_worldgen (gpu_worldgen/shaders/gpu_worldgen.glsl, sha1 4f7ee7ca1206)
// @gc program=gpu_worldgen marker=FE codes=3-9
// Тело программы gpu_worldgen для общего ui.glslf пака gpu_compute (tools/gpu_compute_build.py собирает его в
// content/gpu_compute/shaders/ui.glslf). Маркер прежний: #FE03FF80. Исходный шейдер пака — ui.glslf.api.bak.
// UI-шейдер движка (res/shaders/ui.glslf 0.31 = 0.32.1) + «костыльный compute shader» пака gpu_worldgen.
// Обычная картинка — как в движке (цвет вершины * текстура). Картинка с цветом-маркером #FE03FF80
// (modules/gpu.lua, фрейм gpuwg_fb) — генератор мира: пиксель FBO фрейма = 6 вокселей столба чанка.
//
// Входные данные — текстура картинки (canvas gpuwg_params 256x4, RGBA8, слово u32 = тексель r|g<<8|b<<16|a<<24):
//   слово 0 serial, 1 mode (0 блоки, 1 плотность), 2 tilesX, 3 ntiles, 4 seed (< 2^20),
//   5 S, 6 SY, 7 AMP, 9 HSCALE, 13 CS, 14 CSY, 16 ORE_S (фикс. точка /1024), 8 BASE, 10 SEA, 11 OCT (целые),
//   12 CAVE_T, 15 ORE_T (фикс. точка /65536), 17 serialRow (строка FBO с эхом serial),
//   18 preset (0 classic — ветка ниже без изменений; 1 mountains, 2 caves, 3 islands — gw_preset_main),
//   20 + i — параметр i пресета (фикс. точка /1024, порядок слотов — modules/presets.lua, индексы — #define ниже),
//   слова 256 + 2i, 257 + 2i — cx, cz чанка плитки i (int32).
// Выход mode 0: плитка чанка 128x86 пикселей; пиксель (lx, ly) плитки: x = lx & 15, z = (lx >> 4) + 8 * (ly / 43),
//   группа g = ly % 43, воксели y = 6g .. 6g+5; канал c (R,G,B) = код(6g+2c) | код(6g+2c+1) << 4; A = 255
//   (UI рисует со смешиванием SRC_ALPHA — при A = 1 байт RGB доходит в FBO как есть).
// Выход mode 1: плитка 256x256, пиксель = плотность вокселя (x = lx & 15, z = lx >> 4, y = ly) в 24 битах
//   q = round((d + 8) * 2^20) — для сверки с CPU-референсом modules/noise.lua.
// Шум — улучшенный шум Перлина 3D (Perlin 2002: fade 6t^5-15t^4+10t^3, 12 градиентов по h & 15), но вместо
// таблицы перестановок — целочисленный хэш узла с умножениями только на 14-битные константы: в Lua (double +
// bit.tobit) он считается побайтно так же, как uint на GPU. Формулы продублированы в modules/noise.lua.

bool is_gw_marker(vec4 c) {
    return abs(c.r - 254.0 / 255.0) < 0.002 && abs(c.g - 3.0 / 255.0) < 0.002 && c.b > 0.99
        && abs(c.a - 128.0 / 255.0) < 0.01;
}

uint gw_u(int i) {
    int row = i / 256;
    uvec4 c = uvec4(texelFetch(u_texture, ivec2(i - row * 256, row), 0) * 255.0 + 0.5);
    return c.r | (c.g << 8u) | (c.b << 16u) | (c.a << 24u);
}
int gw_i(int i) { return int(gw_u(i)); }
float gw_f(int i) { return float(int(gw_u(i))) / 1024.0; }
float gw_f16(int i) { return float(int(gw_u(i))) / 65536.0; }

uint g_seedmix = 0u;
float g_S, g_SY, g_AMP, g_HSCALE, g_CS, g_CSY, g_ORE_S, g_CAVE_T, g_ORE_T;
int g_BASE, g_SEA, g_OCT;

int gw_hash(int x, int y, int z) {
    uint h = uint(x) * 1619u + uint(y) * 31337u + uint(z) * 6971u + g_seedmix;
    h = (h ^ (h >> 15u)) * 11291u;
    h = (h ^ (h >> 12u)) * 10619u;
    h = h ^ (h >> 15u);
    return int(h & 15u);
}

float gw_grad(int h, float x, float y, float z) {
    float u = h < 8 ? x : y;
    float v = h < 4 ? y : ((h == 12 || h == 14) ? x : z);
    return ((h & 1) == 0 ? u : -u) + ((h & 2) == 0 ? v : -v);
}

float gw_fade(float t) { return t * t * t * (t * (t * 6.0 - 15.0) + 10.0); }
float gw_lerp(float a, float b, float t) { return a + t * (b - a); }

float gw_noise(float px, float py, float pz) {
    float fx = floor(px), fy = floor(py), fz = floor(pz);
    int X = int(fx), Y = int(fy), Z = int(fz);
    float x = px - fx, y = py - fy, z = pz - fz;
    float u = gw_fade(x), v = gw_fade(y), w = gw_fade(z);
    float n000 = gw_grad(gw_hash(X, Y, Z), x, y, z);
    float n100 = gw_grad(gw_hash(X + 1, Y, Z), x - 1.0, y, z);
    float n010 = gw_grad(gw_hash(X, Y + 1, Z), x, y - 1.0, z);
    float n110 = gw_grad(gw_hash(X + 1, Y + 1, Z), x - 1.0, y - 1.0, z);
    float n001 = gw_grad(gw_hash(X, Y, Z + 1), x, y, z - 1.0);
    float n101 = gw_grad(gw_hash(X + 1, Y, Z + 1), x - 1.0, y, z - 1.0);
    float n011 = gw_grad(gw_hash(X, Y + 1, Z + 1), x, y - 1.0, z - 1.0);
    float n111 = gw_grad(gw_hash(X + 1, Y + 1, Z + 1), x - 1.0, y - 1.0, z - 1.0);
    float x00 = gw_lerp(n000, n100, u);
    float x10 = gw_lerp(n010, n110, u);
    float x01 = gw_lerp(n001, n101, u);
    float x11 = gw_lerp(n011, n111, u);
    float y0 = gw_lerp(x00, x10, v);
    float y1 = gw_lerp(x01, x11, v);
    return gw_lerp(y0, y1, w);
}

float gw_fbm(float px, float py, float pz) {
    float sum = 0.0, amp = 1.0, norm = 0.0;
    for (int o = 0; o < g_OCT; o++) {
        sum += gw_noise(px + float(o) * 31.25, py, pz + float(o) * 17.125) * amp;
        norm += amp;
        amp *= 0.5;
        px *= 2.0; py *= 2.0; pz *= 2.0;
    }
    return sum / norm;
}

// плотность: > 0 — твёрдое; выше 255 — воздух; ниже BASE спад вдвое круче (без полостей с водой в глубине)
float gw_density(int wx, int wy, int wz) {
    if (wy > 255) return -1.0;
    return gw_fbm(float(wx) / g_S, float(wy) / g_SY, float(wz) / g_S) * g_AMP
        + float(g_BASE - wy) / (wy < g_BASE ? g_HSCALE * 0.5 : g_HSCALE);
}

bool gw_cave(int wx, int wy, int wz) {
    float cx = float(wx) / g_CS, cy = float(wy) / g_CSY, cz = float(wz) / g_CS;
    float n1 = gw_noise(cx + 100.5, cy, cz);
    float n2 = gw_noise(cx, cy + 50.25, cz - 30.75);
    return n1 * n1 + n2 * n2 < g_CAVE_T;
}

bool gw_ore(int wx, int wy, int wz) {
    return gw_noise(float(wx) / g_ORE_S - 7.5, float(wy) / g_ORE_S + 3.25, float(wz) / g_ORE_S + 11.75) > g_ORE_T;
}

// коды: 0 воздух, 1 камень, 2 земля, 3 дёрн, 4 песок, 5 вода, 6 базальт, 7 угольная руда
int gw_code(int wx, int y, int wz, bool s0, bool s1, bool s2, bool s3) {
    if (y > 255) return 0;
    if (y == 0) return 6;
    if (s0) {
        if (y > 4 && gw_cave(wx, y, wz)) return 0;
        if (!s1) return y <= g_SEA + 1 ? 4 : 3;
        if (!s2 || !s3) return y <= g_SEA + 1 ? 4 : 2;
        if (gw_ore(wx, y, wz)) return 7;
        return 1;
    }
    return y <= g_SEA ? 5 : 0;
}

vec4 gw_bytes(uint v) {
    return vec4(float(v & 255u), float((v >> 8u) & 255u), float((v >> 16u) & 255u), 255.0) / 255.0;
}

// ---------------------------------------------------------------------------------------------------------------
// Пресеты-витрины (слово 18 != 0). Параметры — слова 20 + i (фикс. точка /1024), значения и порядок слотов задаёт
// modules/presets.lua (там же имена); индексы ниже должны совпадать с порядком слотов в presets.lua.
// Пиксель = 6 вокселей столба (y0..y0+5), как в classic. Для правил считаются 10 вокселей y0-1..y0+8:
//   T[k] — «рельеф» (плотность > 0), C[k] — рельеф, вырезанный пещерой/туннелем (воздух внутри скалы).
// Коды (4 бита; что они значат в блоках — idmap пресета в presets.lua):
//   0 воздух, 1 камень, 2 земля, 3 дёрн, 4 песок, 5 вода, 6 базальт, 7 уголь, 8 снег, 9 лава,
//   10 свечение A (кристалл), 11 свечение B (светокамень), 12 гравий-камень (резерв), 13 лёд, 14 трава, 15 цветок
// параметры пресета читаются из текстуры при каждом использовании (не массивом g_p[44] в регистрах: в общем ui.glslf
// пака gpu_compute регистры шейдера = максимум по всем программам, массив замедлял smollm_gpu на ~20%)
#define GP(i) gw_f(20 + (i))

#define M_S 0
#define M_SY 1
#define M_AMP 2
#define M_BASE 3
#define M_CA 4
#define M_CS 5
#define M_HUP 6
#define M_HDN 7
#define M_HFS 8
#define M_HFMIN 9
#define M_HFMAX 10
#define M_OCT 11
#define M_TOP 12
#define M_SEA 13
#define M_SNOW 14
#define M_ROCK 15
#define M_TS 16
#define M_TSY 17
#define M_TT 18
#define M_FALL 19
#define M_FALLH 20
#define M_GRASSP 21
#define M_FLOWERP 22
#define M_GLOWT 23
#define M_MH 24
#define M_RS 25

#define C_S 0
#define C_SY 1
#define C_AMP 2
#define C_BASE 3
#define C_CA 4
#define C_CS 5
#define C_HUP 6
#define C_HDN 7
#define C_OCT 8
#define C_SEA 9
#define C_CHS 10
#define C_CHSY 11
#define C_CHT 12
#define C_CHTOP 13
#define C_PIL 14
#define C_SPS 15
#define C_SPSY 16
#define C_SPT 17
#define C_NOS 18
#define C_NOT 19
#define C_AQ 20
#define C_WET 21
#define C_WMIN 22
#define C_WRANGE 23
#define C_LAVA 24
#define C_GLOWT 25
#define C_LAMPP 26
#define C_GRASSP 27
#define C_FLOWERP 28
#define C_SINK 29
#define C_PILS 30
#define C_SINKA 31
#define C_SINKT 32

#define I_Y0 0
#define I_DY 1
#define I_NL 2
#define I_IS 3
#define I_T 4
#define I_G 5
#define I_HT 6
#define I_HB 7
#define I_SPS 8
#define I_SPA 9
#define I_DS 10
#define I_DSY 11
#define I_DA 12
#define I_BS 13
#define I_BW 14
#define I_BG 15
#define I_YOFF 16
#define I_FALL 17
#define I_FALLH 18
#define I_LAMPP 19
#define I_GRASSP 20
#define I_FLOWERP 21
#define I_OCT 22
#define I_LAMPT 23

// 32-битный хэш точки (решения «поставить ли цветок/кристалл»): зависит от seed через g_seedmix
uint gw_h32(int x, int y, int z, uint salt) {
    uint h = uint(x) * 1619u + uint(y) * 31337u + uint(z) * 6971u + g_seedmix + salt * 1013904223u;
    h = (h ^ (h >> 15u)) * 2246822519u;
    h = (h ^ (h >> 13u)) * 3266489917u;
    return h ^ (h >> 16u);
}
float gw_rand(int x, int y, int z, uint salt) { return float(gw_h32(x, y, z, salt) & 65535u) / 65536.0; }

float gw_fbmn(float px, float py, float pz, int oct) {
    float sum = 0.0, amp = 1.0, norm = 0.0;
    for (int o = 0; o < oct; o++) {
        sum += gw_noise(px + float(o) * 31.25, py, pz + float(o) * 17.125) * amp;
        norm += amp;
        amp *= 0.5;
        px *= 2.0; py *= 2.0; pz *= 2.0;
    }
    return sum / norm;
}
// 2D-шум столба: срез 3D-шума на дробной высоте (salt разводит поля)
float gw_n2(float x, float z, float salt) { return gw_noise(x + salt * 13.37, salt * 7.31 + 0.5, z - salt * 5.17); }

// ----- столбец (общие для 10 вокселей пикселя значения)
float g_cb, g_chf, g_csink;      // mountains/caves: базовая высота столба, множитель высоты, шум провалов (caves)
float g_A[3], g_Y[3], g_SP[3];   // islands: «сила» острова слоя k, высота слоя, удлинение корней
bool g_BR[3]; float g_BY[3];     // islands: столб на мосту слоя k, высота моста

void gw_column(int preset, float x, float z) {
    if (preset == 1) {
        // горные массивы: гребни ridged-шума (1 - |fbm|)^2 высотой до MH, маска хребтов HFMIN..HFMAX;
        // 3D-шум поверх (амплитуда растёт в горах) даёт нависания, арки и отколовшиеся скалы
        float mask = smoothstep(-0.3, 0.4, gw_n2(x / GP(M_HFS), z / GP(M_HFS), 2.0));
        float r = 1.0 - abs(gw_fbmn(x / GP(M_RS), 7.5, z / GP(M_RS), 3));
        g_cb = GP(M_BASE) + GP(M_CA) * gw_n2(x / GP(M_CS), z / GP(M_CS), 1.0)
            + GP(M_MH) * mix(GP(M_HFMIN), GP(M_HFMAX), mask) * r * r;
        g_chf = 0.6 + 0.8 * mask;
    } else if (preset == 2) {
        g_cb = GP(C_BASE) + GP(C_CA) * gw_n2(x / GP(C_CS), z / GP(C_CS), 1.0);
        g_csink = gw_n2(x / 90.0, z / 90.0, 8.0);
    } else {
        int nl = int(GP(I_NL));
        for (int k = 0; k < 3; k++) {
            g_A[k] = -10.0;
            g_BR[k] = false;
            if (k >= nl) continue;
            float fk = float(k);
            float m = gw_fbmn(x / GP(I_IS) + 100.0 * fk, 3.5 + 11.0 * fk, z / GP(I_IS) - 37.0 * fk, int(GP(I_OCT)));
            g_A[k] = (m - GP(I_T)) * GP(I_G);
            g_Y[k] = GP(I_Y0) + GP(I_DY) * fk + GP(I_YOFF) * gw_n2(x / 220.0, z / 220.0, 4.0 + fk);
            float s = max(0.0, gw_n2(x / GP(I_SPS), z / GP(I_SPS), 6.0 + fk));
            g_SP[k] = 1.0 + GP(I_SPA) * s * s;
            // мост: линия нуля 2D-шума рядом с островами слоя, высота плавно гуляет — арки между островами
            float b = gw_n2(x / GP(I_BS), z / GP(I_BS), 9.0 + fk);
            g_BR[k] = abs(b) < GP(I_BW) && m > GP(I_T) - GP(I_BG);
            g_BY[k] = g_Y[k] + 2.0 + 5.0 * gw_n2(x / 41.0, z / 41.0, 12.0 + fk);
        }
    }
}

// плотность рельефа (> 0 — твёрдое)
float gw_pdens(int preset, float x, int iy, float z) {
    if (iy > 255) return -1.0;
    float y = float(iy);
    if (preset == 1) {
        float hf = g_chf;
        float f = gw_fbmn(x / GP(M_S), y / GP(M_SY), z / GP(M_S), int(GP(M_OCT)));
        float d = f * GP(M_AMP) * hf + (g_cb - y) / (y > g_cb ? GP(M_HUP) : GP(M_HDN));
        return d - max(0.0, y - GP(M_TOP)) * 0.25;
    } else if (preset == 2) {
        float f = gw_fbmn(x / GP(C_S), y / GP(C_SY), z / GP(C_S), int(GP(C_OCT)));
        return f * GP(C_AMP) + (g_cb - y) / (y > g_cb ? GP(C_HUP) : GP(C_HDN));
    }
    float d = -10.0;
    float det = GP(I_DA) * gw_noise(x / GP(I_DS) + 50.5, y / GP(I_DSY), z / GP(I_DS));
    for (int k = 0; k < 3; k++) {
        if (g_A[k] > -3.0) {
            float t = y - g_Y[k];
            float dk = g_A[k] - (t > 0.0 ? t / GP(I_HT) : -t / (GP(I_HB) * g_SP[k])) + det;
            d = max(d, dk);
        }
        if (g_BR[k] && abs(y - g_BY[k]) <= 1.0) d = max(d, 0.5);
    }
    return d;
}

// вырезание (пещеры/туннели) внутри рельефа
bool gw_pcarve(int preset, float x, int iy, float z) {
    float y = float(iy);
    if (iy <= 4) return false;
    if (preset == 1) {
        if (iy <= 8) return false;
        float n1 = gw_noise(x / GP(M_TS) + 100.5, y / GP(M_TSY), z / GP(M_TS));
        float n2 = gw_noise(x / GP(M_TS), y / GP(M_TSY) + 50.25, z / GP(M_TS) - 30.75);
        return n1 * n1 + n2 * n2 < GP(M_TT);
    } else if (preset == 2) {
        // «сыр»: большие залы глубже CHTOP под поверхностью, с колоннами
        // провалы: там, где 2D-шум > SINK, «сыр» доходит до поверхности (входы-воронки в залы)
        float depth = g_cb - y;
        float sf = clamp((g_csink - GP(C_SINK)) / 0.15, 0.0, 1.0);
        float chtop = GP(C_CHTOP) - GP(C_SINKA) * sf;
        float cht = GP(C_CHT) - GP(C_SINKT) * sf;
        float fade = clamp((depth - chtop) / 14.0, 0.0, 1.0) * clamp((y - 6.0) / 10.0, 0.0, 1.0);
        if (fade > 0.0) {
            float c = gw_noise(x / GP(C_CHS) + 7.5, y / GP(C_CHSY), z / GP(C_CHS)) * 0.75
                + gw_noise(x / GP(C_CHS) * 2.0 + 13.5, y / GP(C_CHSY) * 2.0, z / GP(C_CHS) * 2.0) * 0.25;
            if (c * fade > cht) {
                float pil = gw_noise(x / GP(C_PILS) + 3.3, y / 30.0, z / GP(C_PILS) - 8.1);
                if (pil < GP(C_PIL)) return true;
            }
        }
        // «спагетти» — может выходить на поверхность (входы в пещеры)
        float n1 = gw_noise(x / GP(C_SPS) + 100.5, y / GP(C_SPSY), z / GP(C_SPS));
        float n2 = gw_noise(x / GP(C_SPS), y / GP(C_SPSY) + 50.25, z / GP(C_SPS) - 30.75);
        if (n1 * n1 + n2 * n2 < GP(C_SPT)) return true;
        // «лапша» — тонкие ходы
        float m1 = gw_noise(x / GP(C_NOS) - 40.5, y / GP(C_NOS), z / GP(C_NOS) + 9.5);
        float m2 = gw_noise(x / GP(C_NOS) + 21.5, y / GP(C_NOS) - 70.25, z / GP(C_NOS));
        return m1 * m1 + m2 * m2 < GP(C_NOT);
    }
    return false;
}

// материал верхнего блока рельефа на высоте y (снег/скала/песок/дёрн)
int gw_top(int preset, int wx, int iy, int wz) {
    float y = float(iy);
    if (preset == 1) {
        float sn = GP(M_SNOW) + 9.0 * gw_n2(float(wx) / 23.0, float(wz) / 23.0, 3.0);
        if (y >= sn) return 8;
        if (y >= sn - GP(M_ROCK)) return 1;
        return y <= GP(M_SEA) + 1.0 ? 4 : 3;
    } else if (preset == 2) {
        return y <= GP(C_SEA) + 1.0 ? 4 : 3;
    }
    return 3;
}

// водоносные ячейки пещер (2D, C_AQ блоков): тип и уровень жидкости; 0 — сухо (лава до C_LAVA)
void gw_aquifer(int cx, int cz, out bool wet, out float level) {
    uint h = gw_h32(cx, 777, cz, 77u);
    wet = float(h & 65535u) / 65536.0 < GP(C_WET);
    level = wet ? GP(C_WMIN) + float((h >> 16u) % uint(max(1.0, GP(C_WRANGE)))) : GP(C_LAVA);
}

// водопад: столб воды под «крышей» рельефа (mountains: из-под нависаний/арок до земли; islands: через остров в пустоту)
float g_fall_k;  // 0.5..1: длина водопада острова (доля FALLH) по хэшу ячейки
bool gw_fall_col(int wx, int wz, float cell, bool wide) {
    int c = int(cell);
    int cx = int(floor(float(wx) / cell)), cz = int(floor(float(wz) / cell));
    uint h = gw_h32(cx, 555, cz, 31u);
    int px = cx * c + 2 + int(h % uint(c - 4));
    int pz = cz * c + 2 + int((h >> 12u) % uint(c - 4));
    g_fall_k = 0.5 + 0.5 * float((h >> 24u) & 255u) / 255.0;
    if (wide) return (wx == px || wx == px + 1) && (wz == pz || wz == pz + 1);
    return wx == px && wz == pz;
}

#define GW_T(k) (((Tm >> uint(k)) & 1u) != 0u)
#define GW_C(k) (((Cm >> uint(k)) & 1u) != 0u)
uint gw_preset_main(int preset, int wx, int wz, int y0) {
    float x = float(wx), z = float(wz);
    gw_column(preset, x, z);
    // T, C — битовые маски (бит k), не bool-массивы: меньше регистров в общем ui.glslf (см. GP выше)
    uint Tm = 0u, Cm = 0u;
    for (int k = 0; k < 10; k++) {
        int y = y0 - 1 + k;
        if (y < 0) { if (preset != 3) Tm |= 1u << uint(k); continue; }
        bool tk = gw_pdens(preset, x, y, z) > 0.0;
        if (tk) Tm |= 1u << uint(k);
        if (tk && gw_pcarve(preset, x, y, z)) Cm |= 1u << uint(k);
    }
    // водопады: расстояние до ближайшего твёрдого рельефа выше пикселя (только в столбах водопада)
    bool fallc = false;
    float fallh = 0.0;
    int above = 100000;
    int below = -100000;
    if (preset == 1 || preset == 3) {
        float cell = preset == 1 ? GP(M_FALL) : GP(I_FALL);
        fallh = preset == 1 ? GP(M_FALLH) : GP(I_FALLH);
        fallc = gw_fall_col(wx, wz, cell, preset == 3);
        if (fallc) {
            if (preset == 3) fallh *= g_fall_k;
            for (int y = y0 + 9; y <= min(255, y0 + 8 + int(fallh)); y++) {
                if (gw_pdens(preset, x, y, z) > 0.0) { above = y; break; }
            }
            // mountains: и земля (или море) снизу не дальше FALLH — столб воды опирается на обе стороны
            if (preset == 1) {
                for (int y = y0 - 2; y >= max(0, y0 - 1 - int(fallh)); y--) {
                    if (float(y) <= GP(M_SEA) || gw_pdens(preset, x, y, z) > 0.0) { below = y; break; }
                }
            }
        }
    }
    uint v = 0u;
    for (int j = 0; j < 6; j++) {
        int k = j + 1;
        int y = y0 + j;
        int code = 0;
        if (y > 255) { code = 0; }
        else if (y == 0 && preset != 3) { code = 6; }
        else {
            bool t = GW_T(k), c = GW_C(k);
            // ближайший твёрдый рельеф выше (или в) вокселе — для водопадов
            bool fall = false;
            if (fallc) {
                int roof = above;
                for (int kk = 9; kk >= k + (preset == 3 ? 0 : 1); kk--) if (GW_T(kk)) roof = y0 - 1 + kk;
                if (preset == 3) {
                    fall = float(roof - y) <= fallh;
                } else if (!t && float(y) > GP(M_SEA)) {
                    int ground = below;
                    for (int kk = 0; kk < k; kk++) if (GW_T(kk) || float(y0 - 1 + kk) <= GP(M_SEA)) ground = y0 - 1 + kk;
                    // из-под нависания/арки до земли, или по стене обрыва от «родника» на высоте ground + L
                    fall = float(roof - ground) <= fallh;
                    if (!fall && ground > -1000) {
                        float L = fallh * g_fall_k;
                        int sy = ground + int(L);
                        if (float(y - ground) <= L && sy <= 255) {
                            fall = gw_pdens(preset, x + 1.0, sy, z) > 0.0 || gw_pdens(preset, x - 1.0, sy, z) > 0.0
                                || gw_pdens(preset, x, sy, z + 1.0) > 0.0 || gw_pdens(preset, x, sy, z - 1.0) > 0.0;
                        }
                    }
                }
            }
            if (fall) {
                code = 5;
            } else if (t && !c) {
                int top = gw_top(preset, wx, y, wz);
                if (!GW_T(k + 1)) code = top;
                else if (!GW_T(k + 2) || !GW_T(k + 3)) code = top == 3 ? 2 : (top == 8 ? 1 : top);
                else {
                    code = gw_noise(x / 6.0 - 7.5, float(y) / 6.0 + 3.25, z / 6.0 + 11.75) > 0.62 ? 7 : 1;
                    if (preset == 2 && y < 9 && gw_rand(wx, y, wz, 5u) < 0.5) code = 6;
                }
            } else if (t && c) {
                // воздух в скале: жидкости и свечение
                code = 0;
                bool floor_ = GW_T(k - 1) && !GW_C(k - 1);
                bool ceil_ = GW_T(k + 1) && !GW_C(k + 1);
                if (preset == 2) {
                    float aq = GP(C_AQ);
                    int acx = int(floor(x / aq)), acz = int(floor(z / aq));
                    bool wet; float lvl;
                    gw_aquifer(acx, acz, wet, lvl);
                    // барьер на границе ячеек с разными уровнями (как aquifer barrier в Minecraft 1.18)
                    int lx = wx - acx * int(aq), lz = wz - acz * int(aq);
                    bool barrier = false;
                    for (int n = 0; n < 4; n++) {
                        int dx = n == 0 ? -1 : (n == 1 ? 1 : 0);
                        int dz = n == 2 ? -1 : (n == 3 ? 1 : 0);
                        bool edge = (dx == -1 && lx == 0) || (dx == 1 && lx == int(aq) - 1)
                            || (dz == -1 && lz == 0) || (dz == 1 && lz == int(aq) - 1);
                        if (!edge) continue;
                        bool w2; float l2;
                        gw_aquifer(acx + dx, acz + dz, w2, l2);
                        if ((w2 != wet || l2 != lvl) && float(y) <= max(lvl, l2)) barrier = true;
                    }
                    if (barrier) code = 1;
                    else if (float(y) <= lvl) code = wet ? 5 : 9;
                    else if (floor_ && gw_noise(x / 4.0 + 1.5, float(y) / 4.0, z / 4.0 - 2.5) > GP(C_GLOWT)
                        && gw_rand(wx, y, wz, 7u) < 0.45) code = 10;
                    else if (ceil_ && gw_noise(x / 3.0 - 6.5, float(y) / 3.0 + 1.5, z / 3.0) > 0.25
                        && gw_rand(wx, y, wz, 9u) < GP(C_LAMPP)) code = 11;
                } else if (preset == 1) {
                    if (floor_ && gw_noise(x / 4.0 + 1.5, float(y) / 4.0, z / 4.0 - 2.5) > GP(M_GLOWT)) code = 10;
                }
            } else {
                // воздух/вода рельефа
                float sea = preset == 1 ? GP(M_SEA) : (preset == 2 ? GP(C_SEA) : -1.0);
                if (float(y) <= sea) {
                    code = 5;
                    if (preset == 1 && float(y) == sea && gw_top(preset, wx, y, wz) == 8) code = 13;
                } else if (GW_T(k - 1) && !GW_C(k - 1) && gw_top(preset, wx, y - 1, wz) == 3) {
                    float r = gw_rand(wx, y, wz, 3u);
                    float gp = preset == 1 ? GP(M_GRASSP) : (preset == 2 ? GP(C_GRASSP) : GP(I_GRASSP));
                    float fp = preset == 1 ? GP(M_FLOWERP) : (preset == 2 ? GP(C_FLOWERP) : GP(I_FLOWERP));
                    if (r < fp) code = 15;
                    else if (r < fp + gp) code = 14;
                } else if (preset == 3 && GW_T(k + 1) && !GW_C(k + 1)
                    && gw_noise(x / 5.0 + 4.5, float(y) / 5.0, z / 5.0) > GP(I_LAMPT)
                    && gw_rand(wx, y, wz, 11u) < GP(I_LAMPP)) {
                    code = 11;
                }
            }
        }
        v |= uint(code) << uint(4 * j);
    }
    return v;
}

vec4 gw_main() {
    ivec2 p = ivec2(gl_FragCoord.xy);
    uint serial = gw_u(0);
    int mode = gw_i(1);
    int tilesX = gw_i(2);
    int ntiles = gw_i(3);
    // цепочка RLE (слово 112 = высота кадров цепочки, 0 — без неё): верхние 4 строки — копия слов параметров
    // (24 бита) для проходов 4..9, строки между serialRow и ними — нули (области проходов)
    int hrle = gw_i(112);
    if (hrle > 0 && p.y >= hrle - 4) {
        return p.x < 256 ? gw_bytes(gw_u((p.y - (hrle - 4)) * 256 + p.x) & 16777215u) : gw_bytes(0u);
    }
    if (hrle > 0 && p.y > gw_i(17)) return gw_bytes(0u);
    if (p.y == gw_i(17)) {
        return p.x == 0 ? gw_bytes(serial & 16777215u) : gw_bytes(0u);
    }
    int preset = gw_i(18);
    int TW = mode == 0 ? 128 : 256;
    int TH = mode == 0 ? 86 : 256;
    int tx = p.x / TW, ty = p.y / TH;
    if (tx >= tilesX) return gw_bytes(0u);
    int tile = ty * tilesX + tx;
    if (tile >= ntiles) return gw_bytes(0u);
    g_seedmix = gw_u(4) * 1013u;
    g_S = gw_f(5); g_SY = gw_f(6); g_AMP = gw_f(7); g_BASE = gw_i(8); g_HSCALE = gw_f(9);
    g_SEA = gw_i(10); g_OCT = gw_i(11); g_CAVE_T = gw_f16(12); g_CS = gw_f(13); g_CSY = gw_f(14);
    g_ORE_T = gw_f16(15); g_ORE_S = gw_f(16);
    int cx = gw_i(256 + 2 * tile), cz = gw_i(257 + 2 * tile);
    int lx = p.x - tx * TW, ly = p.y - ty * TH;
    if (mode == 1) {
        int wx = cx * 16 + (lx & 15), wz = cz * 16 + (lx >> 4);
        float d = gw_density(wx, ly, wz);
        int q = clamp(int(floor((d + 8.0) * 1048576.0 + 0.5)), 0, 16777215);
        return gw_bytes(uint(q));
    }
    int wx = cx * 16 + (lx & 15);
    int wz = cz * 16 + (lx >> 4) + 8 * (ly / 43);
    int y0 = 6 * (ly % 43);
    // вызов с константой пресета: компилятор вычищает чужие ветки из каждой копии (меньше живых значений и регистров в
    // общем ui.glslf, где регистры шейдера = максимум по всем программам; результат тот же)
    if (preset == 1) return gw_bytes(gw_preset_main(1, wx, wz, y0));
    if (preset == 2) return gw_bytes(gw_preset_main(2, wx, wz, y0));
    if (preset != 0) return gw_bytes(gw_preset_main(3, wx, wz, y0));
    uint sm = 0u;   // бит k — плотность вокселя y0 + k > 0 (маска вместо bool s[9])
    for (int k = 0; k < 9; k++) {
        if (gw_density(wx, y0 + k, wz) > 0.0) sm |= 1u << uint(k);
    }
    uint v = 0u;
    for (int j = 0; j < 6; j++) {
        v |= uint(gw_code(wx, y0 + j, wz, ((sm >> uint(j)) & 1u) != 0u, ((sm >> uint(j + 1)) & 1u) != 0u,
            ((sm >> uint(j + 2)) & 1u) != 0u, ((sm >> uint(j + 3)) & 1u) != 0u)) << uint(4 * j);
    }
    // байты: R = коды 0,1; G = 2,3; B = 4,5 (младший полубайт — нижний воксель)
    return gw_bytes(v);
}


// ---------------------------------------------------------------------------------------------------------------
// RLE на GPU (12.10, gpu_pack2): цепочка проходов gc.chain после генерации (код 3) — коды 4..9. Lua получает готовый
// поток extrle16 чанка (src/coders/rle.cpp extrle::encode16 по 65536 u16 id + 65536 нулевых state, ids <= 255),
// байт в байт как modules/codec.lua (M.extrle16), и только копирует байты, gzip (compression.encode) и set_chunk_data.
// Общая раскладка кадров 1..6 (W x H, строка 0 — низ FBO): плитки кодов (как в коде 3), строка serialRow, строка деревьев
// TR, области ST (статистика слоёв), BY (байты слоёв), PF (префиксная сумма байт) — по ceil(nt*256/W) строк; верхние
// 4 строки H-4..H-1 — копия слов параметров (24 бита, слово i -> тексель (i & 255, H-4 + i/256)), их пишет код 3.
// Каждый проход пишет свою область и копирует остальное из входа (один сэмплер на картинку — всё нужное идёт дальше
// по цепочке). Слои — y чанка: слой s = 256 вокселей (z, x) порядка движка (y*16 + z)*16 + x.
//   код 4 — деревья: тексель t строки TR = поверхность y деревьев плитки t (3 x 8 бит, 255 — нет), как
//           presets.make_deco (последовательно: дерево i видит листву/стволы деревьев < i)
//   код 5 — коды плиток с деревьями (ствол — код WOOD, листва — LEAF; эти коды генератор не выдаёт)
//   код 6 — слой s: число стартов серий nst (9 бит) | позиция первого старта (8 бит) << 9;
//           старт — id отличается от предыдущего в порядке движка
//   код 7 — слой s: байт записей серий, начатых в слое (длина серии — до следующего старта, через слои; хвост чанка —
//           нули state: последняя серия id продолжается в них, если id[65535] == 0; серии > 16384 режутся как в rle.cpp)
//   код 8 — слой s: смещение = сумма байт слоёв < s
//   код 9 — кадр E (W x (1 + nt*KR + HMR)): строка 0 — тексель 0 serial, тексель 1 + t — длина потока плитки t (байт);
//           строки 1 + t*KR … — поток плитки t, 3 байта на тексель (R, G, B); со строки HM (слово 114) — высоты столбцов:
//           тексель t*86 + j — столбцы 3j..3j+2 (индекс z*16 + x) плитки t, байт = 1 + y верхнего вокселя, закрывающего
//           небо (не воздух/вода/трава/цветок; с деревьями), 0 — такого нет; за ними (тексель (nt + t)*86 + j) — y нижнего
//           такого вокселя, 255 — нет (свет неба пака gpu_worldgen_light)
// Слова параметров (modules/gpu.lua): 100 rle, 101 деревьев, 102 порог шанса (h>>20 & 1023 >= — нет дерева), 103 max_y,
// 104 tmin, 105 tmax, 106 код листвы, 107 код ствола, 108 TR, 109 ST, 110 BY, 111 PF, 112 H, 113 KR, 114 HM,
// 120+code — id блока.

ivec2 gwr_p;
int gwr_H, gwr_W, gwr_nt, gwr_tilesX, gwr_ST, gwr_BY, gwr_PF;

uvec3 gwr_rd(ivec2 p) { return uvec3(texelFetch(u_texture, p, 0).rgb * 255.0 + 0.5); }
uint gwr_rd24(ivec2 p) { uvec3 c = gwr_rd(p); return c.r | (c.g << 8u) | (c.b << 16u); }
int gwr_info(int i) {
    uint v = gwr_rd24(ivec2(i & 255, gwr_H - 4 + (i >> 8)));
    return v >= 8388608u ? int(v) - 16777216 : int(v);
}
vec4 gwr_copy() { return vec4(texelFetch(u_texture, gwr_p, 0).rgb, 1.0); }

// код вокселя (x, y, z) плитки t (раскладка кода 3)
int gwr_code(int t, int x, int y, int z) {
    int tx = t % gwr_tilesX, ty = t / gwr_tilesX;
    uvec3 c = gwr_rd(ivec2(tx * 128 + x + 16 * (z & 7), ty * 86 + (z >> 3) * 43 + y / 6));
    int j = y % 6;
    uint b = j < 2 ? c.r : (j < 4 ? c.g : c.b);
    return int((j & 1) == 0 ? (b & 15u) : (b >> 4u));
}

// ----- деревья (presets.make_deco, h32 той же формулой)
int gwr_cx, gwr_cz, gwr_seed, gwr_tmin, gwr_tspan, gwr_leaf, gwr_wood;
uint gwr_th32(int a, int b, int c, int d) {
    uint h = uint(a) * 1619u + uint(b) * 31337u + uint(c) * 6971u + uint(d) * 1013u;
    h = (h ^ (h >> 15u)) * 11291u;
    h = (h ^ (h >> 12u)) * 10619u;
    return h ^ (h >> 15u);
}
void gwr_tree_setup(int t) {
    gwr_cx = gwr_info(256 + 2 * t);
    gwr_cz = gwr_info(257 + 2 * t);
    gwr_seed = gwr_info(4);
    gwr_tmin = gwr_info(104);
    gwr_tspan = gwr_info(105) - gwr_tmin + 1;
    gwr_leaf = gwr_info(106);
    gwr_wood = gwr_info(107);
}
bool gwr_soft(int c) { return c == 0 || c == 14 || c == 15; }
// дерево i (поверхность yi, 255 — нет) на код c вокселя (x, y, z): крона (только в мягкое), затем ствол
int gwr_tree(int i, int yi, int c, int x, int y, int z) {
    if (yi >= 255) return c;
    uint h = gwr_th32(gwr_cx, gwr_cz, i, gwr_seed);
    int tx = 2 + int(h & 15u) % 12, tz = 2 + int((h >> 4u) & 15u) % 12;
    int top = yi + gwr_tmin + int((h >> 8u) & 7u) % gwr_tspan;
    if (y >= top - 2 && y <= top + 1) {
        int r = y <= top - 1 ? 2 : 1;
        int dx = x - tx, dz = z - tz;
        if (abs(dx) <= r && abs(dz) <= r) {
            bool cut = r == 2 && abs(dx) == 2 && abs(dz) == 2
                && (h & (1u << uint((y + dx + dz + 64) % 8 + 16))) == 0u;
            if (!cut && gwr_soft(c)) c = gwr_leaf;
        }
    }
    if (x == tx && z == tz && y > yi && y <= top) c = gwr_wood;
    return c;
}

// код 4: поверхности деревьев плиток (строка TR)
vec4 gwr_trees() {
    int TR = gwr_info(108);
    int k = (gwr_p.y - TR) * gwr_W + gwr_p.x;
    if (gwr_p.y < TR || gwr_p.y >= gwr_ST || k >= gwr_nt) return gwr_copy();
    int t = k;
    int n = gwr_info(101);
    int ys0 = 255, ys1 = 255, ys2 = 255;
    if (n > 0) {
        gwr_tree_setup(t);
        uint chanceT = uint(gwr_info(102));
        int maxy = gwr_info(103);
        for (int i = 0; i < 3; i++) {
            if (i >= n) break;
            uint h = gwr_th32(gwr_cx, gwr_cz, i, gwr_seed);
            if (((h >> 20u) & 1023u) >= chanceT) continue;
            int tx = 2 + int(h & 15u) % 12, tz = 2 + int((h >> 4u) & 15u) % 12;
            int th = gwr_tmin + int((h >> 8u) & 7u) % gwr_tspan;
            int y = 254;
            int c = 0;
            while (true) {
                c = gwr_code(t, tx, y, tz);
                if (i > 0) c = gwr_tree(0, ys0, c, tx, y, tz);
                if (i > 1) c = gwr_tree(1, ys1, c, tx, y, tz);
                if (y <= 0 || !gwr_soft(c)) break;
                y--;
            }
            int ys = (c == 3 && y + th + 2 < 255 && y < maxy) ? y : 255;
            if (i == 0) ys0 = ys; else if (i == 1) ys1 = ys; else ys2 = ys;
        }
    }
    return gc_rgb24(uint(ys0) | (uint(ys1) << 8u) | (uint(ys2) << 16u));
}

// код 5: деревья в коды плиток
vec4 gwr_apply() {
    int SR = gwr_info(17);
    int n = gwr_info(101);
    if (gwr_p.y >= SR || n == 0) return gwr_copy();
    int txi = gwr_p.x / 128, tyi = gwr_p.y / 86;
    if (txi >= gwr_tilesX) return gwr_copy();
    int t = tyi * gwr_tilesX + txi;
    if (t >= gwr_nt) return gwr_copy();
    int lx = gwr_p.x - txi * 128, ly = gwr_p.y - tyi * 86;
    int x = lx & 15, z = (lx >> 4) + 8 * (ly / 43), y0 = 6 * (ly % 43);
    gwr_tree_setup(t);
    int TR = gwr_info(108);
    uint tr = gwr_rd24(ivec2(t % gwr_W, TR + t / gwr_W));
    int ys0 = int(tr & 255u), ys1 = int((tr >> 8u) & 255u), ys2 = int(tr >> 16u);
    uvec3 c = gwr_rd(gwr_p);
    uint v = c.r | (c.g << 8u) | (c.b << 16u);
    uint o = 0u;
    for (int j = 0; j < 6; j++) {
        int y = y0 + j;
        int cd = int((v >> uint(4 * j)) & 15u);
        if (y <= 255) {
            cd = gwr_tree(0, ys0, cd, x, y, z);
            cd = gwr_tree(1, ys1, cd, x, y, z);
            cd = gwr_tree(2, ys2, cd, x, y, z);
        }
        o |= uint(cd) << uint(4 * j);
    }
    return gc_rgb24(o);
}

// значение области (ST/BY/PF) для слоя s плитки t
uint gwr_reg(int R, int t, int s) {
    int k = t * 256 + s;
    return gwr_rd24(ivec2(k % gwr_W, R + k / gwr_W));
}
// старт следующей серии после слоя s (позиция в чанке; конец id-части: 65536, если последний id не воздух, иначе
// 131072 — серия воздуха идёт и по нулевым state)
int gwr_after(int t, int s) {
    for (int s2 = s + 1; s2 < 256; s2++) {
        uint st = gwr_reg(gwr_ST, t, s2);
        if ((st & 511u) != 0u) return s2 * 256 + int(st >> 9u);
    }
    return gwr_code(t, 15, 255, 15) != 0 ? 65536 : 131072;
}
// байт записей серии длины L (rle.cpp: куски по 16384; счётчик L-1 >= 64 — 2 байта заголовка; id <= 255 — 1 байт)
int gwr_rbytes(int L) {
    int kf = (L - 1) >> 14;
    int cnt = L - (kf << 14) - 1;
    return 3 * kf + (cnt < 64 ? 2 : 3);
}
int gwr_recbyte(int L, int v, int rel) {
    int kf = (L - 1) >> 14;
    if (rel < 3 * kf) {
        int m = rel % 3;
        return m == 0 ? 0xBF : (m == 1 ? 0xFF : v);
    }
    int rr = rel - 3 * kf;
    int cnt = L - (kf << 14) - 1;
    if (cnt < 64) return rr == 0 ? cnt : v;
    return rr == 0 ? (0x80 | (cnt & 63)) : (rr == 1 ? (cnt >> 6) : v);
}

// индекс (t, s) пикселя области R (или -1)
int gwr_region_k(int R) {
    if (gwr_p.y < R || gwr_p.y >= R + (gwr_BY - gwr_ST)) return -1;
    int k = (gwr_p.y - R) * gwr_W + gwr_p.x;
    return k < gwr_nt * 256 ? k : -1;
}

// код 6: статистика слоя
vec4 gwr_stats() {
    int k = gwr_region_k(gwr_ST);
    if (k < 0) return gwr_copy();
    int t = k >> 8, s = k & 255;
    int prev = s == 0 ? -1 : gwr_code(t, 15, s - 1, 15);
    int n = 0, first = 0;
    for (int q = 0; q < 256; q++) {
        int c = gwr_code(t, q & 15, s, q >> 4);
        if (c != prev) {
            if (n == 0) first = q;
            n++;
            prev = c;
        }
    }
    return gc_rgb24(uint(n) | (uint(first) << 9u));
}

// код 7: байты слоя
vec4 gwr_bytes() {
    int k = gwr_region_k(gwr_BY);
    if (k < 0) return gwr_copy();
    int t = k >> 8, s = k & 255;
    uint st = gwr_reg(gwr_ST, t, s);
    if ((st & 511u) == 0u) return gc_rgb24(0u);
    int prev = s == 0 ? -1 : gwr_code(t, 15, s - 1, 15);
    int sum = 0, last = -1;
    for (int q = int(st >> 9u); q < 256; q++) {
        int c = gwr_code(t, q & 15, s, q >> 4);
        if (c != prev) {
            int pos = s * 256 + q;
            if (last >= 0) sum += gwr_rbytes(pos - last);
            last = pos;
            prev = c;
        }
    }
    sum += gwr_rbytes(gwr_after(t, s) - last);
    return gc_rgb24(uint(sum));
}

// код 8: префиксная сумма байт слоёв
vec4 gwr_prefix() {
    int k = gwr_region_k(gwr_PF);
    if (k < 0) return gwr_copy();
    int t = k >> 8, s = k & 255;
    uint sum = 0u;
    for (int s2 = 0; s2 < s; s2++) sum += gwr_reg(gwr_BY, t, s2);
    return gc_rgb24(sum);
}

int gwr_total(int t) {
    return int(gwr_reg(gwr_PF, t, 255) + gwr_reg(gwr_BY, t, 255)) + (gwr_code(t, 15, 255, 15) != 0 ? 12 : 0);
}

// старт серии, следующей за серией со стартом pos (код c): вперёд по слою, дальше — через статистику слоёв
int gwr_next_start(int t, int pos, int c) {
    int s = pos >> 8;
    for (int q = (pos & 255) + 1; q < 256; q++) {
        if (gwr_code(t, q & 15, s, q >> 4) != c) return s * 256 + q;
    }
    return gwr_after(t, s);
}

// 3 байта потока плитки t с байта b0 (< total): поиск серии байта b0 — двоичный по смещениям слоёв и проход по слою;
// следующие байты — та же серия или следующая (gwr_next_start); хвост нулевых state — записи [BF FF 00]
uint gwr_stream3(int t, int b0, int total) {
    int ends = int(gwr_reg(gwr_PF, t, 255) + gwr_reg(gwr_BY, t, 255));
    uint o = 0u;
    int start = -1, L = 0, lc = 0, rel = 0;
    for (int i = 0; i < 3; i++) {
        int b = b0 + i;
        if (b >= total) break;
        int v;
        if (b >= ends) {
            int m = (b - ends) % 3;
            v = m == 0 ? 0xBF : (m == 1 ? 0xFF : 0);
        } else {
            if (start < 0) {
                int lo = 0, hi = 255;
                while (lo < hi) {
                    int mid = (lo + hi + 1) >> 1;
                    if (int(gwr_reg(gwr_PF, t, mid)) <= b) lo = mid; else hi = mid - 1;
                }
                int s = lo;
                rel = b - int(gwr_reg(gwr_PF, t, s));
                uint st = gwr_reg(gwr_ST, t, s);
                int prev = s == 0 ? -1 : gwr_code(t, 15, s - 1, 15);
                int last = -1;
                for (int q = int(st >> 9u); q < 256; q++) {
                    int c = gwr_code(t, q & 15, s, q >> 4);
                    if (c != prev) {
                        int pos = s * 256 + q;
                        if (last >= 0) {
                            int nb = gwr_rbytes(pos - last);
                            if (rel < nb) { start = last; L = pos - last; break; }
                            rel -= nb;
                        }
                        last = pos;
                        lc = c;
                        prev = c;
                    }
                }
                if (start < 0) { start = last; L = gwr_after(t, s) - last; }
            } else {
                rel++;
                if (rel >= gwr_rbytes(L)) {
                    start += L;
                    lc = gwr_code(t, start & 15, start >> 8, (start >> 4) & 15);
                    L = gwr_next_start(t, start, lc) - start;
                    rel = 0;
                }
            }
            v = gwr_recbyte(L, gwr_info(120 + lc), rel);
        }
        o |= uint(v) << uint(8 * i);
    }
    return o;
}

// 1 + y верхнего вокселя столба (x, z) плитки t, закрывающего небо; 0 — нет
uint gwr_skytop(int t, int col) {
    int x = col & 15, z = col >> 4;
    for (int y = 255; y >= 0; y--) {
        int c = gwr_code(t, x, y, z);
        if (c != 0 && c != 5 && c != 14 && c != 15) return uint(y + 1);
    }
    return 0u;
}
// y нижнего такого вокселя (255 — нет): под ним столб открыт вниз (пустота под островами)
uint gwr_skybot(int t, int col) {
    int x = col & 15, z = col >> 4;
    for (int y = 0; y < 255; y++) {
        int c = gwr_code(t, x, y, z);
        if (c != 0 && c != 5 && c != 14 && c != 15) return uint(y);
    }
    return 255u;
}

// код 9: кадр потока
vec4 gwr_emit() {
    int HM = gwr_info(114);
    if (HM > 0 && gwr_p.y >= HM) {
        int k = (gwr_p.y - HM) * gwr_W + gwr_p.x;
        int t = k / 86, j = k - t * 86;
        if (t >= gwr_nt) {
            // за высотами: нижние воксели столбов (по 3 на тексель так же), плитка t - nt
            int k2 = k - gwr_nt * 86;
            int t2 = k2 / 86, j2 = k2 - t2 * 86;
            if (t2 >= gwr_nt) return gc_rgb24(0u);
            uint o2 = gwr_skybot(t2, 3 * j2);
            if (3 * j2 + 1 < 256) o2 |= gwr_skybot(t2, 3 * j2 + 1) << 8u;
            if (3 * j2 + 2 < 256) o2 |= gwr_skybot(t2, 3 * j2 + 2) << 16u;
            return gc_rgb24(o2);
        }
        if (t >= gwr_nt) return gc_rgb24(0u);
        uint o = gwr_skytop(t, 3 * j);
        if (3 * j + 1 < 256) o |= gwr_skytop(t, 3 * j + 1) << 8u;
        if (3 * j + 2 < 256) o |= gwr_skytop(t, 3 * j + 2) << 16u;
        return gc_rgb24(o);
    }
    if (gwr_p.y == 0) {
        if (gwr_p.x == 0) return gc_rgb24(uint(gwr_info(0)) & 16777215u);
        if (gwr_p.x <= gwr_nt) return gc_rgb24(uint(gwr_total(gwr_p.x - 1)));
        return gc_rgb24(0u);
    }
    int KR = gwr_info(113);
    int r = gwr_p.y - 1;
    int t = r / KR;
    if (t >= gwr_nt) return gc_rgb24(0u);
    int k = (r - t * KR) * gwr_W + gwr_p.x;
    int total = gwr_total(t);
    int b0 = 3 * k;
    if (b0 >= total) return gc_rgb24(0u);
    return gc_rgb24(gwr_stream3(t, b0, total));
}

vec4 gwr_main(int code) {
    gwr_p = ivec2(gl_FragCoord.xy);
    ivec2 sz = textureSize(u_texture, 0);
    gwr_W = sz.x;
    gwr_H = sz.y;
    gwr_nt = gwr_info(3);
    gwr_tilesX = gwr_info(2);
    gwr_ST = gwr_info(109);
    gwr_BY = gwr_info(110);
    gwr_PF = gwr_info(111);
    if (gwr_nt <= 0) return code == 9 ? gc_rgb24(0u) : gwr_copy();
    if (code == 4) return gwr_trees();
    if (code == 5) return gwr_apply();
    if (code == 6) return gwr_stats();
    if (code == 7) return gwr_bytes();
    if (code == 8) return gwr_prefix();
    return gwr_emit();
}

void gc_main_gpu_worldgen(int code) {
    if (code == 3) f_color = gw_main();
    else f_color = gwr_main(code);
}

// ======== программа smollm_gpu (smollm_gpu/shaders/gpu_smollm.glsl, sha1 c25eda37eff0)
// @gc program=smollm_gpu marker=FF codes=0-255
// Тело программы smollm_gpu для общего ui.glslf пака gpu_compute (tools/gpu_compute_build.py). Маркер прежний:
// #FF<режим>FF80 (R=255, B=255, A=128, режим — байт G). #extension fp64 — в заголовке общего шейдера.
// smollm_gpu: шейдер UI движка + вычислительные режимы для фреймов GUI (gui.create_frame) — разведка «LLM на GPU».
// Обычная картинка — как в движке (цвет вершины * текстура). Картинка с цветом-маркером #FF??FF80 (R=255, B=255,
// A=128) — вычислительный режим, номер режима — байт G. Выход фрейма — RGBA8 со смешиванием SRC_ALPHA (движок), поэтому
// режимы пишут alpha = 1 и несут данные только в RGB (3 байта на тексель); входные canvas-текстуры дают все 4 байта.
//   1 COPY  — тексель источника по UV как есть, alpha = 1
//   2 INC   — 24-битное число RGB источника + 1 (проба порядка фреймов)
//   3 ECHO  — параметры картинки: region="P,Q,P,Q" даёт постоянные UV = (P, Q) (целые < 2^24 точно), пишет P | Q (проба)
//   20..24 точная арифметика через fp64 (GL_ARB_gpu_shader_fp64): a/b, sqrtf, fm_expf, 1/sqrtf, SiLU — как C;
//   25..27 то же во float GLSL (a/b, sqrt, exp) для сравнения. Вход: пары float (a, b) по 4 текселя.
//   10/11 MATVEC Q8 — y = W·x одной страницы (линейная память фрейма/canvas по 3 байта на тексель, см. layout ниже);
//         11 — то же, но произведение материализуется (без слияния в fma), как в C с -ffp-contract=off
// Линейная память: тексель t = (t % ширина, t / ширина) текстуры, байты R,G,B; float32 — 2 текселя (биты 0-23, 24-31).
// Страница матвека (n входов, rows строк, G = n/64 групп, RT = ceil(n/3) текселей на строку):
//   W  [0, rows*RT)            int8 строки весов, строка r с тексела r*RT
//   WS [rows*RT, +rows*G*2)    масштабы весов float (r*G + g)
//   XQ [.., +RT)               int8 вход x (квантованный)
//   XS [.., +G*2)              масштабы x
// Параметры: P = rows | G << 12, Q = row_base | (OW/64) << 16; выход — фрейм шириной OW, float y[j] = 2 текселя 2j, 2j+1,
// фрагмент считает строку r = j - row_base своей страницы.
// --- Прогон модели (modules/llm.lua): все фреймы шириной PW = 768, память линейная (тексель t = (t % 768, t / 768)),
// регионы с начала строки. Параметры картинки: P, Q = region="P,Q,P,Q"; orow — первая строка выхода во фрейме.
//   5  COPYR    строки источника с P -> строки фрейма с Q (как есть)
//   12 MV_ROPE  q,k,v = Wqkv·xq (1280 строк), q и k с RoPE (cos/sin в строке x0row+1)      P = rows | G<<12, Q = row_base | orow<<15
//   13 MV_RES   y = x + W·xq (x — float в строках x0row+1..)                               те же P, Q
//   14 MV_SILU  hb = silu(W1·xq) * (W3·xq); страница: 512 строк w1, затем 512 строк w3       те же P, Q
//   15 MV       y = W·xq                                                                    те же P, Q
//   30 EMBED    x = q[i] * s[i/64] из canvas токена (int8 с тексела 0, масштабы с 256)      Q = orow
//   31 NORMQ    xq/xs = quantize(rmsnorm(x) * w)                                            P = xrow | wrow<<9, Q = orow | (n/64)<<9
//   32 QUANT    xq/xs = quantize(x)                                                         те же
//   33 SCORES   s[h][t] = q_h·k_t / sqrt(64), t <= pos (K-кэш — строки 0..341, q — 342..)  P = pos, Q = orow
//   34 SM_E     e = expf(s - max_h)                                                         P = pos, Q = orow
//   35 SM_N     a = e / sum_h                                                               P = pos, Q = orow
//   36 AV       xb[i] = sum_t a[h][t] * v_t (V-кэш — строки 0..341, a — 342..)              P = pos, Q = orow
//   37 KVPUT    тексели [pos*512, +512) фрейма <- тексели источника с Q (новая строка кэша), остальное — discard
//   16 IVAL     целые суммы групп матвека (страница -> фрейм IV);  40..43 RED_ROPE/RES/SILU/PLAIN — свёртка по группам из IV
//   44 SS       1/sqrtf(mean(x^2)+1e-5) в строку фрейма; 45 NORMQ2 — как 31, но ss из строки 4 источника (фрейм SS)
//   38 ARGMAX1  по 128 логитов: (индекс, значение) первого максимума                          Q = orow
//   39 ARGMAX2  по 192 частичным — индекс токена (тексель 0) и значение (1, 2)
// Матвек-страница: W [0, rows*RT), WS [rows*RT, +rows*G*2), добивка до строки x0row; XQ/XS — строка x0row.
// Все операции float — как C (-ffp-contract=off): произведения через fblk, деление/корень/exp — через fp64.

bool is_marker(vec4 c) {
    return c.r > 0.99 && c.b > 0.99 && abs(c.a - 128.0 / 255.0) < 0.01;
}

uvec4 texel_u(ivec2 at) {
    return uvec4(texelFetch(u_texture, at, 0) * 255.0 + 0.5);
}

vec4 rgb24(uint v) {
    return vec4(float(v & 255u), float((v >> 8) & 255u), float((v >> 16) & 255u), 255.0) / 255.0;
}

ivec2 uv_texel() {
    ivec2 size = textureSize(u_texture, 0);
    return clamp(ivec2(a_textureCoord * vec2(size)), ivec2(0), size - 1);
}

ivec2 lin(int t, int w) { return ivec2(t % w, t / w); }

uvec3 fetch3(int t, int w) {
    return uvec3(texelFetch(u_texture, lin(t, w), 0).rgb * 255.0 + 0.5);
}

uint u24(int t, int w) { uvec3 c = fetch3(t, w); return c.r | (c.g << 8) | (c.b << 16); }

float f32_at(int t, int w) {
    return uintBitsToFloat(u24(t, w) | (fetch3(t + 1, w).r << 24));
}

// --- точная арифметика (как C с -ffp-contract=off): g_z — ноль во время выполнения, «блок» не даёт компилятору
// слить умножение со сложением в fma (биты проходят через целочисленную операцию с неизвестным ему значением)
uint g_z = 0u;
float fblk(float v) { return uintBitsToFloat(floatBitsToUint(v) ^ g_z); }
double dblk(double v) { uvec2 u = unpackDouble2x32(v); u.x ^= g_z; return packDouble2x32(u); }
double dc(uint lo, uint hi) { return packDouble2x32(uvec2(lo, hi)); }

// fmath.c fm_exp: те же операции double в том же порядке, константы — битами
double fm_exp(double x) {
    if (x != x) return x;
    if (x > 709.7LF) return dc(0u, 0x7ff00000u);
    if (x < -745.2LF) return 0.0LF;
    double t = dblk(x * dc(0x652b82feu, 0x3ff71547u));
    int k = int(t >= 0.0LF ? t + 0.5LF : t - 0.5LF);
    double dk = double(k);
    double r = (x - dblk(dk * dc(0xfee00000u, 0x3fe62e42u))) - dblk(dk * dc(0x35793c76u, 0x3dea39efu));
    double p = dc(0xa8c07c9du, 0x3da93974u);
    p = dblk(p * r) + dc(0x13a86d09u, 0x3de61246u);
    p = dblk(p * r) + dc(0xeff8d898u, 0x3e21eed8u);
    p = dblk(p * r) + dc(0x67f544e4u, 0x3e5ae645u);
    p = dblk(p * r) + dc(0xb7789f5cu, 0x3e927e4fu);
    p = dblk(p * r) + dc(0xa556c734u, 0x3ec71de3u);
    p = dblk(p * r) + dc(0x1a01a01au, 0x3efa01a0u);
    p = dblk(p * r) + dc(0x1a01a01au, 0x3f2a01a0u);
    p = dblk(p * r) + dc(0x16c16c17u, 0x3f56c16cu);
    p = dblk(p * r) + dc(0x11111111u, 0x3f811111u);
    p = dblk(p * r) + dc(0x55555555u, 0x3fa55555u);
    p = dblk(p * r) + dc(0x55555555u, 0x3fc55555u);
    p = dblk(p * r) + 0.5LF;
    p = dblk(p * r) + 1.0LF;
    p = dblk(p * r) + 1.0LF;
    // k для входов float в [-1022, 1023]
    return p * dc(0u, uint(k + 1023) << 20);
}
float fm_expf(float x) { return float(fm_exp(double(x))); }
float fdiv(float a, float b) { return float(double(a) / double(b)); }
float fsqrt(float a) { return float(sqrt(double(a))); }

int s8(uint b) { return int(b << 24) >> 24; }

vec4 out_f32_half(float y, int hi) {
    uint bits = floatBitsToUint(y);
    return rgb24(hi == 0 ? (bits & 0xFFFFFFu) : (bits >> 24));
}

// линейный индекс текущего тексела выхода во фрейме шириной ow
int out_index(int ow) { return int(gl_FragCoord.y) * ow + int(gl_FragCoord.x); }

float matvec_row(int r, int n, int rows, bool block) {
    int w = textureSize(u_texture, 0).x;
    int G = n / 64;
    int RT = (n + 2) / 3;
    int ws0 = rows * RT;
    int x0 = ws0 + rows * G * 2;
    int xs0 = x0 + RT;
    uint z = uint(texelFetch(u_texture, ivec2(0), 0).a) - 1u;  // 0 во время выполнения (alpha = 1)
    int wrow = r * RT;
    float val = 0.0;
    int ival = 0;
    int g = 0;
    int k = 0;
    for (int t = 0; t < RT; t++) {
        uvec3 wb = fetch3(wrow + t, w);
        uvec3 xb = fetch3(x0 + t, w);
        for (int c = 0; c < 3; c++) {
            if (k >= n) break;
            ival += s8(wb[c]) * s8(xb[c]);
            if ((k & 63) == 63) {
                float p = (float(ival) * f32_at(ws0 + (r * G + g) * 2, w)) * f32_at(xs0 + g * 2, w);
                if (block) p = uintBitsToFloat(floatBitsToUint(p) + z);
                val += p;
                ival = 0;
                g++;
            }
            k++;
        }
    }
    return val;
}

const int PW = 768;
int g_w = 768;  // ширина текстуры источника
float F(int t) { return f32_at(t, g_w); }
uint U(int t) { return u24(t, g_w); }
int lin_out() { return int(gl_FragCoord.y) * PW + int(gl_FragCoord.x); }

float mv_dot(int r, int n, int rows, int x0) {
    int G = n / 64, RT = (n + 2) / 3;
    int ws0 = ((rows * RT + PW - 1) / PW) * PW, xs0 = x0 + RT;
    int wrow = r * RT;
    float val = 0.0;
    int ival = 0, g = 0, k = 0;
    // по 4 текселя (12 байт) за итерацию: 8 независимых выборок до вычислений (латентность памяти перекрывается)
    for (int t = 0; t < RT; t += 4) {
        uvec3 w0 = fetch3(wrow + t, g_w), w1 = fetch3(wrow + t + 1, g_w), w2 = fetch3(wrow + t + 2, g_w), w3 = fetch3(wrow + t + 3, g_w);
        uvec3 x0v = fetch3(x0 + t, g_w), x1v = fetch3(x0 + t + 1, g_w), x2v = fetch3(x0 + t + 2, g_w), x3v = fetch3(x0 + t + 3, g_w);
        uint wq[12] = uint[12](w0.r, w0.g, w0.b, w1.r, w1.g, w1.b, w2.r, w2.g, w2.b, w3.r, w3.g, w3.b);
        uint xq[12] = uint[12](x0v.r, x0v.g, x0v.b, x1v.r, x1v.g, x1v.b, x2v.r, x2v.g, x2v.b, x3v.r, x3v.g, x3v.b);
        for (int c = 0; c < 12; c++) {
            if (k >= n) break;
            ival += s8(wq[c]) * s8(xq[c]);
            if ((k & 63) == 63) {
                val += fblk(fblk(float(ival) * F(ws0 + (r * G + g) * 2)) * F(xs0 + g * 2));
                ival = 0;
                g++;
            }
            k++;
        }
    }
    return val;
}

int mv_x0row(int rows, int n) {
    int G = n / 64, RT = (n + 2) / 3;
    return (rows * RT + PW - 1) / PW + (rows * G * 2 + PW - 1) / PW;
}

// --- матвек в два прохода: IVAL — целая сумма группы (r, g) одним фрагментом (64 умножения, без дублирования),
// RED — для строки r: val += (ival * ws) * xs по группам по порядку (как C). Фрейм IV: [ival: ceil(rows*G/PW) строк]
// [WS: копия строк страницы] [копия строк страницы с x0row: XQ/XS, rope или x]
int sext24(uint u) { return int(u << 8) >> 8; }

float red_dot(int r, int G, int RT, int ivr, int ex) {
    int ws0 = ivr * PW, xs0 = ex * PW + RT;
    float val = 0.0;
    for (int g = 0; g < G; g++) {
        int iv = sext24(U(r * G + g));
        val += fblk(fblk(float(iv) * F(ws0 + 2 * (r * G + g))) * F(xs0 + 2 * g));
    }
    return val;
}

// NORMQ/QUANT: значение xb[j] (с rmsnorm, если w0 >= 0)
float g_ss = 1.0;
float xb_at(int x0, int w0, int j) {
    float x = F(x0 + 2 * j);
    if (w0 < 0) return x;
    return F(w0 + 2 * j) * fblk(g_ss * x);
}

float group_scale(int x0, int w0, int g) {
    float wmax = 0.0;
    for (int i = 0; i < 64; i += 8) {
        float v[8];
        for (int u = 0; u < 8; u++) v[u] = abs(xb_at(x0, w0, g * 64 + i + u));
        for (int u = 0; u < 8; u++) if (v[u] > wmax) wmax = v[u];
    }
    return fdiv(wmax, 127.0);
}

uint quant_byte(float x, float scale) {
    float v = fdiv(x, scale);
    float r = v >= 0.0 ? floor(v + 0.5) : -floor(-v + 0.5);
    return uint(int(r)) & 255u;
}

float logit_bits_val(int j) { return F(2 * j); }

void gc_main_smollm_gpu(int code) {
    int mode = code;
    g_z = uint(texelFetch(u_texture, ivec2(0), 0).a + 0.5) - 1u;
    if (mode == 1) {
        f_color = vec4(texelFetch(u_texture, uv_texel(), 0).rgb, 1.0);
    } else if (mode == 2) {
        uvec4 c = texel_u(uv_texel());
        f_color = rgb24((c.r | (c.g << 8) | (c.b << 16)) + 1u);
    } else if (mode == 3) {
        uint p = uint(a_textureCoord.x + 0.5), q = uint(a_textureCoord.y + 0.5);
        f_color = rgb24(int(gl_FragCoord.x) == 0 ? p : q);
    } else if (mode >= 20 && mode <= 27) {
        uint p = uint(a_textureCoord.x + 0.5), q = uint(a_textureCoord.y + 0.5);
        int ow = int(q >> 16) * 64;
        int t = out_index(ow) - int(p);
        int i = t / 2;
        int w = textureSize(u_texture, 0).x;
        float a = f32_at(i * 4, w), b = f32_at(i * 4 + 2, w);
        float y;
        if (mode == 20) y = fdiv(a, b);
        else if (mode == 21) y = fsqrt(abs(a));
        else if (mode == 22) y = fm_expf(b);
        else if (mode == 23) y = fdiv(1.0, fsqrt(abs(a)));
        else if (mode == 24) { float v = b; float e = fm_expf(-v); float d = 1.0 + e; v = v * fdiv(1.0, d); y = v; }
        else if (mode == 25) y = a / b;
        else if (mode == 26) y = sqrt(abs(a));
        else y = exp(b);
        f_color = out_f32_half(y, t & 1);
    } else if (mode == 5) {
        uint p = uint(a_textureCoord.x + 0.5), q = uint(a_textureCoord.y + 0.5);
        ivec2 at = ivec2(gl_FragCoord.xy);
        at.y = at.y - int(q) + int(p);
        f_color = vec4(texelFetch(u_texture, at, 0).rgb, 1.0);
    } else if (mode >= 12 && mode <= 15) {
        uint p = uint(a_textureCoord.x + 0.5), q = uint(a_textureCoord.y + 0.5);
        g_w = textureSize(u_texture, 0).x;
        int rows = int(p & 4095u), n = int(p >> 12) * 64;
        int row_base = int(q & 32767u), orow = int(q >> 15);
        int t = lin_out() - orow * PW;
        int j = t / 2;
        int x0row = mv_x0row(rows, n), x0 = x0row * PW;
        int r = j - row_base;
        float y;
        if (mode == 14) {
            if (r < 0 || r >= rows / 2) discard;
            float h1 = mv_dot(r, n, rows, x0), h3 = mv_dot(r + rows / 2, n, rows, x0);
            float e = fm_expf(-h1);
            float d = 1.0 + e;
            float v = h1 * fdiv(1.0, d);
            y = v * h3;
        } else {
            if (r < 0 || r >= rows) discard;
            if (mode == 12 && r < 1024) {
                int i = r < 768 ? r : r - 768;
                int jj = (i % 64) / 2;
                int rope = (x0row + 1) * PW;
                float fcr = F(rope + 2 * jj), fci = F(rope + 64 + 2 * jj);
                int r0 = r & ~1;
                float v0 = mv_dot(r0, n, rows, x0), v1 = mv_dot(r0 + 1, n, rows, x0);
                y = (r & 1) == 0 ? fblk(v0 * fcr) - fblk(v1 * fci) : fblk(v0 * fci) + fblk(v1 * fcr);
            } else {
                y = mv_dot(r, n, rows, x0);
                if (mode == 13) y = F((x0row + 1) * PW + 2 * j) + y;
            }
        }
        f_color = out_f32_half(y, t & 1);
    } else if (mode == 16) {
        uint p = uint(a_textureCoord.x + 0.5), q = uint(a_textureCoord.y + 0.5);
        g_w = textureSize(u_texture, 0).x;
        int rows = int(p & 4095u), G = int(p >> 12), n = G * 64, RT = (n + 2) / 3;
        int t = lin_out() - int(q) * PW;
        int r = t / G, g = t % G;
        if (t < 0 || r >= rows) discard;
        int x0 = mv_x0row(rows, n) * PW, wrow = r * RT;
        int k0 = g * 64, ival = 0;
        for (int tt = k0 / 3; tt <= (k0 + 63) / 3; tt++) {
            uvec3 wb = fetch3(wrow + tt, g_w), xb = fetch3(x0 + tt, g_w);
            for (int c = 0; c < 3; c++) {
                int k = 3 * tt + c;
                if (k >= k0 && k < k0 + 64) ival += s8(wb[c]) * s8(xb[c]);
            }
        }
        f_color = rgb24(uint(ival) & 0xFFFFFFu);
    } else if (mode >= 40 && mode <= 43) {
        uint p = uint(a_textureCoord.x + 0.5), q = uint(a_textureCoord.y + 0.5);
        g_w = textureSize(u_texture, 0).x;
        int rows = int(p & 4095u), G = int(p >> 12), n = G * 64, RT = (n + 2) / 3;
        int row_base = int(q & 32767u), orow = int(q >> 15);
        int ivr = (rows * G + PW - 1) / PW, ex = ivr + (rows * G * 2 + PW - 1) / PW;
        int t = lin_out() - orow * PW;
        int j = t / 2, r = j - row_base;
        float y;
        if (mode == 42) {
            if (t < 0 || r < 0 || r >= rows / 2) discard;
            float h1 = red_dot(r, G, RT, ivr, ex), h3 = red_dot(r + rows / 2, G, RT, ivr, ex);
            float e = fm_expf(-h1);
            float d = 1.0 + e;
            float v = h1 * fdiv(1.0, d);
            y = v * h3;
        } else {
            if (t < 0 || r < 0 || r >= rows) discard;
            if (mode == 40 && r < 1024) {
                int i = r < 768 ? r : r - 768;
                int jj = (i % 64) / 2;
                int rope = (ex + 1) * PW;
                float fcr = F(rope + 2 * jj), fci = F(rope + 64 + 2 * jj);
                int r0 = r & ~1;
                float v0 = red_dot(r0, G, RT, ivr, ex), v1 = red_dot(r0 + 1, G, RT, ivr, ex);
                y = (r & 1) == 0 ? fblk(v0 * fcr) - fblk(v1 * fci) : fblk(v0 * fci) + fblk(v1 * fcr);
            } else {
                y = red_dot(r, G, RT, ivr, ex);
                if (mode == 41) y = F((ex + 1) * PW + 2 * j) + y;
            }
        }
        f_color = out_f32_half(y, t & 1);
    } else if (mode == 44) {
        // SS: 1/sqrt(mean(x^2) + eps) нормы rmsnorm (x — строки 0..1 источника, n = 768), один float
        g_w = textureSize(u_texture, 0).x;
        uint q = uint(a_textureCoord.y + 0.5);
        int t = lin_out() - int(q) * PW;
        if (t < 0 || t >= 2) discard;
        float ss = 0.0;
        for (int j = 0; j < 768; j += 8) {
            float v[8];
            for (int u = 0; u < 8; u++) v[u] = F(2 * (j + u));
            for (int u = 0; u < 8; u++) ss += fblk(v[u] * v[u]);
        }
        ss = fdiv(ss, 768.0);
        ss += 1e-5;
        f_color = out_f32_half(fdiv(1.0, fsqrt(ss)), t);
    } else if (mode == 30) {
        uint q = uint(a_textureCoord.y + 0.5);
        g_w = textureSize(u_texture, 0).x;
        int t = lin_out() - int(q) * PW;
        int j = t / 2;
        if (j < 0 || j >= 768) discard;
        uvec3 b = fetch3(j / 3, g_w);
        float y = float(s8(b[j % 3])) * F(256 + 2 * (j / 64));
        f_color = out_f32_half(y, t & 1);
    } else if (mode == 31 || mode == 32 || mode == 45) {
        uint p = uint(a_textureCoord.x + 0.5), q = uint(a_textureCoord.y + 0.5);
        g_w = textureSize(u_texture, 0).x;
        int x0 = int(p & 511u) * PW, w0 = mode != 32 ? int(p >> 9) * PW : -1;
        int orow = int(q & 511u), G = int(q >> 9), n = G * 64, RT = (n + 2) / 3;
        int t = lin_out() - orow * PW;
        if (t < 0 || t >= RT + 2 * G) discard;
        if (mode == 45) g_ss = F(4 * PW);
        if (mode == 31) {
            float ss = 0.0;
            for (int j = 0; j < n; j += 8) {
                float v[8];
                for (int u = 0; u < 8; u++) v[u] = F(x0 + 2 * (j + u));
                for (int u = 0; u < 8; u++) ss += fblk(v[u] * v[u]);
            }
            ss = fdiv(ss, float(n));
            ss += 1e-5;
            g_ss = fdiv(1.0, fsqrt(ss));
        }
        if (t < RT) {
            uint outb = 0u;
            int gcur = -1;
            float sc = 0.0;
            for (int c = 0; c < 3; c++) {
                int idx = 3 * t + c;
                if (idx >= n) break;
                int g = idx / 64;
                if (g != gcur) { sc = group_scale(x0, w0, g); gcur = g; }
                outb |= quant_byte(xb_at(x0, w0, idx), sc) << (8 * c);
            }
            f_color = rgb24(outb);
        } else {
            int g = (t - RT) / 2;
            f_color = out_f32_half(group_scale(x0, w0, g), (t - RT) & 1);
        }
    } else if (mode >= 33 && mode <= 36) {
        uint p = uint(a_textureCoord.x + 0.5), q = uint(a_textureCoord.y + 0.5);
        g_w = textureSize(u_texture, 0).x;
        int pos = int(p), orow = int(q);
        int t = lin_out() - orow * PW;
        int j = t / 2;
        float y = 0.0;
        if (mode == 36) {
            if (j < 0 || j >= 768) discard;
            int h = j / 64, c = (h / 3) * 64 + j % 64;
            int a0 = 342 * PW + 2 * h * 512;
            for (int tt = 0; tt <= pos; tt++) y += fblk(F(a0 + 2 * tt) * F(tt * 512 + 2 * c));
        } else {
            int h = j / 512, tt = j % 512;
            if (j < 0 || h >= 12) discard;
            if (tt <= pos) {
                if (mode == 33) {
                    int k0 = tt * 512 + 2 * (h / 3) * 64, q0 = 342 * PW + 2 * h * 64;
                    float sc = 0.0;
                    for (int i = 0; i < 64; i++) sc += fblk(F(q0 + 2 * i) * F(k0 + 2 * i));
                    y = fdiv(sc, fsqrt(64.0));
                } else if (mode == 34) {
                    int s0 = 2 * h * 512;
                    float mx = F(s0);
                    for (int i = 1; i <= pos; i++) { float v = F(s0 + 2 * i); if (v > mx) mx = v; }
                    y = fm_expf(F(s0 + 2 * tt) - mx);
                } else {
                    int s0 = 2 * h * 512;
                    float sum = 0.0;
                    for (int i = 0; i <= pos; i++) sum += F(s0 + 2 * i);
                    y = fdiv(F(s0 + 2 * tt), sum);
                }
            }
        }
        f_color = out_f32_half(y, t & 1);
    } else if (mode == 37) {
        uint p = uint(a_textureCoord.x + 0.5), q = uint(a_textureCoord.y + 0.5);
        g_w = textureSize(u_texture, 0).x;
        int off = lin_out() - int(p) * 512;
        if (off < 0 || off >= 512) discard;
        f_color = vec4(texelFetch(u_texture, lin(int(q) + off, g_w), 0).rgb, 1.0);
    } else if (mode == 38) {
        uint q = uint(a_textureCoord.y + 0.5);
        g_w = textureSize(u_texture, 0).x;
        int t = lin_out() - int(q) * PW;
        int f = t / 3;
        if (t < 0 || f >= 192) discard;
        int bi = 128 * f;
        float bv = F(2 * bi);
        for (int i = bi + 1; i < 128 * f + 128; i++) { float v = F(2 * i); if (v > bv) { bv = v; bi = i; } }
        int part = t % 3;
        uint bits = floatBitsToUint(bv);
        f_color = rgb24(part == 0 ? uint(bi) : part == 1 ? (bits & 0xFFFFFFu) : (bits >> 24));
    } else if (mode == 39) {
        g_w = textureSize(u_texture, 0).x;
        int t = lin_out();
        if (t >= 3) discard;
        uint bi = U(0);
        float bv = uintBitsToFloat(U(1) | (U(2) << 24));
        for (int f = 1; f < 192; f++) {
            float v = uintBitsToFloat(U(3 * f + 1) | (U(3 * f + 2) << 24));
            if (v > bv) { bv = v; bi = U(3 * f); }
        }
        uint bits = floatBitsToUint(bv);
        f_color = rgb24(t == 0 ? bi : t == 1 ? (bits & 0xFFFFFFu) : (bits >> 24));
    } else if (mode == 10 || mode == 11) {
        uint p = uint(a_textureCoord.x + 0.5), q = uint(a_textureCoord.y + 0.5);
        int rows = int(p & 4095u), G = int(p >> 12);
        int row_base = int(q & 65535u), ow = int(q >> 16) * 64;
        int t = out_index(ow);
        int j = t / 2;
        f_color = out_f32_half(matvec_row(j - row_base, G * 64, rows, mode == 11), t & 1);
    } else {
        f_color = vec4(1.0, 0.0, 1.0, 1.0);
    }
}

void main() {
    if (a_color.b > 0.99 && abs(a_color.a - 128.0 / 255.0) < 0.01) {
        int gc_r = int(a_color.r * 255.0 + 0.5), gc_g = int(a_color.g * 255.0 + 0.5);
        if (gc_r == 253 && gc_g >= 1 && gc_g <= 3) { gc_main_core(gc_g); return; }
        if (gc_r == 253 && gc_g == 4) { gc_main_noise(gc_g); return; }
        if (gc_r == 254 && gc_g >= 3 && gc_g <= 9) { gc_main_gpu_worldgen(gc_g); return; }
        if (gc_r == 255 && true) { gc_main_smollm_gpu(gc_g); return; }
    }
    f_color = a_color * texture(u_texture, a_textureCoord);
}
