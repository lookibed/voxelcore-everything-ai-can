-- Прямой запуск пака gpu_worldgen при старте движка (без кликов по меню): новый мир на генераторе gpu_worldgen:gpu,
-- генерация квадрата чанков [-R, R]^2 на GPU (или CPU), замеры, сверки, виды для F2F shot.
-- Лаборатория (tools/scenarios/gpu_worldgen_run.py):
--   lab lease wasmrt engine_rt [--param engine=v032] --param packs=gpu_worldgen --param script=gpu_worldgen_world.lua
--       --param ready_marker="\[gpu_worldgen\] ready" --start
-- Параметры — export:gpu_worldgen.txt, строки key=value: backend (gpu|cpu), radius (3), seed, world, load_distance (6),
--   budget_ms, target_fps, batch_max, frame_w, frame_h, bench (1 — readback/density/parity), views (1), view_s (4),
--   timeout (300), stay (0 — выйти после done; >0 — ещё столько секунд статистики).
-- Маркеры лога: [gpu_worldgen] ready | area R done ... | view <имя> | done
app.config_packs({ "base", "gpu_worldgen" })
app.load_content()

local o = {}
-- параметры: export:gpu_worldgen.txt (строки key=value) или, в аренде wasmrt engine_rt, export:wasmrt_manifest.txt
-- (--param manifest="backend=cpu;radius=2" — вид пишет его туда сам)
for _, f in ipairs({ "export:wasmrt_manifest.txt", "export:gpu_worldgen.txt" }) do
    if file.isfile(f) then
        for k, v in file.read(f):gmatch("([%w_]+)%s*=%s*([^;\r\n]*)") do
            o[k] = tonumber(v) or v
        end
    end
end
local function log(s) debug.log("[gpu_worldgen] " .. s) end

local launch = require "gpu_worldgen:launch"
local gen = require "gpu_worldgen:gen"
local bench = require "gpu_worldgen:bench"
local gpu = require "gpu_worldgen:gpu"

local R = o.radius or 3
local parity_list = { { 0, 0 }, { 1, 0 }, { 0, -1 }, { -2, 2 } }
local keep = {}
for _, c in ipairs(parity_list) do keep[#keep + 1] = c[1] .. "," .. c[2] end
local old_ld = launch.open(app, {
    world = o.world or ("gpuwg_" .. tostring(o.seed or "20261011") .. "_" .. tostring(o.backend or "gpu")),
    fresh = true,
    seed = o.seed and tostring(o.seed) or "20261011",
    load_distance = o.load_distance or 6,
    backend = o.backend or "gpu",
    budget_ms = o.budget_ms, target_fps = o.target_fps, batch_max = o.batch_max,
    frame_w = o.frame_w, frame_h = o.frame_h,
    keep_codes = keep,
    flight = true,
    generator = o.generator,  -- base:demo — стоковый генератор для сравнения кадров при загрузке чанков
})
-- туман в кадрах мешает видеть рельеф (настройка 0.32 graphics.enable-fog; settings.toml аренды, не пользователя)
-- в 0.31 настройки нет — туман дальше: fog-curve 6 (непрозрачность = (глубина*k)^curve)
-- 0.31: enable-fog нет (set_setting бросает ошибку), fog-curve 6 туман только ослабляет (он зависит от load-distance)
if (o.fog or 0) == 0 then
    local ok1 = pcall(app.set_setting, "graphics.enable-fog", false)
    local ok2 = pcall(app.set_setting, "graphics.fog-curve", 6)
    local g1, v1 = pcall(app.get_setting, "graphics.enable-fog")
    local g2, v2 = pcall(app.get_setting, "graphics.fog-curve")
    log(("fog: enable-fog set %s now %s, fog-curve set %s now %s"):format(tostring(ok1), g1 and tostring(v1) or "-",
        tostring(ok2), g2 and tostring(v2) or "-"))
end
local stock = not gen.is_active()

-- фаза генерации: от открытия мира до простоя конвейера (очередь пуста 1.5 с подряд) — все чанки зоны загрузки
local now = time.precise_time or os.clock
gen.record(true)
local t_open = now()
local idle_since
local last_count, last_change = -1, now()
local ok = pcall(app.sleep_until, function()
    if stock then
        -- стоковый генератор: простой = число загруженных чанков не меняется
        local c = world.count_chunks()
        if c ~= last_count then last_count, last_change = c, now() end
        if c > 0 and now() - last_change > 1.5 then idle_since = last_change; return true end
        return false
    end
    if gen.idle() and gen.done_count() > 0 then
        idle_since = idle_since or now()
        return now() - idle_since > 1.5
    end
    idle_since = nil
    return false
end, 1e9, o.timeout or 300)
-- окно сравнения кадров: первые W секунд от открытия мира (меши/свет движок досчитывает и после простоя очереди)
local W = o.window or 6
if now() - t_open < W then app.sleep(W - (now() - t_open)) end
local rec = gen.rec
gen.record(false)
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
        :format(stock and tostring(world.get_generator()) or gen.cfg.backend, ts, #fr, ts > 0 and #fr / ts or 0, q(0.5), q(0.95),
            q(0.99), worst * 1000, slow, world.count_chunks()))
end
-- кадры до момента простоя
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
local T = gen.total
local n = T.chunks
local function per(v) return n > 0 and v / n * 1000 or 0 end
local span = (T.t_last and T.t_first) and (T.t_last - T.t_first) or 0
log(("generation %s: ok=%s, %d chunks (world.count_chunks %d) in %.2f s from world open (%.2f s first..last chunk) = %.1f ch/s; frames %d, avg fps %.1f, frame ms p50 %.1f p95 %.1f max %.1f, >33 ms: %d; Lua ms/chunk: read %.3f copy %.3f decode %.3f encode %.3f set %.3f total %.3f; batches %d; mem %.1f MB")
    :format(stock and tostring(world.get_generator()) or gen.cfg.backend, tostring(ok), n, world.count_chunks(), (idle_since or now()) - t_open, span,
        span > 0 and (n - 1) / span or 0, nf, tsum > 0 and nf / tsum or 0, pct(0.5), pct(0.95), pct(1.0), slow,
        per(T.read), per(T.copy), per(T.decode), per(T.encode), per(T.set),
        per(T.read + T.copy + T.decode + T.encode + T.set), T.batches, collectgarbage("count") / 1024))
if n > 0 and T.bytes then
    log(("payload: set_chunk_data avg %.0f B (gzip), extrle16 avg %.0f B, raw 262144 B"):format(T.bytes / n, T.rle / n))
end
local ah = gen.area_hash(-R, -R, R, R)
log(("area hash [%d..%d]^2 = %s"):format(-R, R, ah and bit.tohex(ah) or "incomplete"))
local parts = {}
for _, c in ipairs(parity_list) do
    local h = gen.hash_of(c[1], c[2])
    parts[#parts + 1] = ("%d,%d=%s"):format(c[1], c[2], h and bit.tohex(h) or "-")
end
log("chunk hashes " .. table.concat(parts, " "))
-- то же, но данными, которые хранит движок (world.get_chunk_data после set_chunk_data: кодирует сам движок)
local codec = require "gpu_worldgen:codec"
parts = {}
for _, c in ipairs(parity_list) do
    local d = world.get_chunk_data(c[1], c[2])
    parts[#parts + 1] = ("%d,%d=%s"):format(c[1], c[2], d and bit.tohex(codec.fnv(d)) or "-")
end
log("engine chunk hashes now " .. table.concat(parts, " "))
parts = {}
for _, c in ipairs(parity_list) do
    local h = gen.engine_hash[gen.key(c[1], c[2])]
    parts[#parts + 1] = ("%d,%d=%s"):format(c[1], c[2], h and bit.tohex(h) or "-")
end
log("engine chunk hashes at write " .. table.concat(parts, " "))

if (o.bench or 1) ~= 0 and (o.backend or "gpu") == "gpu" and not stock then
    -- генерацию на паузу: GPU-пакет мог уйти на чанки за квадратом — дождаться его чтения
    gen.hold(true)
    app.sleep_until(function() return gpu.pending == nil end, 600, 20)
    gen.pause(true)
    bench.gpu_cost(app.tick, 120)
    bench.readback(app.tick)
    bench.density(app.tick, 0, 0)
    bench.density(app.tick, -2, 2)
    bench.parity(parity_list)
    gen.pause(false)
    gen.hold(false)
end

if (o.views or 1) ~= 0 then
    local vs = o.view_s or 4
    local function yaw_to(dx, dz) return math.deg(math.atan2(-dx, -dz)) end
    local function look(name, x, y, z, yaw, pitch, extra)
        player.set_flight(0, true)
        player.set_noclip(0, true)
        player.set_pos(0, x, y, z)
        player.set_vel(0, 0, 0, 0)
        player.set_rot(0, yaw, pitch, 0)
        app.tick(); app.tick()
        local d = player.get_dir(0)
        log(("view %s: pos %.1f %.1f %.1f yaw %.0f pitch %.0f dir %.2f %.2f %.2f%s"):format(name, x, y, z, yaw, pitch,
            d[1], d[2], d[3], extra or ""))
        app.sleep(vs)
    end
    -- рельеф: над углом квадрата [-R, R]^2, взгляд к центру и вниз
    local top = 0
    for x = -R * 16, R * 16 + 15, 8 do
        for z = -R * 16, R * 16 + 15, 8 do top = math.max(top, gen.surface_y(x, z)) end
    end
    local c0 = -R * 16 - 8
    look("relief", c0, top + 12, c0, yaw_to(1, 1), -18, (" (max surface %d)"):format(top))
    -- пещера: воздух под поверхностью (камень сверху), откуда дальше всего видно по горизонтали
    local best
    local dirs = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }
    for x = -R * 16, R * 16 + 15, 2 do
        for z = -R * 16, R * 16 + 15, 2 do
            local s = gen.surface_y(x, z)
            for y = s - 8, 10, -2 do
                if block.get(x, y, z) == 0 and block.get(x, y + 1, z) == 0 and block.get(x, y + 6, z) ~= 0 then
                    for _, d in ipairs(dirs) do
                        local len = 0
                        while len < 24 and block.get(x + d[1] * (len + 1), y + 1, z + d[2] * (len + 1)) == 0 do len = len + 1 end
                        if not best or len > best.len then best = { x = x, y = y, z = z, len = len, d = d, s = s } end
                    end
                end
            end
        end
    end
    if best then
        look("cave", best.x + 0.5, best.y + 0.1, best.z + 0.5, yaw_to(best.d[1], best.d[2]), -5,
            (" (open %d blocks, surface %d)"):format(best.len, best.s))
    else
        log("view cave: no cave found")
    end
end

if (o.stay or 0) > 0 then app.sleep(o.stay) end
log("done")
