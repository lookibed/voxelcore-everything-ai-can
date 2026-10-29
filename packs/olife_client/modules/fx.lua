-- olife_client:fx — audio-visual feedback of every interaction (OLIFE_UX §1). Shared by the UX wave agents:
-- minimal API (A1/A2 contract): fx.ok(msg), fx.deny(msg, code); the catalogue: fx.event(name, text, opts).
-- One event = one sound (the user's prototype sounds in sounds/olife/*.ogg, generated ones in sounds/olife/fx_*.wav)
-- + one visual signal (HUD toast with the event's colour, optional screen-edge flash). Every event is logged in a
-- ring (fx.S.log) that the F2F `fx` command returns, so tests assert what the player saw and heard.
local M = {}
local S = {log = {}, n = 0, last = nil, flash = nil, by_event = {}}
M.S = S

-- colours (RGBA 0..255) of the toast / flash per kind
local COL = {
    info = {220, 240, 255, 255}, ok = {150, 255, 170, 255}, deny = {255, 150, 140, 255}, warn = {255, 210, 120, 255},
    op = {255, 170, 255, 255}, sys = {170, 200, 255, 255},
}
M.COL = COL

-- The catalogue of interaction events: sound (pack sound name under olife/), kind (toast colour), flash (edge
-- colour pulse), default text. Sounds: user's = inject/grab/release/delete/refuse/ok (prototype 0.30.6),
-- fx_* = synthesized (tools/olife/gen_sounds.py) where the user had none.
M.EVENTS = {
    inject     = {sound = "inject",     kind = "info", text = "Injector: редактор открыт"},
    run        = {sound = "ok",         kind = "ok",   text = "Запущено"},
    stop       = {sound = "fx_stop",    kind = "info", text = "Остановлено"},
    save       = {sound = "fx_save",    kind = "ok",   text = "Сохранено"},
    grab       = {sound = "grab",       kind = "info", text = "Захвачено"},
    release    = {sound = "release",    kind = "info", text = "Отпущено"},
    spawn      = {sound = "fx_spawn",   kind = "ok",   text = "Сущность создана"},
    delete     = {sound = "delete",     kind = "warn", text = "Сущность удалена"},
    fork       = {sound = "fx_fork",    kind = "ok",   text = "Форк создан"},
    deny       = {sound = "refuse",     kind = "deny", flash = "deny", text = "Нет прав"},
    throttle   = {sound = "fx_throttle", kind = "warn", flash = "warn", text = "Лимит / частота"},
    frozen     = {sound = "fx_freeze",  kind = "op",   flash = "op",   text = "Заморожено администратором"},
    unfrozen   = {sound = "fx_unfreeze", kind = "ok",  text = "Разморожено"},
    killed     = {sound = "delete",     kind = "op",   flash = "op",   text = "Сущность убита администратором"},
    limits     = {sound = "fx_op",      kind = "op",   text = "Лимиты изменены администратором"},
    kicked     = {sound = "fx_kick",    kind = "deny", flash = "deny", text = "Вы отключены администратором"},
    banned     = {sound = "fx_kick",    kind = "deny", flash = "deny", text = "Вы забанены"},
    restarting = {sound = "fx_restart", kind = "warn", flash = "warn", text = "Мир перезапускается, переподключение..."},
    chat       = {sound = "fx_chat",    kind = "info", text = nil, quiet_toast = true},
    op         = {sound = "fx_op",      kind = "op",   text = "Команда оператора выполнена"},
    -- antifraud 16.10 (world fraud.lua: Notice 13/14)
    fraud_warn     = {sound = "fx_throttle", kind = "warn", flash = "warn", text = "Антифрод: предупреждение"},
    fraud_throttle = {sound = "refuse",      kind = "deny", flash = "deny", text = "Антифрод: действия ограничены"},
    -- UX B1 (olife_b1): my-mobs panel
    confirm    = {sound = "fx_op",      kind = "warn", text = "Подтвердите действие"},
    rescue     = {sound = "fx_spawn",   kind = "ok",   text = "Моб спасён"},
    destroy    = {sound = "delete",     kind = "warn", text = "Моб уничтожен"},
    restore    = {sound = "fx_spawn",   kind = "ok",   text = "Моб восстановлен"},
    camera     = {sound = "ok",         kind = "info", text = "Камера"},
    select     = {sound = "fx_save",    kind = "info", text = "Моб выбран"},
    ok         = {sound = "ok",         kind = "ok",   text = "OK"},
    info       = {sound = nil,          kind = "info", text = ""},
}

-- status tag colours (RGB 0..1) per entity state (RUN/STOP/ERROR/THROTTLED/FROZEN); EntityMeta.status 0..4
M.STATUS = {[0] = "STOP", [1] = "RUN", [2] = "ERROR", [3] = "THROTTLED", [4] = "FROZEN"}
M.TAG_RGB = {[0] = {1, 1, 1}, [1] = {0.55, 1, 0.55}, [2] = {1, 0.45, 0.45}, [3] = {1, 0.78, 0.3}, [4] = {0.55, 0.8, 1}}
function M.tag_rgb(status) return M.TAG_RGB[status or 0] or M.TAG_RGB[0] end

local function OL() return require "olife_client:olife" end

local function play(name)
    if not name then return end
    if audio and audio.play_sound_2d then pcall(audio.play_sound_2d, "olife/" .. name, 0.8, 1.0) end
end

-- event `name` of the catalogue with `text` (nil = the default) -> sound + toast (+ flash); opts: {code, eid, silent,
-- no_toast, kind}
function M.event(name, text, opts)
    opts = opts or {}
    local ev = M.EVENTS[name] or M.EVENTS.info
    local kind = opts.kind or ev.kind or "info"
    text = text or ev.text or ""
    S.n = S.n + 1
    local rec = {n = S.n, event = name, text = text, sound = (not opts.silent) and ev.sound or nil, kind = kind,
                 code = opts.code, eid = opts.eid, t = time.uptime()}
    S.log[#S.log + 1] = rec
    if #S.log > 64 then table.remove(S.log, 1) end
    S.last = rec
    S.by_event[name] = (S.by_event[name] or 0) + 1
    print(string.format("[olife_client] fx %s sound=%s kind=%s code=%s text=%s", name, tostring(rec.sound), kind,
        tostring(opts.code), tostring(text):sub(1, 120)))
    if not opts.silent then play(ev.sound) end
    local ol = OL()
    -- keep the UX round 1 sound log of olife.lua in step (its F2F state shows `sounds`)
    if rec.sound and ol.S and ol.S.sounds then
        ol.S.stats.sounds = ol.S.stats.sounds + 1
        ol.S.sounds[#ol.S.sounds + 1] = {name = rec.sound, t = rec.t}
        if #ol.S.sounds > 16 then table.remove(ol.S.sounds, 1) end
    end
    if text ~= "" and not opts.no_toast and not ev.quiet_toast then
        ol.toast(text, kind == "deny" and "error" or kind)
        local d, c = ol.S and ol.S.hud_doc, COL[kind]
        if d and c then pcall(function() d.toast.color = {c[1], c[2], c[3], 255} end) end
    end
    if ev.flash then S.flash = {kind = ev.flash, t = rec.t} end
    return rec
end

function M.ok(msg) return M.event("ok", msg) end
function M.deny(msg, code)
    -- a refusal by limits / rate has its own sound and colour (code 9 rate; A2 op codes 20 throttle)
    if code == 9 or code == 20 then return M.event("throttle", msg, {code = code}) end
    return M.event("deny", msg, {code = code})
end

-- F2F `fx`: what the player saw and heard (newest last)
function M.state()
    return {n = S.n, last = S.last, log = S.log, by_event = S.by_event, flash = S.flash}
end

return M
