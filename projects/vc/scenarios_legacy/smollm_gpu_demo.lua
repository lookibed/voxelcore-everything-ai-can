-- Прямой запуск демо smollm_gpu при старте (аренда lab: --param script=smollm_gpu_demo.lua --param packs=["smollm_gpu"]
--   --param ready_marker="\[sg\] demo done"). То же, что кнопка «Демо» чата smollm_gpu («Сценарии» -> smollm_gpu открывает чат с 12.10).
-- Пробы разведки (чтение пикселей, матвек, профиль) — tools/scenarios/smollm_gpu_probe.lua.
app.config_packs({ "smollm_gpu" })
app.load_content()
app.tick()
local leaving = false
events.on("smollm_gpu:leave", function() leaving = true end)
menu.page = "smollm_gpu"
app.tick()
local function say(text)
    debug.log("[sg] demo: " .. text)
    events.emit("smollm_gpu:say", text)
end
local ok, err = pcall(require("smollm_gpu:llm").demo, app, say, function() return leaving end)
if not ok then say("ошибка: " .. tostring(err)) end
debug.log("[sg] demo done")
while not leaving do app.tick() end
app.reset_content()
menu:reset()
menu.page = "main"
