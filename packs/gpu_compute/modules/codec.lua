-- gpu_compute:codec — упаковка значений для страниц (canvas RGBA8: все 4 байта) и выхода проходов (RGB8: 3 байта на
-- тексель, альфа съедается смешиванием SRC_ALPHA движка). Общие соглашения клиентов:
--   слово параметров u32 = тексель r | g<<8 | b<<16 | a<<24 (gpu_worldgen, gc.params);
--   float32 выхода = 2 текселя: RGB первого — биты 0..23, R второго — биты 24..31 (smollm_gpu);
--   int8 x3 на тексель (веса Q8 smollm_gpu), u24 = RGB одного текселя (эхо serial, индексы).
local M = {}
local band, rshift, tobit = bit.band, bit.rshift, bit.tobit

-- байты u32 (число 0..2^32-1 или int32) -> r, g, b, a
function M.u32_bytes(v)
    v = tobit(v)
    return band(v, 255), band(rshift(v, 8), 255), band(rshift(v, 16), 255), rshift(v, 24)
end

-- float32 -> биты (u32, 0..2^32-1); округление к ближайшему, как (float) в C; nan -> 0x7FC00000
local floor, frexp, huge = math.floor, math.frexp, math.huge
function M.f32_bits(x)
    if x ~= x then return 0x7FC00000 end
    local s = 0
    if x < 0 or (x == 0 and 1 / x < 0) then s = 0x80000000; x = -x end
    if x == 0 then return s end
    if x == huge then return s + 0x7F800000 end
    local m, e = frexp(x)            -- x = m * 2^e, m в [0.5, 1)
    local E = e + 126
    if E <= 0 then                   -- денормализованное
        local q = floor(x * 2 ^ 149 + 0.5)
        if q % 1 ~= 0 then q = floor(q) end
        return s + q
    end
    local f = m * 2 ^ 24             -- 24 бита мантиссы с ведущей единицей
    local fi = floor(f)
    local r = f - fi
    if r > 0.5 or (r == 0.5 and fi % 2 == 1) then fi = fi + 1 end
    if fi >= 2 ^ 24 then fi = fi / 2; E = E + 1 end
    if E >= 255 then return s + 0x7F800000 end
    return s + E * 2 ^ 23 + (fi - 2 ^ 23)
end

function M.bits_f32(b)
    local s = b >= 0x80000000
    if s then b = b - 0x80000000 end
    local e = floor(b / 2 ^ 23)
    local m = b % 2 ^ 23
    local v
    if e == 0 then v = m * 2 ^ -149
    elseif e == 255 then v = m == 0 and huge or 0 / 0
    else v = (2 ^ 23 + m) * 2 ^ (e - 150) end
    return s and -v or v
end

-- выход прохода: Bytearray RGBA (get_data), тексель t ширины w -> u24 / float32 по 2 текселям
local function base(ba)
    if type(ba) == "cdata" and ba.bytes ~= nil then return ba.bytes, 0 end
    return ba, 1
end
M.raw = base
function M.u24_at(ba, t)
    local p, o = base(ba)
    local b = 4 * t + o
    return p[b] + p[b + 1] * 256 + p[b + 2] * 65536
end
function M.rgb_to_f32(ba, t)        -- float из текселей t, t+1
    local p, o = base(ba)
    local b = 4 * t + o
    return M.bits_f32(p[b] + p[b + 1] * 256 + p[b + 2] * 65536 + p[b + 4] * 16777216)
end
-- float -> 2 текселя (r,g,b), (r,0,0) для записи во входную страницу в той же раскладке, что пишет шейдер
function M.f32_to_rgb(x)
    local v = M.f32_bits(x)
    return v % 256, floor(v / 256) % 256, floor(v / 65536) % 256, floor(v / 16777216)
end
-- int8 x3 на тексель: значения -128..127 -> байты
function M.i8x3(a, b, c) return a % 256, (b or 0) % 256, (c or 0) % 256 end
function M.u16(v) return v % 256, floor(v / 256) % 256 end

return M
