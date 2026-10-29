-- smollm_gpu:chat — чат с Ru-Small-Instruct на GPU-пути (12.10, llm_gpu_chat). Состояние (очередь, команды, лента,
-- статус, параметры) — одно на модуль, как smollm:llm_host у CPU-пака; страница layouts/pages/smollm_gpu_chat.xml.lua
-- читает его таймером. Работает M.run(app) в app-скрипте (scripts/app/smollm_gpu.lua или
-- tools/scenarios/smollm_gpu_chat.lua): app.tick() = один кадр движка = один токен (весь forward — один кадр GPU).
--
-- Ход: текст -> шаблон карточки модели -> BPE (smollm_gpu:bpe, на Lua) -> prefill по токену за кадр с позиции pos ->
-- первый токен ответа -> генерация до <|я_закончил|> (7) / <|endoftext|> (3) / max_new / «Стоп» / конца контекста 512.
--   * argmax-режим (temperature 0 и repetition_penalty <= 1 — паритет лаборатории): индекс максимума считает GPU
--     (фрейм AM2, чтение 1 текселя), логиты в Lua не читаются — как демо, токены = эталон C;
--   * семплирование (умолчание, карточка модели: temperature 0.25, top_p 0.85, repetition_penalty 1.15, max_new 120):
--     логиты целиком (фрейм LG, get_data) -> штраф за повторы HF (по всем токенам текущего контекста: logit > 0 ? /p : *p)
--     -> softmax(logit / T) -> top-p как sample_token в real-world-smollm/src/model.c (отсечка (1-p)/(n-1), сортировка,
--     накопление до > p, монета * cum) — в double, ГПСЧ Park–Miller (детерминированный, seed 1 на сессию, как rng = 1 у C).
--   * Контекст: по умолчанию сбрасывается перед каждым вопросом (pos = 0; модель одноходовая — с историей копирует прошлую
--     тему, см. content/smollm/README.md «Диалог и семплирование»); «помнить диалог» — продолжение с текущей pos,
--     следующий ход с новой строки ("\n<|юзер|>..."), как main_vc.c. Конец ответа (7) кладётся в KV-кэш (+1 кадр), как у C.
--     KV-кэш между ходами держат фреймы KA/KB/VA/VB (llm.idle(true) оставляет их копирование), «сброс» = pos 0.
local llm = require("smollm_gpu:llm")
local bpe = require("smollm_gpu:bpe")

local M = {
    queue = {},            -- вопросы от страницы
    cmd = 0,               -- 1 — стоп генерации, 2 — сброс контекста
    remember = false,      -- помнить диалог (по умолчанию контекст сбрасывается перед каждым вопросом, лента остаётся)
    params = { temperature = 0.25, top_p = 0.85, rep_penalty = 1.15, max_new = 120 },  -- карточка модели
    transcript = {},       -- { role = "user" | "model", text = ... }
    status = { phase = -1, a = 0, b = 0, c = 0 },
    dirty = true,
    replies = 0,
    pos = 0,               -- позиция в контексте (строк KV-кэша занято)
    leaving = false,       -- «Назад»: app-скрипт выходит в меню
    demo_req = false,      -- кнопка «Демо»
    in_demo = false,
}
M.CTX = 512
local EOS, EOT = 7, 3
local HEAD, TAIL = "<|юзер|>\n", "\n<|юзерзакончил|>\n<|я_начал|>\n"

local PHASE_TEXT = {
    [-1] = "запуск...",
    [0] = "загрузка весов и сборка конвейера",
    [1] = "обработка промпта",
    [2] = "генерация",
    [3] = "готова",
    [4] = "ошибка",
    [5] = "контекст сброшен",
    [6] = "демо (три эталонных промпта)",
}

local now = time.precise_time or os.clock
local function log(s) debug.log("[smollm_gpu] " .. s) end
M.log = log

local function set_status(phase, a, b, c)
    M.status = { phase = phase, a = a or 0, b = b or 0, c = c or 0, note = M.status.note }
    M.dirty = true
end

-- ---------------------------------------------------------------- UI-часть (зовёт страница)
function M.submit(text)
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return false end
    M.queue[#M.queue + 1] = text
    M.transcript[#M.transcript + 1] = { role = "user", text = text }
    M.transcript[#M.transcript + 1] = { role = "model", text = "" }
    M.dirty = true
    log("prompt: " .. text)
    return true
end

function M.stop() M.cmd = 1; log("stop requested") end

function M.set_remember(on)
    -- без флажка контекст и так сбрасывается перед следующим вопросом; текущий ответ не прерывается
    M.remember = on and true or false
    M.dirty = true
    log("remember dialog: " .. tostring(M.remember))
end

function M.reset()
    M.cmd = 2
    M.transcript = {}
    M.queue = {}
    M.dirty = true
    log("reset requested")
end

function M.render_transcript()
    local parts = {}
    for _, e in ipairs(M.transcript) do
        -- в шрифте движка нет длинного тире (рисуется квадратом): только для показа, лог хранит текст как есть
        local text = e.text:gsub("—", "-"):gsub("%s+$", "")
        parts[#parts + 1] = (e.role == "user" and "Вы: " or "Модель: ") .. text
    end
    return table.concat(parts, "\n\n")
end

function M.status_text()
    local s, CTX = M.status, M.CTX
    local p = s.phase
    local base = PHASE_TEXT[p] or ("фаза " .. tostring(p))
    if p == 0 then
        return base .. (M.status.note and (": " .. M.status.note) or "...")
    elseif p == 1 then
        return ("%s: токен %d / %d, в контексте %d из %d (1 токен = 1 кадр)"):format(base, s.a, s.b, s.c, CTX)
    elseif p == 2 then
        local rate = s.c > 0 and s.a * 1000 / s.c or 0
        return ("%s: %d токенов, %.1f ток/с, в контексте %d из %d (1 токен = 1 кадр)"):format(base, s.a, rate, s.b, CTX)
    elseif p == 3 then
        if s.a > 0 and s.c > 0 then
            return ("%s: последний ответ %d токенов за %.2f с (%.1f ток/с), в контексте %d из %d"):format(
                base, s.a, s.c / 1000, s.a * 1000 / s.c, s.b, CTX)
        end
        return ("%s, в контексте %d из %d"):format(base, s.b, CTX)
    elseif p == 4 then
        return base .. ": " .. tostring(M.status.note or s.a)
    end
    return base
end

-- ---------------------------------------------------------------- токенизатор
function M.tokenizer()
    if M.tok then return M.tok end
    local t0 = now()
    local s = Bytearray_as_string(file.read_bytes("smollm_gpu:data/tokenizer.bin"))
    M.tok = bpe.new(function(i) return s:byte(i + 1) end, #s, require("smollm_gpu:unicode_tables"))
    log(("tokenizer: vocab %d, merges %d, specials %d, loaded in %.1f ms"):format(M.tok.vocab_size, M.tok.n_merges,
        #M.tok.specials, (now() - t0) * 1000))
    return M.tok
end

-- самопроверка кодировщика в движке: export:smollm_gpu_toktest.txt (строки с \n/\t, как --tok-test run_native) ->
-- export:smollm_gpu_toktest_out.txt (ids по строке + ROUNDTRIP-MISMATCH при decode ~= вход)
function M.toktest()
    local path = "export:smollm_gpu_toktest.txt"
    if not file.isfile(path) then return end
    local tok, out, n, ntok, rt = M.tokenizer(), {}, 0, 0, 0
    local t0 = now()
    for line in (file.read(path) .. "\n"):gmatch("(.-)\r?\n") do
        if line ~= "" then
            local s = line:gsub("\\([nt])", { n = "\n", t = "\t" })
            local ids = tok:encode(s)
            out[#out + 1] = table.concat(ids, " ")
            if tok:decode(ids) ~= s then out[#out + 1] = "ROUNDTRIP-MISMATCH"; rt = rt + 1 end
            n, ntok = n + 1, ntok + #ids
        end
    end
    file.write("export:smollm_gpu_toktest_out.txt", table.concat(out, "\n") .. "\n")
    log(("toktest: %d phrases, %d tokens, roundtrip mismatches %d, %.1f ms"):format(n, ntok, rt, (now() - t0) * 1000))
end

-- ---------------------------------------------------------------- семплирование
local rng_state = 1
local function rng()   -- Park–Miller (minimal standard), точен в double: 48271 * 2^31 < 2^53
    rng_state = (rng_state * 48271) % 2147483647
    return rng_state / 2147483647
end

local logits, probs, cand = {}, {}, {}
local N = 24576

local prof = { read = 0, sample = 0, n = 0 }   -- время чтения логитов (to_canvas + get_data + декод) и семплера, мс
M.prof = prof
local function sample(seen_list, P)
    local temp, topp, rep = P.temperature, P.top_p, P.rep_penalty or 1
    local ta = now()
    llm.logits_f32(logits, M.dump_bits)
    local tb = now()
    prof.read, prof.n = prof.read + (tb - ta) * 1000, prof.n + 1
    local id = M.sample_logits(logits, seen_list, temp, topp, rep)
    prof.sample = prof.sample + (now() - tb) * 1000
    return id
end

-- семплер над логитами (массив 0..N-1, меняется на месте: штраф), см. заголовок модуля
function M.sample_logits(logits, seen_list, temp, topp, rep)
    if rep > 1 then
        for _, id in ipairs(seen_list) do
            local l = logits[id]
            logits[id] = l > 0 and l / rep or l * rep
        end
    end
    if temp <= 0 then
        local mi, mv = 0, logits[0]
        for i = 1, N - 1 do if logits[i] > mv then mi, mv = i, logits[i] end end
        return mi
    end
    local mx = -math.huge
    for i = 0, N - 1 do
        local v = logits[i] / temp
        probs[i] = v
        if v > mx then mx = v end
    end
    local sum, exp = 0, math.exp
    for i = 0, N - 1 do local e = exp(probs[i] - mx); probs[i] = e; sum = sum + e end
    for i = 0, N - 1 do probs[i] = probs[i] / sum end
    local coin = rng()
    if topp <= 0 or topp >= 1 then
        local cdf = 0
        for i = 0, N - 1 do cdf = cdf + probs[i]; if coin < cdf then return i end end
        return N - 1
    end
    local cutoff, n0 = (1 - topp) / (N - 1), 0
    for i = 0, N - 1 do if probs[i] >= cutoff then n0 = n0 + 1; cand[n0] = i end end
    for k = n0 + 1, #cand do cand[k] = nil end
    table.sort(cand, function(a, b) if probs[a] ~= probs[b] then return probs[a] > probs[b] end return a < b end)
    local cum, last = 0, n0
    for k = 1, n0 do cum = cum + probs[cand[k]]; if cum > topp then last = k; break end end
    local r, cdf = coin * cum, 0
    for k = 1, last do cdf = cdf + probs[cand[k]]; if r < cdf then return cand[k] end end
    return cand[last]
end

-- ---------------------------------------------------------------- ход диалога
local seen, seen_list = {}, {}
local function reset_context(reason)
    M.pos = 0
    seen, seen_list = {}, {}
    set_status(5, 0, 0, 0)
    log("context reset" .. (reason and (" (" .. reason .. ")") or ""))
end
local function mark_seen(id)
    if not seen[id] then seen[id] = true; seen_list[#seen_list + 1] = id end
end

local function take_cmd()
    local c = M.cmd
    M.cmd = 0
    if c == 2 then reset_context("command") end
    return c
end

-- внутри хода: «Стоп» (1) — снять и прервать; «Очистить» (2) — прервать, сброс сделает главный цикл; «Назад» — прервать
local function interrupted()
    if M.cmd == 1 then M.cmd = 0; return true end
    return M.cmd == 2 or M.leaving
end

local function current_entry()
    local e = M.transcript[#M.transcript]
    if e and e.role == "model" then return e end
    e = { role = "model", text = "" }
    M.transcript[#M.transcript + 1] = e
    return e
end

local function answer(app, text)
    local tok = M.tokenizer()
    local P = M.params
    if not M.remember and M.pos > 0 then reset_context("new question") end
    local function encode() return tok:encode((M.pos > 0 and "\n" or "") .. HEAD .. text .. TAIL) end
    local ids = encode()
    if M.pos + #ids + 1 >= M.CTX then
        reset_context("context full")
        ids = encode()
    end
    if #ids + 1 >= M.CTX then
        M.status.note = ("вопрос слишком длинный: %d токенов из %d"):format(#ids, M.CTX)
        set_status(4, #ids)
        log("error: prompt too long " .. #ids)
        current_entry().text = "(" .. M.status.note .. ")"
        return
    end
    log(("prompt tokens (%d, from pos %d): %s"):format(#ids, M.pos, table.concat(ids, " ")))
    for _, id in ipairs(ids) do mark_seen(id) end
    local argmax_mode = P.temperature <= 0 and (P.rep_penalty or 1) <= 1
    local dump = file.isfile("export:smollm_gpu_dump_logits.txt")
    llm.wake()
    local t0 = now()
    local stopped, fed = false, 0
    for i = 1, #ids do
        set_status(1, i - 1, #ids, M.pos)
        llm.set_token(ids[i], M.pos)
        app.tick()
        M.pos = M.pos + 1
        fed = fed + 1
        if interrupted() then stopped = true; break end
    end
    local t1 = now()
    log(("prefill %d tokens in %.1f ms (%.2f ms/token), ctx %d%s"):format(fed, (t1 - t0) * 1000, (t1 - t0) * 1000 / fed,
        M.pos, stopped and " (stopped)" or ""))
    local e = current_entry()
    local gen, count, raw, shown = {}, 0, "", 0
    local g0 = now()
    local function next_token(first)
        if argmax_mode and not (first and dump) then return (llm.argmax()) end
        M.dump_bits = (first and dump) and {} or nil
        local id = sample(seen_list, P)
        if M.dump_bits then
            if not file.isdir("export:smollm_gpu") then file.mkdirs("export:smollm_gpu") end
            file.write_bytes("export:smollm_gpu/last_logits.f32", llm.bits_to_bytes(M.dump_bits))
            local gid = llm.argmax()
            log(("logits 24576 floats -> export:smollm_gpu/last_logits.f32 (GPU argmax %d, chosen %d)"):format(gid, id))
            M.dump_bits = nil
            if argmax_mode then id = gid end
        end
        return id
    end
    local t_first, frames = nil, 0   -- скорость декодирования: кадры после первого токена (как демо README: 43-45 ток/с)
    if not stopped then
        local nxt = next_token(true)
        t_first = now()
        while M.pos < M.CTX and count < P.max_new do
            mark_seen(nxt)
            gen[#gen + 1] = nxt
            if nxt == EOS or nxt == EOT then
                -- конец ответа тоже кладём в кэш, чтобы диалог продолжался с него (как main_vc.c)
                llm.set_token(nxt, M.pos)
                app.tick()
                frames = frames + 1
                M.pos = M.pos + 1
                break
            end
            raw = raw .. tok:piece(nxt)
            local k = bpe.utf8_complete(raw)
            if k > shown then e.text = raw:sub(1, k); shown = k end
            count = count + 1
            set_status(2, count, M.pos, (now() - g0) * 1000)
            if interrupted() then stopped = true; break end
            llm.set_token(nxt, M.pos)
            app.tick()
            frames = frames + 1
            M.pos = M.pos + 1
            nxt = next_token(false)
        end
    end
    local t_end = now()
    local gms = (t_end - g0) * 1000
    local sprof = prof.n > 0 and (", logits read %.2f ms + sampler %.2f ms per token (%d)"):format(prof.read / prof.n,
        prof.sample / prof.n, prof.n) or ""
    prof.read, prof.sample, prof.n = 0, 0, 0
    local dec = (t_first and frames > 0) and ("decode %d frames in %.1f ms = %.1f tok/s, first token %.1f ms"):format(frames,
        (t_end - t_first) * 1000, frames / (t_end - t_first), (t_first - g0) * 1000) or "decode -"
    e.text = raw
    M.replies = M.replies + 1
    llm.idle(true)
    log(("reply tokens: %s"):format(table.concat(gen, " ")))
    log(("reply: %s"):format(raw:gsub("\n", "\\n")))
    log("reply timing: " .. dec .. sprof)
    log(("reply done: %d tokens, %d ms, %.2f tok/s, prefill %d tokens %.2f ms/token, ctx %d, mode %s%s, lua heap %.1f MB")
        :format(count, math.floor(gms + 0.5), count > 0 and count * 1000 / gms or 0, fed,
            (t1 - t0) * 1000 / fed, M.pos, argmax_mode and "argmax" or ("sample t=%g top_p=%g rep=%g"):format(
                P.temperature, P.top_p, P.rep_penalty or 1), stopped and ", stopped" or "", collectgarbage("count") / 1024))
    set_status(3, count, M.pos, gms)
end

-- ---------------------------------------------------------------- главный цикл (app-скрипт)
-- opts.on_ready() — после сборки конвейера (сценарии: автопромпт); opts.demo(say, stop) — кнопка «Демо».
function M.run(app, opts)
    opts = opts or {}
    M.leaving, M.demo_req, M.in_demo = false, false, false
    M.queue, M.cmd, M.pos = {}, 0, 0
    rng_state = 1
    seen, seen_list = {}, {}
    M.status = { phase = 0, a = 0, b = 0, c = 0, note = "токенизатор" }
    M.dirty = true
    app.tick()
    local ok, err = pcall(function()
        M.tokenizer()
        M.toktest()
        llm.ensure_pipeline(app, function(text)
            M.status.note = text
            M.dirty = true
            app.tick()
        end)
    end)
    if not ok then
        M.status = { phase = 4, a = 0, b = 0, c = 0, note = tostring(err) }
        M.dirty = true
        log("error: " .. tostring(err))
        while not M.leaving do app.tick() end
        return
    end
    llm.idle(true)
    set_status(3, 0, 0, 0)
    log(("model ready (%s)"):format(llm.order and (#llm.order .. " frames") or "?"))
    if opts.on_ready then opts.on_ready() end
    while not M.leaving do
        take_cmd()
        if M.demo_req then
            M.demo_req = false
            if opts.demo then
                M.in_demo = true
                set_status(6)
                local okd, errd = pcall(opts.demo)
                if not okd then log("demo error: " .. tostring(errd)) end
                M.in_demo = false
                reset_context("after demo")   -- демо писало KV-кэш с позиции 0
                llm.idle(true)
                set_status(3, 0, 0, 0)
            end
        end
        local text = table.remove(M.queue, 1)
        if text then
            local oka, erra = pcall(answer, app, text)
            if not oka then
                M.status.note = tostring(erra)
                set_status(4)
                log("error: " .. tostring(erra))
                llm.idle(true)
            end
        else
            app.tick()
        end
    end
    llm.idle(false)
    log("chat loop done")
end

-- Полный запуск из app-скрипта: страница чата, цикл модели, «Демо» (страница smollm_gpu, её «Назад» — обратно в чат),
-- «Назад» чата — в главное меню. opts.on_ready — после сборки конвейера (сценарии: автопромпт).
function M.launch(app, menu, opts)
    opts = opts or {}
    events.on("smollm_gpu:leave", function() if M.in_demo then M.demo_back = true end end)
    menu.page = "smollm_gpu_chat"
    app.tick()
    opts.demo = function()
        M.demo_back = false
        menu.page = "smollm_gpu"
        app.tick()
        local function say(text)
            debug.log("[sg] demo: " .. text)
            events.emit("smollm_gpu:say", text)
        end
        local function stop() return M.demo_back or M.leaving end
        say("три эталонных промпта (уже токенами), argmax на GPU, сверка с эталоном C; «Назад» - в чат")
        llm.demo_prompts(say, stop)
        say("готово (конвейер остановлен)")
        log("demo done")
        while not stop() do app.tick() end
        if not M.leaving then
            menu.page = "smollm_gpu_chat"
            app.tick()
        end
    end
    M.run(app, opts)
    app.reset_content()
    menu:reset()
    menu.page = "main"
end

return M
