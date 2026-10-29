-- Оба клиента gpu_compute в одном мире (критерий «API работает»): паки gpu_compute + gpu_worldgen + smollm_gpu,
-- один общий ui.glslf (программы обоих собраны tools/gpu_compute_build.py). Без кликов по меню, ввод ОС не нужен.
--   lab lease wasmrt engine_rt --param script=gpu_compute_both.lua \
--       --param 'packs=["gpu_compute","gpu_worldgen","smollm_gpu"]' --param 'ready_marker=\[gpu_both\] ready' \
--       [--param engine=v032] [--param manifest="llm=1;far=1"] --start            (tools/scenarios/gpu_compute_both.py)
-- Фазы:
--   1. новый мир на генераторе gpu_worldgen:gpu (classic, seed 20261011, load-distance 6) -> генерация до простоя,
--      хэш области [-3..3]^2 (эталон пака b3e5e930), кадр «view world»;
--   2. в том же мире конвейер smollm_gpu (418 фреймов, проба порядка) и ответ на промпт 1 (argmax, "0 0.85 1 120");
--   3. одновременно: игрок переносится в новую область (x = z = 2000, генерируются чанки) и модель отвечает на промпт 2 —
--      оба клиента считают на GPU в одних кадрах; хэш новой области [123..127]^2 (с llm=0 — эталон без LLM), кадр «view far».
-- Параметры (export:wasmrt_manifest.txt, key=value через ;): llm (1; 0 — только worldgen, эталон хэша дальней области),
--   far (1), timeout (300).
-- Маркеры: [gpu_both] ready | view <имя> | done | error: ...; строки [gpu_worldgen] / [smollm_gpu] / [sg] — от клиентов.
app.config_packs({ "base", "gpu_compute", "gpu_worldgen", "smollm_gpu" })
app.load_content()
app.tick()

local o = {}
for _, f in ipairs({ "export:wasmrt_manifest.txt", "export:gpu_compute_both.txt" }) do
    if file.isfile(f) then
        for k, v in file.read(f):gmatch("([%w_]+)%s*=%s*([^;\r\n]*)") do o[k] = tonumber(v) or v end
    end
end
local function log(s) debug.log("[gpu_both] " .. s) end
local now = time.precise_time or os.clock
log("ready")

local function wait_idle(gen, timeout)
    local idle_since
    local t0 = now()
    local ok = pcall(app.sleep_until, function()
        if gen.idle() and gen.done_count() > 0 then
            idle_since = idle_since or now()
            return now() - idle_since > 1.5
        end
        idle_since = nil
        return false
    end, 1e9, timeout or 300)
    return ok, (idle_since or now()) - t0
end

local function view(name, x, y, z, yaw, pitch)
    player.set_flight(0, true)
    player.set_noclip(0, true)
    player.set_pos(0, x, y, z)
    player.set_vel(0, 0, 0, 0)
    player.set_rot(0, yaw, pitch, 0)
    app.tick(); app.tick()
    log(("view %s: pos %.1f %.1f %.1f yaw %.0f pitch %.0f"):format(name, x, y, z, yaw, pitch))
    app.sleep(3)
end

-- ответы модели на экране (поверх HUD пака gpu_worldgen) — чтобы кадр F2F показывал оба клиента сразу
local shown = 0
local function show_replies(chat)
    local okd, e = pcall(function()
        local lines = {}
        for _, e in ipairs(chat.transcript) do
            lines[#lines + 1] = (e.role == "user" and "Q: " or "LLM (GPU): ") .. (e.text:gsub("\n", " "))
        end
        local text = table.concat(lines, "\n"):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
        shown = shown + 1
        -- новый блок поверх прежнего (текст — в разметке: поиск добавленного элемента по id в документе HUD не работает)
        Document.new("gpu_worldgen:gw_hud").root:add(('<container pos="8,40" size="838,96" color="#101820E0" ' ..
            'interactive="false"><label pos="8,4" size="822,88" color="#E8EEF5FF" multiline="true" text-wrap="true" ' ..
            'interactive="false">%s</label></container>'):format(text))
    end)
    if not okd then log("show_replies: " .. tostring(e)) end
end

local ok, err = pcall(function()
    local gc = require "gpu_compute:compute"
    local progs = {}
    for k, p in pairs(gc.programs()) do progs[#progs + 1] = ("%s=#%02X%02X..%02X"):format(k, p.bank, p.g0, p.g1) end
    table.sort(progs)
    log("programs in ui.glslf: " .. table.concat(progs, " "))
    local launch = require "gpu_worldgen:launch"
    local gen = require "gpu_worldgen:gen"
    local use_llm = (o.llm or 1) ~= 0
    launch.open(app, { world = "gpuboth_20261011", fresh = true, seed = "20261011", load_distance = 6,
        backend = "gpu", flight = true, keep_codes = { "0,0", "1,0", "0,-1", "-2,2" } })
    pcall(app.set_setting, "graphics.enable-fog", false)
    -- 1. генерация
    local t_open = now()
    local okw, dt = wait_idle(gen, o.timeout or 300)
    local T = gen.total
    local span = (T.t_last and T.t_first) and (T.t_last - T.t_first) or 0
    log(("phase1 worldgen: ok=%s, %d chunks in %.2f s (%.2f s first..last) = %.1f ch/s"):format(tostring(okw), T.chunks, dt,
        span, span > 0 and (T.chunks - 1) / span or 0))
    local ah = gen.area_hash(-3, -3, 3, 3)
    log(("phase1 area hash [-3..3]^2 = %s"):format(ah and bit.tohex(ah) or "incomplete"))
    view("world", -56, 110, -56, -135, -20)

    -- 2. LLM в том же мире
    local chat
    local prompts = { "Привет! Кто ты?", "Расскажи о себе." }
    if use_llm then
        local ref = file.isfile("export:gpu_both_prompts.txt") and file.read("export:gpu_both_prompts.txt") or nil
        if ref then
            local i = 0
            for line in (ref .. "\n"):gmatch("(.-)\r?\n") do
                if line ~= "" then i = i + 1; prompts[i] = line end
            end
        end
        chat = require "smollm_gpu:chat"
        chat.params.temperature, chat.params.top_p, chat.params.rep_penalty, chat.params.max_new = 0, 0.85, 1, 120
    end
    local far_x, far_z = 2000, 2000
    local far_done_before, far_t0, far_moved = 0, nil, false
    local function go_far()
        far_moved = true
        gen.cfg.hash = true   -- хэши всех чанков (по умолчанию пак хэширует только [-3..3]^2)
        far_done_before = gen.done_count()
        far_t0 = now()
        gen.total.chunks = 0
        gen.total.t_first, gen.total.t_last = nil, nil
        player.set_flight(0, true)
        player.set_noclip(0, true)
        player.set_pos(0, far_x + 0.5, 160, far_z + 0.5)
        player.set_vel(0, 0, 0, 0)
        log(("phase3: player -> %d %d (new chunks), chunks done so far %d"):format(far_x, far_z, far_done_before))
    end
    if use_llm then
        local stage = 0
        local proxy = setmetatable({}, { __index = app })
        proxy.tick = function(...)
            local r = app.tick(...)
            if stage == 0 and chat.replies >= 1 then
                stage = 1
                show_replies(chat)
                if (o.far or 1) ~= 0 then go_far() end
                chat.submit(prompts[2])
                log("phase3: prompt 2 submitted while worldgen generates the new area")
            elseif stage == 1 and chat.replies >= 2 then
                stage = 2
                show_replies(chat)
                chat.leaving = true
            end
            return r
        end
        local t2 = now()
        chat.run(proxy, { on_ready = function()
            log(("phase2: llm pipeline ready in %.1f s inside the world, chunks %d"):format(now() - t2, gen.done_count()))
            chat.submit(prompts[1])
        end })
        log(("phase2+3: chat loop done, replies %d"):format(chat.replies))
        if far_moved then
            log(("phase3: chunks generated during reply 2: %d"):format(gen.done_count() - far_done_before))
        end
    elseif (o.far or 1) ~= 0 then
        go_far()
    end
    if far_moved then
        local okf, dtf = wait_idle(gen, o.timeout or 300)
        local cx, cz = math.floor(far_x / 16), math.floor(far_z / 16)
        local fh = gen.area_hash(cx - 2, cz - 2, cx + 2, cz + 2)
        local T2 = gen.total
        local span2 = (T2.t_last and T2.t_first) and (T2.t_last - T2.t_first) or 0
        log(("phase3 worldgen far: ok=%s, %d chunks in %.2f s from move (%.2f s first..last) = %.1f ch/s"):format(
            tostring(okf), T2.chunks, now() - far_t0, span2, span2 > 0 and (T2.chunks - 1) / span2 or 0))
        log(("phase3 area hash [%d..%d]x[%d..%d] = %s"):format(cx - 2, cx + 2, cz - 2, cz + 2, fh and bit.tohex(fh) or "incomplete"))
        view("far", far_x - 40, 130, far_z - 40, -135, -18)
    end
end)
if not ok then log("error: " .. tostring(err)) end
log("done")
