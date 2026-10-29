-- Старт пака alphamine в F2F-сборке движка (<repo>\builds\031\VoxelCoreF2F-031.exe --f2f 25571 ...):
-- харнесс (tools/mcp/alpha_vc.py, am_client impl="vc") копирует этот файл в свой --dir как user:alphamine_f2f.lua
-- и пишет user:autorun_app_script.txt; project_client.lua (res) запускает его при старте меню. Сценарий идёт
-- только в кадрах F2F (step), открывает свежий мир AlphaMine (генератор alphamine:void) и регистрирует
-- обработчик F2F пака (alphamine:f2f): hello.handler = true — мир готов, дальше команды connect/wait/state/...
-- Конфиг: user:alphamine_f2f.json {"server": "127.0.0.1:25566", "user": "Player", "load_distance": 16}.
app.config_packs({"base", "alphamine"})
app.load_content()
local cfg = {}
if file.isfile("user:alphamine_f2f.json") then
    cfg = json.parse(file.read("user:alphamine_f2f.json"))
end
require("alphamine:launch").open(app, {load_distance = cfg.load_distance})
-- обработчик регистрирует скрипт мира (on_world_open, главное состояние Lua), здесь — только конфиг
local ok = require("alphamine:f2f").configure({server = cfg.server or "127.0.0.1:25566", user = cfg.user or "Player"})
debug.log("[alphamine_f2f] handler registered: " .. tostring(ok) .. ", server " .. tostring(cfg.server))
