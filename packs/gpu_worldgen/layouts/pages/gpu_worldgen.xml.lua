-- Страница gpu_worldgen: кнопки пресетов -> событие gpu_worldgen:open(preset, seed) для app-скрипта пака
-- (scripts/app/gpu_worldgen.lua открывает/создаёт мир). Координаты кнопок пишутся в лог (для F2F-клика в тестах).
local function log(s) debug.log("[gpu_worldgen] " .. s) end

local function layout()
    local vp = gui.get_viewport()
    document.panel.pos = { math.floor((vp[1] - 520) / 2), math.max(8, math.floor((vp[2] - 440) / 2)) }
end

function on_open()
    -- после мира курсор мог остаться захваченным (null-фрейм): отпустить, иначе кнопки не нажимаются (LESSONS)
    pcall(gui.set_active_frame, gui.main_frame_id or "core:main")
    layout()
    document.root:setInterval(200, layout)
    local parts = {}
    for _, id in ipairs({ "btn_mountains", "btn_caves", "btn_islands", "btn_classic", "seed", "back_btn" }) do
        local e = document[id]
        local p, s = e.wpos, e.size
        parts[#parts + 1] = ("%s=%d,%d,%d,%d"):format(id, p[1], p[2], s[1], s[2])
    end
    local vp = gui.get_viewport()
    log(("page open: viewport %d,%d "):format(vp[1], vp[2]) .. table.concat(parts, " "))
end

function choose(preset)
    local seed = document.seed.text
    if seed then seed = seed:match("^%s*(.-)%s*$") end
    if seed == "" then seed = nil end
    log(("page: preset %s seed %s"):format(preset, tostring(seed)))
    events.emit("gpu_worldgen:open", preset, seed)
end

function leave()
    events.emit("gpu_worldgen:leave")
end
