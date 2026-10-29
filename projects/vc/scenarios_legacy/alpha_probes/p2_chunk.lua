-- Проба 2: world.set_chunk_data с кодеком alphamine:chunk_codec (Lua extrle16 + compression.encode).
-- Замеры: кодирование одного чанка (заполнение raw, extrle16, gzip, заголовок), set_chunk_data,
-- кадры до пересчёта света/меша (время кадров после set), проверка block.get по всему чанку,
-- совпадение нашего extrle16 с тем, что кодирует сам движок (world.get_chunk_data), область 9×9.
-- Маркеры: [alpha_p2] shot1 (один чанк под игроком), shot2 (9×9 сверху), done.
local C = setfenv(load(file.read("user:tools/scenarios/alpha_probes/common.lua")), getfenv(1))()
local T = "alpha_p2"
local pid = C.open_probe_world(T)
local codec = require("alphamine:chunk_codec")
local chunks_mod = require("alphamine:chunks")

local STONE, DIRT, GRASS = block.index("base:stone"), block.index("base:dirt"), block.index("base:grass_block")
local PLANKS, GLASS = block.index("base:planks"), block.index("base:glass")
C.log(T, ("ids stone=%d dirt=%d grass=%d planks=%d glass=%d"):format(STONE, DIRT, GRASS, PLANKS, GLASS))

-- тестовый узор: камень y<60, земля 60..62, дёрн 63; столб камня (8,8) до 79; крыша из досок
-- на y=70 над x 0..6 (тень на дёрне); стеклянный блок (12,64,3); ступенька по x у z=15
local function expected(x, y, z)
    if y < 60 then return STONE end
    if y < 63 then return DIRT end
    if y == 63 then return GRASS end
    if x == 8 and z == 8 and y <= 79 then return STONE end
    if y == 70 and x <= 6 then return PLANKS end
    if x == 12 and y == 64 and z == 3 then return GLASS end
    if z == 15 and y <= 63 + math.floor(x / 4) then return STONE end
    return 0
end

local function fill_pattern(raw)
    local p = raw.bytes
    for i = 0, codec.RAW_LEN - 1 do p[i] = 0 end
    for z = 0, 15 do
        for x = 0, 15 do
            codec.fill_column(raw, x, z, 0, 59, STONE)
            codec.fill_column(raw, x, z, 60, 62, DIRT)
            codec.fill_column(raw, x, z, 63, 63, GRASS)
        end
    end
    codec.fill_column(raw, 8, 8, 64, 79, STONE)
    for z = 0, 15 do for x = 0, 6 do codec.set_id(raw, x, 70, z, PLANKS) end end
    codec.set_id(raw, 12, 64, 3, GLASS)
    for x = 0, 15 do codec.fill_column(raw, x, 15, 64, 63 + math.floor(x / 4), STONE) end
end

-- ждём, пока загрузятся 9×9 чанков вокруг (0,0): при chunks.load-distance=4 грузится круг из 45
-- чанков (углы 9×9 нет), поэтому на время пробы load-distance=7, в конце — возврат
local old_ld = app.get_setting("chunks.load-distance")
app.set_setting("chunks.load-distance", 7)
player.set_spawnpoint(pid, 8, 100, 8)
player.set_pos(pid, 8, 100, 8)
local function area_loaded(r)
    for cz = -r, r do for cx = -r, r do
        if block.get(cx * 16, 0, cz * 16) == -1 then return false end
    end end
    return true
end
local t0 = time.uptime()
local ok = pcall(app.sleep_until, function() return area_loaded(4) end, 1e9, 30)
C.log(T, ("9x9 loaded=%s after %.2f s, chunks=%d, hook present=%d"):format(tostring(ok),
    time.uptime() - t0, world.count_chunks(), chunks_mod.stats.present))
app.sleep(0.5)

-- 1) один чанк: замеры. time.uptime() в сценарии — время кадра (внутри кадра не меняется),
-- os.clock() на Windows — шаг 1 мс, поэтому каждое действие повторяется N раз подряд.
local raw = codec.new_raw()
local N = 200
fill_pattern(raw); codec.encode(raw) -- прогрев JIT
local a = os.clock()
for i = 1, N do fill_pattern(raw) end
local b = os.clock()
local rle_len
for i = 1, N do rle_len = #codec.extrle16(raw) end
local c = os.clock()
local data
for i = 1, N do data = codec.encode(raw) end
local d = os.clock()
local okset
for i = 1, N do okset = world.set_chunk_data(0, 0, data) end
local e = os.clock()
C.log(T, ("avg of %d: fill %.3f ms, extrle16 %.3f ms, encode (extrle16+gzip+header) %.3f ms, set_chunk_data %.3f ms (ok=%s); rle %d B, data %d B"):format(
    N, (b - a) / N * 1e3, (c - b) / N * 1e3, (d - c) / N * 1e3, (e - d) / N * 1e3, tostring(okset), rle_len, #data))

-- кадры после последнего set: сколько кадров и времени до «тишины»
local frames = {}
local tl = time.uptime()
for i = 1, 30 do
    local a = os.clock(); app.tick(); frames[i] = (os.clock() - a) * 1e3
end
local fs = {}
for i = 1, 30 do fs[i] = ("%.1f"):format(frames[i]) end
C.log(T, "frame ms after set: " .. table.concat(fs, " "))

-- проверка содержимого
local bad, first_bad = 0, nil
for y = 0, 255 do for z = 0, 15 do for x = 0, 15 do
    local id = block.get(x, y, z)
    if id ~= expected(x, y, z) then
        bad = bad + 1
        first_bad = first_bad or ("%d,%d,%d got %d want %d"):format(x, y, z, id, expected(x, y, z))
    end
end end end
C.log(T, ("verify chunk 0,0: mismatches=%d %s"):format(bad, first_bad or ""))

-- наш extrle16 против кодирования движком: get_chunk_data -> [flags][res][len][gzip]...
local eng = world.get_chunk_data(0, 0)
local ep = eng.bytes
local glen = ep[2] + ep[3] * 256 + ep[4] * 65536 + ep[5] * 16777216
local egz = eng:slice(7, glen)
local erle = compression.decode(egz)
local ours = codec.extrle16(raw)
local same = #erle == #ours
if same then
    local a, b = erle.bytes, ours.bytes
    for i = 0, #ours - 1 do if a[i] ~= b[i] then same = false; break end end
end
if not same then
    local a, b = erle.bytes, ours.bytes
    local k = 0
    while k < #ours and k < #erle and a[k] == b[k] do k = k + 1 end
    local ha, hb = {}, {}
    for i = math.max(0, k - 4), math.min(k + 12, #erle - 1) do ha[#ha + 1] = ("%02x"):format(a[i]) end
    for i = math.max(0, k - 4), math.min(k + 12, #ours - 1) do hb[#hb + 1] = ("%02x"):format(b[i]) end
    C.log(T, ("rle differ at %d: engine %s | ours %s"):format(k, table.concat(ha, " "), table.concat(hb, " ")))
end
C.log(T, ("engine get_chunk_data: flags=%d total %d B, gzip %d B, rle %d B; ours rle %d B; identical=%s"):format(
    ep[0], #eng, glen, #erle, #ours, tostring(same)))

-- игрок над чанком, смотрит на столб и тень крыши
player.set_pos(pid, 14, 72, -2)
player.set_rot(pid, 150, -35, 0)
C.log(T, "shot1")
app.sleep(4)

-- 2) область 9×9 (кроме уже заполненного 0,0 — тоже перезаписываем)
local t1 = os.clock()
local n = 0
for cz = -4, 4 do for cx = -4, 4 do
    fill_pattern(raw)
    if world.set_chunk_data(cx, cz, codec.encode(raw)) then n = n + 1 end
end end
local t2 = os.clock()
C.log(T, ("9x9: set %d chunks, fill+encode+set %.1f ms (%.2f ms/chunk)"):format(
    n, (t2 - t1) * 1e3, (t2 - t1) * 1e3 / 81))
local w2 = os.clock()
local fr = {}
local slow = 0
for i = 1, 120 do
    local a = os.clock(); app.tick(); fr[i] = (os.clock() - a) * 1e3
    if fr[i] > 30 then slow = i end
end
local fs2 = {}
for i = 1, 40 do fs2[i] = ("%.0f"):format(fr[i]) end
C.log(T, ("after 9x9: 120 frames %.1f ms, last frame >30ms = #%d; first 40: %s"):format(
    (os.clock() - w2) * 1e3, slow, table.concat(fs2, " ")))
player.set_pos(pid, 8, 140, 70)
player.set_rot(pid, 0, -40, 0)
C.log(T, "shot2")
app.sleep(5)
app.set_setting("chunks.load-distance", old_ld)
C.log(T, "done")
