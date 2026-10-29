-- olife_client:mobs — UX B1 (03.10, olife_b1): Injector in hand = "my mobs" mode (OLIFE_UX §2), client side.
--   Panel (layouts/mobs.xml, native 0.32 XML; key M with the Injector selected, or the HUD button): the player's
--   mobs from MobsList of the world (name, status, cost cr/min + fuel + KV memory, distance / relative direction,
--   "вне прогрузки" when the world's chunk is unloaded, "не видно" when the replica has no such entity), per row:
--   «Выбрать» (highlight in the world: 3D text through walls + particles on the entity; HUD marker/arrow that follows
--   it), «Камера» (third person / from the eyes, key V cycles, V again = back), «Спасти», «Уничтожить»; the "last
--   state" slots of removed mobs with «Восстановить». Emergency actions are two-step: the world answers MobConfirm
--   with a token, the panel shows what will happen, «Подтвердить» sends the token (sound + toast through fx).
--   Editor (olife_client:olife): the error line of the status/console text (":<line>:") is highlighted (caret on
--   that line, keep-line-selection, scrolled into view) + a label; tab «Профиль» = MobProfile (owner, rights, code
--   hash, run time, counters, last errors) + CodeHistory rows («Открыть» = the version text into the editor as
--   unsaved edits, «Восстановить» = the version becomes the code as a new commit).
--   Camera is client-only (0.32 `cameras`: resources.json camera "mobcam", player.set_camera); the world knows nothing.
-- The world decides everything (olife_world:mobs); this module only asks and shows. F2F `mobs {op}` — tests.
local FX = require "olife_client:fx"

local M = {}
local S = {
    doc = nil, list = nil, rows = {}, dead_rows = {}, sel = nil, confirm = nil, pid = nil, hud_doc = nil,
    cam_mode = 0, cam_eid = nil, cam = nil, cam_idx = nil, first_idx = nil, cam_pos = nil, cam_target = nil,
    mark_id = nil, mark_eid = nil, part_id = nil, part_uid = nil, rescue_marks = {},
    profile = {}, history = {}, vtext = {}, replies = {}, rescued = {}, restored = {}, err_shown = {}, want_panel = nil,
    marker = nil, open_at = 0,
    stats = {lists = 0, watch_lists = 0, confirms = 0, actions = 0, confirmed = 0, cancelled = 0, rescued = 0,
             restored = 0, profiles = 0, histories = 0, vtexts = 0, ui_errors = 0, cam_frames = 0, cam_switches = 0,
             selects = 0, opens = 0, closes = 0, denied = 0, oks = 0, marker_frames = 0},
}
M.S = S

local STATUS_TXT = {[0] = "STOP", [1] = "RUN", [2] = "ERROR", [3] = "THROTTLED", [4] = "FROZEN"}
local OP_RU = {[12] = "список", [13] = "спасти", [14] = "уничтожить", [15] = "восстановить", [16] = "профиль",
               [17] = "история", [18] = "версия"}
M.OP_RU = OP_RU
local CODE_RU = {[22] = "нужно подтверждение", [23] = "подтверждение устарело", [24] = "безопасная позиция неизвестна",
                 [25] = "чанк не прогружен: подойдите ближе", [26] = "нечего восстанавливать", [27] = "лимит",
                 [28] = "нет такой версии", [29] = "хранилище отказало"}
M.CODE_RU = CODE_RU
local ACT_RU = {[1] = "Спасти", [2] = "Уничтожить", [3] = "Восстановить"}

local function log(fmt, ...) print("[olife_client] mobs: " .. string.format(fmt, ...)) end
local function cl() return require "olife_client:client" end
local function ol() return require "olife_client:olife" end

local function send(name, msg)
    local o = ol()
    msg.seq = msg.seq or (function() o.S.seq = o.S.seq + 1; return o.S.seq end)()
    o.send(name, msg)
    return msg.seq
end

local function esc(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("'", "&apos;"):gsub('"', "&quot;"))
end

local function fmt_num(v)
    v = v or 0
    if v < 0 then return "н/д" end
    if v >= 1e6 then return string.format("%.1fM", v / 1e6) end
    if v >= 1e3 then return string.format("%.1fk", v / 1e3) end
    return string.format("%.0f", v)
end

local function fmt_bytes(v)
    if not v or v < 0 then return "н/д" end
    if v >= 1048576 then return string.format("%.1f МБ", v / 1048576) end
    if v >= 1024 then return string.format("%.1f КБ", v / 1024) end
    return string.format("%d Б", v)
end

local function ui_busy()
    local ok, open = pcall(hud.is_inventory_open)
    return ok and open or false
end

local function panel_open()
    return hud and hud.is_open and hud.is_open("olife_client:mobs") or false
end

local function my_pos()
    local pid = S.pid
    if not pid then return nil end
    local x, y, z = player.get_pos(pid)
    local yaw = player.get_rot(pid)
    return {x = x, y = y, z = z, yaw = yaw or 0}
end

-- replica position of a mob (shown = interpolated), or nil when the replica does not hold it
local function mob_pos(eid)
    local e = cl().S.ents[eid]
    if not e then return nil, nil end
    local p = e.shown or e.pos
    return {x = p.x, y = p.y, z = p.z}, e
end

-- distance and relative direction words ("12 м впереди-слева, выше")
local function where_text(info)
    local me = my_pos()
    local p = info.pos
    if not me then return "?" end
    local dx, dy, dz = p.x - me.x, p.y - me.y, p.z - me.z
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    local yaw = math.rad(me.yaw)
    local fx, fz = -math.sin(yaw), -math.cos(yaw)            -- the engine's front for rot.x = yaw (olife_proto:movement)
    local rx, rz = -fz, fx                                   -- right
    local ahead = dx * fx + dz * fz
    local right = dx * rx + dz * rz
    local ang = math.deg(math.atan2(right, ahead))           -- 0 ahead, +90 right, 180 behind
    local dir
    local a = math.abs(ang)
    if a < 22.5 then dir = "впереди"
    elseif a < 67.5 then dir = ang > 0 and "впереди-справа" or "впереди-слева"
    elseif a < 112.5 then dir = ang > 0 and "справа" or "слева"
    elseif a < 157.5 then dir = ang > 0 and "сзади-справа" or "сзади-слева"
    else dir = "сзади" end
    local vert = dy > 2 and ", выше" or (dy < -2 and ", ниже" or "")
    local s = string.format("%.0f м %s%s", d, dir, vert)
    if not info.loaded then s = s .. "  [вне прогрузки]" end
    if not cl().S.ents[info.eid] then s = s .. "  (не видно)" end
    return s, d, ang
end
M.where_text = where_text

-- ------------------------------------------------------------------ messages from the world
local H = {}

function H.MobsList(m)
    if m.seq == 0 then S.stats.watch_lists = S.stats.watch_lists + 1 else S.stats.lists = S.stats.lists + 1 end
    S.list = m
    M.refresh()
end

function H.MobConfirm(m)
    S.stats.confirms = S.stats.confirms + 1
    S.confirm = m
    FX.event("confirm", string.format("%s #%d: подтвердите (панель M)", ACT_RU[m.op] or "?", m.eid), {eid = m.eid, code = 22})
    M.refresh()
end

local function text3d() return gfx ~= nil and gfx.text3d ~= nil end

function H.MobRescued(m)
    S.stats.rescued = S.stats.rescued + 1
    S.rescued[#S.rescued + 1] = {eid = m.eid, pos = {m.pos.x, m.pos.y, m.pos.z}, from = {m.from.x, m.from.y, m.from.z}, by = m.by, t = time.uptime()}
    if #S.rescued > 16 then table.remove(S.rescued, 1) end
    FX.event("rescue", string.format("Моб #%d спасён: теперь в %.0f,%.0f,%.0f", m.eid, m.pos.x, m.pos.y, m.pos.z), {eid = m.eid})
    -- show where it went: a 3D label at the new place for a few seconds (through walls) + a particle burst
    if text3d() then
        local ok, id = pcall(gfx.text3d.show, {m.pos.x, m.pos.y + 1.4, m.pos.z}, "<< сюда >>",
            {display = "y_free_billboard", scale = 0.05, render_distance = 64, xray_opacity = 1, color = {1, 0.85, 0.3, 1}})
        if ok then S.rescue_marks[#S.rescue_marks + 1] = {id = id, t = time.uptime()} end
    end
    if gfx and gfx.particles then
        pcall(gfx.particles.emit, {m.pos.x, m.pos.y, m.pos.z}, 40, {texture = "blocks:green_lamp", lifetime = 1.2,
            explosion = {3, 3, 3}, size = {0.12, 0.12, 0.12}, collision = false, lighting = false})
    end
    S.sel = m.eid
end

function H.MobRestored(m)
    S.stats.restored = S.stats.restored + 1
    S.restored[#S.restored + 1] = {seq = m.seq, src = m.src_eid, eid = m.eid, name = m.name, code_fnv = m.code_fnv}
    if #S.restored > 16 then table.remove(S.restored, 1) end
    FX.event("restore", string.format("Восстановлен %s: #%d -> #%d", m.name, m.src_eid, m.eid), {eid = m.eid})
    S.sel = m.eid
    ol().S.last_opened = m.eid                 -- Shift+RMB opens the restored mob
end

function H.MobProfile(m)
    S.stats.profiles = S.stats.profiles + 1
    S.profile[m.eid] = m
    ol().refresh()
end

function H.CodeHistory(m)
    S.stats.histories = S.stats.histories + 1
    S.history[m.eid] = m
    ol().refresh()
end

function H.CodeVersionText(m)
    S.stats.vtexts = S.stats.vtexts + 1
    S.vtext[m.eid] = m
    local o = ol()
    if o.S.open == m.eid and o.S.doc then
        pcall(function() o.S.doc.code.text = m.code end)
        o.S.edited = true
        o.S.notice = string.format("открыта версия #%d (не сохранена)", m.n)
        o.refresh()
    end
end

function M.on_msg(name, m)
    local h = H[name]
    if h then h(m) end
end
M.handled = {MobsList = true, MobConfirm = true, MobRescued = true, MobRestored = true, MobProfile = true,
             CodeHistory = true, CodeVersionText = true}

-- RequestReply ops 12..18 (called by olife_client:olife)
function M.on_reply(m)
    S.replies[#S.replies + 1] = {seq = m.seq, op = m.op, eid = m.eid, code = m.code, reason = m.reason}
    if #S.replies > 32 then table.remove(S.replies, 1) end
    if m.code == 22 then return end          -- MobConfirm carries the feedback
    if m.code == 0 then
        if m.op == 13 then S.stats.oks = S.stats.oks + 1; S.confirm = nil
        elseif m.op == 14 then S.stats.oks = S.stats.oks + 1; S.confirm = nil
            FX.event("destroy", string.format("Моб #%d уничтожен", m.eid), {eid = m.eid})
            if S.sel == m.eid then M.select(nil) end
            if S.cam_eid == m.eid then M.cam_set(0) end
        elseif m.op == 15 then S.stats.oks = S.stats.oks + 1; S.confirm = nil
        elseif m.op == 18 then
            if (m.reason or ""):find("^restored") then FX.event("save", "Версия восстановлена: " .. (m.reason or ""), {eid = m.eid}) end
        end
        M.refresh()
        return
    end
    S.stats.denied = S.stats.denied + 1
    local txt = CODE_RU[m.code] or ol().reply_text(m.code, m.reason)
    if m.code == 29 then txt = txt .. ": " .. tostring(m.reason) end
    FX.deny(string.format("%s #%d: %s", OP_RU[m.op] or "?", m.eid, txt), m.code)
    if m.code == 23 or m.code == 24 or m.code == 25 or m.code == 26 or m.code == 27 then S.confirm = nil end
    M.refresh()
end

-- ------------------------------------------------------------------ panel
function M.on_hud_open(pid)
    S.pid = pid
    pcall(input.add_callback, "key:m", function() M.toggle_panel() end)
    pcall(input.add_callback, "key:v", function() M.cam_cycle() end)
end

function M.hud_opened(doc) S.hud_doc = doc end

function M.toggle_panel()
    if panel_open() then return M.ui_close() end
    if ui_busy() then return end
    if ol().held_tool(S.pid) ~= 1 then
        FX.deny("Панель «мои мобы» — с Injector в руке (слот 1)", 13)
        return
    end
    M.open_panel()
end

function M.open_panel()
    S.stats.opens = S.stats.opens + 1
    S.open_at = time.uptime()
    send("MobsRequest", {watch = true})
    cl().flush()
    if hud and hud.show_overlay then
        local ok, err = pcall(hud.show_overlay, "olife_client:mobs", false)
        if not ok then S.stats.ui_errors = S.stats.ui_errors + 1; log("mobs overlay failed: %s", tostring(err)) end
    end
end

function M.ui_opened(doc)
    S.doc = doc
    M.refresh()
end

function M.ui_closed()
    S.doc = nil
    S.stats.closes = S.stats.closes + 1
    send("MobsRequest", {watch = false})
    cl().flush()
end

function M.ui_close()
    if hud and hud.close then pcall(hud.close, "olife_client:mobs") end
end

local function row_xml(i, info)
    local st = STATUS_TXT[info.status] or "?"
    local c = FX.tag_rgb(info.status)
    local col = string.format("#%02X%02X%02X", math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255))
    local sel = S.sel == info.eid
    local line1 = string.format("%s  #%d  %s  |  %.0f cr/мин  %s топл/мин  KV %s%s", info.name, info.eid, st,
        info.credits_min or 0, fmt_num(info.fuel_min), fmt_bytes(info.kv_bytes),
        info.vm_heap and info.vm_heap >= 0 and ("  VM " .. fmt_bytes(info.vm_heap)) or "")
    local line2 = where_text(info)
    if info.error and info.error ~= "" then line2 = line2 .. "  ! " .. info.error:sub(1, 48) end
    return string.format(
        "<container id='mr_%d' size='752,48' color='%s'>" ..
        "<label id='mn_%d' pos='6,4' size='404,18' color='%s'>%s</label>" ..
        "<label id='mw_%d' pos='6,26' size='404,18' color='#C8D4E8'>%s</label>" ..
        "<button id='ms_%d' pos='414,10' size='66,28' color='%s' onclick='ui_mb_select(%d)' tooltip='маркер и подсветка в мире'>%s</button>" ..
        "<button id='mc_%d' pos='484,10' size='66,28' color='#5050ff80' onclick='ui_mb_cam(%d)' tooltip='камера: третье лицо / из глаз / выход (V)'>Камера</button>" ..
        "<button id='mres_%d' pos='554,10' size='66,28' color='#30A05090' onclick='ui_mb_act(1,%d)' tooltip='вернуть на последнюю безопасную позицию (с подтверждением)'>Спасти</button>" ..
        "<button id='mdel_%d' pos='624,10' size='90,28' color='#C03030A0' onclick='ui_mb_act(2,%d)' tooltip='уничтожить (с подтверждением; последнее состояние остаётся)'>Уничтожить</button>" ..
        "</container>",
        i, sel and "#FFD08030" or "#FFFFFF10", i, col, esc(line1), i, esc(line2), i, sel and "#FFD080C0" or "#FFFFFF20",
        i, sel and "Выбран" or "Выбрать", i, i, i, info.eid, i, info.eid)
end

local function dead_xml(i, d)
    return string.format(
        "<container id='dr_%d' size='752,26' color='#FFFFFF10'>" ..
        "<label id='dn_%d' pos='6,4' size='600,18' color='#E0E8F0'>%s</label>" ..
        "<button id='drest_%d' pos='630,0' size='120,26' color='#30A05090' onclick='ui_mb_act(3,%d)' tooltip='восстановить из последнего состояния (с подтверждением; тариф хранилища)'>Восстановить</button>" ..
        "</container>",
        i, i, esc(string.format("%s  (был #%d)  код %08x  %s  убрал: %s", d.name, d.eid, d.code_fnv or 0, fmt_bytes(d.size), d.by or "?")),
        i, d.eid)
end

function M.refresh()
    local doc = S.doc
    if not doc then return end
    local ok, err = pcall(function()
        local l = S.list
        doc.mb_rows:clear()
        S.rows, S.dead_rows = {}, {}
        if not l then
            doc.mb_count.text = "ждём список мира..."
            doc.mb_rows:add("<label size='620,20' color='#90A0B0'>...</label>")
        else
            doc.mb_count.text = string.format("мобов: %d, такт мира %d%s", #l.mobs, l.tick,
                S.sel and (", выбран #" .. S.sel) or "")
            for i, info in ipairs(l.mobs) do
                S.rows[i] = info
                doc.mb_rows:add(row_xml(i, info))
            end
            if #l.mobs == 0 then
                doc.mb_rows:add("<label size='620,20' color='#90A0B0'>У вас пока нет мобов. Форк чужого бенча или spawn у оператора.</label>")
            end
            doc.mb_dead:clear()
            for i, d in ipairs(l.dead or {}) do
                S.dead_rows[i] = d
                doc.mb_dead:add(dead_xml(i, d))
            end
            if #(l.dead or {}) == 0 then
                doc.mb_dead:add("<label size='620,18' color='#90A0B0'>нет (удалённые и убитые мобы появятся здесь)</label>")
            end
        end
        local c = S.confirm
        doc.mb_confirm.visible = c ~= nil
        if c then doc.mb_confirm_text.text = string.format("%s #%d: %s", ACT_RU[c.op] or "?", c.eid, c.text) end
        doc.mb_cam.text = S.cam_mode == 0 and "Камера [V]" or (S.cam_mode == 1 and "Камера: 3-е лицо [V]" or "Камера: из глаз [V]")
    end)
    if not ok then S.stats.ui_errors = S.stats.ui_errors + 1; S.ui_error = tostring(err) end
end

-- ------------------------------------------------------------------ selection: highlight + HUD marker
local function hide_mark()
    if S.mark_id and text3d() then pcall(gfx.text3d.hide, S.mark_id) end
    S.mark_id, S.mark_eid = nil, nil
    if S.part_id and gfx and gfx.particles then pcall(gfx.particles.stop, S.part_id) end
    S.part_id, S.part_uid = nil, nil
end

function M.select(eid)
    if S.sel == eid then return end
    S.sel = eid
    S.stats.selects = S.stats.selects + 1
    hide_mark()
    if eid then FX.event("select", string.format("Выбран моб #%d: маркер в HUD, подсветка в мире", eid), {eid = eid}) end
    M.refresh()
end

function M.ui_select(i)
    local info = S.rows[i]
    if not info then return end
    M.select(S.sel == info.eid and nil or info.eid)
end

local function info_of(eid)
    for _, info in ipairs((S.list or {}).mobs or {}) do if info.eid == eid then return info end end
    return nil
end

local function mark_tick()
    local eid = S.sel
    if not eid then return end
    local p, e = mob_pos(eid)
    if not p then
        if S.mark_id then hide_mark() end
        return
    end
    local info = info_of(eid) or {}
    local name = info.name or ("#" .. eid)
    if text3d() then
        if not S.mark_id or S.mark_eid ~= eid then
            hide_mark()
            local ok, id = pcall(gfx.text3d.show, {p.x, p.y + 1.3, p.z}, "[ " .. name .. " ]",
                {display = "y_free_billboard", scale = 0.03, render_distance = 96, xray_opacity = 1, color = {1, 0.82, 0.3, 1}})
            if ok then S.mark_id, S.mark_eid = id, eid end
        else
            pcall(gfx.text3d.set_pos, S.mark_id, {p.x, p.y + 1.3, p.z})
        end
    end
    if gfx and gfx.particles and e and e.uid and S.part_uid ~= e.uid then
        if S.part_id then pcall(gfx.particles.stop, S.part_id) end
        local ok, id = pcall(gfx.particles.emit, e.uid, -1, {texture = "blocks:green_lamp", spawn_interval = 0.08,
            lifetime = 0.9, explosion = {0.6, 1.5, 0.6}, acceleration = {0, 2, 0}, size = {0.08, 0.08, 0.08},
            collision = false, lighting = false, spawn_shape = "box", spawn_spread = {0.5, 0.5, 0.5}})
        S.part_id, S.part_uid = ok and id or nil, e.uid
    end
end

-- 3D -> HUD pixels through the active camera; nil when behind the camera
local function project(p)
    local pid = S.pid
    if not pid then return nil end
    local okc, cam = pcall(function() return cameras.get(player.get_camera(pid)) end)
    if not okc or not cam then return nil end
    local o, f, r, u = cam:get_pos(), cam:get_front(), cam:get_right(), cam:get_up()
    local fov = cam:get_fov() or 70
    local vp = gui.get_viewport()
    local W, H = vp[1], vp[2]
    local dx, dy, dz = p.x - o[1], p.y - o[2], p.z - o[3]
    local z = dx * f[1] + dy * f[2] + dz * f[3]
    local x = dx * r[1] + dy * r[2] + dz * r[3]
    local y = dx * u[1] + dy * u[2] + dz * u[3]
    local t = math.tan(math.rad(fov) / 2)
    local aspect = W / H
    if z < 0.05 then
        return {x = x, y = y, behind = true, W = W, H = H}
    end
    local sx, sy = x / (z * t * aspect), y / (z * t)
    return {px = (sx * 0.5 + 0.5) * W, py = (0.5 - sy * 0.5) * H, sx = sx, sy = sy, W = W, H = H, behind = false}
end

local function marker_tick()
    local d = S.hud_doc
    if not d then return end
    local eid = S.sel
    local p = eid and mob_pos(eid)
    if not eid or not p then
        if S.marker then S.marker = nil; pcall(function() d.mob_marker.text = ""; d.mob_marker.color = {255, 208, 128, 0} end) end
        return
    end
    local pr = project(p)
    if not pr then return end
    local me = my_pos()
    local dist = me and math.sqrt((p.x - me.x) ^ 2 + (p.y - me.y) ^ 2 + (p.z - me.z) ^ 2) or 0
    local info = info_of(eid) or {}
    local name = info.name or ("#" .. eid)
    local W, H, mw, mh = pr.W, pr.H, 220, 22
    local px, py, arrow
    if pr.behind or pr.px < 0 or pr.px > W or pr.py < 0 or pr.py > H then
        -- off-screen: clamp to the edge in the direction of the target, ASCII arrow (the font has no ▲▼)
        local ax, ay = pr.behind and pr.x or (pr.px - W / 2), pr.behind and -pr.y or (pr.py - H / 2)
        if pr.behind then ay = -ay end
        local l = math.max(math.abs(ax) / (W / 2 - 40), math.abs(ay) / (H / 2 - 40), 1e-6)
        px, py = W / 2 + ax / l, H / 2 + ay / l
        if math.abs(ax) / (W / 2) > math.abs(ay) / (H / 2) then arrow = ax > 0 and ">" or "<"
        else arrow = ay > 0 and "v" or "^" end
        if pr.behind then arrow = arrow .. " (сзади)" end
    else
        px, py, arrow = pr.px, pr.py - 30, "*"
    end
    px, py = math.max(0, math.min(W - mw, px - mw / 2)), math.max(0, math.min(H - mh, py))
    S.stats.marker_frames = S.stats.marker_frames + 1
    S.marker = {eid = eid, px = px, py = py, arrow = arrow, dist = dist, on_screen = not pr.behind and arrow == "*"}
    pcall(function()
        d.mob_marker.pos = {px, py}
        d.mob_marker.text = string.format("%s %s %.0f м", arrow, name, dist)
        d.mob_marker.color = {255, 208, 128, 230}
    end)
end

-- ------------------------------------------------------------------ camera (client-only, 0.32 cameras)
local function cam_get()
    if S.cam then return S.cam end
    local ok, cam = pcall(cameras.get, "olife_client:mobcam")
    if ok and cam then
        S.cam = cam
        S.cam_idx = cam:get_index()
        local okf, fc = pcall(cameras.get, "core:first-person")
        S.first_idx = okf and fc and fc:get_index() or 0
    end
    return S.cam
end

function M.cam_set(mode, eid)
    local pid = S.pid
    if not pid then return false end
    if mode ~= 0 then
        eid = eid or S.cam_eid or S.sel
        if not eid or not mob_pos(eid) then
            FX.deny("Камера: сначала выберите своего моба в панели (M), он должен быть виден", 1)
            return false
        end
        local cam = cam_get()
        if not cam then FX.deny("Камера мобов недоступна (нет olife_client:mobcam)", 13); return false end
        S.cam_eid = eid
        S.cam_mode = mode
        pcall(player.set_camera, pid, S.cam_idx)
        S.stats.cam_switches = S.stats.cam_switches + 1
        FX.event("camera", mode == 1 and string.format("Камера: моб #%d, третье лицо (V — из глаз)", eid)
                                      or string.format("Камера: моб #%d, из глаз (V — назад)", eid), {eid = eid})
        M.cam_frame()
    else
        if S.cam_mode ~= 0 then
            S.stats.cam_switches = S.stats.cam_switches + 1
            FX.event("camera", "Камера: своя", {eid = S.cam_eid})
        end
        S.cam_mode, S.cam_eid, S.cam_pos, S.cam_target = 0, nil, nil, nil
        pcall(player.set_camera, pid, S.first_idx or 0)
    end
    M.refresh()
    return true
end

function M.cam_cycle()
    if ui_busy() and not panel_open() then return end
    if S.cam_mode == 0 then return M.cam_set(1) end
    if S.cam_mode == 1 then return M.cam_set(2) end
    return M.cam_set(0)
end

function M.ui_cam(i)
    if i then
        local info = S.rows[i]
        if info then
            if S.cam_eid == info.eid and S.cam_mode ~= 0 then return M.cam_cycle() end
            return M.cam_set(1, info.eid)
        end
    end
    return M.cam_cycle()
end

function M.cam_frame()
    if S.cam_mode == 0 or not S.pid then return end
    local p, e = mob_pos(S.cam_eid)
    if not p then return end
    local cam = cam_get()
    if not cam then return end
    local pos, target
    if S.cam_mode == 1 then
        local me = my_pos()
        local dx, dz = p.x - (me and me.x or p.x), p.z - (me and me.z or p.z)
        local l = math.sqrt(dx * dx + dz * dz)
        if l < 0.5 then dx, dz, l = 0, 1, 1 end
        pos = {p.x - dx / l * 4.0, p.y + 2.2, p.z - dz / l * 4.0}
        target = {p.x, p.y + 0.4, p.z}
    else
        local yaw = math.rad(e and e.rot and e.rot.y or 0)
        pos = {p.x, p.y + 0.55, p.z}
        target = {p.x - math.sin(yaw) * 4, p.y + 0.55, p.z - math.cos(yaw) * 4}
    end
    pcall(cam.set_pos, cam, pos)
    pcall(cam.look_at, cam, target)
    S.cam_pos, S.cam_target = pos, target
    S.stats.cam_frames = S.stats.cam_frames + 1
    -- the engine may have switched the player camera (its own binding): keep ours while the mode is on
    local okc, cur = pcall(player.get_camera, S.pid)
    if okc and cur ~= S.cam_idx then pcall(player.set_camera, S.pid, S.cam_idx) end
end

-- ------------------------------------------------------------------ actions
function M.ui_act(op, eid)
    if not eid or eid == 0 then return end
    S.stats.actions = S.stats.actions + 1
    local seq = send("MobAction", {eid = eid, op = op, token = 0})
    cl().flush()
    return seq
end

function M.ui_confirm()
    local c = S.confirm
    if not c then return end
    S.stats.confirmed = S.stats.confirmed + 1
    local seq = send("MobAction", {eid = c.eid, op = c.op, token = c.token})
    cl().flush()
    return seq
end

function M.ui_cancel()
    if S.confirm then S.stats.cancelled = S.stats.cancelled + 1 end
    S.confirm = nil
    M.refresh()
end

-- ------------------------------------------------------------------ frame
function M.frame()
    if not S.pid then return end
    mark_tick()
    marker_tick()
    M.cam_frame()
    local now = time.uptime()
    for i = #S.rescue_marks, 1, -1 do
        local r = S.rescue_marks[i]
        if now - r.t > 5 then
            if text3d() then pcall(gfx.text3d.hide, r.id) end
            table.remove(S.rescue_marks, i)
        end
    end
    -- the HUD button: only with the Injector in hand (the tags are shown then too)
    if S.hud_doc then
        local on = ol().held_tool(S.pid) == 1
        if S.btn_on ~= on then
            S.btn_on = on
            pcall(function() S.hud_doc.mob_btn.visible = on end)
        end
    end
end

-- ------------------------------------------------------------------ editor: error line, profile tab, versions
local function err_line_of(st)
    local e = st and st.error or ""
    if e == "" then return nil end
    local n = e:match(":(%d+):")
    return n and tonumber(n) or nil
end
M.err_line_of = err_line_of

-- caret onto the error line (scrolls into view; keep-line-selection shows it), once per distinct error
function M.error_line(doc, st)
    local line = err_line_of(st)
    pcall(function()
        doc.err_line.text = line and string.format("ошибка в строке %d", line) or ""
    end)
    if not line then S.err_shown[st.eid] = nil; return end
    local key = st.error
    if S.err_shown[st.eid] == key then return end
    S.err_shown[st.eid] = key
    pcall(function()
        local tb = doc.code
        local pos = tb:linePos(line - 1)              -- 0-based lines in the 0.32 textbox (checked: lineAt/linePos)
        if pos == nil or pos < 0 then pos = tb:linePos(line) end
        tb.caret = pos or 0
        S.err_caret = {eid = st.eid, line = line, pos = pos, caret_line = tb:lineAt(tb.caret)}
    end)
end

function M.editor_opened(doc)
    S.err_shown = {}
end

-- the «Профиль» tab was opened: ask the world for the profile and the history
function M.editor_tab(eid)
    if not eid then return end
    send("MobProfileRequest", {eid = eid})
    send("CodeHistoryRequest", {eid = eid})
    cl().flush()
end

function M.on_saved(eid)
    if ol().S.tab == "mob" and ol().S.open == eid then send("CodeHistoryRequest", {eid = eid}) end
end

local function ver_row(i, it, cur_fnv)
    local t = ""
    pcall(function() t = os.date("%H:%M:%S", math.floor(it.ms / 1000)) end)
    local same = it.fnv == cur_fnv
    return string.format(
        "<container id='vr_%d' size='380,26' color='%s'>" ..
        "<label id='vn_%d' pos='4,4' size='236,18' color='%s'>%s</label>" ..
        "<button id='vo_%d' pos='244,0' size='60,26' color='#5050ff80' onclick='ui_ver_open(%d)' tooltip='текст версии в редактор (как правка)'>Открыть</button>" ..
        "<button id='vrs_%d' pos='308,0' size='70,26' color='#30A05090' onclick='ui_ver_restore(%d)' tooltip='сделать эту версию кодом сущности (новый коммит)'>Вернуть</button>" ..
        "</container>",
        i, same and "#FFD08030" or "#FFFFFF10", i, same and "#FFD080" or "#E0E8F0",
        esc(string.format("#%d %08x %d Б %s %s %s", it.n, it.fnv, it.size, t, it.author, it.note or "")), i, it.n, i, it.n)
end

function M.editor_refresh(doc, st)
    local pm = S.profile[st.eid]
    local hs = S.history[st.eid]
    local lines = {}
    if pm then
        lines[#lines + 1] = string.format("владелец: %s (#%d)%s", pm.owner ~= "" and pm.owner or "мир", st.eid,
            pm.forked_from ~= 0 and ("  форк #" .. pm.forked_from) or "")
        lines[#lines + 1] = "права: " .. pm.perms
        lines[#lines + 1] = string.format("код: %08x, %d Б, коммитов %d", pm.code_fnv, pm.code_size, pm.versions)
        lines[#lines + 1] = string.format("работал: %d тактов (%.0f с), ошибок %d", pm.run_ticks, pm.run_ticks / 20, pm.errors)
        lines[#lines + 1] = string.format("кредиты %.0f/мин, топливо %s/мин", pm.credits_min, fmt_num(pm.fuel_min))
        lines[#lines + 1] = string.format("память: KV %s (%d ключей), VM %s", fmt_bytes(pm.kv_bytes), pm.kv_keys, fmt_bytes(pm.vm_heap))
        if #pm.last_errors > 0 then
            lines[#lines + 1] = "последние ошибки:"
            for _, x in ipairs(pm.last_errors) do lines[#lines + 1] = "  " .. x end
        else
            lines[#lines + 1] = "последние ошибки: нет"
        end
    else
        lines[#lines + 1] = "профиль: ждём ответ мира..."
    end
    doc.pf_mob.text = table.concat(lines, "\n")
    doc.ver_box:clear()
    local cur = pm and pm.code_fnv or nil
    local items = hs and hs.items or {}
    S.ver_rows = {}
    for i = #items, 1, -1 do                        -- newest first
        local it = items[i]
        S.ver_rows[#S.ver_rows + 1] = it
        doc.ver_box:add(ver_row(#S.ver_rows, it, cur))
    end
    if #items == 0 then doc.ver_box:add("<label size='380,18' color='#90A0B0'>версий пока нет: каждое СОХРАНИТЬ — коммит</label>") end
    doc.ver_note.text = string.format("Версии кода (коммиты): %d, хранится до 16", #items)
end

function M.ui_ver_open(n)
    local eid = ol().S.open
    if not eid then return end
    send("CodeVersionOp", {eid = eid, n = n, op = 1})
    cl().flush()
end

function M.ui_ver_restore(n)
    local eid = ol().S.open
    if not eid then return end
    send("CodeVersionOp", {eid = eid, n = n, op = 2})
    cl().flush()
end

-- ------------------------------------------------------------------ F2F (test build)
local function rect(doc, id, k)
    local ok, r = pcall(function()
        local el = doc[id]
        local p, s = el.wpos, el.size
        return {x = p[1] * k, y = p[2] * k, w = s[1] * k, h = s[2] * k, cx = (p[1] + s[1] / 2) * k,
                cy = (p[2] + s[2] / 2) * k, enabled = el.enabled, visible = el.visible}
    end)
    return ok and r or nil
end

function M.editor_f2f(doc, k)
    local r = {rows = {}}
    pcall(function() r.pf_mob = doc.pf_mob.text; r.ver_note = doc.ver_note.text; r.err_line = doc.err_line.text end)
    for i, it in ipairs(S.ver_rows or {}) do
        r.rows[i] = {n = it.n, fnv = it.fnv, size = it.size, author = it.author, note = it.note,
                     open = rect(doc, "vo_" .. i, k), restore = rect(doc, "vrs_" .. i, k)}
    end
    r.err_caret = S.err_caret
    pcall(function() r.caret = doc.code.caret; r.caret_line = doc.code:lineAt(doc.code.caret) end)
    for _, id in ipairs({"tab_mob", "page_mob", "pf_mob", "ver_box", "err_line"}) do r[id] = rect(doc, id, k) end
    return r
end

function M.f2f(args)
    local op = args.op or "state"
    if op == "gui" then
        local doc = S.doc
        local r = {doc = doc ~= nil, overlay = panel_open(), sel = S.sel, confirm = S.confirm, rows = {}, dead = {},
                   list_tick = S.list and S.list.tick or nil}
        if doc then
            local vp = gui.get_viewport()
            local k = 854 / vp[1]
            r.rects = {}
            for _, id in ipairs({"mb_root", "mb_panel", "mb_rows", "mb_dead", "mb_confirm", "mb_confirm_text", "mb_ok",
                                 "mb_cancel", "mb_close", "mb_cam", "mb_count"}) do
                r.rects[id] = rect(doc, id, k)
            end
            for i, info in ipairs(S.rows) do
                local w, d, ang = where_text(info)
                r.rows[i] = {eid = info.eid, name = info.name, status = info.status, pos = {info.pos.x, info.pos.y, info.pos.z},
                             loaded = info.loaded, credits_min = info.credits_min, fuel_min = info.fuel_min,
                             kv_bytes = info.kv_bytes, vm_heap = info.vm_heap, run_ticks = info.run_ticks, errors = info.errors,
                             code_fnv = info.code_fnv, code_size = info.code_size, versions = info.versions, error = info.error,
                             where = w, dist = d, angle = ang, select = rect(doc, "ms_" .. i, k), cam = rect(doc, "mc_" .. i, k),
                             rescue = rect(doc, "mres_" .. i, k), destroy = rect(doc, "mdel_" .. i, k)}
                pcall(function() r.rows[i].line1 = doc["mn_" .. i].text; r.rows[i].line2 = doc["mw_" .. i].text end)
            end
            for i, d in ipairs(S.dead_rows) do
                r.dead[i] = {eid = d.eid, name = d.name, code_fnv = d.code_fnv, size = d.size, by = d.by,
                             restore = rect(doc, "drest_" .. i, k)}
            end
            pcall(function() r.count = doc.mb_count.text; r.confirm_text = doc.mb_confirm_text.text; r.cam_text = doc.mb_cam.text end)
        end
        return r
    elseif op == "camera" then
        local pid = S.pid
        local cur
        if pid then local okc, c = pcall(player.get_camera, pid); cur = okc and c or nil end
        local act
        if pid then
            local okc, cam = pcall(function() return cameras.get(player.get_camera(pid)) end)
            if okc and cam then act = {pos = cam:get_pos(), front = cam:get_front(), name = cam:get_name()} end
        end
        local mp = S.cam_eid and mob_pos(S.cam_eid) or nil
        local me = my_pos()
        return {mode = S.cam_mode, eid = S.cam_eid, cam_idx = S.cam_idx, first_idx = S.first_idx, player_cam = cur,
                active = act, set_pos = S.cam_pos, target = S.cam_target, mob_pos = mp and {mp.x, mp.y, mp.z} or nil,
                player_pos = me and {me.x, me.y, me.z} or nil, switches = S.stats.cam_switches, frames = S.stats.cam_frames}
    elseif op == "ui" then
        local f = M["ui_" .. tostring(args.call)]
        if not f then error("no ui_" .. tostring(args.call)) end
        return {result = f(args.arg, args.arg2)}
    elseif op == "open" then
        M.open_panel()
        return {opened = true}
    end
    local mobs = {}
    for _, info in ipairs((S.list or {}).mobs or {}) do
        mobs[#mobs + 1] = {eid = info.eid, name = info.name, status = info.status, pos = {info.pos.x, info.pos.y, info.pos.z},
                           loaded = info.loaded, credits_min = info.credits_min, fuel_min = info.fuel_min, kv_bytes = info.kv_bytes,
                           code_fnv = info.code_fnv, versions = info.versions, run_ticks = info.run_ticks}
    end
    local dead = {}
    for _, d in ipairs((S.list or {}).dead or {}) do dead[#dead + 1] = {eid = d.eid, name = d.name, code_fnv = d.code_fnv, by = d.by} end
    return {open = panel_open(), sel = S.sel, confirm = S.confirm, mobs = mobs, dead = dead, list_tick = S.list and S.list.tick,
            marker = S.marker, mark_id = S.mark_id, part_id = S.part_id, cam_mode = S.cam_mode, cam_eid = S.cam_eid,
            replies = S.replies, rescued = S.rescued, restored = S.restored, stats = S.stats, ui_error = S.ui_error,
            hud_btn = S.btn_on or false, rescue_marks = #S.rescue_marks,
            profiles = (function() local l = {} for eid in pairs(S.profile) do l[#l + 1] = eid end table.sort(l) return l end)(),
            err_caret = S.err_caret}
end

return M
