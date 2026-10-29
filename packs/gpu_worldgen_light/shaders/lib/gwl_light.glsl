// gpu_worldgen_light: свет неба в шейдерах мира (12.10, gpu_pack2). Небесный свет движок не считает: пак ставит всем блокам
// sky-light-passing (небо 15 везде, Lighting::buildSkyLight не заводит заливку под нависаниями), а уровень неба грани
// считает фрагмент. Режим GWL_MODE:
//   0 (умолчание) — по высотам столбцов: цепочка RLE пака gpu_worldgen считает на GPU из тех же вокселей, что пишет в мир
//       (функция плотности + деревья), 1 + y верхнего вокселя, закрывающего небо; Lua кладёт их в регион атласа gwl_world
//       (слоты 32x32 чанков по 16x16 текселей: R = верх, A = 1 + низ, G/B = cx/cz & 255 — проверка слота). Клетка выше
//       верха или ниже низа столба (пустота под островами) — небо 15; иначе 15 - (манхэттенское расстояние до столба,
//       открытого на её высоте), не меньше GWL_FLOOR; тень солнца — шаги по верхам вдоль луча к солнцу.
//   1 — лучи по функции плотности (lib/gwl_density.glsl) прямо во фрагменте: вверх, к солнцу, косые (первый вариант;
//       дорого: GPU 75–87 % при 854x480, см. README пака).
// AO в обоих режимах — по плотности: 4 соседа клетки перед гранью в плоскости грани (ближе GWL_AO_DIST).
// Свет ламп (emission) по-прежнему считает движок (a_torchLight). Нужно: u_texture0 (атлас блоков с регионом gwl_world).
#ifndef GWL_LIGHT_GLSL_
#define GWL_LIGHT_GLSL_

#include <gwl_density>

// качество/цена: октав fbm у дальних проб лучей и у AO, дальность тени от солнца и AO (блоки)
#ifndef GWL_FAR_OCT
#define GWL_FAR_OCT 2
#endif
#ifndef GWL_AO_OCT
#define GWL_AO_OCT 8
#endif
#ifndef GWL_SUN_DIST
#define GWL_SUN_DIST 128.0
#endif
#ifndef GWL_AO_DIST
#define GWL_AO_DIST 32.0
#endif

int g_preset, g_top, g_sea;

bool gwl_init() {
    if (!gwl_load()) return false;
    g_preset = gw_i(18);
    g_top = gw_i(64);
    g_sea = gw_i(65);
    return true;
}

// рельеф (плотность > 0) в клетке c; column — gw_column уже посчитан для (c.x, c.z)
bool gwl_terrain(ivec3 c, bool column) {
    if (c.y > 255) return false;
    if (c.y <= 0) return g_preset != 3;
    if (g_preset == 0) {
        g_OCT = min(g_OCT_full, g_lo);
        return gw_density(c.x, c.y, c.z) > 0.0;
    }
    if (!column) gw_column(g_preset, float(c.x), float(c.z));
    return gw_pdens(g_preset, float(c.x), c.y, float(c.z)) > 0.0;
}
// твёрдая клетка по правилу генератора: рельеф и не вырезан пещерой/туннелем
bool gwl_solid(ivec3 c, bool column) {
    if (!gwl_terrain(c, column)) return false;
    if (c.y <= 0) return true;
    if (g_preset == 0) return !(c.y > 4 && gw_cave(c.x, c.y, c.z));
    return !gw_pcarve(g_preset, float(c.x), c.y, float(c.z));
}

// луч вверх из клетки c: 1 — до g_top нет твёрдого, 0 — перекрыт (шаги растут: 1, 2, 4, 7, 11, ... до 12)
float gwl_up(ivec3 c) {
    g_lo = 8;
    if (g_preset != 0) gw_column(g_preset, float(c.x), float(c.z));
    int k = 1, st = 1;
    for (int i = 0; i < 40; i++) {
        int y = c.y + k;
        if (y > g_top) return 1.0;
        g_lo = k <= 2 ? 8 : GWL_FAR_OCT;
        if (gwl_solid(ivec3(c.x, y, c.z), true)) return 0.0;
        k += st;
        st = min(st + 1, 16);
    }
    return 1.0;
}

// косой луч: на 1 блок вверх смещение d.x по x и d.y по z
float gwl_ray(ivec3 c, vec2 d, int n) {
    float k = 1.0, st = 1.0;
    for (int i = 0; i < n; i++) {
        int y = c.y + int(k);
        if (y > g_top) return 1.0;
        g_lo = k <= 2.0 ? 8 : GWL_FAR_OCT;
        ivec3 q = ivec3(c.x + int(floor(d.x * k + 0.5)), y, c.z + int(floor(d.y * k + 0.5)));
        if (gwl_solid(q, false)) return 0.0;
        k += st;
        st = min(st + 1.0, 12.0);
    }
    return 1.0;
}

// AO: 4 соседа клетки перед гранью в плоскости грани затемняют край грани со своей стороны
float gwl_ao(vec3 p, vec3 n, ivec3 c) {
    g_lo = GWL_AO_OCT;
    vec3 an = abs(n);
    ivec3 t1, t2;
    float u, v;
    if (an.y > 0.9) { t1 = ivec3(1, 0, 0); t2 = ivec3(0, 0, 1); u = p.x - float(c.x); v = p.z - float(c.z); }
    else if (an.x > 0.9) { t1 = ivec3(0, 1, 0); t2 = ivec3(0, 0, 1); u = p.y - float(c.y); v = p.z - float(c.z); }
    else if (an.z > 0.9) { t1 = ivec3(1, 0, 0); t2 = ivec3(0, 1, 0); u = p.x - float(c.x); v = p.y - float(c.y); }
    else return 1.0;
    float a = 0.0;
    if (gwl_solid(c + t1, false)) a += smoothstep(0.3, 1.0, u);
    if (gwl_solid(c - t1, false)) a += smoothstep(0.3, 1.0, 1.0 - u);
    if (gwl_solid(c + t2, false)) a += smoothstep(0.3, 1.0, v);
    if (gwl_solid(c - t2, false)) a += smoothstep(0.3, 1.0, 1.0 - v);
    return 1.0 - 0.22 * min(a, 2.0);
}

#ifndef GWL_MODE
#define GWL_MODE 0
#endif
#ifndef GWL_SPILL
#define GWL_SPILL 14
#endif
// небо в закрытых клетках не ниже GWL_FLOOR (рассеянный свет пещер; заливка движка до 15 - расстояние, см. README)
#ifndef GWL_FLOOR
#define GWL_FLOOR 0.35
#endif
#ifndef GWL_SUN_STEPS
#define GWL_SUN_STEPS 24
#endif

// столб (x, z): x — 1 + y верхнего вокселя, закрывающего небо (0 — нет), y — y нижнего (255 — нет);
// (-1, -1) — слот не этого чанка (не записан)
ivec2 gwl_hcol(int x, int z) {
    int cx = x >> 4, cz = z >> 4;
    uvec4 v = uvec4(texelFetch(u_texture0, ivec2(2 + (cx & 31) * 16 + (x & 15), 2 + (cz & 31) * 16 + (z & 15)), 0)
        * 255.0 + 0.5);
    if (v.a == 0u || v.g != uint(cx & 255) || v.b != uint(cz & 255)) return ivec2(-1);
    return ivec2(int(v.r), int(v.a) - 1);
}
int gwl_htop(int x, int z) { return gwl_hcol(x, z).x; }
// клетка на высоте y столба открыта: над верхним вокселем (небо) или под нижним (пустота под островами);
// неизвестный столб — открыт
bool gwl_hopen(int x, int y, int z) { ivec2 h = gwl_hcol(x, z); return h.x <= y || y < h.y; }

// уровень неба клетки c по высотам: 15 над столбом; ниже — 15 - расстояние до ближайшего открытого на высоте c.y столба
// (кольца манхэттенского радиуса r: 4 по осям и 4 диагональных точки); 0..1
float gwl_hsky(ivec3 c) {
    if (gwl_hopen(c.x, c.y, c.z)) return 1.0;
    for (int r = 1; r <= GWL_SPILL; r++) {
        int a = r >> 1, b = r - (r >> 1);
        if (gwl_hopen(c.x + r, c.y, c.z) || gwl_hopen(c.x - r, c.y, c.z) || gwl_hopen(c.x, c.y, c.z + r)
            || gwl_hopen(c.x, c.y, c.z - r) || gwl_hopen(c.x + a, c.y, c.z + b) || gwl_hopen(c.x - a, c.y, c.z - b)
            || gwl_hopen(c.x + b, c.y, c.z - a) || gwl_hopen(c.x - b, c.y, c.z + a)) {
            return max(GWL_FLOOR, float(15 - r) / 15.0);
        }
    }
    return GWL_FLOOR;
}
// тень солнца по высотам: луч из клетки к солнцу (на 1 вверх: 0.35 по x, 0.25 по z)
float gwl_hsun(ivec3 c) {
    for (int k = 1; k <= GWL_SUN_STEPS; k++) {
        int y = c.y + k;
        if (y > g_top) return 1.0;
        if (gwl_htop(c.x + int(floor(0.35 * float(k) + 0.5)), c.z + int(floor(0.25 * float(k) + 0.5))) > y) return 0.0;
    }
    return 1.0;
}

// видимость неба грани в точке p (мир) с нормалью n: множитель a_skyLight (0..1), ao — затемнение углов
float gwl_light(vec3 p, vec3 n, float dist, out float ao) {
#if GWL_MODE == 0
    ao = 1.0;
    bool axis0 = max(abs(n.x), max(abs(n.y), abs(n.z))) > 0.9;
    ivec3 c0 = axis0 ? ivec3(floor(p + n * 0.5)) : ivec3(floor(p));
    float vis0 = gwl_hsky(c0);
    if (vis0 > 0.99 && dist < GWL_SUN_DIST && gwl_htop(c0.x, c0.z) <= c0.y) vis0 *= mix(0.72, 1.0, gwl_hsun(c0));
    if (g_sea >= 0 && c0.y <= g_sea && vis0 > 0.0) {
        g_lo = 8;
        if (!gwl_terrain(c0, false)) vis0 *= clamp(1.0 - float(g_sea - c0.y + 1) / 15.0, 0.0, 1.0);
    }
    if (axis0 && dist < GWL_AO_DIST) ao = gwl_ao(p, n, c0);
    return vis0;
#else
    ao = 1.0;
    bool axis = max(abs(n.x), max(abs(n.y), abs(n.z))) > 0.9;
    // клетка перед гранью (у крестов-растений — своя клетка)
    ivec3 c = axis ? ivec3(floor(p + n * 0.5)) : ivec3(floor(p));
    float up = gwl_up(c);
    float vis = up;
    if (up < 0.5) {
        // под крышей: косые лучи дают мягкий край у выхода к небу (как спад небесного света движка по 1 на блок)
        float v = max(gwl_ray(c, vec2(0.9, 0.4), 12), gwl_ray(c, vec2(-0.5, -0.9), 12));
        if (v < 0.5) v = max(gwl_ray(c, vec2(-0.9, 0.5), 12), gwl_ray(c, vec2(0.4, -0.9), 12));
        vis = 0.6 * v;
    }
    // тень от солнца (направление фиксировано: полдень пака, наклон 0.35 / 0.25 на блок вверх)
    if (vis > 0.0 && dist < GWL_SUN_DIST) vis *= mix(0.72, 1.0, gwl_ray(c, vec2(0.35, 0.25), 10));
    // вода над клеткой: -1/15 на блок глубины (как спад света движка в воде)
    if (g_sea >= 0 && c.y <= g_sea) {
        g_lo = 8;
        if (!gwl_terrain(c, false)) vis *= clamp(1.0 - float(g_sea - c.y + 1) / 15.0, 0.0, 1.0);
    }
    if (axis && dist < GWL_AO_DIST) ao = gwl_ao(p, n, c);
    return vis;
#endif
}

#endif // GWL_LIGHT_GLSL_
