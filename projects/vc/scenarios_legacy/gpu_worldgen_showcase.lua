-- Витрина пресетов gpu_worldgen (12.10, gpu_show): новый мир на пресете (mountains | caves | islands | classic),
-- генерация зоны загрузки на GPU, замеры (как gpu_worldgen_world.lua), хэш области (детерминизм), цена GPU-прохода
-- пресета, затем витринные точки камеры для F2F shot (маркеры «view <имя>»).
-- Лаборатория: tools/scenarios/gpu_worldgen_showcase.py (аренда wasmrt engine_rt, --param engine=v032).
-- Параметры — export:wasmrt_manifest.txt / export:gpu_worldgen.txt, строки key=value (через ';'):
--   preset (mountains), seed (по пресету), load_distance (8), radius (3 — квадрат хэша и поиска точек), views (1),
--   view_s (4 — сколько стоять на точке), bench (1 — gpu_cost), timeout (300), stay (0), hud (0), budget_ms, target_fps,
--   frame_w/h (потолок прохода, умолчание пака 768x432), fit (0 — проход на всю раскладку), p_<СЛОТ> (перекрыть параметр пресета, опыты)
-- Размер кадра задаёт аренда (--param size=…); витринные кадры снимаются 1408x902 (gpu_worldgen_showcase.py), замеры —
-- 854x480 (стандарт лаборатории, как в README пака).
-- Маркеры лога: [gpu_worldgen] ready | spawn … | generation … | area hash … | view <имя>: … | done
local o = {}
for _, f in ipairs({ "export:wasmrt_manifest.txt", "export:gpu_worldgen.txt" }) do
    if file.isfile(f) then
        for k, v in file.read(f):gmatch("([%w_]+)%s*=%s*([^;\r\n]*)") do
            o[k] = tonumber(v) or v
        end
    end
end
local function log(s) debug.log("[gpu_worldgen] " .. s) end
-- light=1 — с паком-дополнением gpu_worldgen_light (свет в шейдерах пака, небесный свет движка выключен свойствами блоков)
local packs = { "base", "gpu_worldgen" }
if (o.light or 0) ~= 0 then packs[#packs + 1] = "gpu_worldgen_light" end
if o.extra_pack and o.extra_pack ~= "" then packs[#packs + 1] = o.extra_pack end
app.config_packs(packs)
app.load_content()
log("packs: " .. table.concat(packs, ","))
-- hold_s — пауза до открытия мира (драйвер успевает включить F2F perf по маркеру «prestart»)
if (o.hold_s or 0) > 0 then
    log("prestart")
    app.sleep(o.hold_s)
end

local launch = require "gpu_worldgen:launch"
local gen = require "gpu_worldgen:gen"
-- rle=1 — поток extrle16 считает GPU (цепочка проходов), rle_verify=N — сверка байт с Lua-кодером на N чанках
if o.rle ~= nil then gen.cfg.rle = o.rle ~= 0 end
if o.rle_verify ~= nil then gen.cfg.rle_verify = o.rle_verify end
if o.rle_rows ~= nil then gen.cfg.rle_rows = o.rle_rows end
-- pace=frame — темп записи по длительности кадра (gen.cfg.pace)
if o.pace ~= nil then gen.cfg.pace = o.pace end
local bench = require "gpu_worldgen:bench"
local gpu = require "gpu_worldgen:gpu"
local presets = require "gpu_worldgen:presets"

local PRESET = o.preset or "mountains"
local pr = presets.get(PRESET)
-- перекрытие параметров пресета для опытов: p_<СЛОТ>=значение (например p_LAMPP=0)
for k, v in pairs(o) do
    local slot = k:match("^p_(%w+)$")
    if slot then pr.values[slot] = v; debug.log(("[gpu_worldgen] override %s.%s = %s"):format(PRESET, slot, tostring(v))) end
end
local R = o.radius or 3
local seed = o.seed and tostring(o.seed) or pr.seed
local FIT = nil
if o.fit ~= nil then FIT = o.fit ~= 0 end
local old_ld = launch.open(app, {
    preset = PRESET,
    world = "gpuwg_show_" .. PRESET .. "_" .. seed,
    fresh = true,
    seed = seed,
    load_distance = o.load_distance or 8,
    budget_ms = o.budget_ms, target_fps = o.target_fps, frame_w = o.frame_w, frame_h = o.frame_h,
    fit = FIT,   -- fit=0 — картинка прохода на всю раскладку (как до 13.10)
    hud = (o.hud or 0) ~= 0,
    flight = true,
})
-- туман мешает видеть рельеф (0.32: graphics.enable-fog; settings.toml аренды, не пользователя)
pcall(app.set_setting, "graphics.enable-fog", false)
pcall(app.set_setting, "graphics.fog-curve", 6)

local now = time.precise_time or os.clock
gen.record(true)
local t_open = now()
local idle_since
local ok = pcall(app.sleep_until, function()
    if gen.idle() and gen.done_count() > 0 then
        idle_since = idle_since or now()
        return now() - idle_since > 1.5
    end
    idle_since = nil
    return false
end, 1e9, o.timeout or 300)
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
        :format(PRESET, ts, #fr, ts > 0 and #fr / ts or 0, q(0.5), q(0.95), q(0.99), worst * 1000, slow, world.count_chunks()))
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
local T = gen.total
local n = T.chunks
local function per(v) return n > 0 and v / n * 1000 or 0 end
local span = (T.t_last and T.t_first) and (T.t_last - T.t_first) or 0
log(("generation %s: ok=%s, %d chunks (world.count_chunks %d) in %.2f s from world open (%.2f s first..last chunk) = %.1f ch/s; frames %d, avg fps %.1f, frame ms p50 %.1f p95 %.1f max %.1f, >33 ms: %d; Lua ms/chunk: read %.3f copy %.3f decode %.3f encode %.3f set %.3f total %.3f; batches %d; mem %.1f MB")
    :format(PRESET, tostring(ok), n, world.count_chunks(), (idle_since or now()) - t_open, span,
        span > 0 and (n - 1) / span or 0, nf, tsum > 0 and nf / tsum or 0, pct(0.5), pct(0.95), pct(1.0), slow,
        per(T.read), per(T.copy), per(T.decode), per(T.encode), per(T.set),
        per(T.read + T.copy + T.decode + T.encode + T.set), T.batches, collectgarbage("count") / 1024))
if n > 0 and T.bytes then
    log(("payload: set_chunk_data avg %.0f B (gzip), extrle16 avg %.0f B, raw 262144 B"):format(T.bytes / n, T.rle / n))
end
if gen.cfg.rle then
    local V = gen.verify
    log(("rle: fallback (stream larger than the tile slot) %d chunks; verify %d/%d equal; engine check %s/%s"):format(
        V.fallback, V.equal, V.n, tostring(V.engine_equal), tostring(V.engine_n)))
end
if (o.light or 0) ~= 0 and (o.light_check or 0) > 0 then
    local ok, lm = pcall(require, "gpu_worldgen_light:light")
    if ok then
        lm.flush()
        local n, bad, ex = lm.check(o.light_check)
        log(("light check: %d columns, region != block.get: %d%s"):format(n, bad, ex and ("; e.g. " .. ex) or ""))
    end
end
local ah = gen.area_hash(-R, -R, R, R)
log(("area hash [%d..%d]^2 = %s"):format(-R, R, ah and bit.tohex(ah) or "incomplete"))
local parts = {}
for _, c in ipairs({ { 0, 0 }, { 1, 0 }, { 0, -1 }, { -2, 2 } }) do
    local h = gen.hash_of(c[1], c[2])
    parts[#parts + 1] = ("%d,%d=%s"):format(c[1], c[2], h and bit.tohex(h) or "-")
end
log("chunk hashes " .. table.concat(parts, " "))

-- состав блоков области (сколько чего поставил пресет) — по массиву движка, шаг 1, только [-1..1]^2
do
    local cnt = {}
    for x = -16, 31 do
        for z = -16, 31 do
            for y = 0, 255 do
                local id = block.get(x, y, z)
                cnt[id] = (cnt[id] or 0) + 1
            end
        end
    end
    local list = {}
    for id, c in pairs(cnt) do list[#list + 1] = { block.name(id) or tostring(id), c } end
    table.sort(list, function(a, b) return a[2] > b[2] end)
    local s = {}
    for _, e in ipairs(list) do s[#s + 1] = e[1] .. "=" .. e[2] end
    log("blocks [-1..1]^2: " .. table.concat(s, " "))
end

if (o.bench or 1) ~= 0 then
    gen.hold(true)
    app.sleep_until(function() return gpu.pending == nil end, 600, 20)
    gen.pause(true)
    bench.gpu_cost(app.tick, 120, o.cost_n)   -- cost_n — плиток в пакете (умолчание — весь проход)
    gen.pause(false)
    gen.hold(false)
end

-- устойчивый режим: все загруженные чанки снова в очередь, как только очередь пуста, sustain_s секунд — чанков/с, fps,
-- Lua мс/чанк в установившемся потоке (драйвер меряет загрузку ПК/GPU между маркерами «sustain start/end»)
if (o.sustain_s or 0) > 0 then
    local t0 = now()
    local c0 = gen.total.chunks
    local T0 = {}
    for k, v in pairs(gen.total) do T0[k] = v end
    gen.record(true)
    gen.cfg.place_player = false   -- classic ставит игрока на (0,0) при каждой записи этого чанка — не в замере
    log(("sustain start: %d s"):format(o.sustain_s))
    while now() - t0 < o.sustain_s do
        if gen.idle() then gen.requeue_all() end
        app.tick()
    end
    local el = now() - t0
    local rec2 = gen.rec
    gen.record(false)
    local fr = {}
    for i = 2, #rec2 do fr[#fr + 1] = rec2[i] end
    table.sort(fr)
    local q = function(x) return #fr > 0 and fr[math.max(1, math.ceil(#fr * x))] * 1000 or 0 end
    local T = gen.total
    local n2 = T.chunks - c0
    local function d(k) return n2 > 0 and ((T[k] or 0) - (T0[k] or 0)) / n2 * 1000 or 0 end
    log(("sustain end %s: %d chunks in %.2f s = %.1f ch/s; frames %d, avg fps %.1f, frame ms p50 %.1f p95 %.1f max %.1f; Lua ms/chunk: read %.3f copy %.3f decode %.3f encode %.3f set %.3f total %.3f")
        :format(PRESET, n2, el, n2 / el, #fr, #fr / el, q(0.5), q(0.95), q(1.0), d("read"), d("copy"), d("decode"),
            d("encode"), d("set"), d("read") + d("copy") + d("decode") + d("encode") + d("set")))
end

-- витринные точки ----------------------------------------------------------------------------------------------
local surface_y = gen.surface_y
local WATER, LAVA = block.index("base:water"), block.index("gpu_worldgen:lava")
local function air(id) return id == 0 or id == block.index("base:grass") or id == block.index("base:flower") end
local function solid(id) return id ~= 0 and id ~= -1 and not air(id) and id ~= WATER and id ~= LAVA end
local function yaw_pitch(dx, dy, dz)
    return math.deg(math.atan2(-dx, -dz)), math.deg(math.atan2(dy, math.sqrt(dx * dx + dz * dz)))
end
local vs = o.view_s or 4
local function look(name, x, y, z, yaw, pitch, extra)
    player.set_flight(0, true)
    player.set_noclip(0, true)
    player.set_pos(0, x, y, z)
    player.set_vel(0, 0, 0, 0)
    player.set_rot(0, yaw, pitch, 0)
    app.tick(); app.tick()
    -- чанки вокруг новой точки: дождаться очереди (не дольше 10 с)
    pcall(app.sleep_until, function() return gen.idle() end, 1e9, 10)
    log(("view %s: pos %.1f %.1f %.1f yaw %.0f pitch %.0f%s"):format(name, x, y, z, yaw, pitch, extra or ""))
    app.sleep(vs)
end
local function look_at(name, cx, cy, cz, tx, ty, tz, extra)
    local yaw, pitch = yaw_pitch(tx - cx, ty - cy, tz - cz)
    look(name, cx, cy, cz, yaw, pitch, extra)
end
-- камера в стороне от точки (tx, ty, tz): луч от точки (с подъёмом rise блоков на dist) по 16 направлениям,
-- камера — в последней свободной точке луча (сама точка и блок над ней — воздух), выбирается самый длинный луч
local function from_side(tx, ty, tz, dist, rise)
    local best
    rise = rise or 0
    for i = 0, 15 do
        local a = i * math.pi / 8
        local dx, dz = math.sin(a), math.cos(a)
        local last = nil
        for d = 3, dist do
            local px, py, pz = tx + 0.5 + dx * d, ty + 0.5 + rise * d / dist, tz + 0.5 + dz * d
            local fx, fy, fz = math.floor(px), math.floor(py), math.floor(pz)
            local b0, b1 = block.get(fx, fy, fz), block.get(fx, fy + 1, fz)
            if not (air(b0) and air(b1)) then break end
            last = { px, py, pz, d }
        end
        if last and (not best or last[4] > best[4]) then best = last end
    end
    if not best then return tx + 0.5, ty + 0.5, tz + 0.5, 0 end
    return best[1], best[2], best[3], best[4]
end

local X0, X1 = -R * 16, R * 16 + 15
local spawn = { player.get_pos(0) }
local srot = { player.get_rot(0) }
local function top_of_area()
    local top = 0
    for x = X0, X1, 4 do
        for z = X0, X1, 4 do top = math.max(top, surface_y(x, z)) end
    end
    return top
end

-- нависание: столб «твёрдое — воздух (g >= 6) — твёрдое»; балл — высота просвета и толщина крыши
local function find_overhang(minh)
    local cands = {}
    for x = X0, X1, 2 do
        for z = X0, X1, 2 do
            local y = surface_y(x, z)
            -- вниз по крыше
            local roof_top = y
            while y > 1 and solid(block.get(x, y, z)) do y = y - 1 end
            local roof = roof_top - y
            local gap_top = y
            while y > 1 and not solid(block.get(x, y, z)) and block.get(x, y, z) ~= WATER do y = y - 1 end
            local gap = gap_top - y
            if roof >= 2 and gap >= (minh or 6) and y > 1 then
                cands[#cands + 1] = { x = x, z = z, y0 = y, y1 = gap_top, roof = roof, gap = gap, sc = gap + math.min(roof, 12) }
            end
        end
    end
    table.sort(cands, function(a, b) return a.sc > b.sc end)
    return cands
end

-- вода в воздухе (водопад): вода выше min_y, сбоку воздух
local function find_fall(min_y)
    local best
    for x = X0, X1 do
        for z = X0, X1 do
            local s = surface_y(x, z)
            for y = math.min(250, s + 120), min_y, -3 do
                local na = (air(block.get(x + 1, y, z)) and 1 or 0) + (air(block.get(x - 1, y, z)) and 1 or 0)
                    + (air(block.get(x, y, z + 1)) and 1 or 0) + (air(block.get(x, y, z - 1)) and 1 or 0)
                if block.get(x, y, z) == WATER and na >= 2 then
                    local len = 0
                    while block.get(x, y - len, z) == WATER do len = len + 1 end
                    if not best or len > best.len then best = { x = x, y = y, z = z, len = len } end
                    break
                end
            end
        end
    end
    return best
end

-- зал пещеры (как gen.find_spawn для caves), не ближе min_d к точке (ax, az)
local function find_hall(ax, az, min_d)
    local best
    for x = X0, X1, 3 do
        for z = X0, X1, 3 do
            if not ax or (x - ax) ^ 2 + (z - az) ^ 2 >= min_d ^ 2 then
                local s = surface_y(x, z)
                for y = s - 10, 13, -1 do
                    if block.get(x, y, z) == 0 and block.get(x, y + 1, z) == 0 and block.get(x, y + 2, z) == 0
                        and solid(block.get(x, y - 1, z)) then
                        local h = 0
                        while h < 24 and block.get(x, y + h, z) == 0 do h = h + 1 end
                        local l1, l2, bd = 0, 0, 0
                        for i = 0, 7 do
                            local a = i * math.pi / 4
                            local l = gen.free_ray(x + 0.5, y + 1.6, z + 0.5, math.sin(a), 0, math.cos(a), 40)
                            if l > l1 then l1, l2, bd = l, l1, a elseif l > l2 then l2 = l end
                        end
                        local sc = l1 + l2 + h
                        if not best or sc > best.sc then best = { x = x, y = y, z = z, sc = sc, a = bd, l = l1, h = h } end
                    end
                end
            end
        end
    end
    return best
end

-- жидкость в пещере: вода/лава под каменным потолком, над ней воздух
local function find_lake(id_fluid)
    local best
    for x = X0, X1, 2 do
        for z = X0, X1, 2 do
            local s = surface_y(x, z)
            for y = s - 12, 2, -1 do
                if block.get(x, y, z) == id_fluid and block.get(x, y + 1, z) == 0 and block.get(x, y + 2, z) == 0 then
                    local open = 0
                    for i = 0, 7 do
                        local a = i * math.pi / 4
                        open = open + gen.free_ray(x + 0.5, y + 2.5, z + 0.5, math.sin(a), 0, math.cos(a), 24)
                    end
                    if not best or open > best.open then best = { x = x, y = y, z = z, open = open } end
                    break
                end
            end
        end
    end
    return best
end

if (o.views or 1) ~= 0 then
    look("spawn", spawn[1], spawn[2] + 1.6 - 1.6, spawn[3], srot[1] or 0, srot[2] or -10, " (preset spawn)")
    local top = top_of_area()
    local c0 = X0 - 10
    if PRESET == "mountains" or PRESET == "classic" then
        look_at("vista", c0, math.min(top + 6, 250), c0, X1, top * 0.45, X1, (" (max surface %d)"):format(top))
        -- нависание, открытое вбок: камера не ближе 20 блоков, иначе следующий кандидат
        local shown = false
        for i, oh in ipairs(find_overhang(8)) do
            if i > 40 then break end
            local my = (oh.y0 + oh.y1) / 2
            local cx, cy, cz, l = from_side(oh.x, oh.y0 + 2, oh.z, 44, 8)
            if l >= 20 then
                look_at("overhang", cx, cy, cz, oh.x + 0.5, my, oh.z + 0.5,
                    (" (column %d %d: gap %d..%d, roof %d, camera at %d blocks)"):format(oh.x, oh.z, oh.y0, oh.y1, oh.roof, l))
                shown = true
                break
            end
        end
        if not shown then log("no view overhang: none found") end
        local f = find_fall(70)
        if f then
            local cx, cy, cz, l = from_side(f.x, f.y - f.len / 2, f.z, 22, 4)
            look_at("waterfall", cx, cy, cz, f.x + 0.5, f.y - f.len * 0.5, f.z + 0.5,
                (" (water column %d %d %d, length %d)"):format(f.x, f.y, f.z, f.len))
        else
            log("no view waterfall: none found")
        end
    elseif PRESET == "caves" then
        look_at("surface", c0, top + 14, c0, 8, top - 12, 8, (" (max surface %d)"):format(top))
        -- провал к залам: самый низкий открытый небу столб (не вода)
        local pit
        for x = X0, X1, 2 do
            for z = X0, X1, 2 do
                local s = surface_y(x, z)
                if s > 0 and block.get(x, s, z) ~= WATER and (not pit or s < pit.s) then pit = { x = x, z = z, s = s } end
            end
        end
        if pit and pit.s < pr.values.BASE - 20 then
            local cx, cy, cz = from_side(pit.x, pr.values.BASE + 8, pit.z, 26, 4)
            look_at("sinkhole", cx, cy, cz, pit.x + 0.5, pr.values.BASE - 22, pit.z + 0.5,
                (" (open to sky down to y %d at %d %d)"):format(pit.s, pit.x, pit.z))
        else
            log("no view sinkhole: lowest open column y " .. tostring(pit and pit.s))
        end
        local h = find_hall(spawn[1], spawn[3], 40)
        if h then
            look("hall", h.x + 0.5, h.y + 1.6, h.z + 0.5, math.deg(math.atan2(-math.sin(h.a), -math.cos(h.a))), -4,
                (" (score %d, open %d, height %d)"):format(h.sc, h.l, h.h))
        else
            log("no view hall: none found")
        end
        local lk = find_lake(LAVA) or find_lake(WATER)
        local lk2 = find_lake(WATER)
        for i, L in ipairs({ lk, lk2 ~= lk and lk2 or nil }) do
            if L then
                local cx, cy, cz, l = from_side(L.x, L.y + 3, L.z, 14, 0)
                look_at(i == 1 and "lake" or "lake2", cx, cy, cz, L.x + 0.5, L.y, L.z + 0.5,
                    (" (%s at %d %d %d, open %d)"):format(block.name(block.get(L.x, L.y, L.z)), L.x, L.y, L.z, L.open))
            end
        end
    else -- islands
        local lvl = (pr.values.Y0 + pr.values.DY)
        look_at("level", c0 - 20, lvl + 6, c0 - 20, 8, lvl - 10, 8, (" (layer y %d)"):format(lvl))
        -- самая низкая подошва острова в области: камера под ней и в стороне, взгляд вверх
        local low
        for x = X0, X1, 2 do
            for z = X0, X1, 2 do
                local y = 1
                while y < 250 and not solid(block.get(x, y, z)) do y = y + 1 end
                if y < 250 and (not low or y < low.y) then low = { x = x, y = y, z = z } end
            end
        end
        if low then
            look_at("below", low.x + 18.5, math.max(5, low.y - 26), low.z + 18.5, low.x + 0.5, low.y + 10, low.z + 0.5,
                (" (lowest underside %d %d %d)"):format(low.x, low.y, low.z))
        end
        local f = find_fall(10)
        if f then
            local cx, cy, cz, l = from_side(f.x, f.y - 6, f.z, 26, 2)
            look_at("waterfall", cx, cy, cz, f.x + 0.5, f.y - 12, f.z + 0.5,
                (" (water column %d %d %d, length %d)"):format(f.x, f.y, f.z, f.len))
        else
            log("no view waterfall: none found")
        end
    end
end

if (o.stay or 0) > 0 then app.sleep(o.stay) end
log("done")
