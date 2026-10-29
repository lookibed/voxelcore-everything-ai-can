-- Прямой запуск чата smollm_gpu при старте движка (project_client.lua / --script), без кликов по меню:
--   аренда лаборатории: lab lease wasmrt engine_rt --param script=smollm_gpu_chat.lua --param 'packs=["smollm_gpu"]' \
--       --param 'ready_marker=\[smollm_gpu_chat\] ready' [--param engine=v032] --start
-- То же, что пункт «Сценарии» → smollm_gpu (логика — smollm_gpu:chat). Пак подменяет ui.glslf: с gpu_worldgen не включать.
-- Файлы в --dir экземпляра (export:):
--   smollm_gpu_params.txt   — "temperature top_p rep_penalty max_new" (паритет: "0 0.85 1 120"; умолчания пака — карточка
--                             модели 0.25 0.85 1.15 120);
--   smollm_gpu_remember.txt — "1": помнить диалог (контекст копится; по умолчанию сбрасывается перед каждым вопросом);
--   smollm_gpu_prompt.txt   — если есть, вопрос отправляется сам, когда конвейер собран (путь разработки; проверка
--                             лаборатории вводит промпт F2F input в textbox, см. smollm_gpu_check.py);
--   smollm_gpu_dump_logits.txt — логиты первого токена ответа -> export:smollm_gpu/last_logits.f32 (cmp с эталоном C);
--   smollm_gpu_toktest.txt  — фразы (по строке, \n \t экранированы) -> export:smollm_gpu_toktest_out.txt (ids BPE на Lua).
-- Маркеры в логе: [smollm_gpu_chat] ready, [smollm_gpu] model ready, [smollm_gpu] prompt: ..., [smollm_gpu] reply tokens: ...,
-- [smollm_gpu] reply: ..., [smollm_gpu] reply done: ...
app.config_packs({ "smollm_gpu" })
app.load_content()
app.tick()
local chat = require("smollm_gpu:chat")
if file.isfile("export:smollm_gpu_params.txt") then
    local t, tp, rp, mx = file.read("export:smollm_gpu_params.txt"):match("([%d.]+)%s+([%d.]+)%s+([%d.]+)%s+(%d+)")
    if t then
        chat.params.temperature, chat.params.top_p = tonumber(t), tonumber(tp)
        chat.params.rep_penalty, chat.params.max_new = tonumber(rp), tonumber(mx)
        debug.log(("[smollm_gpu_chat] params t=%s top_p=%s rep=%s max_new=%s"):format(t, tp, rp, mx))
    end
end
if file.isfile("export:smollm_gpu_remember.txt") and file.read("export:smollm_gpu_remember.txt"):match("1") then
    chat.set_remember(true)
end
local auto = nil
if file.isfile("export:smollm_gpu_prompt.txt") then
    auto = file.read("export:smollm_gpu_prompt.txt"):gsub("%s+$", "")
    if auto == "" then auto = nil end
end
debug.log("[smollm_gpu_chat] ready" .. (auto and (" (auto prompt: " .. auto .. ")") or ""))
chat.launch(app, menu, {
    on_ready = function()
        if auto then
            chat.submit(auto)
            debug.log("[smollm_gpu_chat] auto prompt submitted")
        end
    end,
})
