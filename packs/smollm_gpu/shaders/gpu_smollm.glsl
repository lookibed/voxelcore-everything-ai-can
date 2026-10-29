// @gc program=smollm_gpu marker=FF codes=0-255
#extension GL_ARB_gpu_shader_fp64 : enable
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
