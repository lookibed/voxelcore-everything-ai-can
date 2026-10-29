-- Пропускная способность прохода gpu_worldgen: «чанков на кадр» (13.10, агент gpu_cap).
-- Драйвер: tools/scenarios/gpu_worldgen_throughput.py (аренда wasmrt engine_rt, --param engine=v032, --param size=WxH).
-- Две фазы в одной аренде:
--   static — новый мир (classic), от первого записанного чанка до последнего при дальности load_distance: время, чанков/с,
--            чанков на кадр (сгенерировано GPU / записано set_chunk_data: среднее, p95, максимум), fps, длина очереди;
--   flight — игрок летит по +x с постоянной скоростью speed (блоков/с, player.set_pos каждый кадр) flight_s секунд:
--            те же числа, плюс кадры с пустой очередью (скорость должна держать очередь непустой).
-- Параметры — export:wasmrt_manifest.txt, key=value через ';':
--   pass (потолок прохода frame_w x frame_h; не задан — умолчание пака 768x432 или config_pass), config_pass (WxH — записать
--   config:gpu_worldgen/settings.toml до открытия мира: проверка файла настроек), fit (1 — картинка прохода под пакет), pace (frame | raw | lua),
--   load_distance (8), load_speed (не трогать, если не задан), speed (160 блоков/с: при ld 32 — 10 чанков/с × 65 = 650 новых чанков/с, больше, чем пишет пак;
--   640 блоков/с движок не тянет сам — chunks_load 33 мс/кадр на пустые чанки, 24 fps), flight_s (20), alt (150),
--   static (1), requeue (0 — фаза перезаписи всех загруженных чанков), hold_s (3), timeout (300), hud (0), preset (classic), budget_ms, target_fps
-- Маркеры лога: [gpu_worldgen] prestart | ready | pass: … | static … | flight start | flight … | done
local o = {}
local f = "export:wasmrt_manifest.txt"
if file.isfile(f) then
    for k, v in file.read(f):gmatch("([%w_]+)%s*=%s*([^;\r\n]*)") do
        o[k] = tonumber(v) or v
    end
end
local function log(s) debug.log("[gpu_worldgen] " .. s) end
app.config_packs({ "base", "gpu_worldgen" })
app.load_content()
log("packs: base,gpu_worldgen")
if (o.hold_s or 3) > 0 then
    log("prestart")
    app.sleep(o.hold_s or 3)
end
local launch = require "gpu_worldgen:launch"
local gen = require "gpu_worldgen:gen"
local now = time.precise_time or os.clock

local pw, ph
if o.pass then pw, ph = tostring(o.pass):match("(%d+)x(%d+)") end
-- config_pass=WxH — проверка файла настроек: потолок из config:gpu_worldgen/settings.toml (pass не задавать)
if o.config_pass then
    local cw, ch = tostring(o.config_pass):match("(%d+)x(%d+)")
    file.mkdirs("config:gpu_worldgen")
    file.write("config:gpu_worldgen/settings.toml", ("# потолок прохода gpu_worldgen\npass_w = %s\npass_h = %s\n"):format(cw, ch))
    log("config written: config:gpu_worldgen/settings.toml pass " .. cw .. "x" .. ch)
end
local PRESET = o.preset or "classic"
local TAG = ("%s_%s_%s"):format(tostring(o.pass or (o.config_pass and ("cfg" .. o.config_pass)) or "default"), tostring(o.pace or "frame"), (o.fit or 1) ~= 0 and "fit" or "full")
if o.load_speed then app.set_setting("chunks.load-speed", o.load_speed) end
local LD = o.load_distance or 8
local old_ld = launch.open(app, {
    preset = PRESET,
    world = "gpuwg_tp_" .. PRESET,
    fresh = true,
    load_distance = LD,
    frame_w = tonumber(pw), frame_h = tonumber(ph),
    fit = (o.fit or 1) ~= 0,
    pace = o.pace or "frame",
    budget_ms = o.budget_ms, target_fps = o.target_fps,
    hud = (o.hud or 0) ~= 0,
    hash = 3,
    flight = true,
})
pcall(app.set_setting, "graphics.enable-fog", false)
log(("settings: load-distance %s load-speed %s padding %s, tag %s"):format(tostring(app.get_setting("chunks.load-distance")),
    tostring(app.get_setting("chunks.load-speed")), tostring(app.get_setting("chunks.padding")), TAG))

-- сводка записи gen.cpf по кадрам [i0, i1]
local function report(R, i0, i1)
    local S = gen.summ
    local dts = {}
    for i = math.max(i0, 2), i1 do dts[#dts + 1] = R.t[i] - R.t[i - 1] end
    local d = S(dts)
    local frames = i1 - i0 + 1
    -- от конца кадра перед первым (начало первого кадра окна) до конца последнего
    local span = R.t[i1] - R.t[math.max(1, i0 - 1)]
    local q = S(R.q, i0, i1)
    local empty = 0
    local wsum, gsum = 0, 0
    for i = i0, i1 do
        if R.q[i] == 0 then empty = empty + 1 end
        wsum = wsum + R.wr[i]
        gsum = gsum + R.gen[i]
    end
    -- p50 кадра
    table.sort(dts)
    local p50 = #dts > 0 and dts[math.max(1, math.ceil(#dts * 0.5))] or 0
    return {
        frames = frames, span = span, fps = span > 0 and (i0 > 1 and frames or frames - 1) / span or 0, p50 = p50 * 1000, p95 = d.p95 * 1000,
        max = d.max * 1000, gen = S(R.gen, i0, i1), wr = S(R.wr, i0, i1), q = q, empty = empty, written = wsum,
        gpu = gsum, chps = span > 0 and wsum / span or 0,
    }
end
local function fmt(name, r, extra)
    return ("%s %s: %d chunks in %.2f s = %.1f ch/s; frames %d, fps %.1f, frame ms p50 %.1f p95 %.1f max %.1f; per frame: gpu avg %.2f p95 %d max %d, written avg %.2f p95 %d max %d; queue avg %.0f max %d, empty-queue frames %d; gpu tiles %d%s")
        :format(name, TAG, r.written, r.span, r.chps, r.frames, r.fps, r.p50, r.p95, r.max, r.gen.mean, r.gen.p95,
            r.gen.max, r.wr.mean, r.wr.p95, r.wr.max, r.q.mean, r.q.max, r.empty, r.gpu, extra or "")
end

-- фаза static: от открытия мира до простоя очереди 1.5 с
gen.record_cpf(true)
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
local R = gen.cpf
gen.record_cpf(false)
local T = gen.total
local pi = gen.pass_info or {}
log(("pass info: %dx%d, %d tiles per pass, ceiling %sx%s, window %sx%s, fit %s"):format(pi.w or 0, pi.h or 0, pi.tiles or 0,
    tostring(pi.cap_w), tostring(pi.cap_h), tostring(pi.win_w), tostring(pi.win_h), tostring(pi.fit)))
if (o.static or 1) ~= 0 and T.t_first and T.t_last and #R.t > 2 then
    -- кадры от первого до последнего записанного чанка
    local i0, i1
    for i = 1, #R.t do
        if R.wr[i] > 0 then
            i0 = i0 or i
            i1 = i
        end
    end
    local r = report(R, i0, i1)
    log(fmt("static", r, (", ok=%s, total chunks %d, world.count_chunks %d, from open %.2f s, mem %.1f MB"):format(tostring(ok),
        T.chunks, world.count_chunks(), (T.t_last or now()) - t_open, collectgarbage("count") / 1024)))
end
log(("area hash [-3..3]^2 = %s"):format((function() local h = gen.area_hash(-3, -3, 3, 3) return h and bit.tohex(h) or "incomplete" end)()))

-- фаза requeue (requeue=1): все загруженные чанки снова в очередь разом — очередь не ждёт, пока движок создаст пустые
-- чанки (подача движка — не больше ~load-speed мс / 1.3 мс ≈ 24 чанков за кадр), и проход упирается только в себя и
-- в свет/меши движка после set_chunk_data
if (o.requeue or 0) ~= 0 then
    app.sleep(1.0)
    gen.record_cpf(true)
    local n = gen.requeue_all()
    log(("requeue start: %d chunks"):format(n))
    local idle2
    pcall(app.sleep_until, function()
        if gen.idle() then
            idle2 = idle2 or now()
            return now() - idle2 > 1.0
        end
        idle2 = nil
        return false
    end, 1e9, o.timeout or 300)
    local R3 = gen.cpf
    gen.record_cpf(false)
    local i0, i1
    for i = 1, #R3.t do
        if R3.wr[i] > 0 then i0 = i0 or i; i1 = i end
    end
    if i0 then log(fmt("requeue", report(R3, i0, i1), (", requeued %d"):format(n))) end
    log("requeue end")
end

-- фаза flight
local FS = o.flight_s or 20
if FS > 0 then
    local V = o.speed or 160
    local ALT = o.alt or 150
    player.set_flight(0, true)
    player.set_noclip(0, true)
    local x, _, z = player.get_pos(0)
    player.set_pos(0, x, ALT, z)
    player.set_rot(0, -90, -10, 0)
    app.tick()
    local fail0 = gen.total.fail or 0
    gen.record_cpf(true)
    log(("flight start: speed %g blocks/s along +x, %g s, alt %d"):format(V, FS, ALT))
    local t0 = now()
    local tp = t0
    local x0 = x
    while now() - t0 < FS do
        app.tick()
        local t = now()
        x = x + V * (t - tp)
        tp = t
        player.set_pos(0, x, ALT, z)
        player.set_vel(0, 0, 0, 0)
    end
    local R2 = gen.cpf
    gen.record_cpf(false)
    log("flight end")
    -- первую секунду (разгон очереди) не считать
    local i0 = 1
    while i0 < #R2.t and R2.t[i0] - R2.t[1] < 1.0 do i0 = i0 + 1 end
    local r = report(R2, i0, #R2.t)
    log(fmt("flight", r, (", speed %g blocks/s, distance %.0f blocks, set_chunk_data false (chunk unloaded) %d, mem %.1f MB"):format(V,
        x - x0, (gen.total.fail or 0) - fail0, collectgarbage("count") / 1024)))
end
log("done")
