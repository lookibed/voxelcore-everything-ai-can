-- CPU-растеризация треугольников gfx_tris для снимков экрана (glCopyTexSubImage2D из экрана в
-- текстуру: размытие панорамы главного меню Minecraft — 8 проходов «скопировать область и
-- нарисовать её же со сдвигом»). GPU рисует кадр одним проходом шейдера в конце, поэтому
-- промежуточное содержимое экрана, которое читает копия, считается здесь, на CPU, по тем же
-- формулам, что ui.glslf: барицентрические веса в 1/16 пикселя в центре пикселя, перспективно-
-- корректные цвет и UV (веса w_i / w), выборка из слота атласа (NEAREST/LINEAR, REPEAT/CLAMP,
-- .bgra или .rgba при SWAP_RB), альфа-тест, тест и запись глубины, смешивание 0-7. Цвет области
-- хранится байтами и округляется после каждого треугольника — как 8-битный кадровый буфер WebGL.
-- Туман (флаг 8) здесь не применяется.
--
-- Запись SNAPSHOT (флаг 64 в поле флагов слова 12, VcGL.java): [0] id текстуры программы,
-- [1] x | y << 16 — левый верхний угол прямоугольника экрана (пиксели, y вниз), [2] w | h << 16,
-- [3] смещение в текстуре x | y << 16. Строка r текстуры = строка экрана y + h - 1 - r (у GL
-- строка 0 текстуры — нижняя строка окна). Тексели пишутся байтами B, G, R, 255 (как пиксели
-- программы: шейдер берёт .bgra); альфа кадрового буфера WebGL без альфа-канала — 1.
local floor, ceil, min, max, ldexp, huge = math.floor, math.ceil, math.min, math.max, math.ldexp, math.huge

local M = {}

local FLAG_TEXTURED, FLAG_ALPHATEST, FLAG_SWAP_RB = 1, 2, 4
local FLAG_LINEAR, FLAG_CLAMP, FLAG_SNAPSHOT, FLAG_CLEAR_DEPTH = 16, 32, 64, 128
local EPS = 1 / 65535

local function s16(v)
    return v >= 32768 and v - 65536 or v
end

-- float из 4 байт little-endian
local function f32(b0, b1, b2, b3)
    local e = (b3 % 128) * 2 + floor(b2 / 128)
    local m = (b2 % 128) * 65536 + b1 * 256 + b0
    local v
    if e == 0 then
        v = ldexp(m, -149)
    elseif e == 255 then
        v = m == 0 and huge or 0 / 0
    else
        v = ldexp(m + 8388608, e - 150)
    end
    return b3 >= 128 and -v or v
end

-- Генератор специализированного быстрого пути: тело цикла без ветвлений по флагам треугольника
-- (перспектива/аффинный, NEAREST/LINEAR, REPEAT/CLAMP, SWAP_RB, альфа-тест, функция и запись глубины).
-- Каждое сочетание компилируется один раз (loadstring) и кэшируется.
local DEPTH_TEST = {
    [1] = "z < Z[k] - EPS * 0.25", [2] = "z <= Z[k] + EPS", [3] = "math.abs(z - Z[k]) <= EPS",
    [4] = "z > Z[k] + EPS * 0.25", [5] = "z >= Z[k] - EPS",
}

local function gen_source(affine, linear, clampuv, swap, alpha_test, func, zwrite)
    local L = {}
    local function add(s) L[#L + 1] = s end
    add("local p, R, G, B, Z, W, EPS, stats = ...")
    add("local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max")
    add("return function(rx, ry, rw, px0, px1, py0, py1, A0, B0, K0, A1, B1, K1, iw0, iw1, iw2,")
    add("        u0, v0, u1, v1, u2, v2, z0, z1, z2, cr, cg, cb, ca0, sx, sy, sw, sh, thr)")
    add("    local A2, B2, K2 = -A0 - A1, -B0 - B1, 1 - K0 - K1")
    if affine then
        add("    local nu2, nv2, du0, du1, dv0, dv1 = u2, v2, u0 - u2, u1 - u2, v0 - v2, v1 - v2")
    else
        add("    local dq0, dq1 = iw0 - iw2, iw1 - iw2")
        add("    local nu2, nv2 = u2 * iw2, v2 * iw2")
        add("    local du0, du1 = u0 * iw0 - nu2, u1 * iw1 - nu2")
        add("    local dv0, dv1 = v0 * iw0 - nv2, v1 * iw1 - nv2")
    end
    add("    local dz0, dz1 = z0 - z2, z1 - z2")
    add("    local ka = ca0 / 255")
    add("    local W4 = W * 4")
    add("    local base = (sy * W + sx) * 4")
    add("    local swm1, shm1 = sw - 1, sh - 1")
    add("    local pix = 0")
    add("    for py = py0, py1 do")
    add("        local Y = (py + 0.5) * 16")
    add("        local row = (py - ry) * rw - rx + 1")
    add("        local lo, hi = px0, px1")
    add("        local c0, c1, c2 = K0 + B0 * Y, K1 + B1 * Y, K2 + B2 * Y")
    for _, e in ipairs({ { "A0", "c0" }, { "A1", "c1" }, { "A2", "c2" } }) do
        local A, c = e[1], e[2]
        add(("        if %s > 0 then lo = max(lo, ceil(-%s / %s / 16 - 1)) elseif %s < 0 then hi = min(hi, floor(-%s / %s / 16)) elseif %s < 0 then hi = lo - 1 end")
            :format(A, c, A, A, c, A, c))
    end
    add("        if lo <= hi then")
    add("            local X = (lo + 0.5) * 16")
    add("            local w0 = c0 + A0 * X")
    add("            local w1 = c1 + A1 * X")
    add("            local d0, d1 = A0 * 16, A1 * 16")
    add("            for px = lo, hi do")
    add("                local w2 = 1 - w0 - w1")
    add("                if w0 >= 0 and w1 >= 0 and w2 >= 0 then")
    add("                    local k = row + px")
    local depth = func ~= 0 and (zwrite or DEPTH_TEST[func])
    if depth then add("                    local z = z2 + w0 * dz0 + w1 * dz1") end
    if func ~= 0 and DEPTH_TEST[func] then add("                    if " .. DEPTH_TEST[func] .. " then") else add("                    do") end
    if affine then
        add("                        local tu = nu2 + w0 * du0 + w1 * du1")
        add("                        local tv = nv2 + w0 * dv0 + w1 * dv1")
    else
        add("                        local iq = 1 / (iw2 + w0 * dq0 + w1 * dq1)")
        add("                        local tu = (nu2 + w0 * du0 + w1 * du1) * iq")
        add("                        local tv = (nv2 + w0 * dv0 + w1 * dv1) * iq")
    end
    if not linear then
        if clampuv then
            add("                        local ix, iy = floor(tu * sw), floor(tv * sh)")
            add("                        ix = ix < 0 and 0 or (ix > swm1 and swm1 or ix)")
            add("                        iy = iy < 0 and 0 or (iy > shm1 and shm1 or iy)")
        else
            add("                        local ix, iy = floor((tu - floor(tu)) * sw), floor((tv - floor(tv)) * sh)")
            add("                        if ix > swm1 then ix = swm1 end")
            add("                        if iy > shm1 then iy = shm1 end")
        end
        add("                        local o = base + iy * W4 + ix * 4")
        add("                        local t0, t1, t2, t3 = p[o], p[o + 1], p[o + 2], p[o + 3]")
    else
        add("                        local fx, fy = tu * sw - 0.5, tv * sh - 0.5")
        add("                        local x0, y0 = floor(fx), floor(fy)")
        add("                        local fu, fv = fx - x0, fy - y0")
        add("                        local x1, y1 = x0 + 1, y0 + 1")
        if clampuv then
            add("                        x0 = x0 < 0 and 0 or (x0 > swm1 and swm1 or x0); x1 = x1 < 0 and 0 or (x1 > swm1 and swm1 or x1)")
            add("                        y0 = y0 < 0 and 0 or (y0 > shm1 and shm1 or y0); y1 = y1 < 0 and 0 or (y1 > shm1 and shm1 or y1)")
        else
            add("                        x0 = x0 % sw; x1 = x1 % sw; y0 = y0 % sh; y1 = y1 % sh")
        end
        add("                        local oa = base + y0 * W4 + x0 * 4")
        add("                        local ob = base + y0 * W4 + x1 * 4")
        add("                        local oc = base + y1 * W4 + x0 * 4")
        add("                        local od = base + y1 * W4 + x1 * 4")
        add("                        local fu1, fv1 = 1 - fu, 1 - fv")
        add("                        local t0 = (p[oa] * fu1 + p[ob] * fu) * fv1 + (p[oc] * fu1 + p[od] * fu) * fv")
        add("                        local t1 = (p[oa + 1] * fu1 + p[ob + 1] * fu) * fv1 + (p[oc + 1] * fu1 + p[od + 1] * fu) * fv")
        add("                        local t2 = (p[oa + 2] * fu1 + p[ob + 2] * fu) * fv1 + (p[oc + 2] * fu1 + p[od + 2] * fu) * fv")
        add("                        local t3 = (p[oa + 3] * fu1 + p[ob + 3] * fu) * fv1 + (p[oc + 3] * fu1 + p[od + 3] * fu) * fv")
    end
    add("                        local a = ka * t3")
    if alpha_test then add("                        if a >= thr then") else add("                        do") end
    if func ~= 0 and zwrite then add("                            Z[k] = z") end
    add("                            local ia = 1 - a")
    local sr, sb = swap and "t0" or "t2", swap and "t2" or "t0"
    add(("                            R[k] = floor(%s * cr * a + R[k] * ia + 0.5)"):format(sr))
    add("                            G[k] = floor(t1 * cg * a + G[k] * ia + 0.5)")
    add(("                            B[k] = floor(%s * cb * a + B[k] * ia + 0.5)"):format(sb))
    add("                            pix = pix + 1")
    add("                        end")
    add("                    end")
    add("                end")
    add("                w0, w1 = w0 + d0, w1 + d1")
    add("            end")
    add("        end")
    add("    end")
    add("    stats.pixels = stats.pixels + pix")
    add("end")
    return table.concat(L, "\n")
end

-- p — байты canvas (FFI-указатель Bytearray.bytes или таблица), W — ширина canvas в текселях,
-- header — номер тексела заголовка, tri_base — номер тексела первого треугольника,
-- slot0 — первое слово слотов в заголовке, slot_of(id) -> номер слота или nil.
function M.new(p, W, header, tri_base, tri_texels, slot0, slot_of)
    local self = {}
    -- цвет области — байты (Bytearray движка: FFI-указатель без проверок границ таблиц), иначе таблицы
    local R, G, B, Z = {}, {}, {}, {}
    local keep = {}
    local function bytes(n)
        if Bytearray then
            local b = Bytearray(n + 1)
            keep[#keep + 1] = b
            return b.bytes
        end
        return {}
    end
    local MAXPIX = 1024 * 1024
    R, G, B = bytes(MAXPIX), bytes(MAXPIX), bytes(MAXPIX)
    local rx, ry, rw, rh = 0, 0, 0, 0
    local done = 0       -- записей кадра, уже нарисованных в область
    local stats = { pixels = 0, tris = 0, snapshots = 0 }
    self.stats = stats

    local function init_region(x, y, w, h, clear, clear_depth)
        if w * h > MAXPIX then h = math.floor(MAXPIX / w) end
        rx, ry, rw, rh = x, y, w, h
        local cr, cg, cb = clear % 256, floor(clear / 256) % 256, floor(clear / 65536) % 256
        local cz = (clear_depth or 65535) / 65535
        for i = 1, w * h do R[i], G[i], B[i], Z[i] = cr, cg, cb, cz end
    end

    local function slot_rect(slot)
        local o = (header + slot0 + slot * 2) * 4
        return p[o] + p[o + 1] * 256, p[o + 2] + p[o + 3] * 256, p[o + 4] + p[o + 5] * 256, p[o + 6] + p[o + 7] * 256
    end

    local function depth_pass(func, z, depth)
        if func == 1 then return z < depth - EPS * 0.25 end
        if func == 2 then return z <= depth + EPS end
        if func == 3 then return math.abs(z - depth) <= EPS end
        if func == 4 then return z > depth + EPS * 0.25 end
        if func == 5 then return z >= depth - EPS end
        return true
    end

    -- Быстрый путь (панорама и размытие меню): текстура, одинаковый цвет вершин, смешивание alpha.
    -- Всё линейное по экрану (веса, сумма q = w_i / w_i, числители u и v, глубина) приращивается
    -- по пикселю; у аффинного треугольника (1/w вершин равны) деления нет. Результат — те же формулы,
    -- что в общем пути (до округления float).
    local function raster_fast(px0, px1, py0, py1, A0, B0, K0, A1, B1, K1, iw0, iw1, iw2,
            u0, v0, u1, v1, u2, v2, z0, z1, z2, cr, cg, cb, ca0, sx, sy, sw, sh,
            linear, clampuv, swap, alpha_test, thr, func, zwrite)
        local A2, B2, K2 = -A0 - A1, -B0 - B1, 1 - K0 - K1
        local affine = iw0 == iw1 and iw1 == iw2
        -- по весам w0, w1 (w2 = 1 - w0 - w1): q = iw2 + w0 dq0 + w1 dq1, nu = u2 iw2 + w0 du0 + w1 du1 ...
        local dq0, dq1 = iw0 - iw2, iw1 - iw2
        local nu2, nv2 = u2 * iw2, v2 * iw2
        local du0, du1 = u0 * iw0 - nu2, u1 * iw1 - nu2
        local dv0, dv1 = v0 * iw0 - nv2, v1 * iw1 - nv2
        if affine then
            nu2, nv2, du0, du1, dv0, dv1 = u2, v2, u0 - u2, u1 - u2, v0 - v2, v1 - v2
        end
        local dz0, dz1 = z0 - z2, z1 - z2
        -- цвет * тексель: множители в байтах текселя (0..255 -> 0..1 цвета)
        local kr, kg, kb, ka = cr, cg, cb, ca0 / 255
        local W4 = W * 4
        local base = (sy * W + sx) * 4
        local swm1, shm1 = sw - 1, sh - 1
        local pix = 0
        for py = py0, py1 do
            local Y = (py + 0.5) * 16
            local row = (py - ry) * rw - rx + 1
            local lo, hi = px0, px1
            local c0, c1, c2 = K0 + B0 * Y, K1 + B1 * Y, K2 + B2 * Y
            if A0 > 0 then lo = max(lo, ceil(-c0 / A0 / 16 - 1)) elseif A0 < 0 then hi = min(hi, floor(-c0 / A0 / 16)) elseif c0 < 0 then hi = lo - 1 end
            if A1 > 0 then lo = max(lo, ceil(-c1 / A1 / 16 - 1)) elseif A1 < 0 then hi = min(hi, floor(-c1 / A1 / 16)) elseif c1 < 0 then hi = lo - 1 end
            if A2 > 0 then lo = max(lo, ceil(-c2 / A2 / 16 - 1)) elseif A2 < 0 then hi = min(hi, floor(-c2 / A2 / 16)) elseif c2 < 0 then hi = lo - 1 end
            if lo <= hi then
                local X = (lo + 0.5) * 16
                local w0 = c0 + A0 * X
                local w1 = c1 + A1 * X
                local d0, d1 = A0 * 16, A1 * 16
                for px = lo, hi do
                    local w2 = 1 - w0 - w1
                    if w0 >= 0 and w1 >= 0 and w2 >= 0 then
                        local k = row + px
                        local z = z2 + w0 * dz0 + w1 * dz1
                        if func == 0 or depth_pass(func, z, Z[k]) then
                            local tu, tv
                            if affine then
                                tu = nu2 + w0 * du0 + w1 * du1
                                tv = nv2 + w0 * dv0 + w1 * dv1
                            else
                                local iq = 1 / (iw2 + w0 * dq0 + w1 * dq1)
                                tu = (nu2 + w0 * du0 + w1 * du1) * iq
                                tv = (nv2 + w0 * dv0 + w1 * dv1) * iq
                            end
                            local t0, t1, t2, t3
                            if not linear then
                                local ix, iy
                                if clampuv then
                                    ix = floor(tu * sw); iy = floor(tv * sh)
                                    ix = ix < 0 and 0 or (ix > swm1 and swm1 or ix)
                                    iy = iy < 0 and 0 or (iy > shm1 and shm1 or iy)
                                else
                                    ix = floor((tu - floor(tu)) * sw); iy = floor((tv - floor(tv)) * sh)
                                    if ix > swm1 then ix = swm1 end
                                    if iy > shm1 then iy = shm1 end
                                end
                                local o = base + iy * W4 + ix * 4
                                t0, t1, t2, t3 = p[o], p[o + 1], p[o + 2], p[o + 3]
                            else
                                local fx, fy = tu * sw - 0.5, tv * sh - 0.5
                                local x0, y0 = floor(fx), floor(fy)
                                local fu, fv = fx - x0, fy - y0
                                local x1, y1 = x0 + 1, y0 + 1
                                if clampuv then
                                    x0 = x0 < 0 and 0 or (x0 > swm1 and swm1 or x0); x1 = x1 < 0 and 0 or (x1 > swm1 and swm1 or x1)
                                    y0 = y0 < 0 and 0 or (y0 > shm1 and shm1 or y0); y1 = y1 < 0 and 0 or (y1 > shm1 and shm1 or y1)
                                else
                                    x0 = x0 % sw; x1 = x1 % sw; y0 = y0 % sh; y1 = y1 % sh
                                end
                                local oa = base + y0 * W4 + x0 * 4
                                local ob2 = base + y0 * W4 + x1 * 4
                                local oc = base + y1 * W4 + x0 * 4
                                local od = base + y1 * W4 + x1 * 4
                                local fu1, fv1 = 1 - fu, 1 - fv
                                t0 = (p[oa] * fu1 + p[ob2] * fu) * fv1 + (p[oc] * fu1 + p[od] * fu) * fv
                                t1 = (p[oa + 1] * fu1 + p[ob2 + 1] * fu) * fv1 + (p[oc + 1] * fu1 + p[od + 1] * fu) * fv
                                t2 = (p[oa + 2] * fu1 + p[ob2 + 2] * fu) * fv1 + (p[oc + 2] * fu1 + p[od + 2] * fu) * fv
                                t3 = (p[oa + 3] * fu1 + p[ob2 + 3] * fu) * fv1 + (p[oc + 3] * fu1 + p[od + 3] * fu) * fv
                            end
                            local a = ka * t3
                            if not (alpha_test and a < thr) then
                                if func ~= 0 and zwrite then Z[k] = z end
                                local ia = 1 - a
                                local sr, sb
                                if swap then sr, sb = t0, t2 else sr, sb = t2, t0 end
                                R[k] = floor(sr * kr * a + R[k] * ia + 0.5)
                                G[k] = floor(t1 * kg * a + G[k] * ia + 0.5)
                                B[k] = floor(sb * kb * a + B[k] * ia + 0.5)
                                pix = pix + 1
                            end
                        end
                    end
                    w0, w1 = w0 + d0, w1 + d1
                end
            end
        end
        stats.pixels = stats.pixels + pix
    end

    local special = {}
    local compile = loadstring or load
    local function specialized(affine, linear, clampuv, swap, alpha_test, func, zwrite)
        local key = (affine and 1 or 0) + (linear and 2 or 0) + (clampuv and 4 or 0) + (swap and 8 or 0)
            + (alpha_test and 16 or 0) + (zwrite and 32 or 0) + func * 64
        local f = special[key]
        if f == nil then
            f = false
            if compile then
                local chunk = compile(gen_source(affine, linear, clampuv, swap, alpha_test, func, zwrite), "=gfx_snap_fast")
                if chunk then f = chunk(p, R, G, B, Z, W, EPS, stats) end
            end
            special[key] = f
        end
        return f
    end

    -- Треугольник записи с началом байтов ob в область.
    local function raster(rec, ob)
        local flags = rec[ob + 50]
        local texured = flags % 2 == 1
        local slot = rec[ob + 48] + rec[ob + 49] * 256
        local sx, sy, sw, sh = 0, 0, 1, 1
        if texured then
            if slot == 0xFFFF then return end
            sx, sy, sw, sh = slot_rect(slot)
            if sw == 0 or sh == 0 then return end
        end
        local alpha_test = floor(flags / 2) % 2 == 1
        local swap = floor(flags / 4) % 2 == 1
        local linear = floor(flags / 16) % 2 == 1
        local clampuv = floor(flags / 32) % 2 == 1
        local thr = rec[ob + 51] / 255
        local blend = rec[ob + 52]
        local m1 = rec[ob + 53]
        local func = m1 % 16
        local zwrite = floor(m1 / 16) % 2 == 1
        local nocolor = floor(m1 / 32) % 2 == 1
        -- вершины
        local ax, ay = s16(rec[ob] + rec[ob + 1] * 256), s16(rec[ob + 2] + rec[ob + 3] * 256)
        local bx, by = s16(rec[ob + 16] + rec[ob + 17] * 256), s16(rec[ob + 18] + rec[ob + 19] * 256)
        local cx, cy = s16(rec[ob + 32] + rec[ob + 33] * 256), s16(rec[ob + 34] + rec[ob + 35] * 256)
        local area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
        if math.abs(area) < 1e-6 then return end
        -- ограничивающий прямоугольник в пикселях области (центр пикселя (px + 0.5) * 16)
        local px0 = max(rx, ceil(min(ax, bx, cx) / 16 - 0.5))
        local px1 = min(rx + rw - 1, floor(max(ax, bx, cx) / 16 - 0.5))
        local py0 = max(ry, ceil(min(ay, by, cy) / 16 - 0.5))
        local py1 = min(ry + rh - 1, floor(max(ay, by, cy) / 16 - 0.5))
        if px0 > px1 or py0 > py1 then return end
        stats.tris = stats.tris + 1
        local ia = 1 / area
        -- w0 = (K0 + A0 X + B0 Y) / area, w1 = (K1 + A1 X + B1 Y) / area (X, Y в 1/16 пикселя)
        local A0, B0, K0 = (by - cy) * ia, (cx - bx) * ia, (bx * cy - by * cx) * ia
        local A1, B1, K1 = (cy - ay) * ia, (ax - cx) * ia, (cx * ay - cy * ax) * ia
        -- 1/w, UV, цвет, глубина вершин
        local iw0 = f32(rec[ob + 12], rec[ob + 13], rec[ob + 14], rec[ob + 15])
        local iw1 = f32(rec[ob + 28], rec[ob + 29], rec[ob + 30], rec[ob + 31])
        local iw2 = f32(rec[ob + 44], rec[ob + 45], rec[ob + 46], rec[ob + 47])
        local u0 = (rec[ob + 4] + rec[ob + 5] * 256) / 4096 - 8
        local v0 = (rec[ob + 6] + rec[ob + 7] * 256) / 4096 - 8
        local u1 = (rec[ob + 20] + rec[ob + 21] * 256) / 4096 - 8
        local v1 = (rec[ob + 22] + rec[ob + 23] * 256) / 4096 - 8
        local u2 = (rec[ob + 36] + rec[ob + 37] * 256) / 4096 - 8
        local v2 = (rec[ob + 38] + rec[ob + 39] * 256) / 4096 - 8
        local r0, g0, b0, a0 = rec[ob + 8] / 255, rec[ob + 9] / 255, rec[ob + 10] / 255, rec[ob + 11] / 255
        local r1, g1, b1, a1 = rec[ob + 24] / 255, rec[ob + 25] / 255, rec[ob + 26] / 255, rec[ob + 27] / 255
        local r2, g2, b2, a2 = rec[ob + 40] / 255, rec[ob + 41] / 255, rec[ob + 42] / 255, rec[ob + 43] / 255
        local z0 = (rec[ob + 56] + rec[ob + 57] * 256) / 65535
        local z1 = (rec[ob + 58] + rec[ob + 59] * 256) / 65535
        local z2 = (rec[ob + 60] + rec[ob + 61] * 256) / 65535
        if texured and blend == 1 and not nocolor and r0 == r1 and r1 == r2 and g0 == g1 and g1 == g2
                and b0 == b1 and b1 == b2 and a0 == a1 and a1 == a2 then
            local f = specialized(iw0 == iw1 and iw1 == iw2, linear, clampuv, swap, alpha_test, func, zwrite)
            if f then
                return f(rx, ry, rw, px0, px1, py0, py1, A0, B0, K0, A1, B1, K1, iw0, iw1, iw2,
                    u0, v0, u1, v1, u2, v2, z0, z1, z2, r0, g0, b0, a0, sx, sy, sw, sh, thr)
            end
            return raster_fast(px0, px1, py0, py1, A0, B0, K0, A1, B1, K1, iw0, iw1, iw2,
                u0, v0, u1, v1, u2, v2, z0, z1, z2, r0, g0, b0, a0, sx, sy, sw, sh,
                linear, clampuv, swap, alpha_test, thr, func, zwrite)
        end
        local slotw, sloth = sw, sh
        -- w2 = 1 - w0 - w1 = K2 + A2 X + B2 Y
        local A2, B2, K2 = -A0 - A1, -B0 - B1, 1 - K0 - K1
        for py = py0, py1 do
            local Y = (py + 0.5) * 16
            local row = (py - ry) * rw - rx + 1
            -- отрезок строки внутри треугольника: e_i(X) = c_i + A_i X >= 0, с запасом в пиксель;
            -- точная проверка весов - в цикле, как в шейдере
            local lo, hi = px0, px1
            local c0, c1, c2 = K0 + B0 * Y, K1 + B1 * Y, K2 + B2 * Y
            if A0 > 0 then lo = max(lo, ceil(-c0 / A0 / 16 - 1)) elseif A0 < 0 then hi = min(hi, floor(-c0 / A0 / 16)) elseif c0 < 0 then hi = lo - 1 end
            if A1 > 0 then lo = max(lo, ceil(-c1 / A1 / 16 - 1)) elseif A1 < 0 then hi = min(hi, floor(-c1 / A1 / 16)) elseif c1 < 0 then hi = lo - 1 end
            if A2 > 0 then lo = max(lo, ceil(-c2 / A2 / 16 - 1)) elseif A2 < 0 then hi = min(hi, floor(-c2 / A2 / 16)) elseif c2 < 0 then hi = lo - 1 end
            local X = (lo + 0.5) * 16
            local w0 = c0 + A0 * X
            local w1 = c1 + A1 * X
            local d0, d1 = A0 * 16, A1 * 16
            for px = lo, hi do
                local w2 = 1 - w0 - w1
                if w0 >= 0 and w1 >= 0 and w2 >= 0 then
                    local k = row + px
                    local z = 0
                    local pass = true
                    if func ~= 0 then
                        z = z0 * w0 + z1 * w1 + z2 * w2
                        pass = depth_pass(func, z, Z[k])
                    end
                    if pass then
                        local q0, q1, q2 = w0 * iw0, w1 * iw1, w2 * iw2
                        local qs = q0 + q1 + q2
                        if qs ~= 0 then
                            q0, q1, q2 = q0 / qs, q1 / qs, q2 / qs
                        else
                            q0, q1, q2 = w0, w1, w2
                        end
                        local cr = r0 * q0 + r1 * q1 + r2 * q2
                        local cg = g0 * q0 + g1 * q1 + g2 * q2
                        local cb = b0 * q0 + b1 * q1 + b2 * q2
                        local ca = a0 * q0 + a1 * q1 + a2 * q2
                        if texured then
                            local tu = u0 * q0 + u1 * q1 + u2 * q2
                            local tv = v0 * q0 + v1 * q1 + v2 * q2
                            local t0, t1, t2, t3
                            if not linear then
                                local ix, iy
                                if clampuv then
                                    ix = min(max(floor(tu * slotw), 0), slotw - 1)
                                    iy = min(max(floor(tv * sloth), 0), sloth - 1)
                                else
                                    ix = min(floor((tu - floor(tu)) * slotw), slotw - 1)
                                    iy = min(floor((tv - floor(tv)) * sloth), sloth - 1)
                                end
                                local o = ((sy + iy) * W + sx + ix) * 4
                                t0, t1, t2, t3 = p[o], p[o + 1], p[o + 2], p[o + 3]
                            else
                                local fx, fy = tu * slotw - 0.5, tv * sloth - 0.5
                                local x0, y0 = floor(fx), floor(fy)
                                local fu, fv = fx - x0, fy - y0
                                local x1, y1 = x0 + 1, y0 + 1
                                if clampuv then
                                    x0 = min(max(x0, 0), slotw - 1); x1 = min(max(x1, 0), slotw - 1)
                                    y0 = min(max(y0, 0), sloth - 1); y1 = min(max(y1, 0), sloth - 1)
                                else
                                    x0 = x0 % slotw; x1 = x1 % slotw; y0 = y0 % sloth; y1 = y1 % sloth
                                end
                                local oa = ((sy + y0) * W + sx + x0) * 4
                                local ob2 = ((sy + y0) * W + sx + x1) * 4
                                local oc = ((sy + y1) * W + sx + x0) * 4
                                local od = ((sy + y1) * W + sx + x1) * 4
                                local fu1, fv1 = 1 - fu, 1 - fv
                                t0 = (p[oa] * fu1 + p[ob2] * fu) * fv1 + (p[oc] * fu1 + p[od] * fu) * fv
                                t1 = (p[oa + 1] * fu1 + p[ob2 + 1] * fu) * fv1 + (p[oc + 1] * fu1 + p[od + 1] * fu) * fv
                                t2 = (p[oa + 2] * fu1 + p[ob2 + 2] * fu) * fv1 + (p[oc + 2] * fu1 + p[od + 2] * fu) * fv
                                t3 = (p[oa + 3] * fu1 + p[ob2 + 3] * fu) * fv1 + (p[oc + 3] * fu1 + p[od + 3] * fu) * fv
                            end
                            if swap then
                                cr, cg, cb = cr * t0 / 255, cg * t1 / 255, cb * t2 / 255
                            else
                                cr, cg, cb = cr * t2 / 255, cg * t1 / 255, cb * t0 / 255
                            end
                            ca = ca * t3 / 255
                        end
                        if not (alpha_test and ca < thr) then
                            if func ~= 0 and zwrite then Z[k] = z end
                            if not nocolor then
                                local dr, dg, db = R[k] / 255, G[k] / 255, B[k] / 255
                                if blend == 0 then
                                    dr, dg, db = cr, cg, cb
                                elseif blend == 1 then
                                    local ia2 = 1 - ca
                                    dr, dg, db = cr * ca + dr * ia2, cg * ca + dg * ia2, cb * ca + db * ia2
                                elseif blend == 2 then
                                    dr, dg, db = min(dr + cr * ca, 1), min(dg + cg * ca, 1), min(db + cb * ca, 1)
                                elseif blend == 4 then
                                    dr, dg, db = cr * (1 - dr) + dr * (1 - cr), cg * (1 - dg) + dg * (1 - cg), cb * (1 - db) + db * (1 - cb)
                                elseif blend == 5 then
                                    dr, dg, db = min(2 * cr * dr, 1), min(2 * cg * dg, 1), min(2 * cb * db, 1)
                                elseif blend == 6 then
                                    dr, dg, db = dr * (1 - cr), dg * (1 - cg), db * (1 - cb)
                                elseif blend == 7 then
                                    dr, dg, db = min(cr * cr + dr, 1), min(cg * cg + dg, 1), min(cb * cb + db, 1)
                                else
                                    dr, dg, db = dr * cr, dg * cg, db * cb
                                end
                                R[k] = floor(min(max(dr, 0), 1) * 255 + 0.5)
                                G[k] = floor(min(max(dg, 0), 1) * 255 + 0.5)
                                B[k] = floor(min(max(db, 0), 1) * 255 + 0.5)
                                stats.pixels = stats.pixels + 1
                            end
                        end
                    end
                end
                w0, w1 = w0 + d0, w1 + d1
            end
        end
    end

    -- Снимок: прямоугольник области -> слот текстуры (строки перевёрнуты, байты B, G, R, 255).
    -- slot_map: id текстуры -> слот (задание пишет в промежуточный слот), иначе slot_of.
    local slot_map = nil
    local function snapshot(rec, ob, x, y, w, h)
        local id = rec[ob] + rec[ob + 1] * 256 + rec[ob + 2] * 65536
        local dx, dy = rec[ob + 12] + rec[ob + 13] * 256, rec[ob + 14] + rec[ob + 15] * 256
        local slot = slot_map and slot_map[id] or slot_of(id)
        if not slot then return end
        local sx, sy, sw, sh = slot_rect(slot)
        stats.snapshots = stats.snapshots + 1
        for r = 0, h - 1 do
            local ty = dy + r
            local srow = y + h - 1 - r
            if ty >= 0 and ty < sh and srow >= ry and srow < ry + rh then
                for c = 0, w - 1 do
                    local tx, scol = dx + c, x + c
                    if tx >= 0 and tx < sw and scol >= rx and scol < rx + rw then
                        local k = (srow - ry) * rw + (scol - rx) + 1
                        local o = ((sy + ty) * W + sx + tx) * 4
                        p[o], p[o + 1], p[o + 2], p[o + 3] = B[k], G[k], R[k], 255
                    end
                end
            end
        end
    end

    local function rect_of(rec, ob)
        return rec[ob + 4] + rec[ob + 5] * 256, rec[ob + 6] + rec[ob + 7] * 256, rec[ob + 8] + rec[ob + 9] * 256, rec[ob + 10] + rec[ob + 11] * 256
    end

    -- Обработка записей first..upto буфера rec (base — номер тексела записи 0) в состоянии st:
    -- st.have — область задана, st.i — следующая запись. Возвращает true, когда дошли до upto;
    -- deadline (os.clock) — прерваться после записи, когда время вышло.
    local function process(rec, base, upto, st, clear, clear_depth, full, deadline)
        local clock = os.clock
        while st.i <= upto do
            local i = st.i
            local ob = (base + i * tri_texels) * 4
            local flags = rec[ob + 50]
            if flags >= FLAG_CLEAR_DEPTH then
                if st.have then
                    local cz = (rec[ob + 56] + rec[ob + 57] * 256) / 65535
                    for k = 1, rw * rh do Z[k] = cz end
                end
            elseif floor(flags / FLAG_SNAPSHOT) % 2 == 1 then
                local x, y, w, h = rect_of(rec, ob)
                if not st.have or (not full and (x ~= rx or y ~= ry or w ~= rw or h ~= rh)) then
                    -- новая область: заново с начала кадра
                    init_region(x, y, w, h, clear, clear_depth)
                    st.have = true
                    for j = 0, i - 1 do
                        local oj = (base + j * tri_texels) * 4
                        local fj = rec[oj + 50]
                        if fj >= FLAG_CLEAR_DEPTH then
                            local cz = (rec[oj + 56] + rec[oj + 57] * 256) / 65535
                            for k = 1, rw * rh do Z[k] = cz end
                        elseif floor(fj / FLAG_SNAPSHOT) % 2 == 0 then
                            raster(rec, oj)
                        end
                    end
                end
                snapshot(rec, ob, x, y, w, h)
            elseif st.have then
                raster(rec, ob)
            end
            st.i = i + 1
            if deadline and clock() > deadline then break end
        end
        return st.i > upto
    end

    -- Задание (бюджет времени): копия записей кадра, снимки — в промежуточные слоты; видимые слоты
    -- обновляются целиком, когда задание дошло до последнего снимка.
    local job = nil
    local job_buf, job_cap = nil, 0
    self.staging_of = nil   -- function(id, w, h) -> промежуточный слот (задаёт gfx_tris)
    self.budget = nil       -- секунд на кадр; nil — всё в этом же кадре

    local function start_job(count, last, clear, clear_depth)
        local n = last + 1
        local size = n * tri_texels * 4
        if size > job_cap then
            job_cap = size * 2
            job_buf = bytes(job_cap)
        end
        local buf = job_buf
        local src = tri_base * 4
        for k = 0, size - 1 do buf[k] = p[src + k] end
        -- целевые текстуры снимков -> промежуточные слоты; треугольники, читающие цель, читают их
        local map, remap = {}, {}
        for i = 0, last do
            local ob = i * tri_texels * 4
            local fl = buf[ob + 50]
            if fl < FLAG_CLEAR_DEPTH and floor(fl / FLAG_SNAPSHOT) % 2 == 1 then
                local id = buf[ob] + buf[ob + 1] * 256 + buf[ob + 2] * 65536
                if map[id] == nil then
                    local slot = slot_of(id)
                    local staging = false
                    if slot and self.staging_of then
                        local _, _, sw, sh = slot_rect(slot)
                        staging = self.staging_of(id, sw, sh) or false
                        if staging then
                            -- промежуточный слот начинается с текущего содержимого цели
                            local ax, ay = slot_rect(slot)
                            local bx, by = slot_rect(staging)
                            for r = 0, sh - 1 do
                                local oa, ob2 = ((ay + r) * W + ax) * 4, ((by + r) * W + bx) * 4
                                for c = 0, sw * 4 - 1 do p[ob2 + c] = p[oa + c] end
                            end
                            remap[slot] = staging
                        end
                    end
                    map[id] = staging
                end
            end
        end
        for i = 0, last do
            local ob = i * tri_texels * 4
            local fl = buf[ob + 50]
            if fl < FLAG_CLEAR_DEPTH and floor(fl / FLAG_SNAPSHOT) % 2 == 0 and fl % 2 == 1 then
                local s2 = remap[buf[ob + 48] + buf[ob + 49] * 256]
                if s2 then buf[ob + 48], buf[ob + 49] = s2 % 256, floor(s2 / 256) end
            end
        end
        -- область — прямоугольник первого снимка: треугольники до него рисуются по бюджету, а не разом
        local st = { i = 0, have = false }
        for i = 0, last do
            local ob = i * tri_texels * 4
            local fl = buf[ob + 50]
            if fl < FLAG_CLEAR_DEPTH and floor(fl / FLAG_SNAPSHOT) % 2 == 1 then
                local x, y, w, h = rect_of(buf, ob)
                init_region(x, y, w, h, clear, clear_depth)
                st.have = true
                break
            end
        end
        job = { buf = buf, last = last, st = st, clear = clear,
            clear_depth = clear_depth, map = map, frames = 0 }
    end

    -- Текстуры, в которые уже положен готовый снимок. Пока его нет, первая цепочка считается сразу
    -- (в том же кадре): иначе финальный квад показал бы начальное содержимое текстуры (у GuiMainMenu —
    -- остатки общего буфера загрузки, резкая панорама), которое в WebGL никогда не видно.
    local committed = {}
    function self:invalidate(id) committed[id] = nil end

    local function targets_ready(last)
        for i = 0, last do
            local ob = (tri_base + i * tri_texels) * 4
            local fl = p[ob + 50]
            if fl < FLAG_CLEAR_DEPTH and floor(fl / FLAG_SNAPSHOT) % 2 == 1 then
                if not committed[p[ob] + p[ob + 1] * 256 + p[ob + 2] * 65536] then return false end
            end
        end
        return true
    end

    local function mark_committed(last)
        for i = 0, last do
            local ob = (tri_base + i * tri_texels) * 4
            local fl = p[ob + 50]
            if fl < FLAG_CLEAR_DEPTH and floor(fl / FLAG_SNAPSHOT) % 2 == 1 then
                committed[p[ob] + p[ob + 1] * 256 + p[ob + 2] * 65536] = true
            end
        end
    end

    local function commit_job()
        for id, staging in pairs(job.map) do
            committed[id] = true
            local slot = staging and slot_of(id)
            if slot then
                local ax, ay, sw, sh = slot_rect(slot)
                local bx, by = slot_rect(staging)
                for r = 0, sh - 1 do
                    local oa, ob2 = ((ay + r) * W + ax) * 4, ((by + r) * W + bx) * 4
                    for c = 0, sw * 4 - 1 do p[oa + c] = p[ob2 + c] end
                end
            end
        end
        stats.job_frames = job.frames
        job = nil
    end

    -- Кадр: count записей; last — номер последней записи SNAPSHOT (или -1). Область — прямоугольник
    -- первого снимка (full = {x, y, w, h} — вся заданная область и все записи: для проверки).
    -- С бюджетом (self.budget) снимки кадра считаются заданием на несколько кадров; пока задание
    -- идёт, снимки новых кадров пропускаются (видна последняя завершённая цепочка).
    function self:run(count, last, clear, clear_depth, full)
        stats.pixels, stats.tris, stats.snapshots = 0, 0, 0
        if full then
            slot_map = nil
            init_region(full[1], full[2], full[3], full[4], clear, clear_depth)
            process(p, tri_base, count - 1, { i = 0, have = true }, clear, clear_depth, full, nil)
            return true
        end
        if not self.budget then
            slot_map = nil
            if last >= 0 then process(p, tri_base, last, { i = 0, have = false }, clear, clear_depth, nil, nil) end
            return true
        end
        if not job then
            if last < 0 then return true end
            if not targets_ready(last) then
                slot_map = nil
                process(p, tri_base, last, { i = 0, have = false }, clear, clear_depth, nil, nil)
                mark_committed(last)
                return true
            end
            start_job(count, last, clear, clear_depth)
        end
        job.frames = job.frames + 1
        slot_map = job.map
        local done = process(job.buf, 0, job.last, job.st, job.clear, job.clear_depth, nil, os.clock() + self.budget)
        slot_map = nil
        if done then commit_job() end
        return done
    end
    function self:busy() return job ~= nil end

    -- Для проверки: байты области (R, G, B по строкам) и её размер.
    function self:region() return R, G, B, rx, ry, rw, rh end
    return self
end

M.f32 = f32
return M
