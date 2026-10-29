-- Замер стокового генератора мира (13.10, агент gen_bench) той же процедурой, что tools/scenarios/gpu_worldgen_showcase.lua
-- (фаза «генерация от открытия мира» и «поток»), чтобы сравнить с gpu_worldgen (classic + gpu_worldgen_light).
-- Драйвер: tools/scenarios/gen_bench_stock.py (аренда wasmrt engine_rt, --param engine=v032, F2F perf по маркерам).
-- Параметры — export:wasmrt_manifest.txt, key=value через ';':
--   generator (base:demo | base:flat_grass | core:default), seed (20261011 — seed classic), load_distance (8),
--   hold_s (3 — пауза до открытия мира, маркер «prestart»), sustain_s (10), window (6), timeout (300), views (1),
--   view_s (4), hop (22 — шаг телепорта потока в чанках: новая область без пересечения со старой при ld 8 + padding 2),
--   dwell_s (0.2 — пауза после того, как зона сгенерирована, до следующего прыжка: меши догоняют; в фазе генерации
--   последний меш шёл через 0.14 с после последнего чанка; 0 — прыжок сразу, меши почти не строятся)
-- Паки: только base (без gpu_worldgen). Кадры пишет сам сценарий: длительность каждого app.tick (один кадр движка),
-- как gen.rec в gpu_worldgen (on_hud_render раз в кадр).
-- Маркеры лога: [gen_bench] prestart | ready | generation … | window … | zone … | sustain start | hop … | sustain end … |
--   view <имя>: … | done
local o = {}
local f = "export:wasmrt_manifest.txt"
if file.isfile(f) then
    for k, v in file.read(f):gmatch("([%w_]+)%s*=%s*([^;\r\n]*)") do
        o[k] = tonumber(v) or v
    end
end
local function log(s) debug.log("[gen_bench] " .. s) end
local GEN = o.generator or "base:demo"
local LABEL = "stock_" .. GEN:gsub("[^%w]", "_")   -- метка строк замеров (\w+ в разборе драйвера)
local SEED = tostring(o.seed or "20261011")
local LD = o.load_distance or 8
app.config_packs({ "base" })
app.load_content()
log("packs: base; generator " .. GEN .. " seed " .. SEED)
if (o.hold_s or 0) > 0 then
    log("prestart")
    app.sleep(o.hold_s)
end
local old_ld = app.get_setting("chunks.load-distance")
if old_ld ~= LD then app.set_setting("chunks.load-distance", LD) end
log(("settings: load-distance %s load-speed %s padding %s"):format(tostring(app.get_setting("chunks.load-distance")),
    tostring(app.get_setting("chunks.load-speed")), tostring(app.get_setting("chunks.padding"))))
local now = time.precise_time or os.clock
local name = "genbench_" .. GEN:gsub("[^%w]", "_") .. "_" .. SEED
log(("creating world %s seed %s generator %s"):format(name, SEED, GEN))
app.new_world(name, SEED, GEN)
local t_open = now()
-- как launch.open у classic: день, полёт над (8.5, 8.5); у стока чанк (0,0) уже есть (предзагрузка движка до открытия)
world.set_day_time(0.5)
world.set_day_time_speed(0)
-- точка спавна задана (как launch.open): иначе движок ищет её сам случайным перебором и уводит игрока от (0,0)
player.set_spawnpoint(0, 8.5, 140, 8.5)
player.set_flight(0, true)
player.set_noclip(0, true)
player.set_pos(0, 8.5, 140, 8.5)
player.set_vel(0, 0, 0, 0)
pcall(app.set_setting, "graphics.enable-fog", false)
pcall(app.set_setting, "graphics.fog-curve", 6)
local n0 = world.count_chunks()
log(("ready: world %s generator %s, chunks at open %d"):format(name, tostring(world.get_generator()), n0))

-- фаза генерации: кадры и число чанков движка (world.count_chunks) каждый кадр; простой — число не меняется 1.5 с
local rec, tf = {}, {}   -- длительности кадров; моменты роста числа чанков {t, count}
local last_t = now()
local last_count, last_change, t_first, t_last = n0, now(), nil, nil
local idle_since
local function tick()
    app.tick()
    local t = now()
    rec[#rec + 1] = t - last_t
    last_t = t
    return t
end
local ok = pcall(function()
    while true do
        local t = tick()
        local c = world.count_chunks()
        if c ~= last_count then
            t_first = t_first or t
            t_last = t
            last_count, last_change = c, t
        end
        if c > n0 and t - last_change > 1.5 then idle_since = last_change; break end
        if t - t_open > (o.timeout or 300) then error("timeout") end
    end
end)
local W = o.window or 6
while now() - t_open < W do tick() end
do
    local fr, ts, worst, slow = {}, 0, 0, 0
    for i = 1, #rec do
        if ts >= W then break end
        ts = ts + rec[i]
        fr[#fr + 1] = rec[i]
        if rec[i] > worst then worst = rec[i] end
        if rec[i] > 1 / 30 then slow = slow + 1 end
    end
    table.sort(fr)
    local q = function(x) return #fr > 0 and fr[math.max(1, math.ceil(#fr * x))] * 1000 or 0 end
    log(("window %s: first %.1f s after world open: %d frames, avg fps %.1f, frame ms p50 %.1f p95 %.1f p99 %.1f max %.1f, >33 ms: %d, chunks loaded %d")
        :format(LABEL, ts, #fr, ts > 0 and #fr / ts or 0, q(0.5), q(0.95), q(0.99), worst * 1000, slow, world.count_chunks()))
end
local frames, tsum = {}, 0
for i = 1, #rec do
    if tsum >= (idle_since or now()) - t_open then break end
    tsum = tsum + rec[i]
    frames[#frames + 1] = rec[i]
end
table.sort(frames)
local nf = #frames
local function pct(q) return nf > 0 and frames[math.max(1, math.ceil(nf * q))] * 1000 or 0 end
local slow = 0
for _, dt in ipairs(frames) do if dt > 1 / 30 then slow = slow + 1 end end
local n = last_count
local span = (t_last and t_first) and (t_last - t_first) or 0
-- те же поля, что строка generation у gpu_worldgen (Lua мс/чанк у стока нет — нули); «chunks» — все чанки зоны,
-- «after open» — созданные после открытия мира (до открытия движок создаёт чанки вокруг игрока сам, ld 1)
log(("generation %s: ok=%s, %d chunks (world.count_chunks %d) in %.2f s from world open (%.2f s first..last chunk) = %.1f ch/s; frames %d, avg fps %.1f, frame ms p50 %.1f p95 %.1f max %.1f, >33 ms: %d; Lua ms/chunk: read 0.000 copy 0.000 decode 0.000 encode 0.000 set 0.000 total 0.000; chunks at open %d, after open %d, after-open rate %.1f ch/s; mem %.1f MB")
    :format(LABEL, tostring(ok), n, world.count_chunks(), (idle_since or now()) - t_open, span,
        span > 0 and (n - n0 - 1) / span or 0, nf, tsum > 0 and nf / tsum or 0, pct(0.5), pct(0.95), pct(1.0), slow,
        n0, n - n0, ((idle_since or now()) - t_open) > 0 and (n - n0) / ((idle_since or now()) - t_open) or 0,
        collectgarbage("count") / 1024))

-- зона загрузки: смещения загруженных чанков от чанка игрока (для потока)
local px, _, pz = player.get_pos(0)
local ccx, ccz = math.floor(px / 16), math.floor(pz / 16)
local zone = {}
for dx = -14, 14 do
    for dz = -14, 14 do
        if block.get((ccx + dx) * 16, 0, (ccz + dz) * 16) ~= -1 then zone[#zone + 1] = { dx, dz } end
    end
end
log(("zone: %d chunks loaded around chunk %d,%d"):format(#zone, ccx, ccz))

-- поток: игрок телепортируется на hop чанков по x, как только вся зона вокруг него загружена; чанки потока — новые
-- (создание + генерация + свет + меши, старые выгружаются). Отличие от «перезаписи» gpu_worldgen (те же 193 чанка
-- снова пишутся set_chunk_data): здесь ещё выгрузка/запись старых чанков и смена видимой области.
if (o.sustain_s or 0) > 0 then
    app.sleep(1.0)
    local HOP = o.hop or 22
    local hop, total, got = 0, 0, 0
    local function loaded_in(cx, cz)
        local k = 0
        for _, d in ipairs(zone) do
            if block.get((cx + d[1]) * 16, 0, (cz + d[2]) * 16) ~= -1 then k = k + 1 end
        end
        return k
    end
    local cx, cz = ccx, ccz
    local function jump()
        hop = hop + 1
        cx = ccx + hop * HOP
        player.set_pos(0, cx * 16 + 8.5, 140, cz * 16 + 8.5)
        player.set_vel(0, 0, 0, 0)
    end
    rec = {}
    last_t = now()
    log(("sustain start: %d s"):format(o.sustain_s))
    local t0 = now()
    jump()
    local hop_t = now()
    while now() - t0 < o.sustain_s do
        tick()
        got = loaded_in(cx, cz)
        if got >= #zone then
            total = total + got
            local td = now()
            while now() - td < (o.dwell_s or 0.2) and now() - t0 < o.sustain_s do tick() end
            log(("hop %d: %d chunks in %.2f s"):format(hop, got, now() - hop_t))
            jump()
            hop_t = now()
            got = 0
        end
    end
    local el = now() - t0
    total = total + loaded_in(cx, cz)
    local fr = {}
    for i = 2, #rec do fr[#fr + 1] = rec[i] end
    table.sort(fr)
    local q = function(x) return #fr > 0 and fr[math.max(1, math.ceil(#fr * x))] * 1000 or 0 end
    log(("sustain end %s: %d chunks in %.2f s = %.1f ch/s; frames %d, avg fps %.1f, frame ms p50 %.1f p95 %.1f max %.1f; Lua ms/chunk: read 0.000 copy 0.000 decode 0.000 encode 0.000 set 0.000 total 0.000; hops %d")
        :format(LABEL, total, el, total / el, #fr, #fr / el, q(0.5), q(0.95), q(1.0), hop))
    -- назад к спавну (кадр стокового мира — у (0,0), как витрина classic)
    player.set_pos(0, ccx * 16 + 8.5, 140, ccz * 16 + 8.5)
    pcall(app.sleep_until, function() return loaded_in(ccx, ccz) >= #zone end, 1e9, 60)
    app.sleep(1.0)
end

-- кадры: спавн и обзор (как точка «vista» витрины classic: из угла области на её центр)
if (o.views or 1) ~= 0 then
    local vs = o.view_s or 4
    local function surface(x, z)
        for y = 255, 0, -1 do
            local id = block.get(x, y, z)
            if id > 0 then return y end
        end
        return 0
    end
    local function look(nm, x, y, z, yaw, pitch)
        player.set_pos(0, x, y, z)
        player.set_vel(0, 0, 0, 0)
        player.set_rot(0, yaw, pitch, 0)
        app.tick(); app.tick()
        app.sleep(1.0)
        log(("view %s: pos %.1f %.1f %.1f yaw %.0f pitch %.0f"):format(nm, x, y, z, yaw, pitch))
        app.sleep(vs)
    end
    local sy = surface(8, 8)
    look("spawn", 8.5, sy + 3.6, 8.5, 0, -10)
    local R = 3
    local X0, X1 = -R * 16, R * 16 + 15
    local top = 0
    for x = X0, X1, 4 do for z = X0, X1, 4 do top = math.max(top, surface(x, z)) end end
    local c0 = X0 - 10
    local dx, dy, dz = X1 - c0, top * 0.45 - math.min(top + 6, 250), X1 - c0
    look("vista", c0, math.min(top + 6, 250), c0, math.deg(math.atan2(-dx, -dz)),
        math.deg(math.atan2(dy, math.sqrt(dx * dx + dz * dz))))
end
log("done")
