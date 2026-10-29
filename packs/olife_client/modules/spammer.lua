-- olife_client:spammer — UX B2 (03.10, olife_b2): the Spammer tool on the client (OLIFE_UX §3).
-- Item olife_client:spammer in hotbar slot 2 (key 3), next to the Injector (1) and the GravityGun (2). LMB on a mob =
-- SpamCapture (the world snapshots it into my library: code, KV memory, look, appearance, asset refs, rights, run state;
-- `clone` right unless it is mine); RMB = SpamThrow of the SELECTED snapshot (a ball flies, the world spawns the instance
-- where it lands); [ / ] or Shift+mouse wheel = select the slot; Shift+RMB = the library page (layouts/spammer.xml:
-- list, preview, size, time, spawned count, rename, delete, select). Every press is edge-triggered with the 150 ms
-- debounce of olife_client:olife (accept_press); every answer = sound + toast through olife_client:fx. Nothing is
-- decided here: what is shown is the last SpamList / SpamReply / SpamBall of the world. The ball itself is an entity
-- (kind 5, def olife_client:spam_ball) replicated like any other; this module adds the landing burst (particles) and
-- the sounds. F2F `spammer {op=state|gui|select|cycle|list|rename|delete|capture|throw|open|close}`.
local LOOKS = require "olife_proto:looks"
local M = {}
local S = {
    cur = nil, list = nil, snaps = {}, doc = nil, hud_doc = nil, replies = {}, pending = {}, balls = {}, events = {},
    rename_id = nil, want_list = false, keys_ok = {}, slot_was = nil, held_last = false, last_spawned = nil,
    stats = {captures = 0, captures_ok = 0, throws = 0, throws_ok = 0, spawned = 0, lists = 0, replies = 0, refused = 0,
             balls_seen = 0, landed = 0, lost = 0, selects = 0, cycles = 0, wheel_cycles = 0, key_cycles = 0,
             renames = 0, deletes = 0, ui_opens = 0, ui_errors = 0, particles = 0},
}
M.S = S
M.SLOT = 2                                   -- hotbar slot of the Spammer (Injector 0, GravityGun 1)
local OP_TXT = {[1] = "захват", [2] = "бросок", [3] = "список", [4] = "имя", [5] = "удаление"}
local CODE_RU = {[1] = "нет такой сущности", [2] = "не моб", [3] = "нет прав", [6] = "слишком далеко", [7] = "луч мимо",
                 [9] = "слишком часто", [14] = "позиция/направление", [15] = "недопустимое имя", [40] = "нет сущности",
                 [43] = "квота активов", [44] = "кредиты хранилища кончились", [47] = "файл снимка пропал из хранилища",
                 [50] = "нет такого снимка", [51] = "квота снимков исчерпана", [52] = "слишком много спавнов в минуту",
                 [53] = "достигнут лимит мобов", [54] = "бросок не удался"}

local function log(fmt, ...) print("[olife_client] spammer: " .. string.format(fmt, ...)) end
local function cl() return require "olife_client:client" end
local function ol() return require "olife_client:olife" end
local function fx() return require "olife_client:fx" end

-- the catalogue of olife_client:fx gets the Spammer events (no edit of the shared file: added at load)
do
    local F = fx()
    F.EVENTS.spam_capture = F.EVENTS.spam_capture or {sound = "grab", kind = "ok", text = "Снимок сохранён"}
    F.EVENTS.spam_throw = F.EVENTS.spam_throw or {sound = "release", kind = "info", text = "Бросок"}
    F.EVENTS.spam_spawn = F.EVENTS.spam_spawn or {sound = "fx_spawn", kind = "ok", text = "Экземпляр создан"}
    F.EVENTS.spam_lost = F.EVENTS.spam_lost or {sound = "refuse", kind = "warn", text = "Шар потерян"}
end

local function send(name, msg)
    local c = cl()
    if c.S.state ~= "play" then return false end
    msg.seq = msg.seq or ol().next_seq()
    c.send(name, msg)
    return msg.seq
end

local function reply_text(code, reason)
    if code == 3 and type(reason) == "string" then
        local a, aud = reason:match("^forbidden: ([%w_]+) is for (%w+)")
        if a then return ol().reply_text(code, reason) end
    end
    return CODE_RU[code] or reason or tostring(code)
end

-- ------------------------------------------------------------------ slots
local function snap_at(i) return S.snaps[i] end
local function cur_index()
    for i, s in ipairs(S.snaps) do if s.id == S.cur then return i end end
    return nil
end
M.cur_index = cur_index

function M.current() return S.cur and S.snaps[cur_index() or 0] or nil end

function M.select(i)
    local s = snap_at(i)
    if not s then return false end
    S.cur = s.id
    S.stats.selects = S.stats.selects + 1
    M.refresh()
    return true
end

function M.cycle(d)
    local n = #S.snaps
    if n == 0 then return false end
    local i = cur_index() or 1
    i = ((i - 1 + (d or 1)) % n) + 1
    S.stats.cycles = S.stats.cycles + 1
    return M.select(i)
end

local function apply_list(m)
    S.list = m
    S.snaps = m.snaps
    if S.cur and not cur_index() then S.cur = nil end
    if not S.cur and #S.snaps > 0 then S.cur = S.snaps[#S.snaps].id end     -- the newest capture is selected
    M.refresh()
end

-- ------------------------------------------------------------------ actions
local function eid_of_uid(uid)
    if not uid or uid == 0 then return 0 end
    for eid, e in pairs(cl().S.ents) do if e.uid == uid then return eid end end
    return 0
end

function M.aimed_eid(pid)
    local ok, uid = pcall(player.get_selected_entity, pid)
    return ok and eid_of_uid(uid) or 0
end

function M.capture(pid)
    pid = pid or ol().S.cam_pid
    if not pid then return nil end
    local target = M.aimed_eid(pid)
    local o, d = ol().camera_ray(pid)
    S.stats.captures = S.stats.captures + 1
    local seq = send("SpamCapture", {target = target, origin = o, dir = d})
    if seq then S.pending[seq] = {op = 1, target = target, t = time.uptime()} end
    return seq
end

function M.throw(pid)
    pid = pid or ol().S.cam_pid
    if not pid then return nil end
    local s = M.current()
    if not s then
        fx().deny("Спамер: нет снимка — всосите моба (ЛКМ) или выберите слот", 50)
        return nil
    end
    local o, d = ol().camera_ray(pid)
    S.stats.throws = S.stats.throws + 1
    local seq = send("SpamThrow", {id = s.id, origin = o, dir = d, name = ""})
    if seq then S.pending[seq] = {op = 2, id = s.id, name = s.name, t = time.uptime()} end
    return seq
end

function M.request_list()
    local seq = send("SpamSlotOp", {op = 1, id = 0, name = ""})
    if not seq then S.want_list = true end
    return seq
end

function M.rename(id, name)
    S.stats.renames = S.stats.renames + 1
    local seq = send("SpamSlotOp", {op = 2, id = id, name = name})
    if seq then S.pending[seq] = {op = 4, id = id, name = name} end
    return seq
end

function M.delete(id)
    S.stats.deletes = S.stats.deletes + 1
    local seq = send("SpamSlotOp", {op = 3, id = id, name = ""})
    if seq then S.pending[seq] = {op = 5, id = id} end
    return seq
end

-- ------------------------------------------------------------------ messages
local H = {}
function H.SpamList(m)
    S.stats.lists = S.stats.lists + 1
    apply_list(m)
end

function H.SpamReply(m)
    S.stats.replies = S.stats.replies + 1
    local r = {seq = m.seq, op = m.op, id = m.id, eid = m.eid, code = m.code, reason = m.reason, tick = cl().S.tick}
    S.replies[#S.replies + 1] = r
    if #S.replies > 32 then table.remove(S.replies, 1) end
    local pd = S.pending[m.seq]
    if m.code ~= 0 then
        S.stats.refused = S.stats.refused + 1
        S.pending[m.seq] = nil
        fx().deny(string.format("Спамер (%s): %s", OP_TXT[m.op] or "?", reply_text(m.code, m.reason)), m.code)
        if S.doc then pcall(function() S.doc.sp_note.text = reply_text(m.code, m.reason) end) end
        return
    end
    if m.op == 1 then
        S.stats.captures_ok = S.stats.captures_ok + 1
        S.cur = m.id                      -- the new snapshot becomes the selected slot
        S.pending[m.seq] = nil
        fx().event("spam_capture", string.format("Снимок #%d моба #%d сохранён", m.id, m.eid), {eid = m.eid})
    elseif m.op == 2 then
        if m.reason == "thrown" then
            S.stats.throws_ok = S.stats.throws_ok + 1
            fx().event("spam_throw", string.format("Бросок: %s", pd and pd.name or ("#" .. m.id)), {eid = m.eid})
        else                              -- the second reply: the instance is spawned (reason "spawned #n")
            S.stats.spawned = S.stats.spawned + 1
            S.last_spawned = m.eid
            ol().S.last_opened = m.eid    -- Shift+RMB with the Injector opens the new instance
            S.pending[m.seq] = nil
            fx().event("spam_spawn", string.format("Экземпляр #%d создан (%s)", m.eid, m.reason), {eid = m.eid})
        end
    elseif m.op == 4 then
        S.pending[m.seq] = nil
        fx().ok(string.format("Снимок #%d переименован", m.id))
        S.rename_id = nil
        if S.doc then pcall(function() S.doc.sp_name.text = "" end) end
    elseif m.op == 5 then
        S.pending[m.seq] = nil
        fx().event("delete", string.format("Снимок #%d удалён", m.id))
    end
    M.refresh()
end

function H.SpamBall(m)
    local ev = {eid = m.eid, state = m.state, thrower = m.thrower, snap = m.snap, pos = {m.pos.x, m.pos.y, m.pos.z},
                spawned_eid = m.spawned_eid, tick = m.tick, t = time.uptime()}
    S.events[#S.events + 1] = ev
    if #S.events > 32 then table.remove(S.events, 1) end
    if m.state == 1 then
        S.stats.balls_seen = S.stats.balls_seen + 1
        S.balls[m.eid] = ev
    elseif m.state == 2 then
        S.stats.landed = S.stats.landed + 1
        S.balls[m.eid] = nil
        M.burst(m.pos.x, m.pos.y, m.pos.z)
        local me = cl().S.name
        if m.thrower ~= me then        -- the thrower hears its own SpamReply; others hear the landing
            fx().event("spam_spawn", nil, {silent = false, no_toast = true, eid = m.spawned_eid})
        end
    else
        S.stats.lost = S.stats.lost + 1
        S.balls[m.eid] = nil
    end
end

M.handled = {SpamList = true, SpamReply = true, SpamBall = true}
function M.on_msg(name, m)
    local h = H[name]
    if h then h(m) end
end

-- the landing burst (gfx.particles 0.32; windowed client only)
function M.burst(x, y, z)
    if not (gfx and gfx.particles and gfx.particles.emit) then return false end
    local ok = pcall(gfx.particles.emit, {x, y + 0.3, z}, 24, {
        texture = "entities/olife_spamball", lifetime = 0.7, lifetime_spread = 0.3, spawn_interval = 0.0001,
        explosion = {2.5, 2.0, 2.5}, velocity = {0, 1.5, 0}, acceleration = {0, -6, 0}, size = {0.12, 0.12, 0.12},
        size_spread = 0.05, spawn_shape = "box", spawn_spread = {0.3, 0.3, 0.3}, lighting = false, collision = true,
        random_sub_uv = 0.25,
    })
    if ok then S.stats.particles = S.stats.particles + 1 end
    return ok
end

-- ------------------------------------------------------------------ HUD line + keys (every rendered frame)
local function held(pid) return pid ~= nil and ol().held_tool(pid) == 3 end
M.held = held

function M.on_hud_open(pid)
    pcall(hud.open_permanent, "olife_client:spammer_hud")
    -- [ / ] cycle the snapshot slot while the Spammer is in hand (key names of the 0.32 bindings: key:left-bracket)
    for name, d in pairs({["left-bracket"] = -1, ["right-bracket"] = 1}) do
        local ok = pcall(input.add_callback, "key:" .. name, function()
            if not held(ol().S.cam_pid) then return end
            local okb, open = pcall(hud.is_inventory_open)
            if okb and open then return end
            S.stats.key_cycles = S.stats.key_cycles + 1
            M.cycle(d)
        end)
        S.keys_ok[name] = ok
    end
    S.want_list = true
    log("hud player %d: spammer in slot %d, keys %s", pid, M.SLOT, json.tostring(S.keys_ok))
end

function M.hud_opened(doc) S.hud_doc = doc end

local function hud_text()
    local s = M.current()
    local n = #S.snaps
    if n == 0 then return "СПАМЕР ▸ снимков нет — наведитесь на моба и нажмите ЛКМ" end
    local i = cur_index() or 0
    return string.format("СПАМЕР ▸ слот %d/%d: %s  (x%d, %s, %d Б)", i, n, s and s.name or "?", s and s.spawned or 0,
        s and (s.status == 1 and "RUN" or "STOP") or "?", s and s.size or 0)
end
M.hud_text = hud_text

function M.frame()
    local pid = ol().S.cam_pid
    local on = held(pid)
    if S.hud_doc then
        pcall(function()
            local d = S.hud_doc
            if on then
                d.sp_line.text = hud_text()
                d.sp_keys.text = "ЛКМ — всосать моба · ПКМ — бросить · [ ] / Shift+колесо — слот · Shift+ПКМ — библиотека"
            end
            d.sp_line.visible = on
            d.sp_keys.visible = on
        end)
    end
    -- Shift + mouse wheel: the engine moves the hotbar slot; with Shift held and the Spammer selected a frame ago the
    -- slot goes back and the snapshot slot moves instead (there is no wheel event in the 0.32 Lua API)
    if pid and S.held_last and not on and ol().shift_down() then
        local okinv, invid, slot = pcall(player.get_inventory, pid)
        if okinv and slot ~= M.SLOT and slot ~= nil and math.abs(slot - M.SLOT) <= 1 then
            pcall(player.set_selected_slot, pid, M.SLOT)
            S.stats.wheel_cycles = S.stats.wheel_cycles + 1
            M.cycle(slot > M.SLOT and 1 or -1)
            on = true
        end
    end
    S.held_last = on
    if S.want_list and cl().S.state == "play" then
        S.want_list = false
        M.request_list()
    end
end

-- ------------------------------------------------------------------ library page (layouts/spammer.xml)
local function esc(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("'", "&apos;"):gsub('"', "&quot;"))
end

local function preview_of(s)
    local tex = s.texture or ""
    if tex:sub(1, 9) == "entities/" then return tex end
    return LOOKS.DEFAULT_TEXTURE or "entities/olife_bench"
end

local function fmt_time(ms)
    if not ms or ms <= 0 then return "-" end
    local ok, t = pcall(os.date, "%H:%M:%S", math.floor(ms / 1000))
    return ok and t or tostring(math.floor(ms / 1000))
end

function M.open_ui()
    S.stats.ui_opens = S.stats.ui_opens + 1
    M.request_list()
    if hud and hud.show_overlay then
        local ok, err = pcall(hud.show_overlay, "olife_client:spammer", false)
        if not ok then S.stats.ui_errors = S.stats.ui_errors + 1; log("library overlay failed: %s", tostring(err)) end
    end
end

function M.ui_opened(doc)
    S.doc = doc
    M.refresh()
end

function M.ui_closed() S.doc = nil; S.rename_id = nil end

function M.refresh()
    local doc = S.doc
    if not doc then return end
    local ok, err = pcall(function()
        local l = S.list
        doc.sp_quota.text = l and string.format("снимков %d/%d, %d/%d Б; спавнов за минуту %d/%d; мобов %d/%d", l.count,
            l.max_count, l.used, l.quota, l.spawns_min, l.spawn_limit, l.mobs, l.mobs_max) or "ждём ответ мира..."
        doc.sp_rows:clear()
        if #S.snaps == 0 then
            doc.sp_rows:add("<label size='560,22' color='#90A0B0'>Снимков нет. Наведитесь на моба со Спамером и нажмите ЛКМ.</label>")
        end
        for i, s in ipairs(S.snaps) do
            local sel = s.id == S.cur
            local info = string.format("%d Б · %s · v%d · x%d · %s · %s", s.size, fmt_time(s.ms), s.ver, s.spawned,
                s.status == 1 and "RUN" or "STOP", s.src_owner ~= "" and ("из #" .. s.src_eid .. " [" .. s.src_owner .. "]") or "")
            doc.sp_rows:add(string.format(
                "<container id='srow_%d' size='560,44' color='%s'>" ..
                "<image id='sp_img_%d' src='%s' pos='4,4' size='36,36' interactive='false'></image>" ..
                "<label id='sp_nm_%d' pos='48,4' size='300,20' color='%s'>%s</label>" ..
                "<label id='sp_info_%d' pos='48,24' size='330,18' color='#90A0B0'>%s</label>" ..
                "<button id='sp_sel_%d' pos='380,8' size='84,28' color='%s' onclick='ui_sp_select(%d)'>%s</button>" ..
                "<button id='sp_ren_%d' pos='468,8' size='56,28' color='#5050ff60' onclick='ui_sp_rename(%d)'>Имя</button>" ..
                "<button id='sp_del_%d' pos='528,8' size='28,28' color='#C0303060' onclick='ui_sp_delete(%d)'>x</button>" ..
                "</container>", i, sel and "#3050A080" or "#FFFFFF10", i, esc(preview_of(s)), i, sel and "#FFFFFF" or "#E0E8F0",
                esc(string.format("#%d %s", s.id, s.name)), i, esc(info), i, sel and "#30A05090" or "#5050ff60", i,
                sel and "ТЕКУЩИЙ" or "Выбрать", i, i, i, i))
        end
        local c = M.current()
        doc.sp_sel.text = c and string.format("выбран: #%d %s", c.id, c.name) or "снимок не выбран"
        if not S.rename_id and not doc.sp_name.focused then doc.sp_name.text = c and c.name or "" end
    end)
    if not ok then S.stats.ui_errors = S.stats.ui_errors + 1; S.ui_error = tostring(err); log("ui refresh: %s", tostring(err)) end
end

function M.ui_select(i) return M.select(i) end

function M.ui_rename(i)
    local s = snap_at(i)
    if not s then return end
    S.rename_id = s.id
    if S.doc then pcall(function() S.doc.sp_name.text = s.name; S.doc.sp_note.text = "новое имя для #" .. s.id .. " и «Переименовать»" end) end
end

function M.ui_rename_ok()
    local id = S.rename_id or S.cur
    if not id then return end
    local n = ""
    if S.doc then pcall(function() n = S.doc.sp_name.text end) end
    n = tostring(n or "")
    if not LOOKS.valid_name(n) then fx().deny("Спамер: недопустимое имя", 15); return nil end
    return M.rename(id, n)
end

function M.ui_delete(i)
    local s = snap_at(i)
    if not s then return end
    return M.delete(s.id)
end

function M.ui_refresh() return M.request_list() end
function M.ui_close() if hud and hud.close then pcall(hud.close, "olife_client:spammer") end end

-- ------------------------------------------------------------------ F2F (test build)
local function rect(doc, id, k)
    local ok, r = pcall(function()
        local el = doc[id]
        local p, s = el.wpos, el.size
        return {x = p[1] * k, y = p[2] * k, w = s[1] * k, h = s[2] * k, cx = (p[1] + s[1] / 2) * k,
                cy = (p[2] + s[2] / 2) * k, enabled = el.enabled, visible = el.visible, focused = el.focused}
    end)
    return ok and r or nil
end

function M.f2f(args)
    local op = args.op or "state"
    if op == "gui" then
        local doc = S.doc
        local r = {doc = doc ~= nil, overlay = hud and hud.is_open and hud.is_open("olife_client:spammer") or false, rows = {}}
        if doc then
            local vp = gui.get_viewport()
            local k = 854 / vp[1]
            r.rects = {}
            for _, id in ipairs({"sp_root", "sp_rows", "sp_name", "sp_rename_ok", "sp_close", "sp_refresh", "sp_quota", "sp_sel"}) do
                r.rects[id] = rect(doc, id, k)
            end
            for i, s in ipairs(S.snaps) do
                r.rows[i] = {id = s.id, name = s.name, select = rect(doc, "sp_sel_" .. i, k), rename = rect(doc, "sp_ren_" .. i, k),
                             delete = rect(doc, "sp_del_" .. i, k), img = rect(doc, "sp_img_" .. i, k)}
                pcall(function() r.rows[i].text = doc["sp_nm_" .. i].text; r.rows[i].info = doc["sp_info_" .. i].text end)
            end
            pcall(function() r.quota, r.sel, r.note, r.name = doc.sp_quota.text, doc.sp_sel.text, doc.sp_note.text, doc.sp_name.text end)
        end
        return r
    elseif op == "select" then return {ok = M.select(args.i or 1), cur = S.cur}
    elseif op == "cycle" then return {ok = M.cycle(args.d or 1), cur = S.cur}
    elseif op == "list" then return {seq = M.request_list()}
    elseif op == "rename" then return {seq = M.rename(args.id or S.cur, args.name or "")}
    elseif op == "delete" then return {seq = M.delete(args.id or S.cur)}
    elseif op == "capture" then return {seq = M.capture(ol().S.cam_pid)}
    elseif op == "throw" then return {seq = M.throw(ol().S.cam_pid)}
    elseif op == "open" then M.open_ui(); return {opened = true}
    elseif op == "close" then M.ui_close(); return {closed = true}
    elseif op == "burst" then return {ok = M.burst(args.x or 0, args.y or 80, args.z or 0)}
    end
    local balls = {}
    for eid, e in pairs(cl().S.ents) do
        if e.kind == 5 then
            local p = e.shown or e.pos
            balls[#balls + 1] = {eid = eid, pos = {p.x, p.y, p.z}, uid = e.uid}
        end
    end
    table.sort(balls, function(a, b) return a.eid < b.eid end)
    local pid = ol().S.cam_pid
    local okinv, _, slot = pid and pcall(player.get_inventory, pid)
    return {cur = S.cur, cur_index = cur_index(), snaps = S.snaps, list = S.list and {count = S.list.count, max_count = S.list.max_count,
            used = S.list.used, quota = S.list.quota, spawns_min = S.list.spawns_min, spawn_limit = S.list.spawn_limit,
            mobs = S.list.mobs, mobs_max = S.list.mobs_max} or nil, replies = S.replies, events = S.events, balls = balls,
            stats = S.stats, hud = hud_text(), held = held(pid), slot = okinv and slot or nil, keys_ok = S.keys_ok,
            last_spawned = S.last_spawned, ui_error = S.ui_error, doc = S.doc ~= nil}
end

return M
