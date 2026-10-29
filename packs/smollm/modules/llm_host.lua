-- Расширение wasmrt для smollm (манифест: "extension": "smollm:llm_host"): очередь промптов от UI,
-- команды (стоп / сброс контекста), параметры генерации, текст ответа по токенам и статус программы.
-- Импорты vc.llm_* описаны в src/main_vc.c (Spider, tests/manual/real-world-smollm).
-- Состояние одно на модуль (один чат за раз); страница layouts/pages/smollm_chat.xml.lua читает его в ui_tick.
local M = {
    queue = {},            -- промпты для программы
    cmd = 0,               -- 1 — стоп генерации, 2 — сброс контекста
    remember = false,      -- помнить диалог: модель одноходовая (11.10: с историей в контексте она повторяет
                           -- предыдущую тему/ответ — и в нативном эталоне тоже), поэтому по умолчанию контекст
                           -- сбрасывается перед каждым вопросом; лента при этом остаётся
    params = { temperature = 0.25, top_p = 0.85, rep_penalty = 1.15, max_new = 120 },  -- карточка модели (HF:
                           -- temperature 0.25, top_p 0.85, repetition_penalty 1.15, max_new 120–150); паритет
                           -- лаборатории — temperature 0 и rep_penalty 1 через export:smollm_params.txt  -- temperature 0 = argmax (детерминированно)
    transcript = {},       -- { role = "user" | "model", text = ... }
    status = { phase = -1, a = 0, b = 0, c = 0 },
    tokens = {},           -- id токенов текущего ответа
    generating = false,
    dirty = true,
    replies = 0,
}

local PHASE_TEXT = {
    [-1] = "запуск программы...",
    [0] = "загрузка весов",
    [1] = "обработка промпта",
    [2] = "генерация",
    [3] = "готова",
    [4] = "ошибка",
    [5] = "контекст сброшен",
}

local function log(text) debug.log("[smollm] " .. text) end

-- Профиль по ядрам forward (11.10, llm_cpu): программа зовёт vc.llm_kprof(id, 0|1) до и после каждого ядра
-- (enum K_* в src/model.h), если llm_param(3) = 1. Включается файлом export:smollm_kprof.txt или полем манифеста
-- "kprof": true. Время ядра — без вложенных (softmax вложен в attention); часы — time.precise_time (0.32) или
-- os.clock (0.31, шаг 1 мс — доли верны в среднем). Время между квантами (кадр движка) попадает в ядро, на котором
-- программа уступила, поэтому сумма по ядрам ~ стене prefill/генерации. В лог: [smollm] kprof {...} (JSON).
M.KNAMES = { "embed", "rmsnorm", "quantize", "matvec_q8", "rope", "attention", "silu_mul", "residual", "logits", "softmax" }
local kp = { on = false, ms = {}, calls = {}, t0 = {}, stack = {}, depth = 0 }
local kclock = (time and time.precise_time) or os.clock
local function kp_reset()
    for k = 0, #M.KNAMES - 1 do kp.ms[k], kp.calls[k] = 0, 0 end
    kp.depth = 0
end
kp_reset()
local function kprof(id, phase)
    local t = kclock()
    if phase == 0 then
        if kp.depth > 0 then local p = kp.stack[kp.depth]; kp.ms[p] = kp.ms[p] + (t - kp.t0[p]) * 1000 end
        kp.depth = kp.depth + 1
        kp.stack[kp.depth] = id
        kp.t0[id] = t
        kp.calls[id] = kp.calls[id] + 1
    elseif kp.depth > 0 then
        kp.ms[id] = kp.ms[id] + (t - kp.t0[id]) * 1000
        kp.depth = kp.depth - 1
        if kp.depth > 0 then kp.t0[kp.stack[kp.depth]] = t end
    end
end
local function kp_report(what, ntok)
    if not kp.on or ntok <= 0 then return end
    local total, rows = 0, {}
    for k = 0, #M.KNAMES - 1 do total = total + kp.ms[k] end
    for k = 0, #M.KNAMES - 1 do
        rows[#rows + 1] = ('"%s":[%.3f,%.1f,%.0f]'):format(M.KNAMES[k + 1], kp.ms[k] / ntok,
            total > 0 and kp.ms[k] * 100 / total or 0, kp.calls[k] / ntok)
    end
    log(('kprof {"phase":"%s","tokens":%d,"ms_per_token":%.2f,"clock":"%s","kernels":{%s}}'):format(what, ntok,
        total / ntok, (time and time.precise_time) and "precise_time" or "os.clock", table.concat(rows, ",")))
    kp_reset()
end

function M.submit(text)
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return false end
    if not M.remember and #M.transcript > 0 then M.cmd = 2 end   -- сброс контекста программы, лента остаётся
    M.queue[#M.queue + 1] = text
    M.transcript[#M.transcript + 1] = { role = "user", text = text }
    M.transcript[#M.transcript + 1] = { role = "model", text = "" }
    M.dirty = true
    log("prompt: " .. text)
    return true
end

function M.stop() M.cmd = 1; log("stop requested") end

function M.set_remember(on)
    M.remember = on and true or false
    if not M.remember then M.cmd = 2 end
    M.dirty = true
    log("remember dialog: " .. tostring(M.remember))
end

function M.reset()
    M.cmd = 2
    M.transcript = {}
    M.dirty = true
    log("reset requested")
end

-- Текст ленты для textbox (последние записи)
function M.render_transcript()
    local parts = {}
    for _, e in ipairs(M.transcript) do
        -- в шрифте движка нет длинного тире (рисуется квадратом): только для показа, лог хранит текст как есть
        parts[#parts + 1] = (e.role == "user" and "Вы: " or "Модель: ") .. e.text:gsub("—", "-")
    end
    return table.concat(parts, "\n\n")
end

-- Строка статуса для UI
function M.status_text(ctx_max)
    local s = M.status
    local p = s.phase
    local base = PHASE_TEXT[p] or ("фаза " .. tostring(p))
    if p == 0 then
        return ("%s: %d / %d МБ"):format(base, math.floor(s.a / 1024), math.floor(s.b / 1024))
    elseif p == 1 then
        return ("%s: токен %d / %d, в контексте %d из %d"):format(base, s.a, s.b, s.c, ctx_max)
    elseif p == 2 then
        local rate = s.c > 0 and s.a * 1000 / s.c or 0
        return ("%s: %d токенов, %.2f ток/с, в контексте %d из %d%s"):format(base, s.a, rate, s.b, ctx_max,
            M.replies == 0 and " (прогрев JIT)" or "")
    elseif p == 3 then
        if s.a > 0 and s.c > 0 then
            return ("%s: последний ответ %d токенов за %.1f с (%.2f ток/с), в контексте %d из %d"):format(
                base, s.a, s.c / 1000, s.a * 1000 / s.c, s.b, ctx_max)
        end
        return ("%s, в контексте %d из %d"):format(base, s.b, ctx_max)
    elseif p == 4 then
        return ("%s %d"):format(base, s.a)
    end
    return base
end

local function current_entry()
    local e = M.transcript[#M.transcript]
    if e and e.role == "model" then return e end
    e = { role = "model", text = "" }
    M.transcript[#M.transcript + 1] = e
    return e
end

setmetatable(M, { __call = function(_, ctx)
    local api, memory = ctx.api, ctx.memory
    M.queue, M.cmd, M.tokens, M.generating = {}, 0, {}, false
    M.status = { phase = -1, a = 0, b = 0, c = 0 }
    M.ctx = ctx
    kp.on = (ctx.manifest and ctx.manifest.kprof) or file.isfile("export:smollm_kprof.txt")
    kp_reset()
    local selftest = file.isfile("export:smollm_selftest.txt")
    local prompt_tokens = 0
    -- Ручные Lua-ядра (llm_kernels.lua): манифест "kernels": "lua" (по умолчанию) | "c" — эталон C -> wasm -> Lua;
    -- "prefill_batch": N — prompt матрицей по N токенов (1 — по одному). Переопределение для замеров —
    -- export:smollm_kernels.txt ("c" или "lua") и export:smollm_batch.txt (число).
    local man = ctx.manifest or {}
    local kmode = man.kernels or "lua"
    local batch = tonumber(man.prefill_batch) or 1
    if file.isfile("export:smollm_kernels.txt") then kmode = file.read("export:smollm_kernels.txt"):gsub("%s+", "") end
    if file.isfile("export:smollm_batch.txt") then batch = tonumber((file.read("export:smollm_batch.txt"):gsub("%s+", ""))) or batch end
    local kernels = nil
    if kmode == "lua" then
        kernels = require("smollm:llm_kernels").new({
            words = function() local m = memory(); return m and m[1] and m[1].__w end,
            yield = ctx.slice_yield,
        })
    end
    log(("kernels %s, prefill batch %d"):format(kernels and "lua" or "c", batch))
    M.kernels = kernels
    return {
        llm_poll = function(buf, cap)
            local text = table.remove(M.queue, 1)
            if not text then return 0 end
            if #text > cap - 1 then text = text:sub(1, cap - 1) end
            api().write_string(memory(), buf, text)
            return #text
        end,
        llm_cmd = function()
            local c = M.cmd
            M.cmd = 0
            return c
        end,
        llm_param = function(which)
            if which == 0 then return math.floor(M.params.temperature * 1000 + 0.5) end
            if which == 1 then return math.floor(M.params.top_p * 1000 + 0.5) end
            if which == 2 then return M.params.max_new end
            if which == 7 then return math.floor((M.params.rep_penalty or 1) * 1000 + 0.5) end
            if which == 3 then return kp.on and 1 or 0 end
            if which == 4 then return selftest and 1 or 0 end
            if which == 5 then return kernels and 1 or 0 end
            if which == 6 then return batch end
            return 0
        end,
        -- памяти не табличная (bytearray) — words() = nil: ядро откажется, считает C
        llm_matmul = function(...)
            if not kernels or not memory()[1].__w then return 0 end
            return kernels.matmul(...)
        end,
        llm_attention = function(...)
            if not kernels or not memory()[1].__w then return 0 end
            return kernels.attention(...)
        end,
        llm_kprof = kprof,
        llm_emit = function(ptr, len)
            local piece = api().read_string(memory(), ptr, len)
            local e = current_entry()
            e.text = e.text .. piece
            M.dirty = true
        end,
        llm_token = function(id, pos)
            if #M.tokens == 0 then kp_report("prefill", prompt_tokens) end
            M.tokens[#M.tokens + 1] = id
            log(("gen %d pos %d"):format(id, pos))
        end,
        llm_logits = function(ptr, n)
            -- логиты первого токена ответа для сверки с эталоном (reference/logits_*.f32 в Spider)
            if file.isfile("export:smollm_dump_logits.txt") then
                local size = n * 4
                local data = Bytearray(size)
                api().copy_out(memory(), ptr, size, data.bytes, 0)
                if not file.isdir("export:smollm") then file.mkdirs("export:smollm") end
                file.write_bytes("export:smollm/last_logits.f32", data)
                log(("logits %d floats -> export:smollm/last_logits.f32"):format(n))
            end
        end,
        llm_status = function(phase, a, b, c)
            if phase == 1 and not M.generating then
                M.generating = true
                M.tokens = {}
                kp_reset()
            elseif phase == 3 and M.generating then
                M.generating = false
                kp_report("generation", #M.tokens)   -- forward на каждый токен ответа, включая конец (как main_vc.c)
                M.replies = M.replies + 1
                local e = M.transcript[#M.transcript]
                log(("reply tokens: %s"):format(table.concat(M.tokens, " ")))
                log(("reply: %s"):format((e and e.text or ""):gsub("\n", "\\n")))
                log(("reply done: %d tokens, %d ms, ctx %d, lua heap %.1f MB"):format(a, c, b, collectgarbage("count") / 1024))
            elseif phase == 5 then
                log("context reset")
            elseif phase == 4 then
                log(("error %d"):format(a))
            end
            if phase == 1 then prompt_tokens = b end
            M.status = { phase = phase, a = a, b = b, c = c }
            M.dirty = true
        end,
    }
end })

return M
