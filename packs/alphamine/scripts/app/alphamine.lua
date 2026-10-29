-- Пункт меню «Сценарии» (для пользователя при сдаче): мир "AlphaMine" на генераторе alphamine:void,
-- подключение к серверу Alpha localhost:25565 (адрес — export:alphamine_server.txt, если файл есть).
-- Во время разработки запускать напрямую: vc_start(script="user:tools/scenarios/alphamine_world.lua").
-- Логика — alphamine:launch. Маркер в логе: [alphamine_app] ready.
app.config_packs({"base", "alphamine"})
app.load_content()
local server = "localhost:25565"
if file.isfile("export:alphamine_server.txt") then
    server = file.read("export:alphamine_server.txt"):gsub("%s+", "")
end
local launch = require("alphamine:launch")
local old = launch.open(app, {connect = server})
launch.restore_on_close(app, old)
