-- Ручные ядра ref_soft под LuaJIT (12.10, hl_gpu): спаны поверхностей D_DrawSpans16 / D_AddSpans16 целиком
-- (список espan_t, перспективная коррекция через 8 пикселей, текстура 16 бит) — вместо кода C -> wasm -> Lua
-- (Spider), где каждое чтение/запись памяти идёт через обёртки рантайма. Ядро работает прямо с табличной памятью
-- модуля Spider (memory[1].__w: слова по 4 байта, знаковая форма bit.tobit), как ядра smollm (llm_kernels.lua).
--
-- Паритет бит в бит с C (upstream r_scan.c, без SW_TEXFILT): каждая операция float — double-операция над двумя
-- binary32 и округление до binary32 (rnd, как round_f32 рантайма Spider --f32 number); (int)x — усечение к нулю
-- с насыщением (i32.trunc_sat_f32_s); целые — знаковые 32 бита (tobit). Вызов: vc.hl_spans(mode, pspan, params)
-- из patches/xash3d-fwgs.patch (r_scan.c, XASH_WASI); params — структура VC_SpanParams (src/... r_scan.c).
-- Проверка — хэши кадров вне движка (run_luajit.lua) совпадают со сборкой без ядра.
local bit = bit or require("bit")
local band, bor, rshift, lshift, arshift, tobit = bit.band, bit.bor, bit.rshift, bit.lshift, bit.arshift, bit.tobit
local floor, ceil, abs, huge = math.floor, math.ceil, math.abs, math.huge

local M = {}

local POW = {}
for e = 0, 255 do POW[e] = 2 ^ (e - 150) end
local SUB = 2 ^ -149
local function f32(b)
    local e = band(rshift(b, 23), 255)
    local m = band(b, 0x7FFFFF)
    local v
    if e == 0 then v = m * SUB
    elseif e == 255 then if m == 0 then v = huge else v = 0 / 0 end
    else v = (m + 8388608) * POW[e] end
    if b < 0 then return -v end
    return v
end

local SPLIT, MIN_NORMAL, OVERFLOW = 2 ^ 29 + 1, 2 ^ -126, 2 ^ 128 - 2 ^ 103
local SUB_MAGIC = 1.5 * 2 ^ -97
local function round_special(x)
    if x ~= x then return x end
    local a = abs(x)
    if a >= OVERFLOW then if x > 0 then return huge end return -huge end
    local r = (a + SUB_MAGIC) - SUB_MAGIC
    if x < 0 or 1 / x < 0 then return -r end
    return r
end
local function rnd(x)
    local a = abs(x)
    if a >= MIN_NORMAL and a < OVERFLOW then
        local c = x * SPLIT
        return c - (c - x)
    end
    return round_special(x)
end
M.rnd = rnd

-- (int)x для float: усечение к нулю, насыщение, NaN -> 0
local function toint(x)
    if x >= 0 then
        if x >= 2147483647 then return 2147483647 end
        return floor(x)
    elseif x < 0 then
        if x <= -2147483648 then return -2147483648 end
        return ceil(x)
    end
    return 0
end

-- деление целых C (к нулю)
local function idiv(a, b)
    local q = a / b
    if q >= 0 then return floor(q) end
    return ceil(q)
end

local function rd32(w, a) return w[rshift(a, 2) + 1] end

-- mode 0: D_DrawSpans16 (копия), mode 1: D_AddSpans16 (z-тест, BLEND_ADD через vid.addmap, без записи z),
-- mode 2: D_DrawZSpans (только z-буфер)
function M.spans(memory, mode, pspan, prm)
    local w = memory.__w
    local pbase = rd32(w, prm)
    local viewbuf = rd32(w, prm + 4)
    local screenw = rd32(w, prm + 8)
    local cw = rd32(w, prm + 12)
    local sadjust = rd32(w, prm + 16)
    local tadjust = rd32(w, prm + 20)
    local bbs = rd32(w, prm + 24)
    local bbt = rd32(w, prm + 28)
    local sdu = f32(rd32(w, prm + 32))
    local tdu = f32(rd32(w, prm + 36))
    local zdu = f32(rd32(w, prm + 40))
    local sdv = f32(rd32(w, prm + 44))
    local tdv = f32(rd32(w, prm + 48))
    local zdv = f32(rd32(w, prm + 52))
    local so = f32(rd32(w, prm + 56))
    local to = f32(rd32(w, prm + 60))
    local zo = f32(rd32(w, prm + 64))
    local pzbuf = rd32(w, prm + 68)
    local zwidth = rd32(w, prm + 72)
    local addmap = rd32(w, prm + 76)

    if mode == 2 then -- D_DrawZSpans: 1/z в z-буфер (short), парами словом
        local izistep = toint(rnd(rnd(zdu * 32768) * 65536))
        repeat
            local u, v = rd32(w, pspan), rd32(w, pspan + 4)
            local count = rd32(w, pspan + 8)
            local pd = pzbuf + 2 * (zwidth * v + u)
            local zi = rnd(rnd(zo + rnd(v * zdv)) + rnd(u * zdu))
            local izi = toint(rnd(rnd(zi * 32768) * 65536))
            if band(pd, 2) ~= 0 then
                local k = rshift(pd, 2) + 1
                w[k] = bor(band(w[k], 0xFFFF), lshift(arshift(izi, 16), 16))
                pd = pd + 2
                izi = tobit(izi + izistep)
                count = count - 1
            end
            local dc = arshift(count, 1)
            while dc > 0 do
                local lo = arshift(izi, 16)
                izi = tobit(izi + izistep)
                w[rshift(pd, 2) + 1] = bor(lo, band(izi, -65536))
                izi = tobit(izi + izistep)
                pd = pd + 4
                dc = dc - 1
            end
            if band(count, 1) ~= 0 then
                local k = rshift(pd, 2) + 1
                w[k] = bor(band(w[k], -65536), band(arshift(izi, 16), 0xFFFF))
            end
            pspan = rd32(w, pspan + 12)
        until pspan == 0
        return 0
    end

    local sdu8, tdu8, zdu8 = rnd(sdu * 8), rnd(tdu * 8), rnd(zdu * 8)
    local izistep = 0
    if mode == 1 then izistep = toint(rnd(rnd(zdu * 32768) * 65536)) end

    repeat
        local u, v = rd32(w, pspan), rd32(w, pspan + 4)
        local count = rd32(w, pspan + 8)
        local pdest = viewbuf + 2 * (screenw * v + u)
        local pz, izi = 0, 0
        local du, dv = u, v -- (float)int: точны для координат экрана
        local sdivz = rnd(rnd(so + rnd(dv * sdv)) + rnd(du * sdu))
        local tdivz = rnd(rnd(to + rnd(dv * tdv)) + rnd(du * tdu))
        local zi = rnd(rnd(zo + rnd(dv * zdv)) + rnd(du * zdu))
        if mode == 1 then
            pz = pzbuf + 2 * (zwidth * v + u)
            izi = toint(rnd(rnd(zi * 32768) * 65536))
        end
        local z = rnd(65536 / zi)
        local s = tobit(toint(rnd(sdivz * z)) + sadjust)
        if s > bbs then s = bbs elseif s < 0 then s = 0 end
        local t = tobit(toint(rnd(tdivz * z)) + tadjust)
        if t > bbt then t = bbt elseif t < 0 then t = 0 end
        local sstep, tstep = 0, 0
        repeat
            local spancount = count
            if count >= 8 then spancount = 8 end
            count = count - spancount
            local snext, tnext
            if count ~= 0 then
                sdivz = rnd(sdivz + sdu8)
                tdivz = rnd(tdivz + tdu8)
                zi = rnd(zi + zdu8)
                z = rnd(65536 / zi)
                snext = tobit(toint(rnd(sdivz * z)) + sadjust)
                if snext > bbs then snext = bbs elseif snext < 8 then snext = 8 end
                tnext = tobit(toint(rnd(tdivz * z)) + tadjust)
                if tnext > bbt then tnext = bbt elseif tnext < 8 then tnext = 8 end
                sstep = arshift(tobit(snext - s), 3)
                tstep = arshift(tobit(tnext - t), 3)
            else
                local m1 = spancount - 1
                sdivz = rnd(sdivz + rnd(sdu * m1))
                tdivz = rnd(tdivz + rnd(tdu * m1))
                zi = rnd(zi + rnd(zdu * m1))
                z = rnd(65536 / zi)
                snext = tobit(toint(rnd(sdivz * z)) + sadjust)
                if snext > bbs then snext = bbs elseif snext < 8 then snext = 8 end
                tnext = tobit(toint(rnd(tdivz * z)) + tadjust)
                if tnext > bbt then tnext = bbt elseif tnext < 8 then tnext = 8 end
                if spancount > 1 then
                    sstep = tobit(idiv(tobit(snext - s), m1))
                    tstep = tobit(idiv(tobit(tnext - t), m1))
                end
            end
            if mode == 0 then
                local n = spancount
                if n < 1 then n = 1 end -- do { } while( --spancount > 0 )
                -- первый пиксель на нечётном месте слова
                if band(pdest, 2) ~= 0 then
                    local a = pbase + 2 * (arshift(s, 16) + arshift(t, 16) * cw)
                    local px = band(rshift(w[rshift(a, 2) + 1], band(a, 2) * 8), 0xFFFF)
                    local k = rshift(pdest, 2) + 1
                    w[k] = bor(band(w[k], 0xFFFF), lshift(px, 16))
                    pdest = pdest + 2
                    s = tobit(s + sstep); t = tobit(t + tstep)
                    n = n - 1
                end
                while n >= 2 do
                    local a = pbase + 2 * (arshift(s, 16) + arshift(t, 16) * cw)
                    local pa = band(rshift(w[rshift(a, 2) + 1], band(a, 2) * 8), 0xFFFF)
                    s = tobit(s + sstep); t = tobit(t + tstep)
                    a = pbase + 2 * (arshift(s, 16) + arshift(t, 16) * cw)
                    local pb = rshift(w[rshift(a, 2) + 1], band(a, 2) * 8)
                    s = tobit(s + sstep); t = tobit(t + tstep)
                    w[rshift(pdest, 2) + 1] = bor(pa, lshift(pb, 16))
                    pdest = pdest + 4
                    n = n - 2
                end
                if n > 0 then
                    local a = pbase + 2 * (arshift(s, 16) + arshift(t, 16) * cw)
                    local px = band(rshift(w[rshift(a, 2) + 1], band(a, 2) * 8), 0xFFFF)
                    local k = rshift(pdest, 2) + 1
                    w[k] = bor(band(w[k], -65536), px)
                    pdest = pdest + 2
                    s = tobit(s + sstep); t = tobit(t + tstep)
                end
            else
                local n = spancount
                repeat
                    -- *pz (short) <= izi >> 16
                    local zw = rshift(w[rshift(pz, 2) + 1], band(pz, 2) * 8)
                    local zv = arshift(lshift(zw, 16), 16)
                    if zv <= arshift(izi, 16) then
                        local a = pbase + 2 * (arshift(s, 16) + arshift(t, 16) * cw)
                        local src = band(rshift(w[rshift(a, 2) + 1], band(a, 2) * 8), 0xFFFF)
                        if src ~= 0x0349 then
                            local k = rshift(pdest, 2) + 1
                            local sh = band(pdest, 2) * 8
                            local word = w[k]
                            local scr = band(rshift(word, sh), 0xFFFF)
                            local ai = addmap + bor(band(src, 0xFF00), rshift(scr, 8))
                            local am = band(rshift(w[rshift(ai, 2) + 1], band(ai, 3) * 8), 0xFF)
                            local px = band(bor(lshift(am, 8), band(scr, 0xFF), band(src, 0xFF)), 0xFFFF)
                            if sh == 0 then w[k] = bor(band(word, -65536), px)
                            else w[k] = bor(band(word, 0xFFFF), lshift(px, 16)) end
                        end
                    end
                    pdest = pdest + 2
                    pz = pz + 2
                    izi = tobit(izi + izistep)
                    s = tobit(s + sstep); t = tobit(t + tstep)
                    n = n - 1
                until n <= 0
            end
        until count <= 0
        pspan = rd32(w, pspan + 12)
    until pspan == 0
    return 0
end

return M
