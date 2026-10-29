-- Зеркало пункта меню «Сценарии» -> gpu_worldgen (content/gpu_worldgen/scripts/app/gpu_worldgen.lua) для прямого запуска
-- при разработке (vc_start / аренда wasmrt engine_rt --param script=gpu_worldgen_play.lua). Отличие — тестовые крючки из
-- export:wasmrt_manifest.txt: autoclose=N — закрыть мир через N с после спавна (проверка возврата на страницу),
-- rounds=K — выйти после K миров.
app.config_packs({ "base", "gpu_worldgen" })
app.load_content()
app.tick()
local launch = require "gpu_worldgen:launch"
local presets = require "gpu_worldgen:presets"

local o = {}
if file.isfile("export:wasmrt_manifest.txt") then
    for k, v in file.read("export:wasmrt_manifest.txt"):gmatch("([%w_]+)%s*=%s*([^;\r\n]*)") do o[k] = tonumber(v) or v end
end
local gen = require "gpu_worldgen:gen"
local rounds = 0
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
    rounds = rounds + 1
    if o.autoclose then
        app.sleep_until(function() local g = require "gpu_worldgen:gen"; return g.done_count() > 50 and g.idle() end, 1e12, 120)
        app.sleep(o.autoclose)
        debug.log("[gpu_worldgen] autoclose world " .. name)
        app.close_world(true)
    end
    launch.restore_on_close(app, old)
    -- закрытие мира выгружает контент паков: страница пака снова доступна только после load_content
    app.config_packs({ "base", "gpu_worldgen" })
    app.load_content()
    debug.log("[gpu_worldgen] world closed, back to page (round " .. rounds .. ")")
    if o.rounds and rounds >= o.rounds then leaving = true; break end
    app.tick()
end
app.reset_content()
menu:reset()
menu.page = "main"
