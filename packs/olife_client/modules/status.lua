-- olife_client:status — UX B (16.10, olife_menu): the state of the login / connection, the ONLY source of the status
-- screen (layouts/pages/olife_status.xml in the menu, layouts/olife_status.xml as a HUD element in the game). The login
-- (olife_client:login), the in-game watcher (olife_client:play) and packs (olife_client:packs) publish here; views only
-- draw (olife_client:status_view) — publish -> subscribers are called, `seq` grows on every change.
-- The state table is owned by the application script (scripts/app/olife.lua): closing the world unloads the pack's
-- modules (0.32: content resets to "base"), so the script keeps the table and binds it again after the content reload
-- (M.bind) — the error of a lost connection survives into the menu.
-- Lines for tests: M.lines() — one text line per phase + error + progress; the lab gates on them (not on pixels).
local M = {}

-- the phases of a login in order (OLIFE_UX §8 p.1); in-game banners use the same table (mode = "game")
M.PHASES = {
    {id = "config",   title = "Адрес и ник"},
    {id = "ticket",   title = "Билет у сервиса"},
    {id = "connect",  title = "Соединение со шлюзом"},
    {id = "welcome",  title = "Приветствие сервера (Welcome)"},
    {id = "manifest", title = "Манифест паков"},
    {id = "download", title = "Загрузка файлов"},
    {id = "verify",   title = "Проверка sha256"},
    {id = "world",    title = "Мир-реплика"},
    {id = "chunks",   title = "Первые чанки"},
    {id = "play",     title = "В игре"},
}
local INDEX = {}
for i, p in ipairs(M.PHASES) do INDEX[p.id] = i end
M.INDEX = INDEX

-- error kinds -> human text (prefix of the line; the reason of the server/HTTP follows)
M.KINDS = {
    no_config   = "нет адреса шлюза",
    bad_address = "неверный адрес",
    bad_nick    = "неверный ник",
    auth_down   = "сервис билетов недоступен",
    auth_http   = "сервис билетов: ошибка HTTP",
    ticket      = "билет отклонён",
    banned      = "бан",
    whitelist   = "нет в вайтлисте",
    nick        = "ник недоступен",              -- antifraud: занят / похож / зарезервирован
    antifraud   = "антифрод: лимит",              -- частота, мультиаккаунт, сессии с адреса
    no_server   = "нет соединения со шлюзом",
    timeout     = "таймаут",
    refused     = "шлюз отказал",
    lost        = "соединение потеряно",
    restart     = "мир перезапускается",
    manifest    = "манифест паков",
    download    = "загрузка файла",
    sha256      = "расхождение sha256",
    world       = "мир-реплика",
    internal    = "ошибка клиента",
    no_info     = "шлюз не сообщил сведения о сервере",   -- olife_friends: InfoRequest без ответа, а данных нет
    server_key  = "ключ сервера не совпал",              -- olife_friends: отпечаток приглашения / запомненный ключ
}

-- Disconnect codes of the gateway (tools/olife/gateway_dev.py CODES = Rust gateway)
M.DISCONNECT = {[1] = "сервер остановлен", [2] = "таймаут рукопожатия", [3] = "ошибка протокола", [4] = "вход отклонён",
                [5] = "бан", [6] = "keepalive", [7] = "флуд", [8] = "таймаут", [9] = "мир недоступен (перезапуск)",
                [10] = "кик", [11] = "медленный клиент", [12] = "дубликат входа", [13] = "лимит",
                [14] = "билет просрочен", [15] = "билет уже использован", [16] = "подпись билета неверна",
                [17] = "билет для другого шлюза", [18] = "ник уже в игре с другого адреса",
                [19] = "сведения о сервере отправлены"}

local S                     -- bound state table (owned by the app script)
local subs = {}

-- wall clock: time.uptime() is the frame time — it stands still inside one long frame (app.new_world, reopen)
local function now()
    if time.precise_utc_time then return time.precise_utc_time() end
    return time.uptime()
end
M.now = now

local function fresh(t)
    t = t or {}
    t.mode = t.mode or "idle"      -- idle | login | game
    t.seq = t.seq or 0
    t.attempt = t.attempt or 0
    t.phases = t.phases or {}
    t.log = t.log or {}
    t.progress = t.progress or {}
    return t
end

function M.bind(t)
    -- views registered while this instance still had its own table (a HUD opened before the state was carried over)
    if S and S ~= t and S._views then
        t._views = t._views or {}
        for k, v in pairs(S._views) do t._views[k] = v end
    end
    S = fresh(t)
    M.S = S
    return S
end
M.bind({})

local function log(fmt, ...)
    local s = "[olife_status] " .. string.format(fmt, ...)
    if debug and debug.log then debug.log(s) else print(s) end
end

local function changed(what)
    S.seq = S.seq + 1
    for _, f in pairs(subs) do pcall(f, S, what) end
end

-- subscribe(key, fn(S, what)) — one subscriber per key (a view re-subscribes after the content reload)
function M.subscribe(key, fn) subs[key] = fn end
function M.unsubscribe(key) subs[key] = nil end

local function rec(id, state, text)
    local l = S.log
    l[#l + 1] = {t = now() - (S.t0 or now()), phase = id, state = state, text = text, attempt = S.attempt}
    if #l > 200 then table.remove(l, 1) end
    log("%s %s %s", id, state, tostring(text or ""))
end

-- a new login attempt to target {host, port, nick, ...}
function M.reset(target, mode)
    S.attempt = (S.attempt or 0) + 1
    S.mode = mode or "login"
    S.target = target
    S.phases = {}
    for _, p in ipairs(M.PHASES) do S.phases[p.id] = {state = "wait"} end
    S.current, S.error, S.banner, S.done, S.done_t = nil, nil, nil, false, nil
    S.progress = {}
    S.t0 = now()
    rec("reset", S.mode, target and string.format("%s@%s:%s", tostring(target.nick), tostring(target.host),
        tostring(target.port)) or "")
    changed("reset")
end

-- phase `id` runs now (the previous running one, if any and earlier, becomes ok)
function M.phase(id, detail)
    if S.current and S.current ~= id and S.phases[S.current] and S.phases[S.current].state == "run" then
        S.phases[S.current].state = "ok"
        S.phases[S.current].t1 = now()
    end
    local p = S.phases[id] or {}
    S.phases[id] = p
    p.state, p.detail, p.t0, p.t1 = "run", detail, now(), nil
    S.current = id
    rec(id, "run", detail)
    changed(id)
end

function M.detail(id, detail)
    local p = S.phases[id]
    if p and p.detail ~= detail then p.detail = detail; changed(id) end
end

function M.ok(id, detail)
    local p = S.phases[id] or {}
    S.phases[id] = p
    p.state, p.t1 = "ok", now()
    if detail then p.detail = detail end
    if S.current == id then S.current = nil end
    rec(id, "ok", p.detail)
    changed(id)
end

function M.skip(id, why)
    local p = S.phases[id] or {}
    S.phases[id] = p
    p.state, p.detail = "skip", why
    rec(id, "skip", why)
    changed(id)
end

-- progress of the downloads: {done, total, bytes, bytes_total, pack, file, verified, verify_total}
function M.progress(t)
    local pr = S.progress
    for k, v in pairs(t) do pr[k] = v end
    changed("progress")
end

-- error on phase `id`: kind (M.KINDS), code (protocol / HTTP / service code), text (the reason as received)
function M.fail(id, kind, code, text)
    id = id or S.current or "config"
    local p = S.phases[id] or {}
    S.phases[id] = p
    p.state, p.t1 = "fail", now()
    S.error = {phase = id, kind = kind, code = code, text = tostring(text or ""), title = M.KINDS[kind] or kind,
               attempt = S.attempt, t = now() - (S.t0 or now())}
    S.current = nil
    rec(id, "fail", string.format("%s code=%s %s", tostring(kind), tostring(code), tostring(text)))
    changed("error")
end

function M.finish()
    S.done = true
    S.done_t = now()
    S.mode = "game"
    rec("play", "done", nil)
    changed("done")
end

-- in-game banner (HUD status element): kind = packs_live | packs_reopen | packs_download | restarting | reconnect | lost,
-- text; nil kind hides it. `until_t` — hide by itself after that uptime.
function M.banner(kind, text, hold_s)
    if kind == nil then
        if S.banner then S.banner = nil; rec("banner", "hide", nil); changed("banner") end
        return
    end
    local b = S.banner
    if b and b.kind == kind and b.text == text then
        if hold_s then b.until_t = now() + hold_s end
        return
    end
    S.banner = {kind = kind, text = text, t = now(), until_t = hold_s and (now() + hold_s) or nil}
    S.banners = (S.banners or 0) + 1
    S.banner_log = S.banner_log or {}
    local bl = S.banner_log
    bl[#bl + 1] = {kind = kind, text = text, t = now()}
    if #bl > 40 then table.remove(bl, 1) end
    rec("banner", kind, text)
    changed("banner")
end

function M.tick()
    local b = S.banner
    if b and b.until_t and now() >= b.until_t then M.banner(nil) end
end

-- ------------------------------------------------------------------------------------------ text for views and tests
local MARK = {wait = "[ ]", run = "[..]", ok = "[ok]", skip = "[--]", fail = "[!!]"}
M.MARK = MARK

local function kb(n) return string.format("%.1f", (n or 0) / 1024) end

function M.progress_text()
    local p = S.progress
    if not p.total then return "" end
    local s = string.format("файлы %d/%d, %s/%s КБ", p.done or 0, p.total or 0, kb(p.bytes), kb(p.bytes_total))
    if p.verify_total then s = s .. string.format(", sha256 %d/%d", p.verified or 0, p.verify_total) end
    return s
end

function M.current_text()
    local p = S.progress
    if p.pack and p.file then return string.format("%s / %s", p.pack, p.file) end
    return ""
end

-- 0..1 for the progress bar (bytes when known, else files)
function M.fraction()
    local p = S.progress
    if (p.bytes_total or 0) > 0 then return math.min(1, (p.bytes or 0) / p.bytes_total) end
    if (p.total or 0) > 0 then return math.min(1, (p.done or 0) / p.total) end
    return 0
end

function M.line(id)
    local p = S.phases[id] or {state = "wait"}
    local title = M.PHASES[INDEX[id]] and M.PHASES[INDEX[id]].title or id
    local s = (MARK[p.state] or "[?]") .. " " .. title
    if p.detail and p.detail ~= "" then s = s .. ": " .. p.detail end
    if p.state == "ok" and p.t0 and p.t1 then s = s .. string.format(" (%.2f с)", p.t1 - p.t0) end
    return s
end

function M.error_text()
    local e = S.error
    if not e then return "" end
    return string.format("Ошибка [%s%s]: %s. %s", tostring(e.kind), e.code ~= nil and (" " .. tostring(e.code)) or "",
        e.title or "", e.text or "")
end

function M.lines()
    local out = {}
    for _, p in ipairs(M.PHASES) do out[#out + 1] = M.line(p.id) end
    return out
end

function M.title()
    local t = S.target
    if S.mode == "game" and S.banner then return S.banner.text end
    if S.error then return "Вход не удался" end
    if S.done then return "В игре" end
    if t then return string.format("Вход: %s @ %s:%s", tostring(t.nick), tostring(t.host), tostring(t.port)) end
    return "Olife"
end

-- F2F / tests: the whole state, plain data
function M.snapshot()
    local ph = {}
    for _, p in ipairs(M.PHASES) do
        local x = S.phases[p.id] or {state = "wait"}
        ph[#ph + 1] = {id = p.id, state = x.state, detail = x.detail,
                       ms = (x.t0 and x.t1) and math.floor((x.t1 - x.t0) * 1000 + 0.5) or nil}
    end
    return {mode = S.mode, seq = S.seq, attempt = S.attempt, target = S.target, current = S.current, done = S.done,
            phases = ph, lines = M.lines(), error = S.error, error_text = M.error_text(), progress = S.progress,
            progress_text = M.progress_text(), current_file = M.current_text(), fraction = M.fraction(),
            banner = S.banner, banners = S.banners or 0, banner_log = S.banner_log or {}, title = M.title(),
            log = S.log}
end

return M
