-- gpu_worldgen: кадр конвейера генерации (каждый кадр, до отрисовки GUI — фрейм gpuwg_fb рисуется после),
-- подсказка пресета в HUD (layouts/gw_hud.xml) и F6 — следующий пресет (перезапись загруженных чанков)
local gen = require "gpu_worldgen:gen"
local presets = require "gpu_worldgen:presets"

function on_hud_render() gen.frame() end

function on_hud_open()
    if not gen.is_active() then return end
    local ok, err = true, nil
    if gen.cfg.hud ~= false then
        ok, err = pcall(hud.open_permanent, "gpu_worldgen:gw_hud")
        if not ok then gen.log("hud: " .. tostring(err)) end
    end
    ok, err = pcall(input.add_callback, "key:f6", function()
        local cur = gen.preset and gen.preset.name or "classic"
        gen.set_preset(presets.next(cur))
    end)
    if not ok then gen.log("hud: key:f6 " .. tostring(err)) end
end
