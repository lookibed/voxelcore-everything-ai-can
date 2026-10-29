-- gpu_worldgen:presets — пресеты-витрины генератора (12.10, gpu_show). Каждый пресет — своя функция плотности
-- и правила материалов в shaders/ui.glslf (ветка gw_preset_main, номер пресета — слово 18 текстуры параметров),
-- параметры — слова 20 + i (фикс. точка /1024) в порядке slots; индексы слотов продублированы #define в шейдере.
-- Пресет мира берётся по имени генератора (generators/gpu_<имя>.toml — стоковая пустота), смена пресета в мире
-- (F6 / команда консоли gpuwg.preset) пишет world:data/gpu_worldgen/preset.txt и перезаписывает загруженные чанки.
--   classic   — исходный генератор пака (11.10): fbm 5 октав + «спагетти», ветка шейдера без изменений (хэш b3e5e930)
--   mountains — «Горы и арки» (Amplified): экстремальный 3D-рельеф, нависания, туннели насквозь, водопады из-под
--               арок, снег и скалы на вершинах, пляжи, трава и цветы, деревья
--   caves     — «Пещерные миры» (1.18 noise caves): обычная поверхность сверху, внизу «сыр» (залы с колоннами),
--               «спагетти» и «лапша», водоносные ячейки воды/лавы с барьерами, аметист на полу, светокамень на потолке
--   islands   — «Парящие острова» (sky islands): архипелаг на трёх уровнях, конусы-«корни» вниз, мосты-арки,
--               водопады сквозь остров в пустоту, светокамень под островами, пустота внизу
local M = {}

-- код шейдера (4 бита) -> блок; пресет может перекрыть отдельные коды (idmap)
M.CODES = {
    [0] = "core:air", "base:stone", "base:dirt", "base:grass_block", "base:sand", "base:water", "base:bazalt",
    "base:coal_ore", "gpu_worldgen:snow", "gpu_worldgen:lava", "gpu_worldgen:crystal", "gpu_worldgen:glowstone",
    "base:stone", "base:ice", "base:grass", "base:flower",
}

M.ORDER = { "mountains", "caves", "islands" }

M.LIST = {
    classic = {
        id = 0, title = "Classic (3D noise)", title_ru = "Классика (3D-шум)",
        world = "GPU Worldgen", generator = "gpu_worldgen:gpu", seed = "20261011",
        slots = {}, values = {},
    },
    mountains = {
        id = 1, title = "Mountains & arches", title_ru = "Горы и арки",
        world = "GPU Worldgen Mountains", generator = "gpu_worldgen:gpu_mountains", seed = "1212",
        slots = { "S", "SY", "AMP", "BASE", "CA", "CS", "HUP", "HDN", "HFS", "HFMIN", "HFMAX", "OCT", "TOP", "SEA",
            "SNOW", "ROCK", "TS", "TSY", "TT", "FALL", "FALLH", "GRASSP", "FLOWERP", "GLOWT", "MH", "RS" },
        values = {
            S = 80, SY = 110, AMP = 8,            -- 3D fbm: масштаб xz / y (SY > S — башни, столбы), амплитуда:
                                                  -- 8 * 50 = 400 блоков на единицу fbm (std 0.16) — «amplified»
            BASE = 86, CA = 20, CS = 520,         -- базовая высота, «континенты» (±CA блоков, масштаб CS)
            MH = 30, RS = 220,                    -- хребты: высота MH * (1 - |fbm2(xz / RS)|)^2
            HFS = 400, HFMIN = 0.25, HFMAX = 1.0, -- маска горных массивов (и амплитуды 3D: 0.6..1.4)
            HUP = 50, HDN = 16,                   -- спад плотности выше/ниже высоты столба (блоков на 1)
            OCT = 5, TOP = 236, SEA = 62,
            SNOW = 160, ROCK = 24,                -- снеговая линия (±9 шумом), полоса голых скал под ней
            TS = 72, TSY = 36, TT = 0.022,        -- туннели насквозь (дырки и арки в горах)
            FALL = 20, FALLH = 48,                -- водопады: ячейка; «крыша — земля» <= FALLH или по стене обрыва
            GRASSP = 0.10, FLOWERP = 0.012, GLOWT = 0.55,
        },
        deco = { trees = 2, chance = 0.6, max_y = 126, trunk = { 4, 6 }, leaf_code = 11 },
    },
    caves = {
        id = 2, title = "Noise caves", title_ru = "Пещерные миры",
        world = "GPU Worldgen Caves", generator = "gpu_worldgen:gpu_caves", seed = "118",
        slots = { "S", "SY", "AMP", "BASE", "CA", "CS", "HUP", "HDN", "OCT", "SEA", "CHS", "CHSY", "CHT", "CHTOP",
            "PIL", "SPS", "SPSY", "SPT", "NOS", "NOT", "AQ", "WET", "WMIN", "WRANGE", "LAVA", "GLOWT", "LAMPP",
            "GRASSP", "FLOWERP", "SINK", "PILS", "SINKA", "SINKT" },
        values = {
            S = 110, SY = 64, AMP = 0.9, BASE = 86, CA = 10, CS = 300, HUP = 26, HDN = 10, OCT = 4, SEA = 66,
            CHS = 70, CHSY = 34, CHT = 0.20, CHTOP = 14,               -- «сыр»: залы глубже CHTOP
            PIL = 0.5, PILS = 8,                                        -- колонны: шум (xz/PILS, y/30) > PIL
            SINK = 0.15, SINKA = 40, SINKT = 0.12,                      -- провалы-воронки к залам: где 2D-шум > SINK,
                                                                        -- «сыр» поднимается до поверхности (до SINKA
                                                                        -- блоков) и порог ниже на SINKT
            SPS = 56, SPSY = 36, SPT = 0.012,                           -- «спагетти» (выходят на поверхность)
            NOS = 22, NOT = 0.004,                                      -- «лапша»
            AQ = 48, WET = 0.5, WMIN = 18, WRANGE = 24, LAVA = 15,      -- водоносные ячейки: вода WMIN..+WRANGE или лава
            GLOWT = 0.5, LAMPP = 0.18,                                  -- аметист на полу, светокамень на потолке
            GRASSP = 0.18, FLOWERP = 0.02,
        },
        deco = { trees = 2, chance = 0.6, max_y = 200, trunk = { 4, 6 }, leaf_code = 13 },
    },
    islands = {
        id = 3, title = "Sky islands", title_ru = "Парящие острова",
        world = "GPU Worldgen Islands", generator = "gpu_worldgen:gpu_islands", seed = "777",
        slots = { "Y0", "DY", "NL", "IS", "T", "G", "HT", "HB", "SPS", "SPA", "DS", "DSY", "DA", "BS", "BW", "BG",
            "YOFF", "FALL", "FALLH", "LAMPP", "GRASSP", "FLOWERP", "OCT", "LAMPT" },
        values = {
            Y0 = 70, DY = 50, NL = 3,              -- уровни архипелага: 70, 120, 170 (±YOFF)
            IS = 120, T = 0.06, G = 4, OCT = 3,    -- маска острова: fbm2 > T, «сила» (m - T) * G
            HT = 7, HB = 16,                       -- профиль: купол сверху (HT), конус снизу (HB)
            SPS = 9, SPA = 5,                      -- «корни»: удлинение конуса пятнами шума
            DS = 22, DSY = 14, DA = 0.4,           -- 3D-деталь (дыры, арки в самих островах)
            BS = 110, BW = 0.03, BG = 0.2,         -- мосты: линии нуля 2D-шума рядом с островами
            YOFF = 10, FALL = 48, FALLH = 44,      -- водопады 2x2 сквозь остров, длина 0.5..1 FALLH от верха
            LAMPP = 0.12, LAMPT = 0.35,            -- светокамень под островами
            GRASSP = 0.2, FLOWERP = 0.03,
        },
        deco = { trees = 3, max_y = 250, trunk = { 4, 6 }, leaf_code = 13 },
    },
}
for name, p in pairs(M.LIST) do p.name = name end

M.BY_GENERATOR = {}
for _, p in pairs(M.LIST) do M.BY_GENERATOR[p.generator] = p end

function M.get(name) return M.LIST[name] end
function M.by_generator(gen) return M.BY_GENERATOR[gen] end

function M.next(name)
    for i, n in ipairs(M.ORDER) do
        if n == name then return M.ORDER[i % #M.ORDER + 1] end
    end
    return M.ORDER[1]
end

-- значения слотов -> слова 20 + i (фикс. точка /1024)
function M.words(p)
    local out = {}
    for i, s in ipairs(p.slots) do
        local v = p.values[s]
        if v == nil then error("gpu_worldgen preset " .. p.name .. ": no value for slot " .. s) end
        out[i] = math.floor(v * 1024 + 0.5)
    end
    return out
end

-- код -> id блока
function M.idmap(p)
    local m = {}
    for code = 0, 15 do
        local name = (p.codes and p.codes[code]) or M.CODES[code]
        local id = block.index(name)
        if id == nil then error("gpu_worldgen: block " .. name .. " not found") end
        m[code] = id
    end
    return m
end

-- id кодов для RLE на GPU: деревья ставит проход шейдера (код 4/5), ствол — код 12 (резерв, генератор его не выдаёт),
-- листва — свободный код пресета deco.leaf_code (mountains 11: светокамня там нет; caves/islands 13: льда там нет)
function M.idmap_rle(p, m)
    local r = {}
    for code = 0, 15 do r[code] = m[code] end
    if p.deco and (p.deco.trees or 0) > 0 then
        r[12] = block.index("base:wood")
        r[p.deco.leaf_code] = block.index("base:leaves")
    end
    return r
end

-- деревья (структуры через границы столбцов — в Lua по массиву id чанка, детерминированно по seed и чанку):
-- ствол на дёрне, крона 5x5 / 3x3; ставится только в воздух/траву/цветы, целиком внутри чанка
local band, bxor, rshift, tobit = bit.band, bit.bxor, bit.rshift, bit.tobit
local function h32(a, b, c, d)
    local h = tobit(a * 1619 + b * 31337 + c * 6971 + d * 1013)
    h = tobit(bxor(h, rshift(h, 15)) * 11291)
    h = tobit(bxor(h, rshift(h, 12)) * 10619)
    return bxor(h, rshift(h, 15))
end
function M.make_deco(p, idmap, seed20)
    local d = p.deco
    if not d or (d.trees or 0) == 0 then return nil end
    local AIR, GRASS_BLOCK, PLANT, FLOWER = idmap[0], idmap[3], idmap[14], idmap[15]
    local WOOD, LEAVES = block.index("base:wood"), block.index("base:leaves")
    local soft = { [AIR] = true, [PLANT] = true, [FLOWER] = true }
    local tmin, tmax = d.trunk[1], d.trunk[2]
    return function(cx, cz, ids)
        for i = 0, d.trees - 1 do
            local h = h32(cx, cz, i, seed20)
            if band(rshift(h, 20), 1023) >= (d.chance or 1) * 1024 then goto continue end
            local x = 2 + band(h, 15) % 12
            local z = 2 + band(rshift(h, 4), 15) % 12
            local th = tmin + band(rshift(h, 8), 7) % (tmax - tmin + 1)
            -- верхняя поверхность столба
            local y = 254
            local base = z * 16 + x
            while y > 0 do
                local id = ids[y * 256 + base]
                if id ~= AIR and id ~= PLANT and id ~= FLOWER then break end
                y = y - 1
            end
            if ids[y * 256 + base] == GRASS_BLOCK and y + th + 2 < 255 and y < d.max_y then
                local top = y + th
                for ly = top - 2, top + 1 do
                    local r = ly <= top - 1 and 2 or 1
                    for dz = -r, r do
                        for dx = -r, r do
                            -- углы кроны срезаны через раз (по хэшу)
                            if not (r == 2 and math.abs(dx) == 2 and math.abs(dz) == 2 and band(h, 2 ^ ((ly + dx + dz) % 8 + 16)) == 0) then
                                local idx = ly * 256 + (z + dz) * 16 + (x + dx)
                                if soft[ids[idx]] then ids[idx] = LEAVES end
                            end
                        end
                    end
                end
                for ty = y + 1, top do ids[ty * 256 + base] = WOOD end
            end
            ::continue::
        end
    end
end

return M
