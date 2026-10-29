// Шейдер UI движка с режимом палитры для wasmrt (vc_gfx_present_indexed, "palette": "gpu").
// Обычная картинка: как в движке (цвет вершины * текстура). Картинка с цветом-маркером
// #FF00FF80: текстура шириной w/4 хранит индексы по 4 в тексель (RGBA = 4 соседних пикселя),
// последние 4 строки — палитра (256 текселей RGB). Перевод индекса в цвет — здесь, на GPU.
in vec2 a_textureCoord;
in vec4 a_color;
out vec4 f_color;

uniform sampler2D u_texture;

// Режим треугольников (wasmrt:gfx_tris, маркер #FF01FF80): раскладка текстуры описана в
// modules/gfx_tris.lua. Для пикселя берётся его тайл (заголовок [4], таблица тайлов, списки
// номеров u16) и перебираются только треугольники из списка тайла в исходном порядке; без
// биннинга ([4] = 0) — все треугольники кадра. В режиме сверки ([5] = 1) считаются оба
// варианта, расхождение — пурпурный пиксель.
// Смешивание (слово 13, биты 0-7), src — цвет фрагмента, dst — цвет пикселя:
//   0 none: src; 1 alpha: src*a + dst*(1-a); 2 add: min(dst + src*a, 1); 3 mul: dst*src;
//   4 invert: src*(1-dst) + dst*(1-src); 5 mul2: min(2*src*dst, 1); 6 darken: dst*(1-src);
//   7 glint: min(src*src + dst, 1); прочие — как mul. Бит 13 — цвет не пишется (только глубина).
// Туман (флаг 8, набор — биты 14-21 слова 13; наборы — строки заголовка [7] >> 16, формат в
// gfx_tris.lua): после текстуры и альфа-теста, до смешивания, как core.glsl Eaglercraft:
//   i = mode == 1 ? (dist - start) / (end - start) : 1 - exp(-density * dist);
//   rgb = mix(rgb, fogColor.rgb, clamp(i, 0, 1) * fogColor.a).
const int TRIS_W = 2048;
const int TRIS_ATLAS_H = 2048;
const int TRI_TEXELS = 16;
const int TRIS_SLOT0 = 8;

bool is_tris_marker(vec4 c) {
    return c.r > 0.99 && abs(c.g - 1.0 / 255.0) < 0.002 && c.b > 0.99 && abs(c.a - 128.0 / 255.0) < 0.01;
}

uvec4 texel_u(ivec2 at) {
    return uvec4(texelFetch(u_texture, at, 0) * 255.0 + 0.5);
}

uint word_at(int index, int row0) {
    uvec4 c = texel_u(ivec2(index % TRIS_W, row0 + index / TRIS_W));
    return c.r | (c.g << 8) | (c.b << 16) | (c.a << 24);
}

vec2 signed_pair(uint w) {
    return vec2(float(int(w << 16) >> 16), float(int(w) >> 16));
}

vec4 fetch_color(int index, int row0) {
    return vec4(texel_u(ivec2(index % TRIS_W, row0 + index / TRIS_W))) / 255.0;
}

int g_fog_row = 0;
bool g_fog_debug = false;  // tris_verify = 2: вместо тумана выводится его коэффициент (серым)
// tris_verify = 3: числовой зонд — для пикселя-зонда (tris_probe) значения тумана и покрытия
// печатаются ячейками 8×8 в левом верхнем углу (протокол tools/mcp/pixel_debug.py, vc_shader_cells)
bool g_probe = false;
int g_dbg_n = 0, g_dbg_fogn = 0, g_dbg_set = 0, g_dbg_flags = 0;
float g_dbg_i = 0.0, g_dbg_dist = 0.0, g_dbg_xe = 0.0, g_dbg_ye = 0.0, g_dbg_ze = 0.0, g_dbg_wc = 0.0, g_dbg_d = 0.0;
float g_dbg_mode = 0.0, g_dbg_start = 0.0, g_dbg_len = 0.0;

float fog_word(int i) {
    return uintBitsToFloat(word_at(i, g_fog_row));
}

// Туман набора set для пикселя p (1/16 пикселя): позиция в пространстве камеры восстанавливается
// по пикселю, wc = 1 / qsum (qsum — интерполированное по экрану 1/w) и глубине окна d.
vec3 apply_fog(uint set, vec2 p, float qsum, float d, vec3 rgb) {
    int f = int(set) * TRI_TEXELS;
    uint cw = word_at(f, g_fog_row);
    vec4 fog_color = vec4(float(cw & 255u), float((cw >> 8) & 255u), float((cw >> 16) & 255u), float(cw >> 24)) / 255.0;
    float wc = 1.0 / qsum;
    vec2 px = p / 16.0;
    float ze = wc * fog_word(f + 11) + fog_word(f + 12) + d * fog_word(f + 13);
    float xe = wc * (px.x * fog_word(f + 5) + fog_word(f + 6)) + fog_word(f + 7) + d * fog_word(f + 14);
    float ye = wc * (px.y * fog_word(f + 8) + fog_word(f + 9)) + fog_word(f + 10) + d * fog_word(f + 15);
    float dist = sqrt(xe * xe + ye * ye + ze * ze + 1.0);
    float i = fog_word(f + 1) == 1.0 ? (dist - fog_word(f + 2)) / fog_word(f + 3)
            : 1.0 - exp(-fog_word(f + 4) * dist);
    if (g_probe) {
        g_dbg_fogn++;
        g_dbg_set = int(set);
        g_dbg_i = i; g_dbg_dist = dist; g_dbg_xe = xe; g_dbg_ye = ye; g_dbg_ze = ze; g_dbg_wc = wc; g_dbg_d = d;
        g_dbg_mode = fog_word(f + 1); g_dbg_start = fog_word(f + 2); g_dbg_len = fog_word(f + 3);
    }
    if (g_fog_debug) {
        return vec3(clamp(i, 0.0, 1.0));
    }
    return mix(rgb, fog_color.rgb, clamp(i, 0.0, 1.0) * fog_color.a);
}

// Выборка текстуры внутри прямоугольника слота атласа (t — координаты текстуры, 1 = размер):
// флаг 16 LINEAR — билинейно по 4 текселям (центры текселей в (i + 0.5) / size), иначе ближайший;
// флаг 32 CLAMP — координаты зажимаются к краю, иначе повтор (mod по размеру слота).
vec4 fetch_slot(vec2 pos, vec2 size, vec2 i) {
    return texelFetch(u_texture, ivec2(pos + i), 0);
}

vec4 sample_slot(vec2 t, vec2 pos, vec2 size, uint flags) {
    bool clamp_uv = (flags & 32u) != 0u;
    if ((flags & 16u) == 0u) {
        vec2 c = clamp_uv ? clamp(floor(t * size), vec2(0.0), size - 1.0) : min(floor(fract(t) * size), size - 1.0);
        return fetch_slot(pos, size, c);
    }
    vec2 st = t * size - 0.5;
    vec2 i0 = floor(st);
    vec2 f = st - i0;
    vec2 i1 = i0 + 1.0;
    if (clamp_uv) {
        i0 = clamp(i0, vec2(0.0), size - 1.0);
        i1 = clamp(i1, vec2(0.0), size - 1.0);
    } else {
        i0 = mod(i0, size);
        i1 = mod(i1, size);
    }
    vec4 a = fetch_slot(pos, size, i0);
    vec4 b = fetch_slot(pos, size, vec2(i1.x, i0.y));
    vec4 c = fetch_slot(pos, size, vec2(i0.x, i1.y));
    vec4 d = fetch_slot(pos, size, i1);
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Глубина хранится с шагом 1/65535, интерполяция даёт погрешность — сравнение с допуском.
bool depth_pass(uint func, float z, float depth) {
    const float EPS = 1.0 / 65535.0;
    if (func == 1u) return z < depth - EPS * 0.25;
    if (func == 2u) return z <= depth + EPS;
    if (func == 3u) return abs(z - depth) <= EPS;
    if (func == 4u) return z > depth + EPS * 0.25;
    if (func == 5u) return z >= depth - EPS;
    return true;
}

// Один треугольник i поверх пикселя p (1/16 пикселя экрана программы): dst — цвет,
// depth — глубина пикселя. Порядок и математика — как у полного перебора.
void apply_tri(int i, vec2 p, int row0, inout vec4 dst, inout float depth) {
    int base = i * TRI_TEXELS;
    uint info = word_at(base + 12, row0);
    uint flags = (info >> 16) & 255u;
    if ((flags & 128u) != 0u) {
        depth = float(word_at(base + 14, row0) & 0xFFFFu) / 65535.0;
        return;
    }
    if ((flags & 64u) != 0u) {
        return;  // SNAPSHOT: снимок экрана в текстуру, считается на CPU (gfx_snap.lua)
    }
    vec2 a = signed_pair(word_at(base, row0));
    vec2 b = signed_pair(word_at(base + 4, row0));
    vec2 c = signed_pair(word_at(base + 8, row0));
    if (p.x < min(a.x, min(b.x, c.x)) || p.x > max(a.x, max(b.x, c.x))
            || p.y < min(a.y, min(b.y, c.y)) || p.y > max(a.y, max(b.y, c.y))) {
        return;
    }
    float area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
    if (abs(area) < 1e-6) {
        return;
    }
    float w0 = ((b.x - p.x) * (c.y - p.y) - (b.y - p.y) * (c.x - p.x)) / area;
    float w1 = ((c.x - p.x) * (a.y - p.y) - (c.y - p.y) * (a.x - p.x)) / area;
    float w2 = 1.0 - w0 - w1;
    if (w0 < 0.0 || w1 < 0.0 || w2 < 0.0) {
        return;
    }
    if (g_probe) { g_dbg_n++; g_dbg_flags = int(flags); }
    uint mode = word_at(base + 13, row0);
    uint func = (mode >> 8) & 15u;
    float z = 0.0;
    if (func != 0u) {
        uint z01 = word_at(base + 14, row0);
        uint z2 = word_at(base + 15, row0);
        z = (float(z01 & 0xFFFFu) * w0 + float(z01 >> 16) * w1 + float(z2 & 0xFFFFu) * w2) / 65535.0;
        if (!depth_pass(func, z, depth)) {
            return;
        }
    }
    // перспективно-корректные веса
    float q0 = w0 * uintBitsToFloat(word_at(base + 3, row0));
    float q1 = w1 * uintBitsToFloat(word_at(base + 7, row0));
    float q2 = w2 * uintBitsToFloat(word_at(base + 11, row0));
    float qs = q0 + q1 + q2;
    float qsum = qs;
    if (qs != 0.0) {
        q0 /= qs; q1 /= qs; q2 /= qs;
    } else {
        q0 = w0; q1 = w1; q2 = w2;
    }
    vec4 color = fetch_color(base + 2, row0) * q0 + fetch_color(base + 6, row0) * q1 + fetch_color(base + 10, row0) * q2;
    if ((flags & 1u) != 0u) {
        uint slot = info & 0xFFFFu;
        if (slot == 0xFFFFu) {
            return;
        }
        uint r0 = word_at(TRIS_SLOT0 + int(slot) * 2, TRIS_ATLAS_H);
        uint r1 = word_at(TRIS_SLOT0 + 1 + int(slot) * 2, TRIS_ATLAS_H);
        vec2 rect_pos = vec2(float(r0 & 0xFFFFu), float(r0 >> 16));
        vec2 rect_size = vec2(float(r1 & 0xFFFFu), float(r1 >> 16));
        uint ua = word_at(base + 1, row0), ub = word_at(base + 5, row0), uc = word_at(base + 9, row0);
        vec2 ta = vec2(float(ua & 0xFFFFu), float(ua >> 16));
        vec2 tb = vec2(float(ub & 0xFFFFu), float(ub >> 16));
        vec2 tc = vec2(float(uc & 0xFFFFu), float(uc >> 16));
        vec2 t = (ta * q0 + tb * q1 + tc * q2) / 4096.0 - 8.0;
        vec4 tex = sample_slot(t, rect_pos, rect_size, flags);
        // как core.glsl Eaglercraft: пиксели приходят ARGB-числами (байты B, G, R, A),
        // флаг CC_swap_rb — уже RGBA
        color *= (flags & 4u) != 0u ? tex : tex.bgra;
    }
    if ((flags & 2u) != 0u && color.a < float(info >> 24) / 255.0) {
        return;
    }
    if ((flags & 8u) != 0u && qsum > 0.0) {
        float d = z;
        if (func == 0u) {
            uint z01 = word_at(base + 14, row0);
            uint z2 = word_at(base + 15, row0);
            d = (float(z01 & 0xFFFFu) * w0 + float(z01 >> 16) * w1 + float(z2 & 0xFFFFu) * w2) / 65535.0;
        }
        color.rgb = apply_fog((mode >> 14) & 255u, p, qsum, d, color.rgb);
    }
    if (func != 0u && (mode & 4096u) != 0u) {
        depth = z;
    }
    if ((mode & 8192u) != 0u) {
        return;  // цвет не пишется (glColorMask(false...)): только тест и запись глубины
    }
    uint blend = mode & 255u;
    vec3 src = color.rgb;
    if (blend == 0u) {
        dst = vec4(src, 1.0);
    } else if (blend == 1u) {
        dst.rgb = src * color.a + dst.rgb * (1.0 - color.a);
    } else if (blend == 2u) {
        dst.rgb = min(dst.rgb + src * color.a, vec3(1.0));
    } else if (blend == 4u) {
        // INVERT: GL_ONE_MINUS_DST_COLOR, GL_ONE_MINUS_SRC_COLOR
        dst.rgb = src * (1.0 - dst.rgb) + dst.rgb * (1.0 - src);
    } else if (blend == 5u) {
        // MUL2: GL_DST_COLOR, GL_SRC_COLOR
        dst.rgb = min(2.0 * src * dst.rgb, vec3(1.0));
    } else if (blend == 6u) {
        // DARKEN: GL_ZERO, GL_ONE_MINUS_SRC_COLOR
        dst.rgb = dst.rgb * (1.0 - src);
    } else if (blend == 7u) {
        // GLINT: GL_SRC_COLOR, GL_ONE
        dst.rgb = min(src * src + dst.rgb, vec3(1.0));
    } else {
        // 3 MUL (GL_DST_COLOR, GL_ZERO) и неизвестные режимы — как раньше
        dst.rgb = dst.rgb * src;
    }
}

// Номер i-го элемента списка тайла: индексы u16, по два на тексель (младшие 16 бит — чётный).
int tile_entry(int n, int idx_row0) {
    uint w = word_at(n >> 1, idx_row0);
    return int((n & 1) != 0 ? (w >> 16) : (w & 0xFFFFu));
}

vec4 draw_pixel(vec2 p, uint count, uint clear, uint bins, int row0, int tile_row, int idx_row0, uint verify);

vec4 draw_tris(vec2 uv) {
    uint count = word_at(0, TRIS_ATLAS_H);
    uint screen = word_at(1, TRIS_ATLAS_H);
    uint clear = word_at(2, TRIS_ATLAS_H);
    uint bins = word_at(4, TRIS_ATLAS_H);
    uint verify = word_at(5, TRIS_ATLAS_H);
    uint rows = word_at(6, TRIS_ATLAS_H);
    int row0 = int(rows & 0xFFFFu);
    int tile_row = int(rows >> 16);
    uint rows7 = word_at(7, TRIS_ATLAS_H);
    int idx_row0 = int(rows7 & 0xFFFFu);
    g_fog_row = int(rows7 >> 16);
    uint probe_word = verify;
    verify &= 255u;
    g_fog_debug = verify == 2u;
    vec2 size = vec2(float(screen & 0xFFFFu), float(screen >> 16));
    // Текстура canvas перевёрнута относительно экрана: строка 0 внизу.
    vec2 p = vec2(uv.x, 1.0 - uv.y) * size * 16.0;
    if (verify == 3u) {
        vec2 px = p / 16.0;
        int cell = int(floor(px.x / 8.0));
        if (px.y < 8.0 && cell < 24) {
            if (cell == 0) {
                return vec4(90.0, 165.0, 60.0, 255.0) / 255.0;  // маркер 5A A5 3C
            }
            vec2 pp = (vec2(float((probe_word >> 8) & 0xFFFu), float(probe_word >> 20)) + 0.5) * 16.0;
            g_probe = true;
            vec4 res = draw_pixel(pp, count, clear, bins, row0, tile_row, idx_row0, 0u);
            g_probe = false;
            float v = 0.0;
            if (cell == 1) v = g_dbg_i; else if (cell == 2) v = g_dbg_dist; else if (cell == 3) v = g_dbg_xe;
            else if (cell == 4) v = g_dbg_ye; else if (cell == 5) v = g_dbg_ze; else if (cell == 6) v = g_dbg_wc;
            else if (cell == 7) v = g_dbg_d; else if (cell == 8) v = float(g_dbg_set); else if (cell == 9) v = float(g_dbg_fogn);
            else if (cell == 10) v = g_dbg_mode; else if (cell == 11) v = g_dbg_start; else if (cell == 12) v = g_dbg_len;
            else if (cell == 13) v = res.r * 255.0; else if (cell == 14) v = res.g * 255.0; else if (cell == 15) v = res.b * 255.0;
            else if (cell == 16) v = float(g_dbg_flags); else if (cell == 17) v = float(g_dbg_n);
            else if (cell == 18) v = pp.x / 16.0; else if (cell == 19) v = pp.y / 16.0;
            else if (cell == 20) v = float(g_fog_row); else if (cell == 21) v = float(count);
            else return vec4(0.0, 0.0, 0.0, 1.0);
            float q = clamp(floor(v * 1000.0 + 0.5) + 8388608.0, 0.0, 16777215.0);
            float r = floor(q / 65536.0), g = floor((q - r * 65536.0) / 256.0), b = q - r * 65536.0 - g * 256.0;
            return vec4(r, g, b, 255.0) / 255.0;
        }
    }
    return draw_pixel(p, count, clear, bins, row0, tile_row, idx_row0, verify);
}

vec4 draw_pixel(vec2 p, uint count, uint clear, uint bins, int row0, int tile_row, int idx_row0, uint verify) {
    vec4 clear_color = vec4(float(clear & 255u), float((clear >> 8) & 255u), float((clear >> 16) & 255u), 255.0) / 255.0;
    float clear_depth = float(word_at(3, TRIS_ATLAS_H) & 0xFFFFu) / 65535.0;
    vec4 dst = clear_color;
    float depth = clear_depth;
    uint shift = bins & 255u;
    if (shift == 0u || verify == 1u) {
        for (int i = 0; i < int(count); i++) {
            apply_tri(i, p, row0, dst, depth);
        }
    }
    if (shift != 0u) {
        // тайл пикселя: те же floor(p / (16 * сторона)), что и при биннинге на CPU
        int tiles_x = int((bins >> 8) & 0xFFFu);
        int tiles_y = int(bins >> 20);
        float scale = 1.0 / float(16u << shift);
        int tx = clamp(int(floor(p.x * scale)), 0, tiles_x - 1);
        int ty = clamp(int(floor(p.y * scale)), 0, tiles_y - 1);
        int t = ty * tiles_x + tx;
        int n0 = int(word_at(t, tile_row));
        int n1 = int(word_at(t + 1, tile_row));
        vec4 full = dst;
        dst = clear_color;
        depth = clear_depth;
        for (int n = n0; n < n1; n++) {
            apply_tri(tile_entry(n, idx_row0), p, row0, dst, depth);
        }
        if (verify == 1u && full.rgb != dst.rgb) {
            return vec4(1.0, 0.0, 1.0, 1.0);
        }
    }
    return vec4(dst.rgb, 1.0);
}

bool is_marker(vec4 c) {
    return c.r > 0.99 && c.g < 0.01 && c.b > 0.99 && abs(c.a - 128.0 / 255.0) < 0.01;
}

// Режим 16-битного кадра ref_soft Xash3D (vc_gfx_present_rgb16, маркер #FF02FF80, 12.10, пак halflife):
// тексель = 2 пикселя (r,g — младший/старший байт левого, b,a — правого). Цвет — как таблица
// R_BuildScreenMap ref_soft при RGBA8: старший байт RGB 3-3-2, младший GBRGBRGB; каналы масштабируются
// по частям (x*256/31, x*256/63) и объединяются OR (сверено со всеми 65536 значениями).
bool is_rgb16_marker(vec4 c) {
    return c.r > 0.99 && abs(c.g - 2.0 / 255.0) < 0.002 && c.b > 0.99 && abs(c.a - 128.0 / 255.0) < 0.01;
}

vec4 draw_rgb16(vec2 uv) {
    ivec2 size = textureSize(u_texture, 0);
    int width = size.x * 2;
    int x = clamp(int(uv.x * float(width)), 0, width - 1);
    int y = clamp(int(uv.y * float(size.y)), 0, size.y - 1);
    uvec4 t = uvec4(texelFetch(u_texture, ivec2(x / 2, y), 0) * 255.0 + 0.5);
    bool left = (x & 1) == 0;
    uint lo = left ? t.r : t.b;
    uint hi = left ? t.g : t.a;
    uint rmaj = ((hi >> 5u) << 2u) & 31u;
    uint gmaj = ((hi >> 2u) << 3u) & 63u;
    uint bmaj = (hi << 3u) & 31u;
    uint rmin = (((lo >> 5u) & 1u) << 1u) | ((lo >> 2u) & 1u);
    uint gmin = (((lo >> 7u) & 1u) << 2u) | (((lo >> 4u) & 1u) << 1u) | ((lo >> 1u) & 1u);
    uint bmin = (((lo >> 6u) & 1u) << 2u) | (((lo >> 3u) & 1u) << 1u) | (lo & 1u);
    uint r = (rmaj * 256u / 31u) | (rmin * 256u / 31u);
    uint g = (gmaj * 256u / 63u) | (gmin * 256u / 63u);
    uint b = (bmaj * 256u / 31u) | (bmin * 256u / 31u);
    return vec4(float(r), float(g), float(b), 255.0) / 255.0;
}

void main() {
    if (is_tris_marker(a_color)) {
        f_color = draw_tris(a_textureCoord);
        return;
    }
    if (is_rgb16_marker(a_color)) {
        f_color = draw_rgb16(a_textureCoord);
        return;
    }
    if (!is_marker(a_color)) {
        f_color = a_color * texture(u_texture, a_textureCoord);
        return;
    }
    ivec2 size = textureSize(u_texture, 0);
    int rows = size.y - 4;
    int width = size.x * 4;
    int x = clamp(int(a_textureCoord.x * float(width)), 0, width - 1);
    int y = clamp(int(a_textureCoord.y * float(size.y)), 0, rows - 1);
    vec4 texel = texelFetch(u_texture, ivec2(x / 4, y), 0);
    int lane = x - (x / 4) * 4;
    float value = lane == 0 ? texel.r : (lane == 1 ? texel.g : (lane == 2 ? texel.b : texel.a));
    int index = int(value * 255.0 + 0.5);
    ivec2 entry = ivec2(index - (index / size.x) * size.x, rows + index / size.x);
    f_color = vec4(texelFetch(u_texture, entry, 0).rgb, 1.0);
}
