-- Пункт меню «Сценарии» -> gpu_worldgen (для пользователя): страница выбора пресета-витрины (layouts/pages/gpu_worldgen.xml):
-- «Горы и арки», «Пещерные миры», «Парящие острова», «Классика» и поле seed. Кнопка открывает мир пресета
-- («GPU Worldgen <Пресет>», создаётся при первом запуске; с seed — «GPU Worldgen <Пресет> <seed>»), после закрытия мира —
-- снова эта страница. В мире: F6 / gpuwg.preset — сменить пресет. Чанки считает GPU (3D-шум в UI-шейдере фрейма).
-- Во время разработки — tools/scenarios/gpu_worldgen_play.lua (зеркало этого файла) и gpu_worldgen_showcase.lua/.py.
-- Маркеры: [gpu_worldgen] page open … | ready.
app.config_packs({ "base", "gpu_worldgen" })
app.load_content()
app.tick()
local launch = require "gpu_worldgen:launch"
local presets = require "gpu_worldgen:presets"

local choice, leaving = nil, false
local function on_open(preset, seed) choice = { preset, seed } end
local function on_leave() leaving = true end

while true do
    -- открытие/закрытие мира перезагружает контент: обработчики — заново на каждом круге (повтор безвреден)
    events.on("gpu_worldgen:open", on_open)
    events.on("gpu_worldgen:leave", on_leave)
    menu.page = "gpu_worldgen"
    app.sleep_until(function() return choice ~= nil or leaving end, 1e12)
    if leaving then break end
    local preset, seed = choice[1], choice[2]
    choice = nil
    local pr = presets.get(preset)
    local name = pr.world
    if seed then name = name .. " " .. seed end
    local old = launch.open(app, { preset = preset, seed = seed, world = name, load_distance = 12, hash = false })
    launch.restore_on_close(app, old)
    -- закрытие мира выгружает контент паков: страница пака снова доступна только после load_content
    app.config_packs({ "base", "gpu_worldgen" })
    app.load_content()
    app.tick()
end
app.reset_content()
menu:reset()
menu.page = "main"
