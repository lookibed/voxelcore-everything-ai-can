-- Прямой запуск чата smollm при старте движка (project_client.lua), без кликов по меню:
--   vc_start(script="user:tools/scenarios/smollm_chat.lua") или аренда лаборатории
--   lab lease wasmrt engine_rt --param script=smollm_chat.lua --param packs=wasmrt,smollm \
--       --param ready_marker='\[smollm_chat\] ready' --start
-- То же, что пункт «Сценарии» → smollm (логика — smollm:launch).
-- Файлы в --dir экземпляра:
--   export:smollm_prompt.txt   — если есть, промпт отправляется сам, когда модель загружена (путь разработки;
--                                 проверка лаборатории вводит промпт F2F input в textbox, см. smollm_check.py);
--   export:smollm_manifest.txt — другой манифест (smollm:wasm_jitdefault.json — стоковые настройки JIT);
--   export:smollm_dump_logits.txt — писать логиты первого токена ответа в export:smollm/last_logits.f32;
--   export:smollm_params.txt   — "temperature top_p rep_penalty max_new" (паритет: "0 0.85 1 120"; умолчания
--                                 пака — карточка модели 0.25 0.85 1.15 120);
--   export:smollm_remember.txt — "1": помнить диалог (контекст копится; по умолчанию сбрасывается перед вопросом).
-- Маркеры в логе: [smollm] page open, [smollm_chat] ready, [smollm] reply tokens: ..., [smollm] reply done.
app.config_packs({ "wasmrt", "smollm" })
app.load_content()
app.tick()
local launch = require("smollm:launch")
launch.open_page(menu)
launch.bind_leave(app, menu)

local auto = nil
if file.isfile("export:smollm_prompt.txt") then
    auto = file.read("export:smollm_prompt.txt"):gsub("%s+$", "")
    if auto == "" then auto = nil end
end
do
    local host = require("smollm:llm_host")
    if file.isfile("export:smollm_params.txt") then
        local t, tp, rp, mx = file.read("export:smollm_params.txt"):match("([%d.]+)%s+([%d.]+)%s+([%d.]+)%s+(%d+)")
        if t then
            host.params.temperature, host.params.top_p = tonumber(t), tonumber(tp)
            host.params.rep_penalty, host.params.max_new = tonumber(rp), tonumber(mx)
            debug.log(("[smollm_chat] params t=%s top_p=%s rep=%s max_new=%s"):format(t, tp, rp, mx))
        end
    end
    if file.isfile("export:smollm_remember.txt") and file.read("export:smollm_remember.txt"):match("1") then
        host.set_remember(true)
    end
end
app.sleep(1)
debug.log("[smollm_chat] ready" .. (auto and (" (auto prompt: " .. auto .. ")") or ""))
if auto then
    local host = require("smollm:llm_host")
    local waited = 0
    while host.status.phase ~= 3 and host.status.phase ~= 4 and waited < 600 do
        app.sleep(0.25)
        waited = waited + 0.25
    end
    if host.status.phase == 3 then
        host.submit(auto)
        debug.log("[smollm_chat] auto prompt submitted after " .. waited .. " s")
    else
        debug.log("[smollm_chat] auto prompt not sent: phase " .. tostring(host.status.phase))
    end
end
