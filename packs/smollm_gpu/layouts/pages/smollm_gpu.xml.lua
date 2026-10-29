-- Страница демо smollm_gpu: строки приходят событием smollm_gpu:say от app-скрипта (llm.demo / chat «Демо»).
-- Обработчик вешается один раз на загрузку пака (флаг в модуле chat): повторное открытие страницы из чата
-- не должно удваивать строки.
local chat = require "smollm_gpu:chat"
lines = lines or {}

function on_open()
    lines = {}
    document.log.text = ""
    if not chat.say_hooked then
        chat.say_hooked = true
        events.on("smollm_gpu:say", function(text)
            lines[#lines + 1] = text
            if document.log and document.log.exists then document.log.text = table.concat(lines, "\n") end
        end)
    end
end

function leave()
    events.emit("smollm_gpu:leave")
end
