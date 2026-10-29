-- Подсказка gw_hud.xml: «GPU worldgen: <пресет> | F6 — следующий | очередь N»
local gen = require "gpu_worldgen:gen"

function on_open()
    document.root:setInterval(250, function()
        local p = gen.preset
        local q = gen.queue_count()
        local s = ("GPU worldgen: %s  |  F6 - next preset"):format(p and p.title or "-")
        if q > 0 then s = s .. ("  |  queue %d"):format(q) end
        -- проход: размер фрейма, плиток за проход; чанков на кадр за последнее окно stats (среднее / максимум)
        local pi, c = gen.pass_info, gen.last_cpf
        if pi then
            s = s .. ("\npass %dx%d, %d tiles"):format(pi.w, pi.h, pi.tiles)
            if c then
                s = s .. (" | %.1f/pass | ch/frame gpu %.1f (max %d), set %.1f (max %d)"):format(
                    c.tiles_per_pass, c.gen.mean, c.gen.max, c.wr.mean, c.wr.max)
            end
        end
        document.lbl.text = s
    end)
end
