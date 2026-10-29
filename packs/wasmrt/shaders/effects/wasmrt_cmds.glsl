// wasmrt: исполняет список команд отрисовки wasm-программы (графика 'posteffect').
// Команда — 2 vec4: (a, b, c, d) и (r, g, b, тип).
//   1 — прямоугольник x=a, y=b, w=c, h=d;  2 — круг: центр (a, b), радиус c;
//   3 — линия (a, b)-(c, d) толщиной 1;    4 — очистка всего экрана цветом;
//   6 — текст: (a, b) — позиция, c — масштаб, d — длина; коды символов — в следующих
//       командах типа 7 (по 7 кодов: 4 в первом vec4, 3 во втором). Шрифт 5x7 (u_font:
//       на глиф 2 числа по 4 строки/3 строки, 5 бит на строку), шаг 6.
// Координаты — виртуальный экран u_virtual, начало в левом верхнем углу; экран вписан
// в окно по центру, вокруг виден мир.
//
// Отладка (u_debug): 1 — ячейки значений в левом верхнем углу окна (маркер 5A A5 3C,
// числа в RGB 24 бит, шаг 0.001, смещение 2^23; читает MCP vc_shader_cells), считаются
// для точки-зонда u_probe; 2 — карта перерисовки (сколько команд легло в пиксель).
#param vec4 u_cmds[512]
#param vec4 u_font[32]
#param int u_cmdCount = 0
#param vec2 u_virtual = [320, 200]
#param float u_screenFill = 0.9
#param int u_debug = 0
#param vec2 u_probe = [160, 100]

struct Shade {
    vec3 color;
    int hits;
    int last;
};

float segment_distance(vec2 p, vec2 a, vec2 b) {
    vec2 ab = b - a;
    float t = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
    return length(p - (a + ab * t));
}

float font_part(int index) {
    return u_font[index / 4][index - (index / 4) * 4];
}

// Пиксель текстовой команды i в точке local (единицы шрифта от начала строки).
bool text_pixel(int i, vec2 local, float len) {
    if (local.x < 0.0 || local.y < 0.0 || local.y >= 7.0) return false;
    int column = int(local.x);
    int ch = column / 6;
    int col = column - ch * 6;
    if (ch >= int(len) || col >= 5) return false;
    int data = i + 1 + ch / 7;
    int slot = ch - (ch / 7) * 7;
    float code_f = slot < 4 ? u_cmds[data * 2][slot] : u_cmds[data * 2 + 1][slot - 4];
    int code = int(code_f + 0.5);
    if (code >= 97 && code <= 122) code -= 32;
    if (code < 32 || code > 95) code = 63;
    int glyph = code - 32;
    int row = int(local.y);
    int bits = row < 4
        ? (int(font_part(glyph * 2)) >> (5 * row)) & 31
        : (int(font_part(glyph * 2 + 1)) >> (5 * (row - 4))) & 31;
    return ((bits >> (4 - col)) & 1) != 0;
}

Shade render(vec2 p, vec3 base) {
    Shade s = Shade(base, 0, -1);
    for (int i = 0; i < u_cmdCount; i++) {
        vec4 geom = u_cmds[i * 2];
        vec4 paint = u_cmds[i * 2 + 1];
        int type = int(paint.w + 0.5);
        bool inside = false;
        if (type == 1) {
            inside = p.x >= geom.x && p.y >= geom.y && p.x < geom.x + geom.z && p.y < geom.y + geom.w;
        } else if (type == 2) {
            inside = distance(p, geom.xy) <= geom.z;
        } else if (type == 3) {
            inside = segment_distance(p, geom.xy + 0.5, geom.zw + 0.5) <= 0.5;
        } else if (type == 4) {
            inside = true;
        } else if (type == 6) {
            inside = text_pixel(i, (p - geom.xy) / max(geom.z, 1.0), geom.w);
        }
        if (inside) {
            s.color = paint.rgb;
            s.hits++;
            s.last = i;
        }
    }
    return s;
}

const float DBG_CELL = 8.0;
const int DBG_CELLS = 16;

vec3 dbg_encode(float v) {
    float q = clamp(floor(v * 1000.0 + 0.5) + 8388608.0, 0.0, 16777215.0);
    float r = floor(q / 65536.0);
    float g = floor((q - r * 65536.0) / 256.0);
    float b = q - r * 65536.0 - g * 256.0;
    return vec3(r, g, b) / 255.0;
}

float dbg_value(int cell, vec2 screen, float scale) {
    Shade s = render(u_probe, vec3(-1.0));
    if (cell == 1) return float(u_cmdCount);
    if (cell == 2) return u_probe.x;
    if (cell == 3) return u_probe.y;
    if (cell == 4) return float(s.hits);
    if (cell == 5) return float(s.last);
    if (cell == 6) return s.color.r;
    if (cell == 7) return s.color.g;
    if (cell == 8) return s.color.b;
    if (cell == 9) return screen.x;
    if (cell == 10) return screen.y;
    if (cell == 11) return scale;
    if (cell == 12) return u_virtual.x;
    if (cell == 13) return u_virtual.y;
    if (cell == 14) return s.last >= 0 ? u_cmds[s.last * 2 + 1].w : -1.0;
    return u_timer;
}

int dbg_cell_at(vec2 frag, vec2 screen) {
    vec2 top = vec2(frag.x, screen.y - frag.y);
    if (top.y >= DBG_CELL || top.x >= DBG_CELL * float(DBG_CELLS)) return -1;
    return int(top.x / DBG_CELL);
}

vec4 effect() {
    vec4 world = texture(u_screen, v_uv);
    vec2 screen = vec2(u_screenSize);
    float scale = min(screen.x / u_virtual.x, screen.y / u_virtual.y) * u_screenFill;

    if (u_debug == 1) {
        int cell = dbg_cell_at(gl_FragCoord.xy, screen);
        if (cell == 0) return vec4(90.0, 165.0, 60.0, 255.0) / 255.0;
        if (cell > 0) return vec4(dbg_encode(dbg_value(cell, screen, scale)), 1.0);
    }

    vec2 origin = (screen - u_virtual * scale) * 0.5;
    vec2 p = (gl_FragCoord.xy - origin) / scale;
    if (p.x < 0.0 || p.y < 0.0 || p.x >= u_virtual.x || p.y >= u_virtual.y) {
        return world;
    }
    p.y = u_virtual.y - p.y;

    Shade s = render(p, world.rgb);
    if (u_debug == 2) {
        if (s.hits == 0) return vec4(1.0, 0.0, 0.0, 1.0);
        return vec4(vec3(min(float(s.hits), 8.0) / 8.0), 1.0);
    }
    if (u_debug == 1 && distance(p, u_probe) < 2.0) {
        return vec4(1.0, 0.0, 1.0, 1.0);
    }
    return vec4(s.color, 1.0);
}
