-- gpu_worldgen_light:light — данные для света в шейдерах мира -> регион атласа блоков gwl_world (textures/blocks/gwl_world.png
-- 512x520: самая высокая текстура атласа, упаковщик кладёт её в (2, 2); шейдер читает тексель (2 + x, 2 + y)).
--   строки 0..511 — высоты столбцов: слот чанка (cx mod 32, cz mod 32) по 16x16 текселей, тексель столба (x, z):
--                   R = 1 + y верхнего вокселя, закрывающего небо (0 — нет), G = cx & 255, B = cz & 255,
--                   A = 1 + y нижнего такого вокселя (255 — нет; 0 — слот не записан).
--                   Высоты считает цепочка RLE пака gpu_worldgen на GPU (кадр E, gpu.rle_heightmap) — из тех же вокселей,
--                   что пишутся в мир; правки игрока — пересчёт столба по block.get (on_block_placed/broken).
--   строки 512..519 — слова параметров: слово i -> тексель (i % 512, 512 + i / 512), байты RGBA = u32 LE. Слово 0 — маркер
--                   "GWLP" (без него шейдер светит как движок), 4..53 — как у прохода генерации (gpu.world_words),
--                   64 — высота, выше которой рельефа нет, 65 — уровень моря (-1 — нет).
-- Буфер региона пишется в Lua, в атлас — canvas:set_data + canvas:update() не чаще раза в кадр (scripts/hud.lua).
local gen = require "gpu_worldgen:gen"
local gpu = require "gpu_worldgen:gpu"

local M = {}
local W, H, PROW = 512, 520, 512
local canvas, buf
local written
M.dirty = false
M.columns = 0

local function log(s) debug.log("[gpu_worldgen_light] " .. s) end
local band, rshift, tobit = bit.band, bit.rshift, bit.tobit

local function top_y(p, P)
    local v = p.values or {}
    if p.name == "mountains" then return 255 end
    if p.name == "caves" then return math.min(255, math.ceil(v.BASE + v.CA + v.AMP * v.HUP + 12)) end
    if p.name == "islands" then
        return math.min(255, math.ceil(v.Y0 + v.DY * (v.NL - 1) + v.YOFF + v.HT * v.G + v.HT * v.DA + 12))
    end
    return math.min(255, math.ceil(P.BASE + P.AMP / 1024 * P.HSCALE / 1024 + 12))
end
local function sea_level(p, P)
    local v = p.values or {}
    if p.name == "mountains" or p.name == "caves" then return v.SEA end
    if p.name == "islands" then return -1 end
    return P.SEA
end

local function init()
    if canvas then return true end
    local ok, c = pcall(assets.to_canvas, "blocks:gwl_world")
    if not ok or not c then
        log("no atlas region blocks:gwl_world: " .. tostring(c))
        return false
    end
    if c.width ~= W or c.height ~= H then
        log(("atlas region gwl_world %dx%d, expected %dx%d"):format(c.width, c.height, W, H))
        return false
    end
    canvas = c
    buf = Bytearray(W * H * 4)
    local p = buf.bytes
    for i = 0, W * H * 4 - 1 do p[i] = 0 end
    log(("atlas region gwl_world %dx%d"):format(c.width, c.height))
    return true
end

local function put_word(i, v)
    v = tobit(v)
    local o = ((PROW + math.floor(i / W)) * W + i % W) * 4
    local p = buf.bytes
    p[o] = band(v, 255); p[o + 1] = band(rshift(v, 8), 255); p[o + 2] = band(rshift(v, 16), 255); p[o + 3] = band(rshift(v, 24), 255)
end

local function write_params()
    local p, P = gen.preset, gen.params()
    if not p or not P then return end
    local k = p.name .. ":" .. tostring(P.seed)
    if k == written or not init() then return end
    local words = gpu.world_words(P, gen.preset_desc())
    words[64] = top_y(p, P)
    words[65] = sea_level(p, P)
    for i = 0, 1023 do put_word(i, 0) end
    for i, v in pairs(words) do put_word(i, v) end
    put_word(0, 0x504C5747)  -- "GWLP"
    -- смена пресета: прежние высоты не годятся (слоты сбросить)
    local q = buf.bytes
    for i = 0, PROW * W * 4 - 1 do q[i] = 0 end
    written = k
    M.dirty = true
    log(("params: preset %s seed20 %d top %d sea %d"):format(p.name, P.seed, words[64], words[65]))
end

-- высоты столбцов чанка (x, z) из кадра E цепочки RLE (data — Bytearray RGBA, tile — плитка)
local function on_written(cx, cz, data, tile)
    if not init() then return end
    write_params()
    local src = data.bytes
    local o, ob = gpu.rle_heightmap(tile)
    o, ob = o * 4, ob * 4
    local q = buf.bytes
    local sx, sz = cx % 32, cz % 32
    local g, b = band(cx, 255), band(cz, 255)
    local col = 0
    for _ = 0, 85 do
        for ch = 0, 2 do
            if col < 256 then
                local x, z = col % 16, math.floor(col / 16)
                local d = ((sz * 16 + z) * W + sx * 16 + x) * 4
                local bot = src[ob + ch]
                q[d] = src[o + ch]; q[d + 1] = g; q[d + 2] = b; q[d + 3] = bot < 254 and bot + 1 or 255
                col = col + 1
            end
        end
        o = o + 4
        ob = ob + 4
    end
    M.columns = M.columns + 256
    M.dirty = true
end

local pending = {}   -- столбы, изменённые игроком: пересчёт в M.flush (событие on_block_broken приходит до удаления блока)

-- правка игрока: столб (x, z) заново по block.get (те же правила, что в шейдере цепочки: небо закрывает всё, кроме
-- воздуха, воды, травы и цветка)
local open_ids
local function column(x, z)
    if not canvas then return end
    if not open_ids then
        open_ids = { [0] = true }
        for _, n in ipairs({ "base:water", "base:grass", "base:flower" }) do
            local id = block.index(n)
            if id then open_ids[id] = true end
        end
    end
    local top, bot = 0, 255
    for y = 255, 0, -1 do
        local id = block.get(x, y, z)
        if id ~= -1 and not open_ids[id] then top = y + 1; break end
    end
    for y = 0, 254 do
        local id = block.get(x, y, z)
        if id ~= -1 and not open_ids[id] then bot = y; break end
    end
    local cx, cz = math.floor(x / 16), math.floor(z / 16)
    local d = (((cz % 32) * 16 + (z - cz * 16)) * W + (cx % 32) * 16 + (x - cx * 16)) * 4
    local q = buf.bytes
    q[d] = top; q[d + 1] = band(cx, 255); q[d + 2] = band(cz, 255); q[d + 3] = bot < 254 and bot + 1 or 255
    M.dirty = true
end

-- проверка: высоты региона против block.get по столбцам квадрата чанков [-r, r]^2 -> число столбцов, расхождений, пример
function M.check(r)
    if not buf then return 0, 0, "no region" end
    local q = buf.bytes
    local n, bad, ex = 0, 0, nil
    for cx = -r, r do
        for cz = -r, r do
            for col = 0, 255 do
                local x, z = cx * 16 + col % 16, cz * 16 + math.floor(col / 16)
                local d = (((cz % 32) * 16 + col / 16 - col / 16 % 1) * W + (cx % 32) * 16 + col % 16) * 4
                local top = 0
                for y = 255, 0, -1 do
                    local id = block.get(x, y, z)
                    if id ~= -1 and id ~= 0 and id ~= block.index("base:water") and id ~= block.index("base:grass")
                        and id ~= block.index("base:flower") then top = y + 1; break end
                end
                n = n + 1
                if q[d] ~= top or q[d + 1] ~= band(cx, 255) or q[d + 2] ~= band(cz, 255) then
                    bad = bad + 1
                    ex = ex or ("%d,%d: region %d (%d,%d) block.get %d"):format(x, z, q[d], q[d + 1], q[d + 2], top)
                end
            end
        end
    end
    return n, bad, ex
end

function M.column_later(x, z) pending[#pending + 1] = { x, z } end

function M.flush()
    if #pending > 0 then
        local list = pending
        pending = {}
        for _, c in ipairs(list) do column(c[1], c[2]) end
    end
    if M.dirty and canvas then
        canvas:set_data(buf)
        canvas:update()
        M.dirty = false
    end
end

function M.world_open()
    canvas, buf, written, M.dirty = nil, nil, nil, false
    gen.on_written = on_written
    if gen.is_active() and not gen.cfg.rle then log("gen.cfg.rle is off: column heights need the GPU RLE chain") end
end
function M.tick() if gen.is_active() then write_params() end end
M.column = column

return M
