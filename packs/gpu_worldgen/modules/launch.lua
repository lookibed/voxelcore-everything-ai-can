-- gpu_worldgen:launch — общий код пункта меню «Сценарии» -> gpu_worldgen (scripts/app/gpu_worldgen.lua) и прямого
-- запуска tools/scenarios/gpu_worldgen_world.lua. Вызывать из корутины app-скрипта после
-- app.config_packs({"base", "gpu_worldgen"}) + app.load_content(); глобала app в модулях нет — передаётся параметром.
-- opts: preset ("classic" | "mountains" | "caves" | "islands", modules/presets.lua: имя мира, генератор, seed),
--       world (имя, по пресету), seed (по пресету), fresh (новый мир, даже если есть), load_distance (8),
--       backend ("gpu"|"cpu"), budget_ms, target_fps, batch_max, frame_w, frame_h (потолок прохода, умолчание 768x432),
--       fit (картинка прохода под пакет), pace ("frame"|"lua"|"raw"), keep_codes ({"x,z", ...})
local gen = require "gpu_worldgen:gen"
local presets = require "gpu_worldgen:presets"

local M = {}
M.WORLD = "GPU Worldgen"
M.GENERATOR = "gpu_worldgen:gpu"

local log = gen.log

function M.open(app, opts)
    opts = opts or {}
    local cfg = gen.cfg
    for _, k in ipairs({ "backend", "budget_ms", "target_fps", "batch_max", "frame_w", "frame_h", "place_player", "hud", "hash",
        "fit", "pace" }) do
        if opts[k] ~= nil then
            cfg[k] = opts[k]
            gen.cfg_explicit[k] = true   -- config:gpu_worldgen/settings.toml не перекрывает
        end
    end
    for _, k in ipairs(opts.keep_codes or {}) do cfg.keep_codes[k] = true end
    local ld = opts.load_distance or 8
    local old_ld = app.get_setting("chunks.load-distance")
    if old_ld ~= ld then app.set_setting("chunks.load-distance", ld) end
    local pr = presets.get(opts.preset or "classic") or presets.get("classic")
    local name = opts.world or pr.world
    local seed = opts.seed and tostring(opts.seed) or pr.seed
    if not opts.fresh and world.exists and world.exists(name) then
        log("opening world " .. name)
        app.open_world(name)
    else
        local generator = opts.generator or pr.generator
        log(("creating world %s seed %s generator %s (preset %s)"):format(name, seed, generator, pr.name))
        app.new_world(name, seed, generator)
    end
    world.set_day_time(0.5)
    world.set_day_time_speed(0)
    -- пустой мир: держим игрока в полёте над спавном, пока GPU не заполнит чанк (0,0) (gen ставит на поверхность)
    if gen.is_active() and cfg.place_player ~= false and gen.done_count() == 0 then
        local hy = gen.preset.id == 0 and 140 or 200
        player.set_spawnpoint(0, 8.5, hy, 8.5)
        player.set_flight(0, true)
        player.set_noclip(0, true)
        player.set_pos(0, 8.5, hy, 8.5)
        player.set_vel(0, 0, 0, 0)
        -- пресеты ставят игрока сами (gen.find_spawn: точка, взгляд, spawnpoint)
        if gen.preset.id ~= 0 then
            gen.on_spawn = function()
                player.set_flight(0, opts.flight == true)
                gen.on_spawn = nil
            end
        else gen.on_spawn = function(y)
            player.set_spawnpoint(0, 8.5, y + 2, 8.5)
            player.set_noclip(0, false)
            player.set_flight(0, opts.flight == true)
            gen.on_spawn = nil
        end end
    end
    log(("world %s generator %s preset %s load-distance %d backend %s"):format(name, tostring(world.get_generator()),
        gen.preset and gen.preset.name or "-", ld, cfg.backend))
    log("ready")
    return old_ld
end

-- ждать, пока все чанки квадрата [-r, r]^2 готовы; -> секунды или nil по таймауту
function M.wait_area(app, r, timeout)
    local t0 = time.uptime()
    local ok = pcall(app.sleep_until, function()
        for x = -r, r do
            for z = -r, r do
                if not gen.is_done(x, z) then return false end
            end
        end
        return true
    end, 1e9, timeout or 300)
    return time.uptime() - t0, ok
end

function M.restore_on_close(app, old_ld)
    if old_ld == nil then return end
    app.sleep_until(function() return not world.is_open() end, 1e12)
    app.set_setting("chunks.load-distance", old_ld)
end

return M
