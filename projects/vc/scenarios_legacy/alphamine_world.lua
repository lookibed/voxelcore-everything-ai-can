-- Прямой запуск мира AlphaMine при старте движка (project_client.lua), без кликов по меню:
--   vc_start(script="user:tools/scenarios/alphamine_world.lua", wait_for="\\[alphamine_app\\] ready")
-- Сервер: export:alphamine_server.txt ("host:port"), по умолчанию 127.0.0.1:25566 (свой сервер агента VoxelCore,
-- tools/alphamine/server_v.py); "none" — без подключения. То же, что пункт «Сценарии» → alphamine.
app.config_packs({"base", "alphamine"})
app.load_content()
local server = "127.0.0.1:25566"
if file.isfile("export:alphamine_server.txt") then
    server = file.read("export:alphamine_server.txt"):gsub("%s+", "")
end
local launch = require("alphamine:launch")
local old = launch.open(app, {connect = server ~= "none" and server or nil})
launch.restore_on_close(app, old)
