// СОБРАНО tools/gpu_worldgen_light_build.py из content/gpu_worldgen/shaders/gpu_worldgen.glsl — не править руками.
// Шум и плотность генератора gpu_worldgen (classic и пресеты) для света в шейдерах мира (пак gpu_worldgen_light).
// Параметры — регион атласа блоков gwl_world (u_texture0 с (2, 2); строки GWL_PARAM_ROW.. : тексель (i % 512, строка + i / 512)
// = слово i, RGBA), его пишет scripts/world.lua пака; слово 0 — маркер "GWLP". Параметры пресета — массив g_P (gwl_load).
#ifndef GWL_DENSITY_GLSL_
#define GWL_DENSITY_GLSL_

#define GWL_PARAM_ROW 512

uint gw_u(int i) {
    uvec4 c = uvec4(texelFetch(u_texture0, ivec2(2 + (i & 511), 2 + GWL_PARAM_ROW + (i >> 9)), 0) * 255.0 + 0.5);
    return c.r | (c.g << 8u) | (c.b << 16u) | (c.a << 24u);
}
int gw_i(int i) { return int(gw_u(i)); }
float gw_f(int i) { return float(int(gw_u(i))) / 1024.0; }
float gw_f16(int i) { return float(int(gw_u(i))) / 65536.0; }

float g_P[40];
#define GP(i) g_P[i]
int g_lo = 8;                       // октав fbm не больше g_lo (дальние пробы луча — меньше, ближние — все)
int gwl_oct(int n) { return min(n, g_lo); }

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

uint g_seedmix = 0u;
float g_S, g_SY, g_AMP, g_HSCALE, g_CS, g_CSY, g_ORE_S, g_CAVE_T, g_ORE_T;
int g_BASE, g_SEA, g_OCT;
float g_cb, g_chf, g_csink;      // mountains/caves: базовая высота столба, множитель высоты, шум провалов (caves)
float g_A[3], g_Y[3], g_SP[3];   // islands: «сила» острова слоя k, высота слоя, удлинение корней
bool g_BR[3]; float g_BY[3];     // islands: столб на мосту слоя k, высота моста

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

float gw_n2(float x, float z, float salt) { return gw_noise(x + salt * 13.37, salt * 7.31 + 0.5, z - salt * 5.17); }

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
            float m = gw_fbmn(x / GP(I_IS) + 100.0 * fk, 3.5 + 11.0 * fk, z / GP(I_IS) - 37.0 * fk, gwl_oct(int(GP(I_OCT))));
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

float gw_pdens(int preset, float x, int iy, float z) {
    if (iy > 255) return -1.0;
    float y = float(iy);
    if (preset == 1) {
        float hf = g_chf;
        float f = gw_fbmn(x / GP(M_S), y / GP(M_SY), z / GP(M_S), gwl_oct(int(GP(M_OCT))));
        float d = f * GP(M_AMP) * hf + (g_cb - y) / (y > g_cb ? GP(M_HUP) : GP(M_HDN));
        return d - max(0.0, y - GP(M_TOP)) * 0.25;
    } else if (preset == 2) {
        float f = gw_fbmn(x / GP(C_S), y / GP(C_SY), z / GP(C_S), gwl_oct(int(GP(C_OCT))));
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

int g_OCT_full;
// параметры из региона атласа; false — региона нет (мир не gpu_worldgen или Lua ещё не записал)
bool gwl_load() {
    if (gw_u(0) != 0x504C5747u) return false;
    g_seedmix = gw_u(4) * 1013u;
    g_S = gw_f(5); g_SY = gw_f(6); g_AMP = gw_f(7); g_BASE = gw_i(8); g_HSCALE = gw_f(9);
    g_SEA = gw_i(10); g_OCT_full = gw_i(11); g_OCT = g_OCT_full; g_CAVE_T = gw_f16(12); g_CS = gw_f(13); g_CSY = gw_f(14);
    g_ORE_T = gw_f16(15); g_ORE_S = gw_f(16);
    if (gw_i(18) != 0) {
        for (int i = 0; i < 40; i++) g_P[i] = gw_f(20 + i);
    }
    return true;
}

#endif // GWL_DENSITY_GLSL_
