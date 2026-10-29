-- gpu_worldgen:noise — параметры генератора и CPU-референс того же 3D-шума, что в shaders/ui.glslf.
-- Формулы повторяют шейдер построчно (хэш узла, градиенты, fade, lerp, fbm, плотность, пещеры, руда, правила
-- слоёв), поэтому GPU и CPU дают одни и те же блоки, кроме вокселей с |плотность| ~ 1e-6 (float32 на GPU против
-- double в Lua) — расхождение меряется modules/bench.lua (parity).
-- Хэш: умножения только на константы < 2^15, сумма < 2^47 — в double точно, bit.tobit сворачивает mod 2^32
-- так же, как переполнение uint на GPU.
local M = {}

local floor = math.floor
local bit = bit
local tobit, bxor, rshift, band = bit.tobit, bit.bxor, bit.rshift, bit.band

-- Параметры по умолчанию. Дробные — в фиксированной точке (/1024 или /65536), чтобы GPU и Lua видели одно и то же
-- двоичное значение.
M.DEFAULT = {
    S = 96 * 1024,       -- масштаб по x/z (блоков на период нулевой октавы)
    SY = 48 * 1024,      -- масштаб по y: меньше S — нависания, арки, летающие острова
    AMP = 3 * 1024,      -- амплитуда fbm (3.0)
    BASE = 66,           -- средняя высота поверхности
    HSCALE = 40 * 1024,  -- плотность падает на 1 за HSCALE блоков вверх (ниже BASE — за HSCALE/2: без полостей с водой в глубине)
    SEA = 62,            -- уровень моря
    OCT = 5,             -- октав
    CAVE_T = 786,        -- пещеры-«спагетти»: n1^2 + n2^2 < 0.012 (/65536)
    CS = 48 * 1024,      -- масштаб пещер по x/z
    CSY = 32 * 1024,     -- масштаб пещер по y
    ORE_T = 41943,       -- уголь: шум > 0.64 (/65536)
    ORE_S = 6 * 1024,    -- масштаб рудного шума
}

-- коды блоков (как в шейдере) -> имена
M.CODES = { [0] = "core:air", "base:stone", "base:dirt", "base:grass_block", "base:sand", "base:water",
    "base:bazalt", "base:coal_ore" }

-- сид мира -> 20 бит (GPU получает его словом 4)
function M.seed20(seed)
    seed = tonumber(seed) or 0
    if seed < 0 then seed = -seed end
    return floor(seed % 1048573)
end

-- рабочие параметры (числа с плавающей точкой — те же значения, что получит шейдер)
function M.make(seed, over)
    local p = {}
    for k, v in pairs(M.DEFAULT) do p[k] = v end
    if over then for k, v in pairs(over) do p[k] = v end end
    p.seed = M.seed20(seed)
    p.seedmix = tobit(p.seed * 1013)
    p.fS, p.fSY, p.fAMP, p.fHSCALE = p.S / 1024, p.SY / 1024, p.AMP / 1024, p.HSCALE / 1024
    p.fCS, p.fCSY, p.fORE_S = p.CS / 1024, p.CSY / 1024, p.ORE_S / 1024
    p.fCAVE_T, p.fORE_T = p.CAVE_T / 65536, p.ORE_T / 65536
    return p
end

local P -- текущие параметры (M.use)
local seedmix = 0

function M.use(p)
    P = p
    seedmix = p.seedmix
end

local function hash(x, y, z)
    local h = tobit(x * 1619 + y * 31337 + z * 6971 + seedmix)
    h = tobit(bxor(h, rshift(h, 15)) * 11291)
    h = tobit(bxor(h, rshift(h, 12)) * 10619)
    h = bxor(h, rshift(h, 15))
    return band(h, 15)
end
M.hash = hash

local function grad(h, x, y, z)
    local u = h < 8 and x or y
    local v
    if h < 4 then v = y elseif h == 12 or h == 14 then v = x else v = z end
    if band(h, 1) ~= 0 then u = -u end
    if band(h, 2) ~= 0 then v = -v end
    return u + v
end

local function fade(t) return t * t * t * (t * (t * 6 - 15) + 10) end
local function lerp(a, b, t) return a + t * (b - a) end

local function noise(px, py, pz)
    local fx, fy, fz = floor(px), floor(py), floor(pz)
    local X, Y, Z = fx, fy, fz
    local x, y, z = px - fx, py - fy, pz - fz
    local u, v, w = fade(x), fade(y), fade(z)
    local n000 = grad(hash(X, Y, Z), x, y, z)
    local n100 = grad(hash(X + 1, Y, Z), x - 1, y, z)
    local n010 = grad(hash(X, Y + 1, Z), x, y - 1, z)
    local n110 = grad(hash(X + 1, Y + 1, Z), x - 1, y - 1, z)
    local n001 = grad(hash(X, Y, Z + 1), x, y, z - 1)
    local n101 = grad(hash(X + 1, Y, Z + 1), x - 1, y, z - 1)
    local n011 = grad(hash(X, Y + 1, Z + 1), x, y - 1, z - 1)
    local n111 = grad(hash(X + 1, Y + 1, Z + 1), x - 1, y - 1, z - 1)
    local x00 = lerp(n000, n100, u)
    local x10 = lerp(n010, n110, u)
    local x01 = lerp(n001, n101, u)
    local x11 = lerp(n011, n111, u)
    return lerp(lerp(x00, x10, v), lerp(x01, x11, v), w)
end
M.noise = noise

local function fbm(px, py, pz, oct)
    local sum, amp, norm = 0, 1, 0
    for o = 0, oct - 1 do
        sum = sum + noise(px + o * 31.25, py, pz + o * 17.125) * amp
        norm = norm + amp
        amp = amp * 0.5
        px, py, pz = px * 2, py * 2, pz * 2
    end
    return sum / norm
end

local function density(wx, wy, wz)
    if wy > 255 then return -1 end
    return fbm(wx / P.fS, wy / P.fSY, wz / P.fS, P.OCT) * P.fAMP + (P.BASE - wy) / (wy < P.BASE and P.fHSCALE * 0.5 or P.fHSCALE)
end
M.density = density

local function cave(wx, wy, wz)
    local cx, cy, cz = wx / P.fCS, wy / P.fCSY, wz / P.fCS
    local n1 = noise(cx + 100.5, cy, cz)
    local n2 = noise(cx, cy + 50.25, cz - 30.75)
    return n1 * n1 + n2 * n2 < P.fCAVE_T
end

local function ore(wx, wy, wz)
    local s = P.fORE_S
    return noise(wx / s - 7.5, wy / s + 3.25, wz / s + 11.75) > P.fORE_T
end

local function code(wx, y, wz, s0, s1, s2, s3)
    if y > 255 then return 0 end
    if y == 0 then return 6 end
    local sea = P.SEA
    if s0 then
        if y > 4 and cave(wx, y, wz) then return 0 end
        if not s1 then return y <= sea + 1 and 4 or 3 end
        if not s2 or not s3 then return y <= sea + 1 and 4 or 2 end
        if ore(wx, y, wz) then return 7 end
        return 1
    end
    return y <= sea and 5 or 0
end

-- CPU-генерация чанка: codes[0..65535] (индекс (y*16 + z)*16 + x) — коды блоков, как их отдаёт GPU.
-- Плотность считается по столбцу один раз на воксель (GPU считает 9 плотностей на 6 вокселей пикселя).
local solid = {}
function M.chunk_codes(cx, cz, codes)
    for z = 0, 15 do
        local wz = cz * 16 + z
        for x = 0, 15 do
            local wx = cx * 16 + x
            for y = 0, 258 do
                solid[y] = density(wx, y, wz) > 0
            end
            for y = 0, 255 do
                codes[(y * 16 + z) * 16 + x] = code(wx, y, wz, solid[y], solid[y + 1], solid[y + 2], solid[y + 3])
            end
        end
    end
    return codes
end

return M
