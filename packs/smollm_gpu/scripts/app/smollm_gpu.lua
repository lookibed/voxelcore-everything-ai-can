-- Пункт меню «Сценарии» -> smollm_gpu: чат с Ru-Small-Instruct на GPU (страница smollm_gpu_chat, без мира).
-- То же, что tools/scenarios/smollm_gpu_chat.lua (прямой запуск при старте); логика — smollm_gpu:chat (launch / run).
-- Демо с тремя эталонными промптами — кнопка «Демо» на странице чата (или tools/scenarios/smollm_gpu_demo.lua).
-- Пробы разведки (чтение пикселей, матвек, профиль) — tools/scenarios/smollm_gpu_probe.lua.
app.config_packs({ "smollm_gpu" })
app.load_content()
app.tick()
require("smollm_gpu:chat").launch(app, menu)
