-- Пункт меню «Сценарии» -> smollm: страница чата с моделью Ru-Small-Instruct без открытия мира.
-- Та же логика, что у tools/scenarios/smollm_chat.lua (прямой запуск при старте) — модуль smollm:launch.
app.config_packs({ "wasmrt", "smollm" })
app.load_content()
app.tick()
local launch = require("smollm:launch")
launch.open_page(menu)
launch.bind_leave(app, menu)
