-- Оверлей вокруг экрана компьютера pc_wasmrt:pc (см. pc_overlay.xml и modules/pc_os.lua «XML-оверлей»).
-- on_open(uid) — из hud.show_overlay(..., {uid}) в PC:enter; on_close — при hud.close в PC:leave (или если
-- оверлей закрыл движок — тогда pc_os сажает игрока «встать»). Раскладка — от gui.get_viewport(), опрос
-- каждые 50 мс (как dagger_pc: событий изменения окна нет); тексты — pc_os.overlay_texts().
local pc_os = require "pc_wasmrt:pc_os"

local BAND = 76             -- полоса под экраном при зуме 1 (pc_os HUD_RESERVE)
local CH = 8                -- ширина символа шрифта по умолчанию (оценка для ширины стикера)
local STICKERS = { "st_cam", "st_mouse", "st_keys", "st_hold" }
local BUTTONS = { standup = "btn_standup", lock = "btn_lock", zoom = "btn_zoom" }
local ov = { rects = {}, texts = {}, viewport = { 0, 0 } }
local vw, vh = 0, 0

local function utf8_len(s) local _, n = s:gsub("[^\128-\191]", ""); return n end

-- document[id] — ленивый прокси: ошибка «no element with id» возникает при обращении к атрибуту, поэтому
-- состав подэлементов задан явно: стикер — тень/фон/кромка/подпись, кнопка — только подпись.
local function place(id, x, y, w, h, sticker)
    local el = document[id]
    el.pos = { x, y }
    el.size = { w, h }
    if sticker then
        local sh, bg, edge = document[id .. "_sh"], document[id .. "_bg"], document[id .. "_edge"]
        sh.pos = { 3, 3 }; sh.size = { w, h }
        bg.size = { w, h }
        edge.size = { 4, h }
    end
    document[id .. "_lbl"].size = { w - 12, 18 }
end

local function sticker_w(text) return math.max(150, utf8_len(text) * CH + 28) end

local function layout()
    local vp = gui.get_viewport()
    vw, vh = vp[1], vp[2]
    ov.viewport = { vw, vh }
    local t = ov.texts
    local y0, y1 = vh - BAND + 6, vh - BAND + 40   -- две строки стикеров в полосе
    -- слева: камера, мышь
    local lw = math.max(sticker_w(t.cam or ""), sticker_w(t.mouse or ""))
    place("st_cam", 12, y0, lw, 30, true)
    place("st_mouse", 12, y1, lw, 30, true)
    -- справа: клавиши, удержание Esc
    local rw = math.max(sticker_w(t.keys or ""), sticker_w(t.hold or ""))
    place("st_keys", vw - rw - 12, y0, rw, 30, true)
    place("st_hold", vw - rw - 12, y1, rw, 30, true)
    -- кнопки по центру одной строкой; если полоса узкая — строкой выше стикеров
    local bw = { standup = 120, lock = 170, zoom = 140 }
    local total = bw.standup + bw.lock + bw.zoom + 2 * 10
    local by = vh - BAND + 22
    if 12 + lw + 20 + total + 20 + rw + 12 > vw then by = vh - BAND - 36 end
    local x = math.floor((vw - total) / 2)
    ov.rects = {}
    for _, name in ipairs({ "standup", "lock", "zoom" }) do
        local id = BUTTONS[name]
        place(id, x, by, bw[name], 32)
        ov.rects[name] = { x = x, y = by, w = bw[name], h = 32 }
        x = x + bw[name] + 10
    end
end

local function refresh()
    local t = pc_os.overlay_texts()
    local changed = false
    for k, v in pairs(t) do
        if ov.texts[k] ~= v then changed = true end
    end
    ov.texts = t
    document.st_cam_lbl.text = t.cam
    document.st_mouse_lbl.text = t.mouse
    document.st_keys_lbl.text = t.keys
    document.st_hold_lbl.text = t.hold
    document.btn_lock_lbl.text = t.lock_btn
    document.btn_zoom_lbl.text = t.zoom_btn
    document.btn_standup_lbl.text = t.standup_btn
    if changed then layout() end
end
ov.refresh = refresh

function ov_action(name)
    pc_os.overlay_action(name)
end

function on_open(uid)
    ov.uid = uid
    pc_os.overlay_attach(ov)
    refresh()
    layout()
    document.root:setInterval(50, function()
        local vp = gui.get_viewport()
        if vp[1] ~= vw or vp[2] ~= vh then layout() end
        refresh()
    end)
end

function on_close()
    pc_os.overlay_detach()
end
