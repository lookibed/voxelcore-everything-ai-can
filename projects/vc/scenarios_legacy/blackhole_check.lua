-- Проверка пака blackhole в лаборатории (tools/scenarios/blackhole_check.py), VoxelCore 0.32 F2F:
--   lab lease wasmrt engine_rt --param engine=v032 --param packs=["blackhole"] --param script=blackhole_check.lua
--       --param ready_marker="\[blackhole\] ready" --param audio=true --start
-- Новый мир base + blackhole на стоковом генераторе base:demo. Шаги:
--   (a) граната со скоростью на площадке со стеной: отскоки, детонация -> дыра; (a2) бросок предметом по ПКМ (F2F input)
--   (b) дыра у поверхности + 3 base:drop рядом: замеры на 5/15/30 с, тяга игрока
--   (c) вторая дыра рядом -> слияние; (e) fps при 1 и 3 дырах; (d) коллапс -> возвращённые блоки
-- Кадры: маркеры «[blackhole] view <имя>» — драйвер снимает F2F shot, пока сценарий держит камеру (hold секунд).
-- Параметры — export:wasmrt_manifest.txt (key=value через ;): seed, perf_s (8), hold (2.5), use (1), quick (0).
local o = {}
if file.isfile("export:wasmrt_manifest.txt") then
    for k, v in file.read("export:wasmrt_manifest.txt"):gmatch("([%w_]+)%s*=%s*([^;\r\n]*)") do o[k] = tonumber(v) or v end
end
local function log(s) debug.log("[blackhole] " .. s) end

-- звук в тестовом экземпляре: бэкенд включён (speaker id > 0), но громкость 0 — пользователь ничего не слышит
pcall(app.set_setting, "audio.volume-master", 0)
pcall(app.set_setting, "graphics.enable-fog", false)
-- adv=1: графика как у пользователя (advanced-render, ssao 2, тени 3) — G-буфер, глубина в пост-эффекте
if (o.adv or 0) ~= 0 then
    pcall(app.set_setting, "graphics.advanced-render", true)
    pcall(app.set_setting, "graphics.ssao", 2)
    pcall(app.set_setting, "graphics.shadows-quality", 3)
end

app.config_packs({ "base", "blackhole" })
app.load_content()
local wname = "bh_check_" .. tostring(o.seed or "20261015")
app.new_world(wname, tostring(o.seed or "20261015"), "base:demo")
world.set_day_time(0.5)
world.set_day_time_speed(0)

local api = require "blackhole:api"
local core = require "blackhole:core"
log(("scenario: world %s generator %s, core instance %d, advanced-render %s ssao %s shadows %s"):format(wname,
    tostring(world.get_generator()), core.INSTANCE, tostring(app.get_setting("graphics.advanced-render")),
    tostring(app.get_setting("graphics.ssao")), tostring(app.get_setting("graphics.shadows-quality"))))

-- ждать загрузки чанков: число не меняется 2 с
do
    local last, since = -1, time.uptime()
    app.sleep_until(function()
        local c = world.count_chunks()
        if c ~= last then last, since = c, time.uptime() end
        return c > 0 and time.uptime() - since > 2.0
    end, 1e9, 120)
    log(("chunks loaded %d"):format(world.count_chunks()))
end
log("ready")
-- проба audio.play_stream с путём точки входа (config:): speaker id, is_playing, get_duration — затем stop
do
    local x, y, z = player.get_pos(0)
    local path = "config:blackhole/sfx/hum_v1.wav"
    local id = audio.play_stream(path, x, y, z, 1.0, 1.0, "regular", false)
    app.tick(); app.tick()
    log(("audio probe: play_stream(%s) speaker %d is_playing %s duration %.2f s time %.3f count_speakers %d count_streams %d")
        :format(path, id, tostring(audio.is_playing(id)), audio.get_duration(id), audio.get_time(id),
            audio.count_speakers(), audio.count_streams()))
    audio.stop(id)
end

player.set_flight(0, true)
player.set_noclip(0, false)

local function surface(x, z)
    for y = 200, 1, -1 do
        local id = block.get(x, y, z)
        if id > 0 and not block.is_replaceable_at(x, y, z) then return y end
    end
    return 40
end
local HOLD = o.hold or 2.5

-- держать камеру: игрок в точке, взгляд на цель, скорость 0 (дыра тянет — каждый кадр вернуть)
local function look_from(pos, target)
    local d = vec3.sub(target, { pos[1], pos[2] + 1.6, pos[3] })
    local yaw = math.deg(math.atan2(-d[1], -d[3]))
    local pitch = math.deg(math.atan2(d[2], math.sqrt(d[1] * d[1] + d[3] * d[3])))
    player.set_pos(0, pos[1], pos[2], pos[3])
    player.set_vel(0, 0, 0, 0)
    player.set_rot(0, yaw, pitch, 0)
end
local function hold_view(name, pos, target, secs, extra)
    look_from(pos, target)
    app.tick(); app.tick(); app.tick()
    log(("view %s: cam %.1f %.1f %.1f -> %.1f %.1f %.1f%s; shader %d: %s"):format(name, pos[1], pos[2], pos[3], target[1],
        target[2], target[3], extra or "", core.stats.shader_n, core.fx_last or "-"))
    -- держать камеру, пока драйвер не снимет кадр (файл-квитанция export:bh_ack_<имя>), но не меньше secs
    local t0 = time.uptime()
    local ack = "export:bh_ack_" .. name
    while (time.uptime() - t0 < (secs or 0.5) or not file.exists(ack)) and time.uptime() - t0 < 15 do
        look_from(pos, target)
        app.tick()
    end
    log(("view %s held %.2f s, ack %s"):format(name, time.uptime() - t0, tostring(file.exists(ack))))
end
local function wait(secs, fn)
    local t0 = time.uptime()
    while time.uptime() - t0 < secs do
        if fn then fn() end
        app.tick()
    end
end
-- игрока — подальше (вне радиуса тяги) и над всем, но в зоне загрузки чанков (load-distance 4 = 64 блока)
local PARK = { 0, surface(0, -16) + 45, -16 }
local function park()
    player.set_pos(0, PARK[1], PARK[2], PARK[3])
    player.set_vel(0, 0, 0, 0)
end

local function hole_line(tag, uid)
    local s = api.state(uid)
    if not s then log(("%s: hole %d gone"):format(tag, uid)); return end
    local slot = gfx.posteffects.index("blackhole:holes")
    log(("%s: hole %d phase %s mass %.0f speed %.4g pos %.2f %.2f %.2f radius %.2f horizon %.2f eaten_blocks %d absorbed_blocks %d debris_live %d (all %d) entities_absorbed %d path %s posteffect slot %d active %s shader_holes %d sand %d speakers %d")
        :format(tag, uid, s.phase, s.mass, vec3.length(s.vel), s.center[1], s.center[2], s.center[3], core.suck_radius(s.mass), core.horizon(s.mass),
            s.eaten_blocks, s.absorbed_blocks, #s.debris, core.ndebris, s.eaten_entities, s.path,
            slot, tostring(gfx.posteffects.is_active(slot)), core.stats.shader_n, s.sand or 0, audio.count_speakers()))
end

-- отладка тяги игрока (pulltest=1): дыра, игрок в 8 блоках, позиции по кадрам, ручной set_vel
if (o.pulltest or 0) ~= 0 then
    local sy0 = surface(6, 6)
    local c = { 6.5, sy0 + 0.5, 6.5 }
    local h = api.spawn(c, 400)
    wait(2.0, park)
    local x0, y0, z0 = c[1] + 8, c[2] - 0.9, c[3]
    player.set_pos(0, x0, y0, z0); player.set_vel(0, 0, 0, 0)
    app.tick()
    local ids = player.get_all_in_radius(c, 30)
    log(("pulltest: get_all_in_radius -> %s (type %s), flight %s noclip %s"):format(json.tostring(ids), type(ids),
        tostring(player.is_flight(0)), tostring(player.is_noclip(0))))
    for i = 1, 6 do
        wait(0.2)
        local x, y, z = player.get_pos(0)
        local vx, vy, vz = player.get_vel(0)
        log(("pulltest t=%.1f pos %.2f %.2f %.2f vel %.2f %.2f %.2f"):format(i * 0.2, x, y, z, vx, vy, vz))
    end
    entities.get(h):despawn()
    player.set_pos(0, x0, y0, z0)
    player.set_vel(0, 5, 0, 0)
    wait(0.5)
    local x, y, z = player.get_pos(0)
    log(("pulltest manual set_vel 5: dx %.2f in 0.5 s"):format(x - x0))
    log("done (pulltest)")
    return
end
-- ============================================================ (a) граната
local ax, az = -24, 0
local top = 0
for x = ax - 8, ax + 8 do for z = az - 4, az + 4 do top = math.max(top, surface(x, z)) end end
local py = top + 6
for x = ax - 7, ax + 7 do
    for z = az - 3, az + 3 do
        block.set(x, py, z, block.index("base:stone"), 0)
        for y = py + 1, py + 6 do block.set(x, y, z, 0, 0) end
    end
end
local WX = ax + 2
for y = py + 1, py + 4 do for z = az - 3, az + 3 do block.set(WX, y, z, block.index("base:brick"), 0) end end
log(("arena: platform y %d x %d..%d, wall x %d"):format(py, ax - 7, ax + 7, WX))
park()
wait(0.5)
local g = api.throw({ ax - 5.5, py + 2.5, az + 0.5 }, { 14, 2.5, 0.3 })
log(("grenade spawned uid %d vel 14 2.5 0.3"):format(g))
local hole_a
do
    local t0 = time.uptime()
    -- камера сбоку площадки
    while entities.exists(g) and time.uptime() - t0 < 6 do
        look_from({ ax, py + 3, az - 9 }, { ax, py + 1, az })
        app.tick()
    end
    for uid, s in pairs(api.all()) do
        if math.abs(s.center[1] - ax) < 10 and math.abs(s.center[2] - py) < 6 then hole_a = uid end
    end
    log(("grenade gone after %.2f s, hole from grenade: %s"):format(time.uptime() - t0, tostring(hole_a)))
end
if hole_a then
    wait(3.0, function() look_from({ ax, py + 3, az - 9 }, { ax, py + 1, az }) end)
    hole_line("grenade hole 3s", hole_a)
    entities.get(hole_a):despawn()
    log(("grenade hole %d removed for the next steps"):format(hole_a))
end
park()
wait(0.5)

-- ============================================================ (a2) бросок предметом: ПКМ через F2F input
if (o.use or 1) ~= 0 then
    local invid = player.get_inventory(0)
    inventory.set(invid, 0, item.index("blackhole:grenade"), 4)
    player.set_selected_slot(0, 0)
    local n0 = 0
    local gid = entities.def_index("blackhole:grenade_thrown")
    local function count_gren()
        local n = 0
        for _, e in pairs(entities.get_all()) do if e:def_index() == gid then n = n + 1 end end
        return n
    end
    n0 = count_gren()
    local up = { ax, py + 1, az - 5 }
    look_from(up, { ax + 3, py + 1, az })
    wait(0.8, function() look_from(up, { ax + 3, py + 1, az }) end)
    log("input rmb: press right mouse button now")
    local t0, n1 = time.uptime(), n0
    while time.uptime() - t0 < 6 do
        look_from(up, { ax + 3, py + 1, az })
        app.tick()
        n1 = math.max(n1, count_gren())
        if n1 > n0 then break end
    end
    local _, cnt = inventory.get(invid, 0)
    log(("item use: grenades before %d after %d, slot count now %s"):format(n0, n1, tostring(cnt)))
    -- дождаться детонации и убрать дыру
    wait(3.5)
    for uid, s in pairs(api.all()) do
        if math.abs(s.center[1] - ax) < 20 then log(("item grenade hole %d (mass %.0f) removed"):format(uid, s.mass)); entities.get(uid):despawn() end
    end
    inventory.set(invid, 0, 0, 0)
    park()
end

if (o.quick or 0) ~= 0 then log("done (quick)"); return end

-- ============================================================ (e) fps при 1 и 3 дырах (часы realtime)
local PERF = o.perf_s or 8
local function perf(tag, cam, target)
    -- прогрев
    -- без вертикальной синхронизации (display.framerate 0 — настройка аренды, не пользователя): иначе всё упирается
    -- в 144 Гц монитора и стоимость не видна
    if (o.uncap or 1) ~= 0 then pcall(app.set_setting, "display.framerate", 0) end
    wait(1.0, function() look_from(cam, target) end)
    log(("perf start %s"):format(tag))
    local d = {}
    local l0, f0 = core.stats.logic_s, core.stats.frames
    local b0 = core.stats.blocks
    local t0 = time.uptime()
    while time.uptime() - t0 < PERF do
        look_from(cam, target)
        app.tick()
        d[#d + 1] = time.delta()
    end
    local T = time.uptime() - t0
    table.sort(d)
    local function q(x) return d[math.max(1, math.ceil(#d * x))] * 1000 end
    local nf = core.stats.frames - f0
    log(("perf %s (framerate %s): %d frames in %.2f s = %.1f fps, frame ms p50 %.2f p95 %.2f max %.2f; pack logic %.3f ms/frame; blocks %.1f/s; holes %d, debris %d, shader %d")
        :format(tag, tostring(app.get_setting("display.framerate")), #d, T, #d / T, q(0.5), q(0.95), q(1.0), nf > 0 and (core.stats.logic_s - l0) * 1000 / nf or -1,
            (core.stats.blocks - b0) / T, core.count_holes(), core.ndebris, core.stats.shader_n))
    log(("perf end %s"):format(tag))
    pcall(app.set_setting, "display.framerate", -1)
end
-- ============================================================ волна 2: сверхмассивные, внешность, схлопыватель,
-- instant-спавн, движение, ударная граната, мягкое слияние, быстрое стирание
local function wave2()
    local W = { 0, 0, 92 }
    W[2] = surface(W[1], W[3])
    local PARK2 = { W[1], W[2] + 45, W[3] - 22 }
    local function park2()
        player.set_pos(0, PARK2[1], PARK2[2], PARK2[3])
        player.set_vel(0, 0, 0, 0)
    end
    park2()
    -- дождаться чанков области (block.get = -1 — не загружено)
    local tw = time.uptime()
    app.sleep_until(function()
        park2()
        for _, c in ipairs({ { -24, 74 }, { 24, 74 }, { -24, 118 }, { 24, 118 }, { 0, 92 } }) do
            if block.get(c[1], 1, c[2]) < 0 then return false end
        end
        return true
    end, 1e9, 60)
    W[2] = surface(W[1], W[3])
    log(("w2 area at %d %d %d, chunks ready in %.1f s"):format(W[1], W[2], W[3], time.uptime() - tw))
    log(("w2 formulas: R(1) %.2f R(1500) %.2f R(12000) %.2f R(80000) %.2f (max_radius %d); lifetime(1) %.0f s lifetime(1500) %.0f s lifetime(8000) %.0f s; damping(1) %.3f damping(1000) %.3f 1/s")
        :format(core.suck_radius(1), core.suck_radius(1500), core.suck_radius(12000), core.suck_radius(80000),
            core.cfg.max_radius, core.lifetime(1), core.lifetime(1500), core.lifetime(8000), core.damping(1),
            core.damping(1000)))

    -- ---------------- п.4 instant-спавн: hole_egg простым ПКМ, игрок движется
    do
        local invid = player.get_inventory(0)
        inventory.set(invid, 0, item.index("blackhole:hole_egg"), 4)
        player.set_selected_slot(0, 0)
        local P = { W[1] - 10, W[2] + 20, W[3] - 10 }
        local function run() look_from(P, { P[1] + 10, P[2] + 1.6, P[3] + 10 }); player.set_vel(0, 4, 0, 4) end
        local before = {}
        for u in pairs(api.all()) do before[u] = true end
        wait(0.8, run)
        log("input rmb: press right mouse button now (hole_egg)")
        local t0, hu = time.uptime(), nil
        while time.uptime() - t0 < 6 and not hu do
            run()
            app.tick()
            for u in pairs(api.all()) do if not before[u] then hu = u end end
        end
        if hu then
            local s = api.state(hu)
            local v0 = vec3.length(s.vel)
            wait(1.0, park2)
            s = api.state(hu)
            log(("hole_egg check: hole %d initial speed %.2f, after 1 s speed %.2f mass %.0f, moved to %.1f %.1f %.1f")
                :format(hu, v0, s and vec3.length(s.vel) or -1, s and s.mass or -1, s and s.center[1] or 0,
                    s and s.center[2] or 0, s and s.center[3] or 0))
            if entities.exists(hu) then entities.get(hu):despawn() end
        else
            log("hole_egg check: no hole spawned")
        end
        inventory.set(invid, 0, 0, 0)
        park2()
    end

    -- ---------------- п.6 ударная граната: стена, пол, сущность
    do
        local wy = W[2] + 14
        local wz = W[3] - 30
        for x = -2, 2 do for y = 0, 4 do block.set(W[1] + x, wy + y, wz, block.index("base:brick"), 0) end end
        local function shoot(tag, pos, vel)
            local before = {}
            for u in pairs(api.all()) do before[u] = true end
            local gu = api.throw(pos, vel, nil, "impact_thrown")
            local t0, hu = time.uptime(), nil
            while time.uptime() - t0 < 5 and not hu do
                park2(); app.tick()
                for u in pairs(api.all()) do if not before[u] then hu = u end end
            end
            log(("impact test %s: grenade %d -> hole %s"):format(tag, gu, tostring(hu)))
            if hu and entities.exists(hu) then entities.get(hu):despawn() end
        end
        shoot("wall", { W[1] + 0.5, wy + 2.5, wz - 4.5 }, { 0, 0, 15 })
        local fx, fz = W[1] - 12, W[3] - 30
        shoot("floor", { fx + 0.5, surface(fx, fz) + 6, fz + 0.5 }, { 0, -10, 0 })
        local ex, ez = W[1] + 12, W[3] - 30
        local dp = { ex + 0.5, surface(ex, ez) + 1.3, ez + 0.5 }
        local drop = entities.spawn("base:drop", dp, { base__drop = { item = "base:stone.item", count = 1 } })
        wait(1.0, park2)
        local dpos = drop.transform:get_pos()
        shoot("entity", { dpos[1], dpos[2] + 3.5, dpos[3] }, { 0, -12, 0 })
        if entities.exists(drop:get_uid()) then drop:despawn() end
        -- стену убрать: она стоит между камерой видов п.2 и дырой
        for x = -3, 3 do for y = -1, 5 do for z = -2, 2 do block.set(W[1] + x, wy + y, wz + z, 0, 0) end end end
    end

    -- ---------------- п.2 внешность: дыра в воздухе, виды сбоку, сверху, сквозь диск на ландшафт
    local VC = { W[1] + 0.5, W[2] + 14.5, W[3] + 0.5 }
    local hv = api.spawn(VC, 600, nil, { 0.22, 1, 0.12 })
    wait(2.5, park2)
    local sv = api.state(hv)
    log(("visual hole %d: mass %.0f horizon %.2f rh_vis %.2f R %.2f axis %.2f %.2f %.2f"):format(hv, sv.mass,
        core.horizon(sv.mass), sv.rh_vis, core.suck_radius(sv.mass), sv.N[1], sv.N[2], sv.N[3]))
    hold_view("disk_side", { VC[1] - 14, VC[2] - 1.6 + 0.6, VC[3] - 3 }, VC, 0.3)
    hold_view("disk_top", { VC[1] - 9, VC[2] - 1.6 + 9, VC[3] - 9 }, VC, 0.3)
    hold_view("through", { VC[1] - 6, VC[2] - 1.6 + 10, VC[3] - 13 }, { VC[1] + 2, W[2], VC[3] + 7 }, 0.3)
    -- производительность трассировки: 1 дыра крупно, 3 дыры издали и крупно (без vsync)
    perf("rt_1close", { VC[1] - 10, VC[2] - 1.6 + 2, VC[3] - 10 }, VC)
    local hv2 = api.spawn({ VC[1] - 18, VC[2], VC[3] + 4 }, 600, nil, { -0.3, 1, 0.2 })
    local hv3 = api.spawn({ VC[1] + 18, VC[2], VC[3] + 4 }, 600, nil, { 0.1, 1, -0.35 })
    wait(2.0, park2)
    perf("rt_3far", { VC[1], VC[2] - 1.6 + 4, VC[3] - 34 }, VC)
    perf("rt_3close", { VC[1], VC[2] - 1.6 + 2, VC[3] - 16 }, VC)
    hold_view("rt_three", { VC[1], VC[2] - 1.6 + 4, VC[3] - 34 }, VC, 0.3)

    -- ---------------- п.3 схлопыватель: бросок в дыру hv
    do
        local from = { VC[1] - 8, VC[2] + 1, VC[3] - 8 }
        local dir = vec3.normalize(vec3.sub(VC, from))
        log(("collapser test: hole %d mass %.0f age %.1f s, lifetime %.1f s"):format(hv, api.state(hv).mass,
            api.state(hv).age, core.lifetime(api.state(hv).mass)))
        api.throw(from, vec3.mul(dir, 22), nil, "collapser_thrown")
        local t0 = time.uptime()
        while time.uptime() - t0 < 4 and api.state(hv) and api.state(hv).phase ~= "collapse" do park2(); app.tick() end
        log(("collapser test: hole %d phase %s after %.2f s (reason %s)"):format(hv,
            api.state(hv) and api.state(hv).phase or "gone", time.uptime() - t0,
            api.state(hv) and tostring(api.state(hv).collapse_reason) or "-"))
        for _, u in ipairs({ hv2, hv3 }) do if entities.exists(u) then entities.get(u):despawn() end end
        wait(3.0, park2)
    end

    -- ---------------- п.7 мягкое слияние в воздухе: 600 + 300 на 8 блоках, кадры при merge_u 0.2 и 0.6 (время дыр
    -- заморожено на время снимка), вид сбоку
    do
        local M1 = { VC[1] - 4, VC[2], VC[3] }
        local M2 = { VC[1] + 4, VC[2], VC[3] }
        local a1 = api.spawn(M1, 600, nil, { 0.15, 1, 0.1 })
        local a2 = api.spawn(M2, 300, nil, { -0.2, 1, 0.1 })
        local cam = { VC[1], VC[2] - 1.6 + 2.5, VC[3] - 17 }
        local marks = { { 0.2, "merge_a" }, { 0.6, "merge_b" } }
        local mi = 1
        local t0 = time.uptime()
        local m_before = api.state(a1).mass + api.state(a2).mass
        while time.uptime() - t0 < 15 and entities.exists(a2) do
            look_from(cam, VC)
            app.tick()
            local s2 = api.state(a2)
            local s1 = api.state(a1)
            local sm = (s2 and s2.phase == "merging") and s2 or ((s1 and s1.phase == "merging") and s1 or nil)
            if sm and marks[mi] and (sm.merge_u or 0) >= marks[mi][1] then
                core.time_scale = 0
                local tg = api.state(sm.target)
                log(("merge air %s: hole %d -> %d merge_u %.2f rh_vis %.2f, target rh_vis %.2f, distance %.2f (frozen)")
                    :format(marks[mi][2], sm.uid, sm.target, sm.merge_u, sm.rh_vis, tg and tg.rh_vis or -1,
                        tg and vec3.length(vec3.sub(tg.center, sm.center)) or -1))
                hold_view(marks[mi][2], cam, VC, 0.3)
                core.time_scale = 1
                mi = mi + 1
            end
        end
        local s1 = api.state(a1)
        log(("merge air result after %.1f s: hole %d exists %s mass %.0f (before %.0f) rh_vis %.2f horizon %.2f"):format(
            time.uptime() - t0, a1, tostring(entities.exists(a1)), s1 and s1.mass or -1, m_before,
            s1 and s1.rh_vis or -1, s1 and core.horizon(s1.mass) or -1))
        wait(1.0, function() look_from(cam, VC) end)
        hold_view("merge_after", cam, VC, 0.3)
        for _, u in ipairs({ a1, a2 }) do if entities.exists(u) then entities.get(u):despawn() end end
        park2()
    end

    -- ---------------- п.8 быстрое стирание: одно кольцо двумя путями, одинаковый радиус, разные участки; на каждом
    -- участке два кольца одно под другим (второе — «тёплое»: фрагмент уже собран и ставился)
    for _, k in ipairs({ 8, 14 }) do
        for rep = 1, 3 do
            -- #1 — у поверхности (в кольце есть воздух), #2 — под ним, #3 — рядом с #2 (под землёй)
            local dz = (rep == 3) and -(2 * k + 4) or 0
            local dy = (rep == 1) and 0 or -(2 * k + 4)
            local A = { W[1] - 22, 0, W[3] - 8 + dz }
            local B = { W[1] + 22, 0, W[3] - 8 + dz }
            A[2] = surface(A[1], A[3]) - 4 + dy
            B[2] = surface(B[1], B[3]) - 4 + dy
            local ms1, n1, _, sc1, wr1 = core.bench_ring(A, k, "set")
            local ms2, n2, build, sc2, wr2 = core.bench_ring(B, k, "fragment")
            local vx, vy, vz = math.floor(B[1]) + k, math.floor(B[2]), math.floor(B[3])
            local vid = block.get(vx, vy, vz)
            log(("bench ring k=%d #%d (%d cells): set %.2f ms for %d blocks (%.4f ms/block; scan %.2f + block.set %.2f); fragment %.2f ms for %d blocks (%.4f ms/block; scan %.2f + place/restore %.2f), fragment build %.1f ms once; erased cell %s replaceable %s")
                :format(k, rep, core.shell(k).n, ms1, n1, n1 > 0 and ms1 / n1 or 0, sc1, wr1, ms2, n2,
                    n2 > 0 and ms2 / n2 or 0, sc2, wr2, build, vid >= 0 and block.name(vid) or "?",
                    tostring(block.is_replaceable_at(vx, vy, vz))))
            wait(0.3, park2)
        end
    end

    -- ---------------- п.1 + п.7 сверхмассивная: 4 дыры рядом -> одна, плавное слияние; п.8 авто-выбор пути
    do
        local C = { W[1] + 0.5, W[2] + 0.5, W[3] + 28.5 }
        local four = {}
        local m0 = 0
        for i, d in ipairs({ { -7, -7 }, { 7, -7 }, { -7, 7 }, { 7, 7 } }) do
            local p = { C[1] + d[1], surface(math.floor(C[1] + d[1]), math.floor(C[3] + d[2])) + 0.5, C[3] + d[2] }
            four[i] = api.spawn(p, 2000)
            m0 = m0 + 2000
        end
        wait(0.2, park2)
        local s1 = api.state(four[1])
        log(("supermassive: 4 holes of mass 2000 (R %.2f, horizon %.2f, interaction 2R %.2f), side 14, total %d")
            :format(core.suck_radius(2000), core.horizon(2000), 2 * core.suck_radius(2000), m0))
        local cam = { C[1], C[2] + 16, C[3] - 34 }
        local shot_mid = false
        local t0 = time.uptime()
        local function alive()
            local n, last = 0, nil
            for _, u in ipairs(four) do
                local s = api.state(u)
                if s and s.phase ~= "dead" then n = n + 1; last = u end
            end
            return n, last
        end
        while time.uptime() - t0 < 25 do
            look_from(cam, C)
            app.tick()
            if not shot_mid then
                for _, u in ipairs(four) do
                    local s = api.state(u)
                    if s and s.phase == "merging" and (s.merge_u or 0) >= 0.45 then
                        shot_mid = true
                        -- заморозить время дыр (core.time_scale = 0), пока драйвер снимает кадр: середина перехода
                        core.time_scale = 0
                        local tg = api.state(s.target)
                        local mc = tg and vec3.mul(vec3.add(s.center, tg.center), 0.5) or s.center
                        log(("merge mid: hole %d -> %d merge_u %.2f rh_vis %.2f (target rh_vis %.2f), distance %.2f, frozen")
                            :format(u, s.target or -1, s.merge_u, s.rh_vis, tg and tg.rh_vis or -1,
                                tg and vec3.length(vec3.sub(tg.center, s.center)) or -1))
                        hold_view("merge4_mid", cam, mc, 0.3)
                        core.time_scale = 1
                        break
                    end
                end
            end
            local n = alive()
            if n <= 1 and time.uptime() - t0 > 2 then break end
        end
        local n, last = alive()
        local s = last and api.state(last)
        log(("supermassive result after %.1f s: %d hole(s) left, hole %s mass %.0f (sum of 4 = %d, + eaten), radius %.2f (each was %.2f), horizon %.2f, merges %d, path %s")
            :format(time.uptime() - t0, n, tostring(last), s and s.mass or -1, m0, s and core.suck_radius(s.mass) or -1,
                core.suck_radius(2000), s and core.horizon(s.mass) or -1, s and s.merged or -1, s and s.path or "-"))
        if s then
            -- пусть ест: путь стирания и кольца в лог
            local te = time.uptime()
            while time.uptime() - te < 12 do look_from(cam, s.center); app.tick() end
            hole_line("supermassive +12s", last)
            log(("supermassive rings: set %d rings %.1f ms %d blocks; fragment %d rings %.1f ms %d blocks"):format(
                s.rings.set.n, s.rings.set.ms, s.rings.set.blocks, s.rings.fragment.n, s.rings.fragment.ms,
                s.rings.fragment.blocks))
            hold_view("supermassive", cam, s.center, 0.3)
            s.age = 1e9
            local tc = time.uptime()
            while api.state(last) and time.uptime() - tc < 5 do park2(); app.tick() end
            wait(3.0, park2)
        end
    end
    do
        local zs = {}
        for _, z in ipairs(core.collapse_zones) do zs[#zs + 1] = tostring(z.sand) end
        log(("w2 done: speakers %d, open collapse zones %d, falling sand replaced by silent ejecta: %s"):format(
            audio.count_speakers(), #core.collapse_zones, table.concat(zs, ",")))
    end
end
if (o.w2only or 0) ~= 0 then wave2(); log("done (w2only)"); return end

-- ============================================================ (b) дыра у поверхности
local hx, hz = 6, 6
local sy = surface(hx, hz)
local hc = { hx + 0.5, sy + 0.5, hz + 0.5 }
local drops = {}
for i = 1, 3 do
    local a = i * 2.1
    local p = { hc[1] + math.cos(a) * 4.5, surface(math.floor(hc[1] + math.cos(a) * 4.5), math.floor(hc[3] + math.sin(a) * 4.5)) + 1.5,
        hc[3] + math.sin(a) * 4.5 }
    local e = entities.spawn("base:drop", p, { base__drop = { item = "base:stone.item", count = 1 } })
    drops[#drops + 1] = e:get_uid()
end
log(("test drops spawned: %s"):format(table.concat(drops, ",")))
local cam_b = { hc[1] - 11, sy + 5, hc[3] - 11 }
perf("0holes", { hc[1], hc[2] + 6, hc[3] - 34 }, hc)
-- (п.5 волны 2) дыра брошена в землю: скорость 4,-6,2 — движется по инерции, тормозит от массы
local h1 = api.spawn({ hc[1] - 1.2, hc[2] + 1.8, hc[3] - 0.6 }, 1, { 4, -6, 2 })
local tb = time.uptime()
log(("surface hole %d at %.1f %.1f %.1f (surface y %d)"):format(h1, hc[1], hc[2], hc[3], sy))
wait(0.35)
hold_view("birth", cam_b, hc, 0.1)
local function until_t(t, fn) while time.uptime() - tb < t do if fn then fn() end app.tick() end end
until_t(5, function() park() end)
hole_line("t=5s", h1)
until_t(12, function() park() end)
hold_view("feed", cam_b, hc, 0.3)
until_t(15, function() park() end)
hole_line("t=15s", h1)
local alive = 0
for _, u in ipairs(drops) do if entities.exists(u) then alive = alive + 1 end end
log(("drops alive at 15s: %d of %d"):format(alive, #drops))
-- тяга игрока: 9 блоков от центра, без ввода, 1 с
do
    local s = api.state(h1)
    local R = core.suck_radius(s.mass)
    -- над землёй (в полёте), иначе физика выталкивает игрока из блоков и это не тяга
    local px = math.floor(hc[1] + R + 5)
    local p0 = { hc[1] + R + 5, math.max(hc[2] + 1, surface(px, math.floor(hc[3])) + 2.5) + 0.9, hc[3] }
    player.set_pos(0, p0[1], p0[2] - 0.9, p0[3])
    player.set_vel(0, 0, 0, 0)
    local d0 = vec3.length(vec3.sub(p0, s.center))
    wait(1.0)
    local x, y, z = player.get_pos(0)
    local d1 = vec3.length(vec3.sub({ x, y + 0.9, z }, s.center))
    log(("player pull: distance %.2f -> %.2f in 1 s (flight mode, pull radius %.1f)"):format(d0, d1, core.pull_radius(s.mass)))
    park()
end
until_t(30, function() park() end)
hole_line("t=30s", h1)

-- ============================================================ (c) две дыры -> слияние
local h2
do
    local s = api.state(h1)
    local R1 = core.suck_radius(s.mass)
    local dist = R1 + 2 + 1.5
    local c2 = { s.center[1] + dist, s.center[2] + 1, s.center[3] }
    h2 = api.spawn(c2, 1)
    log(("second hole %d at distance %.1f (R1 %.2f + R2 2 = %.2f)"):format(h2, dist, R1, R1 + 2))
    local mid = vec3.mul(vec3.add(s.center, c2), 0.5)
    wait(1.0, park)
    hold_view("two", { mid[1], mid[2] + 4, mid[3] - 15 }, mid, 0.3)
    -- если не слились сами за 8 с — пододвигать вторую к первой по 0.5 блока/с
    local t0 = time.uptime()
    while api.state(h2) and api.state(h2).phase ~= "dead" and time.uptime() - t0 < 20 do
        local s2 = api.state(h2)
        if time.uptime() - t0 > 8 and s2.phase ~= "merging" then
            local e2 = entities.get(h2)
            local p = e2.transform:get_pos()
            local dv = vec3.sub(api.state(h1).center, p)
            e2.transform:set_pos(vec3.add(p, vec3.mul(vec3.normalize(dv), 0.5 / 20)))
        end
        park()
        app.tick()
    end
    log(("merge wait %.1f s: h2 exists %s, merges total %d"):format(time.uptime() - t0, tostring(entities.exists(h2)),
        core.stats.merges))
    hole_line("after merge", h1)
end

local c1 = api.state(h1).center
local camp = { c1[1], c1[2] + 8, c1[3] - 46 }
perf("1hole", camp, c1)
-- дальше 2 R(m) большой (притяжение дыр), чтобы за замер не слились
local h3 = api.spawn({ c1[1] - 34, surface(math.floor(c1[1] - 34), math.floor(c1[3])) + 0.5, c1[3] }, 1)
local h4 = api.spawn({ c1[1] + 34, surface(math.floor(c1[1] + 34), math.floor(c1[3])) + 0.5, c1[3] }, 1)
log(("extra holes %d %d for 3-hole perf"):format(h3, h4))
wait(1.5, function() look_from(camp, c1) end)
perf("3holes", camp, c1)
hold_view("three", camp, c1, 0.3)

-- ============================================================ (d) коллапс
do
    for _, u in ipairs({ h3, h4 }) do
        local s = api.state(u)
        if s then s.age = 1e9 end
    end
    local s = api.state(h1)
    local cc = { s.center[1], s.center[2], s.center[3] }
    log(("collapse request: hole %d mass %.0f absorbed %d"):format(h1, s.mass, s.absorbed_blocks))
    s.age = 1e9
    wait(0.25, park)
    hold_view("collapse", { cc[1] - 10, cc[2] + 4, cc[3] - 10 }, cc, 0.3)
    -- вспышка: дождаться конца коллапса этой дыры (запись во core.flashes) и снять сразу
    local tf = time.uptime()
    while api.state(h1) and time.uptime() - tf < 4 do
        look_from({ cc[1] - 10, cc[2] + 4, cc[3] - 10 }, cc)
        app.tick()
    end
    hold_view("flash", { cc[1] - 10, cc[2] + 4, cc[3] - 10 }, cc, 0.1)
    local t0 = time.uptime()
    while next(core.ejecta) ~= nil and time.uptime() - t0 < 16 do park(); app.tick() end
    log(("ejecta pending after %.1f s: %d groups"):format(time.uptime() - t0, (function() local n = 0 for _ in pairs(core.ejecta) do n = n + 1 end return n end)()))
    hold_view("after", { cc[1] - 12, cc[2] + 6, cc[3] - 12 }, cc, 0.3)
end
wave2()
log(("totals: blocks eaten %d, entities absorbed %d, merges %d, collapses %d"):format(core.stats.blocks,
    core.stats.absorbed, core.stats.merges, core.stats.collapses))
log("done")
