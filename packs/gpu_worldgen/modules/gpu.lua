-- gpu_worldgen:gpu — генерация чанков на GPU через API пака gpu_compute (gpu_compute:compute).
-- Программа gpu_worldgen (shaders/gpu_worldgen.glsl, маркер #FE03FF80) собрана в общий ui.glslf пака gpu_compute
-- (tools/gpu_compute_build.py); свой ui.glslf пака — ui.glslf.api.bak. Проход gc.pass "gpuwg_fb" (W x H, не больше окна),
-- параметры — gc.params "gpuwg_params" (256x4 слов u32), чтение — gc.read конвейером: кадр N — submit, кадр N+1 — read,
-- эхо serial в строке serialRow подтверждает, что прочитан именно этот пакет (gc.read serial_texel).
-- Раскладка параметров и выхода — в shaders/gpu_worldgen.glsl.
local gc = require "gpu_compute:compute"
local M = {}

local band, rshift = bit.band, bit.rshift

M.FRAME = "gpuwg_fb"
M.PARAMS = "gpuwg_params"
M.TW, M.TH = 128, 86         -- плитка чанка (mode 0)
M.DW, M.DH = 256, 256        -- плитка чанка (mode 1, плотность)

local params        -- gc.params 256x4
local pass          -- gc.pass

local function put(i, v) params:set(i, v) end

-- ---------------------------------------------------------------------------------------------------------------
-- Подгон картинки прохода под пакет (13.10, gpu_cap). Шейдер считает каждый пиксель картинки, а не фрейма: проход
-- состоит из двух картинок — A (строки плиток / потока) и B (служебные строки: serial, деревья, области, параметры).
-- При M.fit = true картинка A сжимается до строк, где лежат плитки пакета (ceil(n / tilesX) * 86 строк, при n < tilesX —
-- и по ширине), в кадре E — до 1 + n*KR строк потока; пустые плитки не рисуются вовсе (раньше каждая проходила ранний
-- выход шейдера и копию во всех 7 проходах). Не нарисованные строки фрейма — очищенные движком; их никто не читает
-- (плитки t >= n, области после n*256 текселей). M.fit = false — A на все строки до служебных (как было).
-- Строки FBO (gl_FragCoord.y, 0 — низ) [a, b) = UI-картинка y = Hf - b, высота b - a (Frame::draw: камера UI
-- перевёрнута, фрейм прижат к низу окна).
M.fit = true
M.last_fit = nil     -- { n, rows, w } последнего подгона (для HUD/лога)
local function img_rows(pass, i, x, w, a, b)
    local img = pass.imgs[i]
    local key = x .. "," .. w .. "," .. a .. "," .. b
    pass.rect = pass.rect or {}
    if pass.rect[i] == key then return end
    pass.rect[i] = key
    img.pos = { x, pass.height - b }
    img.size = { w, b - a }
end
M.img_rows = img_rows

-- новый мир: ассеты движка перезагружены — текстуру параметров и фрейм создать заново
function M.reset()
    params, pass = nil, nil
    M.pending = nil
    M.rle = nil
    rle_co = nil
end

-- w, h — желаемый размер (не больше окна); фактический — по целому числу плиток
function M.init(w, h)
    local lim = gc.limits()
    w = math.min(w or lim.max_pass_w, lim.max_pass_w, 2048)
    h = math.min(h or lim.max_pass_h, lim.max_pass_h, 2048)
    M.tilesX = math.floor(w / M.TW)
    M.tilesY = math.floor((h - 1) / M.TH)
    M.W = M.tilesX * M.TW
    if M.W < M.DW then M.W = M.DW end
    M.serialRow = math.max(M.tilesY * M.TH, M.DH)
    M.H = M.serialRow + 1
    M.max_tiles = M.tilesX * M.tilesY
    if M.max_tiles > 384 then M.max_tiles = 384 end
    if not params then
        params = gc.params{ id = M.PARAMS, words = 1024, width = 256 }
    end
    -- A — плитки (строки 0 .. serialRow), B — строка serialRow (эхо serial)
    pass = gc.pass{ id = M.FRAME, program = "gpu_worldgen", code = 3, width = M.W, height = M.H, images = {
        { src = params, code = 3, x = 0, y = 1, w = M.W, h = M.serialRow },
        { src = params, code = 3, x = 0, y = 0, w = M.W, h = 1 } } }
    M.pass = pass
    return M.W, M.H, M.max_tiles
end

-- ---------------------------------------------------------------------------------------------------------------
-- RLE на GPU (12.10, gpu_pack2): цепочка из 7 проходов gc.chain — генерация (код 3), деревья (4), деревья в коды (5),
-- статистика слоёв (6), байты слоёв (7), префиксная сумма (8), поток extrle16 (9, кадр E). Раскладка и формулы —
-- shaders/gpu_worldgen.glsl «RLE на GPU». Порядок кадров в кадре движка — проба gpu_compute:order (кеш); эхо serial
-- идёт по всей цепочке (каждый проход копирует строки параметров входа), поэтому неверный порядок даёт только задержку
-- (кадр E со старым serial не читается), не неверные байты.
M.RLE_N = 7
M.rle = nil          -- состояние цепочки: { ids, passes, W, H, EH, KR, ... } после rle_init
local rle_co         -- корутина пробы порядка фреймов

-- шаг подготовки цепочки (вызывать каждый кадр, пока не вернёт true): проба порядка 7 фреймов (из кеша — 3 кадра)
function M.rle_step(w, h, kr)
    if M.rle then return true end
    if not rle_co then
        rle_co = coroutine.create(function()
            return gc.chain{ id = "gwrle", n = M.RLE_N, ticks = function(k) for _ = 1, k do coroutine.yield() end end }
        end)
    end
    local ok, ch = coroutine.resume(rle_co)
    if not ok then
        rle_co = nil
        error("gpu_worldgen: rle chain probe failed: " .. tostring(ch))
    end
    if coroutine.status(rle_co) ~= "dead" then return false end
    rle_co = nil
    M.rle_init(ch.ids, w, h, kr, ch.info)
    return true
end

-- раскладка: плитки 128x86 по tilesX x tilesY, serialRow, строка(и) деревьев, 3 области по ceil(nt*256/W) строк,
-- 4 строки параметров сверху; кадр E — 1 + nt*KR строк
function M.rle_init(ids, w, h, kr, info)
    local lim = gc.limits()
    w = math.min(w or lim.max_pass_w, lim.max_pass_w, 2048)
    h = math.min(h or lim.max_pass_h, lim.max_pass_h, 2048)
    kr = kr or 6
    local tilesX = math.floor(w / M.TW)
    local W = tilesX * M.TW
    if W < M.DW then W = M.DW end
    local L
    for tilesY = math.floor((h - 1) / M.TH), 1, -1 do
        local nt = math.min(tilesX * tilesY, 384)
        local SR = math.max(tilesY * M.TH, M.DH)
        local TRn = math.ceil(nt / W)
        local RR = math.ceil(nt * 256 / W)
        local H = SR + 1 + TRn + 3 * RR + 4
        local HMR = math.ceil(2 * nt * 86 / W)
        local EH = 1 + nt * kr + HMR
        if H <= h and EH <= h then
            L = { tilesX = tilesX, tilesY = tilesY, nt = nt, W = W, H = H, SR = SR, TR = SR + 1, ST = SR + 1 + TRn,
                RR = RR, EH = EH, KR = kr, HM = 1 + nt * kr }
            L.BY = L.ST + RR
            L.PF = L.BY + RR
            break
        end
    end
    if not L then error("gpu_worldgen: rle layout does not fit the window") end
    M.tilesX, M.tilesY, M.W, M.H = L.tilesX, L.tilesY, L.W, L.H
    M.serialRow = L.SR
    M.max_tiles = L.nt
    if not params then params = gc.params{ id = M.PARAMS, words = 1024, width = 256 } end
    L.ids = ids
    L.passes = {}
    for k = 1, M.RLE_N do
        local last = k == M.RLE_N
        local H = last and L.EH or L.H
        local src = k == 1 and params or ids[k - 1]
        -- A — плитки (кадр E: строки потока), B — служебные строки (кадр E: высоты столбцов)
        local split = last and L.HM or L.SR
        L.passes[k] = gc.pass{ id = ids[k], program = "gpu_worldgen", code = 2 + k, width = W, height = H, images = {
            { src = src, code = 2 + k, x = 0, y = H - split, w = W, h = split },
            { src = src, code = 2 + k, x = 0, y = 0, w = W, h = H - split } } }
    end
    gc.idle(L.passes)
    L.info = info
    M.rle = L
    M.pass = L.passes[1]
    return L
end

-- подгон картинок под пакет из n плиток (mode 0); full — на всю раскладку (как было)
function M.fit_batch(n, full)
    full = full or not M.fit
    local tx = M.tilesX
    local rows = full and M.serialRow or math.min(M.serialRow, math.ceil(n / tx) * M.TH)
    local w = (full or n >= tx) and M.W or n * M.TW
    if M.rle then
        local L = M.rle
        for k = 1, M.RLE_N - 1 do
            img_rows(L.passes[k], 1, 0, w, 0, rows)
            img_rows(L.passes[k], 2, 0, L.W, L.SR, L.H)
        end
        local E = L.passes[M.RLE_N]
        img_rows(E, 1, 0, L.W, 0, full and L.HM or 1 + n * L.KR)
        img_rows(E, 2, 0, L.W, L.HM, L.EH)
    elseif pass then
        img_rows(pass, 1, 0, w, 0, rows)
        img_rows(pass, 2, 0, M.W, M.serialRow, M.H)
    end
    M.last_fit = { n = n, rows = rows, w = w, full = full }
end

-- слова цепочки: раскладка, деревья пресета (presets.make_deco), id кодов (с кодами ствола/листвы)
function M.rle_words(deco, idmap)
    local L = M.rle
    put(100, 1)
    local d = deco or {}
    put(101, d.trees or 0)
    put(102, math.ceil((d.chance or 1) * 1024))
    put(103, d.max_y or 255)
    put(104, d.trunk and d.trunk[1] or 4)
    put(105, d.trunk and d.trunk[2] or 6)
    put(106, d.leaf_code or 13)
    put(107, d.wood_code or 12)
    put(108, L.TR); put(109, L.ST); put(110, L.BY); put(111, L.PF); put(112, L.H); put(113, L.KR); put(114, L.HM)
    for code = 0, 15 do put(120 + code, idmap[code]) end
end

-- чтение кадра E (поток): nil, пока эхо serial не совпало; иначе Bytearray RGBA
function M.read_rle()
    local L, pend = M.rle, M.pending
    local data, info = gc.read(L.passes[M.RLE_N], { sync = true })
    if not data then return nil end
    if gc.codec.u24_at(data, 0) ~= pend.serial % 16777216 then return nil, "stale" end
    M.pending = nil
    pend.rle_data = data
    -- кадры 3 (коды с деревьями) и 1 (коды генератора) — для запасного пути и сверки: читать только по запросу, пока
    -- цепочка видна (до следующего submit); поэтому прятать картинки — после разбора пакета (gen: gpu.rle_done)
    put(3, 0)
    params:update()
    return data, pend, info.read_s, info.get_data_s
end

-- FBO прохода k цепочки (Bytearray RGBA) — для запасного пути (k = 3: коды с деревьями) и сверки (k = 1)
function M.rle_frame_data(k)
    local cv = assets.to_canvas(M.rle.ids[k])
    return cv and cv:get_data()
end

function M.rle_hide() if M.rle then gc.idle(M.rle.passes) end end

-- высоты столбцов плитки t в кадре E: тексель начала верхних (86 текселей по 3 столбца, байт = 1 + y верхнего вокселя,
-- закрывающего небо; 0 — нет) и нижних (y нижнего такого вокселя, 255 — нет)
-- n — плиток в пакете этой плитки (шейдер кладёт нижние высоты после n*86 текселей пакета, не раскладки); без n —
-- M.hm_n (gen ставит перед M.on_written), иначе раскладка (верно только для полного пакета)
M.hm_n = nil
function M.rle_heightmap(t, n)
    n = n or M.hm_n or M.rle.nt
    return M.rle.HM * M.rle.W + t * 86, M.rle.HM * M.rle.W + (n + t) * 86
end

-- плитка t кадра E: длина потока и смещение текселя начала (данные — 3 байта на тексель RGB)
function M.rle_tile(data, t)
    local L = M.rle
    return gc.codec.u24_at(data, 1 + t), (1 + t * L.KR) * L.W, L.KR * L.W * 3
end

-- слова параметров мира (шум, пресет): 4 seed, 5..16 classic, 18 пресет, 20 + i параметры пресета — те же, что видит
-- шейдер генерации; пак gpu_worldgen_light пишет их в регион атласа для света в шейдерах мира
function M.world_words(p, preset)
    local w = {
        [4] = p.seed, [5] = p.S, [6] = p.SY, [7] = p.AMP, [8] = p.BASE, [9] = p.HSCALE, [10] = p.SEA, [11] = p.OCT,
        [12] = p.CAVE_T, [13] = p.CS, [14] = p.CSY, [15] = p.ORE_T, [16] = p.ORE_S, [18] = preset and preset.id or 0,
    }
    if preset and preset.words then
        for i, v in ipairs(preset.words) do w[19 + i] = v end
    end
    return w
end

-- chunks: список {x, z}; mode 0 — блоки, 1 — плотность (по одному чанку на плитку 256x256); p — noise.make();
-- preset — {id, words} (modules/presets.lua: слово 18 и слова 20 + i); nil или id 0 — classic
function M.submit(chunks, p, mode, preset)
    mode = mode or 0
    local tilesX = mode == 0 and M.tilesX or math.floor(M.W / M.DW)
    put(1, mode)
    put(2, tilesX)
    put(3, #chunks)
    for i, v in pairs(M.world_words(p, preset)) do put(i, v) end
    put(17, M.serialRow)
    for i, c in ipairs(chunks) do
        put(256 + 2 * (i - 1), c[1])
        put(257 + 2 * (i - 1), c[2])
    end
    M.fit_batch(#chunks, mode ~= 0)
    if M.rle and mode == 0 then
        M.rle_words(preset and preset.deco, preset and preset.idmap_rle)
        local serial = gc.submit(M.rle.passes[1], params)
        for k = 2, M.RLE_N do gc.show(M.rle.passes[k]) end
        M.pending = { serial = serial, chunks = chunks, mode = mode, tilesX = tilesX, rle = true }
        return serial
    end
    put(112, 0)
    local serial = gc.submit(pass, params)   -- слово 0 = serial, update(), картинка видна
    M.pending = { serial = serial, chunks = chunks, mode = mode, tilesX = tilesX }
    return serial
end

-- чтение результата: nil, если кадр с этим пакетом ещё не нарисован; иначе Bytearray пикселей (RGBA, строка 0 —
-- низ FBO = gl_FragCoord.y 0.5) и время чтения/копирования (с)
M.clock = time.precise_time and "time.precise_time" or "os.clock"
function M.read()
    local pend = M.pending
    if not pend then return nil end
    if pend.rle then return M.read_rle() end
    -- эхо serial: тексель (0, serialRow); sync — как раньше: чтение не ждёт кадра (serial отсекает старый пакет)
    local data, info, s = gc.read(pass, { sync = true, serial_texel = M.serialRow * M.W })
    if not data then
        return nil, s
    end
    M.pending = nil
    -- фрейм рисуется каждый кадр: без пакета шейдер не должен ничего считать (ntiles = 0 -> ранний выход)
    put(3, 0)
    params:update()
    return data, pend, info.read_s, info.get_data_s
end

-- таблицы байт -> id (младший и старший полубайт) для idmap: без band/rshift и двойного поиска на воксель
local lut_for, lut_lo, lut_hi = nil, {}, {}
local function luts(idmap)
    if lut_for ~= idmap then
        for b = 0, 255 do
            lut_lo[b] = idmap[band(b, 15)]
            lut_hi[b] = idmap[rshift(b, 4)]
        end
        lut_for = idmap
    end
    return lut_lo, lut_hi
end
M.luts = luts
-- idmap изменился (смена пресета): пересчитать таблицы
function M.invalidate_luts() lut_for = nil end

-- плитка i (с 0) пакета mode 0 -> ids[0..65535] (idmap: код -> id блока)
function M.decode_tile(data, i, tilesX, idmap, ids, codes_out)
    if not codes_out then return M.decode_tile_fast(data, i, tilesX, idmap, ids) end
    local p = data.bytes
    local W = M.W
    local tx = i % tilesX
    local ty = (i - tx) / tilesX
    local px0, py0 = tx * M.TW, ty * M.TH
    for z = 0, 15 do
        local zl = z % 8
        local lyb = (z - zl) / 8 * 43
        for x = 0, 15 do
            local o = ((py0 + lyb) * W + px0 + x + 16 * zl) * 4
            local idx = z * 16 + x
            for g = 0, 42 do
                local y0 = g * 6
                local r, gg, b = p[o], p[o + 1], p[o + 2]
                local c0, c1 = band(r, 15), rshift(r, 4)
                local c2, c3 = band(gg, 15), rshift(gg, 4)
                local base = y0 * 256 + idx
                ids[base] = idmap[c0]
                ids[base + 256] = idmap[c1]
                ids[base + 512] = idmap[c2]
                ids[base + 768] = idmap[c3]
                if codes_out then
                    codes_out[base] = c0; codes_out[base + 256] = c1
                    codes_out[base + 512] = c2; codes_out[base + 768] = c3
                end
                if g < 42 then
                    local c4, c5 = band(b, 15), rshift(b, 4)
                    ids[base + 1024] = idmap[c4]
                    ids[base + 1280] = idmap[c5]
                    if codes_out then codes_out[base + 1024] = c4; codes_out[base + 1280] = c5 end
                end
                o = o + W * 4
            end
        end
    end
    return ids
end

-- то же без кодов для сверки: таблицы lo/hi вместо полубайтов (≈ на треть быстрее в Lua)
function M.decode_tile_fast(data, i, tilesX, idmap, ids)
    local lo, hi = luts(idmap)
    local p = data.bytes
    local W = M.W
    local W4 = W * 4
    local tx = i % tilesX
    local ty = (i - tx) / tilesX
    local px0, py0 = tx * M.TW, ty * M.TH
    for z = 0, 15 do
        local zl = z % 8
        local lyb = (z - zl) / 8 * 43
        for x = 0, 15 do
            local o = ((py0 + lyb) * W + px0 + x + 16 * zl) * 4
            local base = z * 16 + x
            for g = 0, 41 do
                local r, gg, b = p[o], p[o + 1], p[o + 2]
                ids[base] = lo[r]; ids[base + 256] = hi[r]
                ids[base + 512] = lo[gg]; ids[base + 768] = hi[gg]
                ids[base + 1024] = lo[b]; ids[base + 1280] = hi[b]
                base = base + 1536
                o = o + W4
            end
            -- группа 42: y 252..255 (байт B — y 256, 257 — вне чанка)
            local r, gg = p[o], p[o + 1]
            ids[base] = lo[r]; ids[base + 256] = hi[r]
            ids[base + 512] = lo[gg]; ids[base + 768] = hi[gg]
        end
    end
    return ids
end

-- плитка i пакета mode 1 -> dens[(y*16 + z)*16 + x] (плотность, шаг 2^-20)
function M.decode_density(data, i, tilesX, dens)
    local p = data.bytes
    local W = M.W
    local tx = i % tilesX
    local ty = (i - tx) / tilesX
    local px0, py0 = tx * M.DW, ty * M.DH
    for y = 0, 255 do
        for lx = 0, 255 do
            local o = ((py0 + y) * W + px0 + lx) * 4
            local q = p[o] + p[o + 1] * 256 + p[o + 2] * 65536
            local x, z = lx % 16, math.floor(lx / 16)
            dens[(y * 16 + z) * 16 + x] = q / 1048576 - 8
        end
    end
    return dens
end

return M
