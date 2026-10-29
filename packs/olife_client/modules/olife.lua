-- olife_client:olife — the player-facing Olife layer of the client (replica side): wave 4a + UX round 1 (02.10).
-- Injector (RMB on a scripted entity, or ` while aiming at one) -> ToolUse{injector, use} -> the world raycasts and answers
-- ScriptState (+ RequestReply): the editor overlay (layouts/editor.xml — the user's original layout on native 0.32 XML)
-- shows the code (largest), the console, the scripts panel (local files, the server copy, templates) and one status
-- line; pages Profiler (ScriptMeters + ScriptProfile, sparkline) and Entity settings (rename, model/texture, delete).
-- Buttons only SEND requests (seq); what is shown is the last ScriptState / ConsoleDelta / ScriptProfile from the world.
-- GravityGun (LMB, or RMB through the item script) -> ToolUse{gravity, grab|release}: ONE press = ONE toggle (edge,
-- repeats of a held button ignored, debounce 150 ms), sound on the world's answer; while holding, the look direction
-- goes up as ToolUse{aim} (<= 10/s). Shift+LMB (with an Olife tool): delete the last opened entity (EntityEdit op 1,
-- owner/admin), Shift+RMB: open the editor of the last opened entity from anywhere (ScriptOpen). Name tags (EntityMeta)
-- are 3D text over the replica — only while the Injector is the selected item, small, fading with distance.
-- Camera mode (windowed client without the bot walk): the hud player IS the client player — its position/rotation
-- go up as PlayerInput, world corrections snap it (client.lua calls camera_tick).
local LOOKS = require "olife_proto:looks"
local FXA2 = require "olife_client:fx"          -- UX A2: feedback catalogue (sound + toast per interaction)
local MB = require "olife_client:mobs"          -- UX B1: my-mobs panel, editor profile tab / versions / error line
local M = {}
local S = {
    open = nil, doc = nil, st = {}, console = {}, edited = false, seq = 0, holding = nil, own = {}, meta = {},
    tags = {}, replies = {}, last_reply = {}, cam_pid = nil, hb_at = 0, aim_at = 0, aim_dir = nil,
    pending_open = nil, files_dir = "config:olife/scripts", tab = "code", prof = {}, hist = {}, looks = {},
    last_opened = nil, grab_pending = nil, rmb_held = false, last_press = {}, tags_on = false, sounds = {},
    toast = nil, hud_doc = nil, seen = {}, scripts = {}, del_armed_at = nil, sel_model = nil, sel_texture = nil, cur_file = nil,
    perms = {}, friends = nil, forks = {}, fr_doc = nil, fr_rows = {}, perm_shown = {}, a1_pending = {},   -- UX A1
    stats = {states = 0, deltas = 0, delta_lines = 0, delta_dropped = 0, replies = 0, refused = 0, tool_uses = 0,
             grabs_ok = 0, ownership = 0, meta = 0, opens = 0, closes = 0, saves = 0, runs = 0, stops = 0,
             aims = 0, files_saved = 0, files_opened = 0, ui_errors = 0, presses = 0, presses_ignored = 0,
             toggles = 0, deletes = 0, deletes_ok = 0, shift_opens = 0, backtick_opens = 0, profiles = 0, looks = 0,
             renames = 0, files_deleted = 0, sounds = 0,
             perms = 0, perm_sets = 0, friend_lists = 0, friend_ops = 0, forks = 0, forks_ok = 0, denied = 0},
}
M.S = S
local CONSOLE_KEEP = 200        -- lines kept locally per open editor (the world keeps 64)
local DEBOUNCE = 0.15           -- s between two accepted tool presses (UX round 1)
local HIST_N = 60               -- sparkline: credits per tick, one sample a second
local STATUS_TXT = {[0] = "STOP", [1] = "RUN", [2] = "ERROR"}
local OP_TXT = {[1] = "open", [2] = "save", [3] = "run", [4] = "stop", [5] = "lock", [6] = "tool", [7] = "edit",
                [8] = "права", [9] = "форк", [10] = "друзья", [11] = "проверка",       -- + UX A1
                [12] = "список мобов", [13] = "спасти", [14] = "уничтожить", [15] = "восстановить", [16] = "профиль",
                [17] = "история", [18] = "версия"}                                        -- + UX B1

local TEMPLATES = {
    spin = "-- spin in place\nlocal t = 0\nfunction on_tick(dt)\n    t = t + dt\n    self:set_rot(0, (t * 90) % 360, 0)\nend\n",
    orbit = "-- small circle around the start point, prints every 2 s\nlocal t, home = 0, nil\n" ..
        "function on_tick(dt)\n    t = t + dt\n    local p = self.pos\n    if home == nil then home = {p[1] - 1.5, p[2], p[3]} end\n" ..
        "    self:move_to({home[1] + math.cos(t) * 1.5, home[2], home[3] + math.sin(t) * 1.5})\n" ..
        "    if math.floor(t * 10) % 20 == 0 then print('orbit', math.floor(t)) end\nend\n",
    hello = "-- console demo: one line a second\nlocal n = 0\nfunction on_tick(dt)\n    n = n + 1\n" ..
        "    if n % 20 == 0 then print('hello #' .. (n / 20)) end\nend\n",
    walk = "-- walk back and forth along x\nlocal t = 0\nfunction on_tick(dt)\n    t = t + dt\n    local p = self.pos\n" ..
        "    local dx = (math.floor(t / 2) % 2 == 0) and 0.1 or -0.1\n    self:move_to({p[1] + dx, p[2], p[3]})\nend\n",
}
M.TEMPLATES = TEMPLATES
local TEMPLATE_ORDER = {"spin", "orbit", "hello", "walk"}

local function log(fmt, ...) print("[olife_client] olife: " .. string.format(fmt, ...)) end
local function cl() return require "olife_client:client" end

local function next_seq()
    S.seq = S.seq + 1
    return S.seq
end
M.next_seq = next_seq                 -- UX B2: olife_client:spammer shares the request seq space

local function send(name, msg)
    local c = cl()
    if c.S.state ~= "play" then return false end
    c.send(name, msg)
    return true
end
M.send = send

-- ------------------------------------------------------------------ feedback: sound + HUD toast (UX round 1)
-- sounds are the user's own from the prototype (engine_client/config/olife/sounds), preloaded as olife/<name>
function M.sound(name)
    S.stats.sounds = S.stats.sounds + 1
    S.sounds[#S.sounds + 1] = {name = name, t = time.uptime()}
    if #S.sounds > 16 then table.remove(S.sounds, 1) end
    if audio and audio.play_sound_2d then pcall(audio.play_sound_2d, "olife/" .. name, 0.8, 1.0) end
end

function M.toast(text, kind)
    S.toast = {text = text, kind = kind or "info", t = time.uptime()}
    S.last_toast = text
    local d = S.hud_doc
    if d then
        pcall(function()
            d.toast.text = text
            d.toast.color = kind == "error" and {255, 150, 140, 255} or {220, 240, 255, 255}
        end)
    end
end

function M.hud_opened(doc) S.hud_doc = doc end

local function toast_tick()
    local t = S.toast
    if not t or not S.hud_doc then return end
    local age = time.uptime() - t.t
    local a = age < 2.5 and 255 or math.max(0, math.floor(255 * (1 - (age - 2.5) / 1.0)))
    pcall(function()
        local c = S.hud_doc.toast.color
        S.hud_doc.toast.color = {c[1], c[2], c[3], a}
    end)
    if a == 0 then S.toast = nil end
end

-- ------------------------------------------------------------------ camera player (windowed client)
-- Shift = the crouch binding (what the engine itself treats as shift) or either Shift key
local function shift_down()
    if not input or not input.is_pressed then return false end
    local ok0, c = pcall(input.is_active, "movement.crouch")
    local ok1, a = pcall(input.is_pressed, "key:left-shift")
    local ok2, b = pcall(input.is_pressed, "key:right-shift")
    return (ok0 and c) or (ok1 and a) or (ok2 and b) or false
end
M.shift_down = shift_down

-- an overlay / inventory is open: mouse clicks belong to the UI, not to the tools
local function ui_busy()
    local ok, open = pcall(hud.is_inventory_open)
    return ok and open or false
end

function M.on_hud_open(pid)
    S.cam_pid = pid
    local c = cl()
    c.S.camera_pid = pid
    pcall(player.set_flight, pid, true)
    pcall(player.set_noclip, pid, true)
    pcall(player.set_infinite_items, pid, true)
    M.ensure_tools(pid)
    -- LMB = the attack binding (edge: the engine calls it once per press): gravity gun toggle, Shift+LMB delete
    pcall(input.add_callback, "player.attack", function() M.lmb(pid) end)
    -- RMB = the build binding (edge, once per press, also where the item's on_use is not called: Shift over a block)
    pcall(input.add_callback, "player.build", function() M.rmb_press(pid, M.held_tool(pid)) end)
    -- ` (the engine console key): aiming at a bench -> its editor instead of the console (the console opens first:
    -- its runnable was posted earlier; ours closes it, the editor replaces it when the world answers)
    pcall(input.add_callback, "devtools.console", function() M.backtick(pid) end)
    pcall(hud.open_permanent, "olife_client:olife_hud")
    pcall(function() require("olife_client:spammer").on_hud_open(pid) end)     -- UX B2: HUD line, [ ] keys, library
    log("hud player %d: camera mode, tools in slots 0/1", pid)
end

-- tools into the hotbar: slot 0 injector, slot 1 gravity gun. Called at hud open and during the first 10 s of the
-- session: the world's default player items land in the hotbar AFTER on_hud_open (seen 02.10: slot 0 = stone x32)
function M.ensure_tools(pid)
    local okinv, invid = pcall(player.get_inventory, pid)
    if not okinv or not invid then return false end
    local ok1, inj = pcall(item.index, "olife_client:injector")
    local ok2, gg = pcall(item.index, "olife_client:gravity_gun")
    local changed = false
    if ok1 and inj and inventory.get(invid, 0) ~= inj then pcall(inventory.set, invid, 0, inj, 1); changed = true end
    if ok2 and gg and inventory.get(invid, 1) ~= gg then pcall(inventory.set, invid, 1, gg, 1); changed = true end
    local ok3, sp = pcall(item.index, "olife_client:spammer")                 -- UX B2: slot 2 = Spammer
    if ok3 and sp and inventory.get(invid, 2) ~= sp then pcall(inventory.set, invid, 2, sp, 1); changed = true end
    return changed
end

function M.held_tool(pid)
    local ok, invid, slot = pcall(player.get_inventory, pid)
    if not ok or not invid then return 0 end
    local ok2, id = pcall(inventory.get, invid, slot)
    if not ok2 or not id then return 0 end
    local okn, name = pcall(item.name, id)
    if not okn then return 0 end
    if name == "olife_client:injector" then return 1 end
    if name == "olife_client:gravity_gun" then return 2 end
    if name == "olife_client:spammer" then return 3 end                       -- UX B2
    return 0
end

-- every logical tick in camera mode (client.lua): the hud player's state is what goes up as PlayerInput
function M.camera_tick(cs)
    local pid = S.cam_pid
    if not pid then return end
    local x, y, z = player.get_pos(pid)
    local yaw, pitch, roll = player.get_rot(pid)
    cs.pos.x, cs.pos.y, cs.pos.z = x, y, z
    cs.rot.x, cs.rot.y, cs.rot.z = yaw, pitch, roll
    if cs.tick < 200 and cs.tick % 10 == 0 then M.ensure_tools(pid) end
    M.aim_tick()
end

function M.camera_snap(cs)
    if S.cam_pid then player.set_pos(S.cam_pid, cs.pos.x, cs.pos.y, cs.pos.z) end
end

local function camera_ray(pid)
    local okc, cam = pcall(function() return cameras.get(player.get_camera(pid)) end)
    if okc and cam then
        local o, d = cam:get_pos(), cam:get_front()
        return {x = o[1], y = o[2], z = o[3]}, {x = d[1], y = d[2], z = d[3]}
    end
    local x, y, z = player.get_pos(pid)
    local d = player.get_dir(pid)
    return {x = x, y = y + 0.7, z = z}, {x = d[1], y = d[2], z = d[3]}
end
M.camera_ray = camera_ray

-- ------------------------------------------------------------------ tools
local function eid_of_uid(uid)
    if not uid or uid == 0 then return 0 end
    for eid, e in pairs(cl().S.ents) do
        if e.uid == uid then return eid end
    end
    return 0
end

local function aimed_eid(pid)
    local okse, uid = pcall(player.get_selected_entity, pid)
    return okse and eid_of_uid(uid) or 0
end

-- tool 1 injector (use), 2 gravity gun (grab / release while holding or a grab is on its way)
function M.use_tool(tool, pid)
    pid = pid or S.cam_pid
    if not pid then return false end
    local target = aimed_eid(pid)
    local o, d = camera_ray(pid)
    local action = 1
    local hold = S.holding or S.grab_pending
    if tool == 2 then action = hold and 3 or 2 end
    S.stats.tool_uses = S.stats.tool_uses + 1
    local seq = next_seq()
    if tool == 1 then S.pending_open = seq end
    if tool == 2 then
        S.stats.toggles = S.stats.toggles + 1
        if action == 2 then S.grab_pending = target ~= 0 and target or true else S.grab_pending = nil end
    end
    send("ToolUse", {seq = seq, tool = tool, action = action, target = action == 3 and (S.holding or 0) or target,
                     origin = o, dir = d})
    S.last_tool = {seq = seq, tool = tool, action = action, target = target, tick = cl().S.tick}
    return seq
end

-- one press = one action: a held button repeats (RMB: on_use every 0.16 s, see PlayerController) -> ignored until it
-- is released (frame() watches the binding); two presses closer than DEBOUNCE -> the second is ignored
local function accept_press(kind)
    S.stats.presses = S.stats.presses + 1
    local now = time.uptime()
    if kind == "rmb" then
        if S.rmb_held then S.stats.presses_ignored = S.stats.presses_ignored + 1; return false end
        S.rmb_held = true
    end
    local last = S.last_press[kind]
    if last and now - last < DEBOUNCE then S.stats.presses_ignored = S.stats.presses_ignored + 1; return false end
    S.last_press[kind] = now
    return true
end
M.accept_press = accept_press

-- RMB: the build binding callback (first) and the item scripts' on_use (repeats every 0.16 s while held) both land
-- here; accept_press lets one action per press through
function M.rmb_press(pid, tool)
    pid = pid or S.cam_pid
    if not tool or tool == 0 or ui_busy() then return end
    if not accept_press("rmb") then return end
    if tool == 3 then                                                        -- UX B2: Spammer RMB = throw, Shift+RMB = library
        local SP = require "olife_client:spammer"
        if shift_down() then SP.open_ui(); return nil end
        return SP.throw(pid)
    end
    if shift_down() then return M.open_last() end
    return M.use_tool(tool, pid)
end
function M.rmb(tool, pid) return M.rmb_press(pid, tool) end

-- LMB (attack binding, edge-triggered by the engine): gravity gun toggle; Shift+LMB with an Olife tool: delete
function M.lmb(pid)
    local tool = M.held_tool(pid)
    if tool == 0 or ui_busy() then return end
    if not accept_press("lmb") then return end
    if shift_down() then return M.delete_last() end
    if tool == 2 then return M.use_tool(2, pid) end
    if tool == 3 then return require("olife_client:spammer").capture(pid) end   -- UX B2: Spammer LMB = capture
end

-- Shift+RMB: the editor of the last opened entity, wherever it is (the world opens without a ray)
function M.open_last()
    local eid = S.last_opened
    if not eid then
        M.sound("refuse")
        M.toast("Ещё не открыта ни одна сущность (Injector + ПКМ по сущности)", "error")
        return nil
    end
    S.stats.shift_opens = S.stats.shift_opens + 1
    local seq = next_seq()
    S.pending_open = seq
    send("ScriptOpen", {seq = seq, eid = eid, edit = true})
    return seq
end

-- Shift+LMB / the settings page: delete the last opened entity (owner/admin; the world answers RequestReply op 7)
function M.delete_last(eid)
    eid = eid or S.last_opened
    if not eid then
        M.sound("refuse")
        M.toast("Нечего удалять: сначала откройте сущность Injector'ом", "error")
        return nil
    end
    S.stats.deletes = S.stats.deletes + 1
    local seq = next_seq()
    S.pending_delete = {seq = seq, eid = eid}
    send("EntityEdit", {seq = seq, eid = eid, op = 1, name = "", model = "", texture = ""})
    return seq
end

-- `: aiming at a bench -> its editor (like the engine console, but for the entity)
function M.backtick(pid)
    if shift_down() and not S.open and not ui_busy() then          -- UX A1: Shift+` -> the friends page
        -- the engine console opens AFTER this callback (a frame or two later): frame() closes it when it shows up and
        -- opens the friends page then (or after 0.3 s if it never shows)
        S.fr_want = time.uptime()
        return
    end
    if S.open or ui_busy() then return end
    local eid = aimed_eid(pid)
    if eid == 0 or not S.meta[eid] then return end
    S.stats.backtick_opens = S.stats.backtick_opens + 1
    time.post_runnable(function() pcall(hud.close, "core:console") end)
    M.use_tool(1, pid)
end

-- while holding: the look direction goes up (<= 10/s, only when it changed)
function M.aim_tick()
    if not S.holding or not S.cam_pid then return end
    local t = cl().S.tick
    if t - S.aim_at < 2 then return end
    local _, d = camera_ray(S.cam_pid)
    local a = S.aim_dir
    if a and math.abs(a.x - d.x) + math.abs(a.y - d.y) + math.abs(a.z - d.z) < 1e-3 then return end
    S.aim_at, S.aim_dir = t, d
    S.stats.aims = S.stats.aims + 1
    local o = camera_ray(S.cam_pid)
    send("ToolUse", {seq = next_seq(), tool = 2, action = 4, target = S.holding, origin = o, dir = d})
end

-- ------------------------------------------------------------------ messages from the world
local H = {}

local function hist_push(eid, v)
    local h = S.hist[eid]
    if not h then h = {}; S.hist[eid] = h end
    h[#h + 1] = v
    while #h > HIST_N do table.remove(h, 1) end
end

function H.ScriptState(m)
    S.stats.states = S.stats.states + 1
    local prev = S.st[m.eid]
    S.st[m.eid] = m
    if m.seq ~= 0 and m.seq == S.pending_open or (S.open == nil and m.seq ~= 0 and S.want_open == m.eid) then
        -- answer to our Injector use / open: show the editor
        S.pending_open, S.want_open = nil, nil
        S.console = {}
        for i, l in ipairs(m.console) do S.console[i] = l end
        M.open_editor(m.eid)
        return
    end
    if S.open == m.eid then
        if not m.editing or not S.edited then M.set_code(m.code) end   -- never overwrite unsaved local edits
        if prev and #m.console > 0 and (#S.console == 0) then
            for i, l in ipairs(m.console) do S.console[i] = l end
        end
        M.refresh()
    end
end

function H.ConsoleDelta(m)
    S.stats.deltas = S.stats.deltas + 1
    S.stats.delta_lines = S.stats.delta_lines + #m.lines
    S.stats.delta_dropped = S.stats.delta_dropped + m.dropped
    local st = S.st[m.eid]
    if st then st.meters = m.meters end
    if S.open ~= m.eid then return end
    local last = S.console[#S.console]
    for _, l in ipairs(m.lines) do
        if not last or l.seq > last.seq then
            S.console[#S.console + 1] = l
            last = l
        end
    end
    if m.dropped > 0 then
        S.console[#S.console + 1] = {seq = last and last.seq or 0, tick = 0, kind = 2,
                                     text = string.format("... %d lines dropped (rate limit)", m.dropped)}
    end
    while #S.console > CONSOLE_KEEP do table.remove(S.console, 1) end
    M.refresh()
end

function H.ScriptProfile(m)
    S.stats.profiles = S.stats.profiles + 1
    S.prof[m.eid] = m
    local st = S.st[m.eid]
    hist_push(m.eid, st and st.meters and st.meters.credits_tick or 0)
    if S.open == m.eid then M.refresh() end
end

local REPLY_RU = {[1] = "нет такой сущности", [2] = "не скриптовая сущность", [3] = "нет прав",
                  [16] = "нет такого игрока", [17] = "нет такого запроса", [18] = "превышен лимит",       -- UX A1
                  [4] = "редактирует другой игрок", [5] = "у вас нет блокировки", [6] = "слишком далеко",
                  [7] = "луч мимо", [8] = "держит другой игрок", [9] = "слишком часто", [10] = "плохой код",
                  [11] = "вы ничего не держите", [12] = "песочница недоступна", [13] = "инструмент/действие",
                  [14] = "позиция/направление", [15] = "недопустимое значение",
                  [22] = "нужно подтверждение", [23] = "подтверждение устарело", [24] = "безопасная позиция неизвестна",   -- UX B1
                  [25] = "чанк не прогружен: подойдите ближе", [26] = "нечего восстанавливать", [27] = "лимит",
                  [28] = "нет такой версии", [29] = "хранилище отказало"}

-- UX A1: the reason of a refusal; code 3 names the right ("forbidden: move is for owner")
local A1_ACT_RU = {move = "двигать", read_code = "читать код", edit_code = "менять код", run = "запуск",
                   appearance = "вид/имя", clone = "форк", destroy = "удаление", storage_read = "хранилище: чтение",
                   storage_write = "хранилище: запись"}
local A1_AUD_RU = {owner = "только владелец", friends = "владелец и друзья", list = "владелец и список", everyone = "все"}
local function reply_text(code, reason)
    if code == 3 and type(reason) == "string" then
        local a, aud = reason:match("^forbidden: ([%w_]+) is for (%w+)")
        if a then return string.format("нет прав: %s — %s", A1_ACT_RU[a] or a, A1_AUD_RU[aud] or aud) end
        if reason:find("^forbidden: ") then return "нет прав: " .. reason:sub(12) end
    end
    return REPLY_RU[code] or reason
end
M.reply_text = reply_text

function H.RequestReply(m)
    S.stats.replies = S.stats.replies + 1
    if m.code ~= 0 then S.stats.refused = S.stats.refused + 1 end
    local r = {seq = m.seq, op = m.op, eid = m.eid, code = m.code, reason = m.reason, tick = cl().S.tick}
    S.last_reply[m.op] = r
    S.replies[#S.replies + 1] = r
    if #S.replies > 32 then table.remove(S.replies, 1) end
    local lt = S.last_tool
    if m.op == 6 and lt and lt.seq == m.seq and lt.tool == 2 then
        if m.code == 0 then           -- UX A2: every interaction through the fx catalogue (sound + toast)
            if lt.action == 2 then S.stats.grabs_ok = S.stats.grabs_ok + 1; FXA2.event("grab", string.format("Захвачено #%d", m.eid), {eid = m.eid})
            elseif lt.action == 3 then FXA2.event("release", string.format("Отпущено #%d", m.eid), {eid = m.eid}) end
        else
            S.grab_pending = nil
            FXA2.deny("Гравипушка: " .. reply_text(m.code, m.reason), m.code)
        end
    end
    if m.op == 6 and lt and lt.seq == m.seq and lt.tool == 1 and m.code ~= 0 and m.code ~= 7 then
        FXA2.deny("Injector: " .. reply_text(m.code, m.reason), m.code)
    end
    -- UX A2: run / stop / save confirmed by the world; rate/limit refusals of any op (A1 handles code 3 of 1..4)
    if m.code == 0 and (m.op == 2 or m.op == 3 or m.op == 4) then
        FXA2.event(({[2] = "save", [3] = "run", [4] = "stop"})[m.op], string.format("%s #%d",
            ({[2] = "Сохранено", [3] = "Запущено", [4] = "Остановлено"})[m.op], m.eid), {eid = m.eid})
    elseif m.code ~= 0 and m.code ~= 3 and m.op >= 1 and m.op <= 5 then
        FXA2.deny(string.format("%s: %s", OP_TXT[m.op] or "?", reply_text(m.code, m.reason)), m.code)
    end
    local pd = S.pending_delete
    if m.op == 7 and pd and pd.seq == m.seq then
        S.pending_delete = nil
        if m.code == 0 then
            S.stats.deletes_ok = S.stats.deletes_ok + 1
            FXA2.event("delete", string.format("Сущность #%d удалена", pd.eid), {eid = pd.eid})
            if S.last_opened == pd.eid then S.last_opened = nil end
            if S.open == pd.eid then M.ui_close() end
        else
            FXA2.deny(string.format("Удаление #%d отклонено: %s", pd.eid, REPLY_RU[m.code] or m.reason), m.code)
        end
    elseif m.op == 7 and m.code == 0 then
        FXA2.ok(string.format("#%d: изменено", m.eid))
    elseif m.op == 7 then
        FXA2.deny(string.format("#%d: %s", m.eid, reply_text(m.code, m.reason)), m.code)
    end
    if (m.op >= 8 and m.op <= 11) or (m.code == 3 and m.op >= 1 and m.op <= 4) then M.a1_reply(m) end   -- UX A1 feedback
    if m.op >= 12 and m.op <= 18 then MB.on_reply(m) end                                 -- UX B1: panel / versions
    if m.op == 2 and m.code == 0 then MB.on_saved(m.eid) end                            -- UX B1: a save = a commit
    if m.code ~= 0 then
        log("request seq=%d op=%d eid=%d refused %d: %s", m.seq, m.op, m.eid, m.code, m.reason)
        if m.op == 6 and S.pending_open == m.seq then S.pending_open = nil end
    end
    if m.op ~= 6 or m.code ~= 0 then
        S.notice = m.code ~= 0 and string.format("%s: %s", OP_TXT[m.op] or "?", reply_text(m.code, m.reason)) or nil
    end
    M.refresh()
end

function H.EntityOwnership(m)
    S.stats.ownership = S.stats.ownership + 1
    S.own[m.eid] = {holder_eid = m.holder_eid, holder_name = m.holder_name, tick = m.tick}
    local me = cl().S.eid
    if m.holder_eid ~= 0 and m.holder_eid == me then
        S.holding, S.aim_dir, S.grab_pending = m.eid, nil, nil
    elseif S.holding == m.eid then
        S.holding = nil
    end
    local mt = S.meta[m.eid]
    if mt then M.update_tag(m.eid) end
end

function H.EntityMeta(m)
    S.stats.meta = S.stats.meta + 1
    S.meta[m.eid] = m
    M.update_tag(m.eid)
end

function H.EntityLook(m)
    S.stats.looks = S.stats.looks + 1
    S.looks[m.eid] = {model = m.model, texture = m.texture, applied = nil}
    M.apply_look(m.eid)
    if S.open == m.eid then M.refresh() end
end

-- ------------------------------------------------------------------ UX A1: rights, friends, fork (world: olife_world:perms)
local function fx() return require "olife_client:fx" end

function H.EntityPerms(m)
    S.stats.perms = S.stats.perms + 1
    S.perms[m.eid] = m
    if S.open == m.eid then M.refresh() end
end

function H.FriendList(m)
    S.stats.friend_lists = S.stats.friend_lists + 1
    local old = S.friends
    S.friends = m
    if old then          -- what changed for this player: a new incoming request, a new friend
        local had_in, had_fr = {}, {}
        for _, a in ipairs(old.incoming) do had_in[a] = true end
        for _, f in ipairs(old.friends) do had_fr[f.account] = true end
        for _, a in ipairs(m.incoming) do
            if not had_in[a] then pcall(fx().event, "info", "Запрос в друзья от " .. a .. " (Shift+` — друзья)") ; M.sound("ok") end
        end
        for _, f in ipairs(m.friends) do
            if not had_fr[f.account] and m.seq == 0 then pcall(fx().ok, f.account .. " теперь ваш друг") end
        end
    end
    M.friends_refresh()
    if S.open then M.refresh() end
end

function H.EntityForked(m)
    S.stats.forks_ok = S.stats.forks_ok + 1
    S.forks[#S.forks + 1] = {seq = m.seq, src = m.src, eid = m.eid, name = m.name}
    if #S.forks > 16 then table.remove(S.forks, 1) end
    S.last_opened = m.eid                  -- Shift+RMB opens the fork
    pcall(fx().event, "fork", string.format("Форк #%d -> #%d %s (Shift+ПКМ — открыть)", m.src, m.eid, m.name), {eid = m.eid})
end

local FRIEND_OK = {requested = "запрос отправлен", accepted = "запрос принят", denied = "запрос отклонён",
                   cancelled = "запрос отменён", removed = "удалён из друзей", friends = "теперь друзья",
                   ["already friends"] = "уже друзья"}

-- feedback for the A1 replies (+ code 3 refusals of open/save/run/stop): sound + toast through olife_client:fx
function M.a1_reply(m)
    local f = fx()
    if m.code ~= 0 then
        S.stats.denied = S.stats.denied + 1
        local what = ({[1] = "Открыть", [2] = "Сохранить", [3] = "Запуск", [4] = "Стоп", [8] = "Права", [9] = "Форк",
                       [10] = "Друзья", [11] = "Проверка"})[m.op] or "Запрос"
        if m.op ~= 11 then pcall(f.deny, what .. ": " .. reply_text(m.code, m.reason), m.code) end
        return
    end
    if m.op == 8 then
        local pa = S.a1_pending[m.seq]
        pcall(f.ok, pa and string.format("Права: %s — %s", pa.cap, pa.aud) or "Права изменены")
    elseif m.op == 10 and m.reason ~= "list" then
        pcall(f.ok, "Друзья: " .. (FRIEND_OK[m.reason] or m.reason))
    end
    S.a1_pending[m.seq] = nil
end

function M.on_msg(name, m)
    local h = H[name]
    if h then h(m) end
end
M.handled = {ScriptState = true, ConsoleDelta = true, RequestReply = true, EntityOwnership = true, EntityMeta = true,
             EntityLook = true, ScriptProfile = true, EntityPerms = true, FriendList = true, EntityForked = true}  -- + UX A1

-- ------------------------------------------------------------------ model / texture of a bench (EntityLook)
function M.apply_look(eid)
    local lk = S.looks[eid]
    local e = cl().S.ents[eid]
    if not lk or not e or not e.uid then return false end
    if lk.applied == e.uid then return true end
    local ent = entities.get(e.uid)
    if not ent or not ent.skeleton then return false end
    local rig = ent.skeleton
    local model = lk.model ~= "" and lk.model or LOOKS.DEFAULT_MODEL
    local mdef = LOOKS.model(model) or LOOKS.model(LOOKS.DEFAULT_MODEL)
    local okm = pcall(function()
        local idx = rig:index("rody")
        if idx then rig:set_model(idx, mdef.id) end
    end)
    if mdef.retex then
        local tex = lk.texture ~= "" and lk.texture or LOOKS.DEFAULT_TEXTURE
        for i = 0, 5 do pcall(rig.set_texture, rig, "$" .. i, tex) end
    end
    lk.applied = e.uid
    return okm
end

-- ------------------------------------------------------------------ name tags (render side)
-- checked lazily: this module is first required from the start script, before the engine created gfx (headless: never)
local function text3d() return gfx ~= nil and gfx.text3d ~= nil end
local TAG_SCALE, TAG_NEAR, TAG_FAR = 0.02, 6, 24     -- UX round 1: half the size, fade from 6 to 24 blocks

local function tag_text(eid)
    local m = S.meta[eid]
    local own = S.own[eid]
    local txt = m.label
    if own and own.holder_eid ~= 0 then txt = txt .. " (held by " .. own.holder_name .. ")" end
    return txt
end

local function tag_color(m, alpha)
    local c = FXA2.tag_rgb(m.status)        -- UX A2: RUN green, STOP white, ERROR red, THROTTLED amber, FROZEN blue
    return {c[1], c[2], c[3], alpha}
end

local function hide_tag(eid)
    local id = S.tags[eid]
    if id then
        if text3d() then pcall(gfx.text3d.hide, id) end
        S.tags[eid] = nil
    end
end

-- text of an existing tag (EntityMeta / ownership changed); creation is frame()'s job (only with the Injector)
function M.update_tag(eid)
    local id = S.tags[eid]
    if id and S.meta[eid] and text3d() then
        pcall(gfx.text3d.set_text, id, tag_text(eid))
    end
end

local function tags_tick()
    local ents = cl().S.ents
    local on = S.cam_pid ~= nil and M.held_tool(S.cam_pid) == 1 and text3d()
    S.tags_on = on and true or false
    for eid in pairs(S.tags) do
        if not on or not ents[eid] or not S.meta[eid] then hide_tag(eid) end
    end
    for eid in pairs(S.meta) do          -- an entity that was here and is gone (despawn / deleted) forgets its tag
        if ents[eid] then S.seen[eid] = true elseif S.seen[eid] then S.meta[eid], S.seen[eid] = nil, nil end
    end
    if not on then return end
    local cx, cy, cz = player.get_pos(S.cam_pid)
    for eid, m in pairs(S.meta) do
        local e = ents[eid]
        if not e then goto continue end
        local p = e.shown or e.pos
        local d = math.sqrt((p.x - cx) ^ 2 + (p.y - cy) ^ 2 + (p.z - cz) ^ 2)
        local a = d <= TAG_NEAR and 1 or math.max(0, 1 - (d - TAG_NEAR) / (TAG_FAR - TAG_NEAR))
        local id = S.tags[eid]
        if a <= 0.02 then
            hide_tag(eid)
        elseif not id then
            local ok, nid = pcall(gfx.text3d.show, {p.x, p.y + 0.8, p.z}, tag_text(eid),
                {display = "y_free_billboard", scale = TAG_SCALE, render_distance = TAG_FAR, color = tag_color(m, a)})
            if ok then S.tags[eid] = nid; e.tag_a = a end
        else
            pcall(gfx.text3d.set_pos, id, {p.x, p.y + 0.8, p.z})
            if not e.tag_a or math.abs(e.tag_a - a) > 0.04 or e.tag_st ~= m.status then
                e.tag_a, e.tag_st = a, m.status
                pcall(gfx.text3d.update_settings, id, {color = tag_color(m, a)})
            end
        end
        ::continue::
    end
end

-- every rendered frame (hud.lua on_hud_render): tags, looks, the RMB hold state, the toast, the editor heartbeat
function M.frame()
    -- a held RMB repeats on_use; the hold ends when the binding is released
    if S.rmb_held and input and input.is_active then
        local ok, act = pcall(input.is_active, "player.build")
        if ok and not act then S.rmb_held = false end
    end
    tags_tick()
    pcall(function() require("olife_client:spammer").frame() end)              -- UX B2: HUD line, Shift+wheel slot
    for eid, lk in pairs(S.looks) do
        local e = cl().S.ents[eid]
        if e and e.uid and lk.applied ~= e.uid then M.apply_look(eid) end
    end
    toast_tick()
    if S.fr_want then                         -- UX A1: Shift+` -> friends page instead of the engine console
        local con = hud.is_open and hud.is_open("core:console")
        if con or time.uptime() - S.fr_want > 0.3 then
            S.fr_want = nil
            if con then pcall(hud.close, "core:console") end
            M.ui_friends()
        end
    end
    if S.del_armed_at and time.uptime() - S.del_armed_at > 4 then
        S.del_armed_at = nil
        if S.doc then pcall(function() S.doc.set_note.text = "" end) end
    end
    -- editor heartbeat: keep the lock while the editor is open (the world drops it after 60 s of silence)
    if S.open then
        local st = S.st[S.open]
        local now = time.uptime()
        if st and st.editing and now - S.hb_at > 20 then
            S.hb_at = now
            send("ScriptOpen", {seq = next_seq(), eid = S.open, edit = true})
        end
    end
end

-- ------------------------------------------------------------------ editor overlay
function M.open_editor(eid)
    S.open = eid
    S.last_opened = eid
    S.edited = false
    S.hb_at = time.uptime()
    S.stats.opens = S.stats.opens + 1
    S.del_armed_at = nil
    FXA2.event("inject", string.format("Injector: #%d %s", eid, (S.st[eid] and S.st[eid].name) or ""), {eid = eid})
    if hud and hud.show_overlay then
        if hud.is_open and hud.is_open("olife_client:editor") then
            M.set_code(S.st[eid].code)
            M.scripts_refresh()
            M.refresh()
        else
            local ok, err = pcall(hud.show_overlay, "olife_client:editor", false)
            if not ok then S.stats.ui_errors = S.stats.ui_errors + 1; log("editor overlay failed: %s", tostring(err)) end
        end
    end
end

-- sparkline bars (created once per opened document)
local function spark_build(doc)
    pcall(function()
        doc.spark:clear()
        for i = 1, HIST_N do
            doc.spark:add(string.format("<container id='sp_%d' pos='%d,40' size='6,1' color='#40C0FFC0' interactive='false'/>",
                                        i, (i - 1) * 8 + 2))
        end
    end)
end

function M.ui_opened(doc)
    S.doc = doc
    local st = S.open and S.st[S.open]
    if st then M.set_code(st.code) end
    spark_build(doc)
    M.perm_build(doc)                       -- UX A1
    MB.editor_opened(doc)                   -- UX B1
    M.ui_tab(S.tab or "code")
    M.scripts_refresh()
    M.refresh()
end

function M.ui_closed()
    S.doc = nil
    if S.open then
        S.stats.closes = S.stats.closes + 1
        send("ScriptLockRelease", {seq = next_seq(), eid = S.open, close = true})
        log("editor closed eid=%d", S.open)
    end
    S.open, S.edited = nil, false
    cl().flush()
end

function M.set_code(code)
    S.code = code
    S.edited = false
    if S.doc then
        local ok = pcall(function() S.doc.code.text = code end)
        if not ok then S.stats.ui_errors = S.stats.ui_errors + 1 end
    end
end

function M.ui_code_edited(text)
    local was = S.edited
    S.edited = true
    if not was then M.refresh() end        -- RUN/STOP label: an edited running script shows RUN (apply)
end

local function fmt_num(v)
    if v < 0 then return "н/д" end
    if v >= 1e6 then return string.format("%.1fM", v / 1e6) end
    if v >= 1e3 then return string.format("%.1fk", v / 1e3) end
    return string.format("%.0f", v)
end

local function fmt_bytes(v)
    if not v or v < 0 then return "н/д" end
    if v >= 1048576 then return string.format("%.1f МБ", v / 1048576) end
    return string.format("%.1f КБ", v / 1024)
end

local function console_errors()
    local n = 0
    for _, l in ipairs(S.console) do if l.kind == 1 then n = n + 1 end end
    return n
end

local function refresh_profile(doc, st)
    local mt, pf = st.meters, S.prof[st.eid] or {}
    doc.pf_left.text = table.concat({
        string.format("кредиты: %.1f за такт", mt.credits_tick),
        string.format("кредиты: %s за минуту", fmt_num(mt.credits_min)),
        string.format("топливо: %s за минуту", fmt_num(mt.fuel_min)),
        string.format("действия: %d за минуту", mt.actions_min),
        string.format("отклонено миром: %d за минуту", mt.rejected_min),
        string.format("владелец всего: %s кредитов/мин", fmt_num(mt.owner_credits_min)),
    }, "\n")
    doc.pf_right.text = table.concat({
        string.format("песочница: %s", mt.sb_status ~= "" and mt.sb_status or "-"),
        string.format("память VM: %s", fmt_bytes(pf.vm_heap)),
        string.format("пик памяти VM: %s", fmt_bytes(pf.vm_peak)),
        string.format("тактов: %s, ошибок: %s", pf.ticks or "-", pf.errors or "-"),
        string.format("строк отброшено: %s", pf.text_dropped or "-"),
        string.format("действий отклонено: %s", pf.rejected_total or "-"),
        string.format("ошибок в консоли: %d", console_errors()),
    }, "\n")
    local h = S.hist[st.eid] or {}
    local mx = 0.001
    for _, v in ipairs(h) do if v > mx then mx = v end end
    for i = 1, HIST_N do
        local v = h[#h - HIST_N + i]
        local hh = v and math.max(1, math.floor(38 * v / mx)) or 1
        local el = doc["sp_" .. i]
        if el then
            el.size = {6, hh}
            el.pos = {(i - 1) * 8 + 2, 40 - hh}
        end
    end
end

local function refresh_settings(doc, st)
    doc.set_owner.text = string.format("%s (#%d)", st.owner ~= "" and st.owner or "мир", st.eid)
    local lk = S.looks[st.eid]
    local model = lk and lk.model ~= "" and lk.model or LOOKS.DEFAULT_MODEL
    local tex = lk and lk.texture ~= "" and lk.texture or LOOKS.DEFAULT_TEXTURE
    doc.set_look.text = string.format("сейчас: %s / %s", model, tex)
    -- UX A1: buttons by the rights the world reports for this session (EntityPerms.mine); before it arrives — can_edit
    local pm = S.perms[st.eid]
    local can = st.can_edit
    doc.btn_rename.enabled = pm and M.may(st.eid, "appearance") or (not pm and can)
    doc.btn_look.enabled = pm and M.may(st.eid, "appearance") or (not pm and can)
    doc.btn_delete.enabled = pm and M.may(st.eid, "destroy") or (not pm and can)
    doc.btn_fork.enabled = pm and M.may(st.eid, "clone") or false
    M.perm_refresh(doc, st.eid)
end

-- ------------------------------------------------------------------ UX A1: rights panel (settings page, right column)
M.PERM_ACTIONS = {"move", "read_code", "edit_code", "run", "appearance", "clone", "destroy", "storage_read", "storage_write"}
local PERM_CAP = {"двигать", "читать код", "менять код", "запуск", "вид/имя", "форк", "удаление", "хран. чт.", "хран. зап."}
local AUD_CAP = {[0] = "влад", [1] = "друз", [2] = "спис", [3] = "все"}
local AUD_LONG = {[0] = "только владелец", [1] = "владелец и друзья", [2] = "владелец и список", [3] = "все"}
M.PERM_CAP, M.AUD_LONG = PERM_CAP, AUD_LONG

function M.may(eid, action)
    local pm = S.perms[eid]
    if not pm then return false end
    for i, a in ipairs(M.PERM_ACTIONS) do
        if a == action then return math.floor(pm.mine / 2 ^ (i - 1)) % 2 == 1 end
    end
    return false
end

function M.perm_build(doc)
    pcall(function()
        doc.perm_box:clear()
        for i, cap in ipairs(PERM_CAP) do
            local y = (i - 1) * 26
            doc.perm_box:add(string.format("<label id='pl_%d' pos='0,%d' size='86,24' color='#C8D4E8'>%s</label>", i, y + 4, cap))
            for k = 0, 3 do
                doc.perm_box:add(string.format("<button id='pa_%d_%d' pos='%d,%d' size='42,24' color='#FFFFFF14' " ..
                    "onclick='ui_perm(%d,%d)'>%s</button>", i, k, 88 + k * 44, y, i, k, AUD_CAP[k]))
            end
            doc.perm_box:add(string.format("<textbox id='plist_%d' pos='266,%d' size='92,24' padding='4,2,4,0' " ..
                "hint='a,b'></textbox>", i, y))
            doc.perm_box:add(string.format("<button id='pok_%d' pos='360,%d' size='28,24' color='#5050ff80' " ..
                "onclick='ui_perm_list(%d)' tooltip='list: owner + these accounts'>OK</button>", i, y, i))
        end
    end)
    S.perm_shown = {}
end

function M.perm_refresh(doc, eid)
    local pm = S.perms[eid]
    pcall(function()
        if not pm then
            doc.perm_note.text = "Права: ждём ответ мира..."
            return
        end
        local mine = {}
        for i, a in ipairs(M.PERM_ACTIONS) do if M.may(eid, a) then mine[#mine + 1] = PERM_CAP[i] end end
        doc.perm_note.text = pm.can_admin and "Права (меняете вы):" or
            ("Права (только чтение); вам: " .. (#mine > 0 and table.concat(mine, ", ") or "ничего"))
        for i, r in ipairs(pm.rules) do
            for k = 0, 3 do
                local b = doc["pa_" .. r.action .. "_" .. k]
                if b then
                    b.color = r.audience == k and {80, 160, 255, 200} or {255, 255, 255, 20}
                    b.enabled = pm.can_admin
                end
            end
            local okb = doc["pok_" .. r.action]
            if okb then okb.enabled = pm.can_admin end
            local tb = doc["plist_" .. r.action]
            local txt = table.concat(r.list, ",")
            if tb and S.perm_shown[r.action] ~= txt and not tb.focused then
                tb.text = txt
                tb.editable = pm.can_admin
                S.perm_shown[r.action] = txt
            end
        end
    end)
end

local function perm_send(i, aud, list)
    if not S.open then return nil end
    local seq = next_seq()
    S.stats.perm_sets = S.stats.perm_sets + 1
    S.a1_pending[seq] = {cap = PERM_CAP[i] or "?", aud = AUD_LONG[aud] or "?"}
    send("EntityPermsSet", {seq = seq, eid = S.open, action = i, audience = aud, list = list or {}})
    return seq
end

local function plist_of(i)
    local t = ""
    if S.doc then pcall(function() t = S.doc["plist_" .. i].text end) end
    local l = {}
    for a in tostring(t or ""):gmatch("[^,%s]+") do l[#l + 1] = a end
    return l
end

-- a segment of the row: audience k for action i (the list goes along for k = 2)
function M.ui_perm(i, k)
    return perm_send(i, k, k == 2 and plist_of(i) or {})
end

-- OK of the row: the list textbox -> audience "list"
function M.ui_perm_list(i)
    return perm_send(i, 2, plist_of(i))
end

-- Fork: a copy of this entity (code, rights, look) for me, in front of me (`clone` right)
function M.ui_fork()
    if not S.open then return nil end
    S.stats.forks = S.stats.forks + 1
    local seq = next_seq()
    send("EntityFork", {seq = seq, eid = S.open, name = ""})
    return seq
end

function M.refresh()
    local doc = S.doc
    local st = S.open and S.st[S.open]
    if not doc or not st then return end
    local editable = st.editing and st.can_edit
    local ok, err = pcall(function()
        local lock = st.lock_holder == "" and "свободен" or (st.editing and "вы" or st.lock_holder)
        doc.status.text = string.format("%s #%d | владелец %s | %s%s | лок: %s%s", st.name, st.eid,
            st.owner ~= "" and st.owner or "мир", STATUS_TXT[st.status] or "?", st.error ~= "" and (": " .. st.error) or "",
            lock, editable and "" or " (только чтение)") .. (S.notice and ("  [" .. S.notice .. "]") or "")
        doc.code.editable = editable
        local lines = {}
        local from = math.max(1, #S.console - 80)
        for i = from, #S.console do
            local l = S.console[i]
            lines[#lines + 1] = (l.kind == 1 and "! " or (l.kind == 2 and "* " or "")) .. l.text
        end
        doc.console.text = table.concat(lines, "\n")
        pcall(function() doc.console.caret = -1 end)
        -- the original RUN/STOP toggle; RUN or ERROR without local edits -> STOP; edited -> RUN (save + run again)
        local stop = st.status ~= 0 and not S.edited
        doc.btn_run.text = stop and "STOP" or "RUN"
        doc.run_icon.src = stop and "gui/olife_pause" or "gui/olife_play"
        doc.btn_run.enabled = editable or (M.may(st.eid, "run") and st.lock_holder == "")   -- UX A1: `run` right
        doc.btn_save.enabled = true
        doc.btn_edit.visible = st.can_edit and not st.editing
        doc.btn_edit.enabled = st.can_edit and not st.editing and st.lock_holder == ""
        if S.tab == "prof" then refresh_profile(doc, st) end
        if S.tab == "set" then refresh_settings(doc, st) end
        if S.tab == "mob" then MB.editor_refresh(doc, st) end     -- UX B1: profile + code versions
        MB.error_line(doc, st)                                       -- UX B1: highlight the error line
    end)
    if not ok then S.stats.ui_errors = S.stats.ui_errors + 1; S.ui_error = tostring(err) end
end

local function code_text()
    if S.doc then
        local ok, t = pcall(function() return S.doc.code.text end)
        if ok and t then return t end
    end
    return S.code or ""
end

local function fname()
    local n = ""
    if S.doc then pcall(function() n = S.doc.fname.text end) end
    return (tostring(n or ""):gsub("[^%w_%-]", ""))
end

-- Save: the code to the server (when editing); with a file name also config:olife/scripts/<name>.lua (save-as)
function M.ui_save()
    if not S.open then return end
    local st = S.st[S.open]
    local parts = {}
    if st and st.editing and st.can_edit then
        S.stats.saves = S.stats.saves + 1
        send("ScriptSave", {seq = next_seq(), eid = S.open, code = code_text()})
        S.edited = false
        parts[#parts + 1] = "на сервер"
    end
    local n = fname()
    if n ~= "" then
        local okf, path = M.file_save(n)
        parts[#parts + 1] = okf and path or ("ошибка файла " .. tostring(path))
    end
    S.notice = #parts > 0 and ("сохранено: " .. table.concat(parts, ", ")) or "только чтение: введите имя файла"
    M.refresh()
end

function M.ui_run()
    if not S.open then return end
    local st = S.st[S.open]
    if st and not st.editing and M.may(S.open, "run") then          -- UX A1: run right without edit: run as stored
        S.stats.runs = S.stats.runs + 1
        send("ScriptRun", {seq = next_seq(), eid = S.open})
        return
    end
    if not (st and st.editing) then return end
    if S.edited or (st and code_text() ~= st.code) then
        S.stats.saves = S.stats.saves + 1
        send("ScriptSave", {seq = next_seq(), eid = S.open, code = code_text()})
        S.edited = false
    end
    S.stats.runs = S.stats.runs + 1
    send("ScriptRun", {seq = next_seq(), eid = S.open})
end

function M.ui_stop()
    if not S.open then return end
    S.stats.stops = S.stats.stops + 1
    send("ScriptStop", {seq = next_seq(), eid = S.open})
end

-- the original RUN/STOP toggle button (RUN/ERROR and not edited: STOP; otherwise save if edited + RUN)
function M.ui_run_toggle()
    local st = S.open and S.st[S.open]
    if not st then return end
    if st.status ~= 0 and not S.edited and code_text() == st.code then return M.ui_stop() end
    return M.ui_run()
end

function M.ui_edit()
    if not S.open then return end
    S.want_open = nil
    send("ScriptOpen", {seq = next_seq(), eid = S.open, edit = true})
end

function M.ui_clear()
    if S.doc then pcall(function() S.doc.code.text = "" end) end
    S.edited = true
end

function M.ui_template(v)
    local st = S.open and S.st[S.open]
    if not (st and st.editing) then return end
    local t = TEMPLATES[v]
    if t and S.doc then
        pcall(function() S.doc.code.text = t end)
        S.edited = true
    end
end

function M.ui_console_clear()
    S.console = {}
    M.refresh()
end

function M.ui_tab(t)
    if t ~= "code" and t ~= "prof" and t ~= "set" and t ~= "mob" then return end      -- + UX B1 "mob"
    S.tab = t
    local doc = S.doc
    if not doc then return end
    pcall(function()
        doc.page_code.visible = t == "code"
        doc.page_prof.visible = t == "prof"
        doc.page_set.visible = t == "set"
        doc.page_mob.visible = t == "mob"                                           -- UX B1
        doc.tab_mob.color = t == "mob" and {255, 255, 255, 64} or {255, 255, 255, 16}
        doc.tab_code.color = t == "code" and {255, 255, 255, 64} or {255, 255, 255, 16}
        doc.tab_prof.color = t == "prof" and {255, 255, 255, 64} or {255, 255, 255, 16}
        doc.tab_set.color = t == "set" and {255, 255, 255, 64} or {255, 255, 255, 16}
        if t == "set" then
            local st = S.open and S.st[S.open]
            if st then doc.set_name.text = st.name end
        end
    end)
    if t == "mob" then MB.editor_tab(S.open) end                                     -- UX B1: ask profile + history
    M.refresh()
end

-- ------------------------------------------------------------------ scripts panel (local files, server copy, templates)
function M.list_files()
    local out = {}
    pcall(file.mkdirs, S.files_dir)
    local ok, l = pcall(file.list, S.files_dir)
    if ok and l then
        for _, p in ipairs(l) do
            local n = p:match("([^/:]+)%.lua$")
            if n then out[#out + 1] = n end
        end
    end
    table.sort(out)
    return out
end

local function esc(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("'", "&apos;"):gsub('"', "&quot;"))
end

function M.scripts_refresh()
    local doc = S.doc
    local st = S.open and S.st[S.open]
    local items = {{kind = "new", caption = "+ новый (пустой)"}}
    if st then items[#items + 1] = {kind = "server", caption = "сервер: " .. st.name .. ".lua"} end
    for _, n in ipairs(M.list_files()) do items[#items + 1] = {kind = "file", name = n, caption = n .. ".lua"} end
    for _, n in ipairs(TEMPLATE_ORDER) do items[#items + 1] = {kind = "template", name = n, caption = "шаблон: " .. n} end
    S.scripts = items
    if not doc then return end
    pcall(function()
        doc.scripts:clear()
        doc.scripts:add("<label margin='0,0,0,6'>СКРИПТЫ:</label>")
        for i, it in ipairs(items) do
            local sel = it.kind == "file" and it.name == S.cur_file
            local color = sel and "#FFFFFF40" or (it.kind == "file" and "#00000040" or "#00000020")
            local del = it.kind == "file" and string.format(
                "<button id='sx_%d' size='26,28' gravity='top-right' color='#C0303060' onclick='ui_script_del(%d)'>x</button>", i, i) or ""
            doc.scripts:add(string.format(
                "<container id='srow_%d' size='100,28' color='0'><button id='sf_%d' size-func='%s' color='%s' " ..
                "text-align='left' onclick='ui_script_open(%d)'>%s</button>%s</container>",
                i, i, it.kind == "file" and "-29,28" or "-1,28", color, i, esc(it.caption), del))
        end
    end)
end

function M.ui_script_open(i)
    local it = S.scripts[i]
    if not it or not S.doc then return end
    local st = S.open and S.st[S.open]
    local text
    if it.kind == "new" then text = ""
    elseif it.kind == "server" then text = st and st.code or ""
    elseif it.kind == "template" then text = TEMPLATES[it.name]
    elseif it.kind == "file" then
        local ok, t = pcall(file.read, S.files_dir .. "/" .. it.name .. ".lua")
        if not ok then S.notice = "нет файла " .. it.name; M.refresh(); return end
        text = t
        S.cur_file = it.name
        S.stats.files_opened = S.stats.files_opened + 1
        pcall(function() S.doc.fname.text = it.name end)
    end
    pcall(function() S.doc.code.text = text or "" end)
    S.edited = it.kind ~= "server"
    S.notice = "открыт: " .. it.caption
    M.scripts_refresh()
    M.refresh()
end

function M.ui_script_del(i)
    local it = S.scripts[i]
    if not it or it.kind ~= "file" then return end
    local ok = pcall(file.remove, S.files_dir .. "/" .. it.name .. ".lua")
    if ok then S.stats.files_deleted = S.stats.files_deleted + 1 end
    if S.cur_file == it.name then S.cur_file = nil end
    S.notice = ok and ("удалён " .. it.name .. ".lua") or ("не удалось удалить " .. it.name)
    M.scripts_refresh()
    M.refresh()
end

function M.file_save(name)
    local path = S.files_dir .. "/" .. name .. ".lua"
    local ok, err = pcall(function()
        file.mkdirs(S.files_dir)
        file.write(path, code_text())
    end)
    if ok then
        S.stats.files_saved = S.stats.files_saved + 1
        S.cur_file = name
        M.scripts_refresh()
    end
    return ok, ok and path or err
end

-- ------------------------------------------------------------------ entity settings page
function M.ui_rename()
    if not S.open or not S.doc then return end
    local n = ""
    pcall(function() n = S.doc.set_name.text end)
    if not LOOKS.valid_name(n) then
        S.notice = "недопустимое имя"
        M.sound("refuse")
        return M.refresh()
    end
    S.stats.renames = S.stats.renames + 1
    send("EntityEdit", {seq = next_seq(), eid = S.open, op = 2, name = n, model = "", texture = ""})
end

function M.ui_pick_model(v) S.sel_model = v end
function M.ui_pick_texture(v) S.sel_texture = v end

function M.ui_apply_look()
    if not S.open then return end
    send("EntityEdit", {seq = next_seq(), eid = S.open, op = 3, name = "", model = S.sel_model or "",
                        texture = S.sel_texture or ""})
end

-- two clicks within 4 s: delete (the same request as Shift+LMB)
function M.ui_delete()
    if not S.open then return end
    if not S.del_armed_at then
        S.del_armed_at = time.uptime()
        if S.doc then pcall(function() S.doc.set_note.text = "Нажмите ещё раз, чтобы удалить" end) end
        return
    end
    S.del_armed_at = nil
    if S.doc then pcall(function() S.doc.set_note.text = "" end) end
    return M.delete_last(S.open)
end

function M.ui_close()
    if hud and hud.close then pcall(hud.close, "olife_client:editor") end
end

-- legacy names (wave 4a tests / scripts): file save / open by the name field
function M.ui_file_save()
    local ok, path = M.file_save(fname() ~= "" and fname() or "script")
    S.notice = ok and ("сохранено " .. path) or ("ошибка файла: " .. tostring(path))
    M.refresh()
    return ok, path
end

function M.ui_file_open()
    local n = fname()
    for i, it in ipairs(S.scripts) do
        if it.kind == "file" and it.name == n then return M.ui_script_open(i) end
    end
    S.notice = "нет файла " .. n
    M.refresh()
end

-- ------------------------------------------------------------------ UX A1: friends page (layouts/friends.xml)
-- opened from the editor settings page ("Друзья") or Shift+` ; rows: incoming (accept / deny), outgoing (cancel),
-- friends with online state (remove); add by account name. Everything is a FriendRequest; the list is the world's.
function M.ui_friends()
    S.fr_back = S.open or S.last_opened
    send("FriendRequest", {seq = next_seq(), op = 5, account = ""})
    if hud and hud.show_overlay then
        local ok, err = pcall(hud.show_overlay, "olife_client:friends", false)
        if not ok then S.stats.ui_errors = S.stats.ui_errors + 1; log("friends overlay failed: %s", tostring(err)) end
    end
end

function M.fr_opened(doc)
    S.fr_doc = doc
    M.friends_refresh()
end

function M.fr_closed() S.fr_doc = nil end

local function friend_op(op, account)
    S.stats.friend_ops = S.stats.friend_ops + 1
    local seq = next_seq()
    send("FriendRequest", {seq = seq, op = op, account = account or ""})
    return seq
end
M.friend_op = friend_op

function M.friends_refresh()
    local doc = S.fr_doc
    local fl = S.friends or {friends = {}, incoming = {}, outgoing = {}}
    local rows = {}
    for _, a in ipairs(fl.incoming) do rows[#rows + 1] = {kind = "in", account = a} end
    for _, a in ipairs(fl.outgoing) do rows[#rows + 1] = {kind = "out", account = a} end
    for _, f in ipairs(fl.friends) do rows[#rows + 1] = {kind = "friend", account = f.account, online = f.online} end
    S.fr_rows = rows
    if not doc then return end
    pcall(function()
        doc.fr_rows:clear()
        local function section(t) doc.fr_rows:add("<label size='480,22' color='#FFD080'>" .. esc(t) .. "</label>") end
        local last
        for i, r in ipairs(rows) do
            if r.kind ~= last then
                section(r.kind == "in" and "Входящие запросы" or (r.kind == "out" and "Исходящие запросы" or "Друзья"))
                last = r.kind
            end
            local btns
            if r.kind == "in" then
                btns = string.format("<button id='fa_%d' pos='280,0' size='96,26' color='#30A05090' onclick='ui_fr_accept(%d)'>Принять</button>" ..
                    "<button id='fd_%d' pos='380,0' size='96,26' color='#C0303080' onclick='ui_fr_deny(%d)'>Отклонить</button>", i, i, i, i)
            elseif r.kind == "out" then
                btns = string.format("<button id='fd_%d' pos='380,0' size='96,26' color='#C0303060' onclick='ui_fr_deny(%d)'>Отменить</button>", i, i)
            else
                btns = string.format("<button id='fr_%d' pos='380,0' size='96,26' color='#C0303060' onclick='ui_fr_remove(%d)'>Удалить</button>", i, i)
            end
            local cap = r.account .. (r.kind == "friend" and (r.online and "  (в сети)" or "  (не в сети)") or "")
            doc.fr_rows:add(string.format("<container id='frow_%d' size='480,28' color='%s'><label id='fn_%d' pos='6,4' size='270,20' color='%s'>%s</label>%s</container>",
                i, r.kind == "in" and "#30A05030" or "#FFFFFF10", i, (r.kind == "friend" and r.online) and "#90FF90" or "#E0E8F0",
                esc(cap), btns))
        end
        if #rows == 0 then doc.fr_rows:add("<label size='480,22' color='#90A0B0'>Пока никого. Введите имя аккаунта и нажмите «Добавить».</label>") end
        doc.fr_count.text = string.format("друзей: %d, входящих: %d, исходящих: %d", #fl.friends, #fl.incoming, #fl.outgoing)
        doc.fr_back.visible = S.fr_back ~= nil
    end)
end

function M.ui_fr_add()
    local n = ""
    if S.fr_doc then pcall(function() n = S.fr_doc.fr_name.text end) end
    n = tostring(n or ""):gsub("%s", "")
    if n == "" then pcall(fx().deny, "Друзья: введите имя аккаунта", 15); return nil end
    return friend_op(1, n)
end
function M.ui_fr_accept(i) local r = S.fr_rows[i]; if r then return friend_op(2, r.account) end end
function M.ui_fr_deny(i) local r = S.fr_rows[i]; if r then return friend_op(3, r.account) end end
function M.ui_fr_remove(i) local r = S.fr_rows[i]; if r then return friend_op(4, r.account) end end
function M.ui_fr_close() if hud and hud.close then pcall(hud.close, "olife_client:friends") end end
function M.ui_fr_back()
    local eid = S.fr_back
    M.ui_fr_close()
    if eid then
        S.last_opened = eid
        time.post_runnable(function() M.open_last() end)
    end
end

-- ------------------------------------------------------------------ F2F (test build): drive and read the layer
-- {op="gui"}            editor document: open, tab, texts, code, console, profiler/settings texts, element rects in
--                       FRAME pixels (854x480) incl. the scripts panel rows (scripts[i].rect)
-- {op="state"}          benches seen (meta, ownership, looks), last replies, stats, holding, camera, tags, toast, sounds
-- {op="aim", eid}       turn the hud player to look at entity eid (test harness, like the `look` step)
-- {op="look", yaw, pitch} / {op="place", pos}   harness: camera rotation / position
-- {op="ui", call, arg}  call a ui_* function (only for what the test can not reach by input)
-- {op="send", name, msg} raw request (negative tests: bypasses the UI, the world must refuse)
local function rect(doc, id, k)
    local ok, r = pcall(function()
        local el = doc[id]
        local p, s = el.wpos, el.size
        return {x = p[1] * k, y = p[2] * k, w = s[1] * k, h = s[2] * k, cx = (p[1] + s[1] / 2) * k,
                cy = (p[2] + s[2] / 2) * k, enabled = el.enabled, visible = el.visible, focused = el.focused}
    end)
    return ok and r or nil
end

local function look_at(pid, tx, ty, tz)
    local o = camera_ray(pid)
    local dx, dy, dz = tx - o.x, ty - o.y, tz - o.z
    local l = math.sqrt(dx * dx + dy * dy + dz * dz)
    if l < 1e-6 then return nil end
    dx, dy, dz = dx / l, dy / l, dz / l
    local pitch = math.deg(math.asin(dy))
    local yaw = math.deg(math.atan2(-dx, -dz))
    player.set_rot(pid, yaw, pitch, 0)
    return {yaw = yaw, pitch = pitch, dist = l}
end

local GUI_IDS = {"root", "code", "page_code", "console", "scripts", "toolbar", "tabs", "status", "btn_close", "btn_run",
                 "fname", "btn_save", "btn_edit", "tab_code", "tab_prof", "tab_set", "page_prof", "page_set", "pf_left",
                 "pf_right", "spark", "set_name", "btn_rename", "set_owner", "set_model", "set_texture", "btn_look",
                 "set_look", "btn_delete", "set_note", "btn_fork", "btn_friends", "perm_note", "perm_box",   -- + UX A1
                 "tab_mob", "page_mob", "pf_mob", "ver_box", "err_line"}                                      -- + UX B1

function M.f2f(args)
    local op = args.op or "state"
    if op == "gui" then
        local doc = S.doc
        local r = {open = S.open, doc = doc ~= nil, tab = S.tab,
                   overlay = hud and hud.is_open and hud.is_open("olife_client:editor") or false}
        if doc then
            local vp = gui.get_viewport()
            local k = 854 / vp[1]
            r.scale, r.viewport = k, {vp[1], vp[2]}
            pcall(function()
                r.status = doc.status.text
                r.code, r.console = doc.code.text, doc.console.text
                r.code_editable, r.code_focused = doc.code.editable, doc.code.focused
                r.run_text, r.run_icon = doc.btn_run.text, doc.run_icon.src
                r.pf_left, r.pf_right = doc.pf_left.text, doc.pf_right.text
                r.set_owner, r.set_look, r.set_name, r.set_note = doc.set_owner.text, doc.set_look.text,
                    doc.set_name.text, doc.set_note.text
                r.fname = doc.fname.text
            end)
            r.rects = {}
            for _, id in ipairs(GUI_IDS) do r.rects[id] = rect(doc, id, k) end
            r.scripts = {}
            for i, it in ipairs(S.scripts) do
                r.scripts[i] = {kind = it.kind, name = it.name, caption = it.caption, rect = rect(doc, "sf_" .. i, k),
                                del = it.kind == "file" and rect(doc, "sx_" .. i, k) or nil}
            end
            local spark = {}
            for i = 1, HIST_N do local e = rect(doc, "sp_" .. i, k); spark[i] = e and e.h or nil end
            r.spark_h = spark
            r.perm_rows = {}                    -- UX A1: rights panel, one row per action
            for i, a in ipairs(M.PERM_ACTIONS) do
                local row = {action = a, seg = {}, list = rect(doc, "plist_" .. i, k), ok = rect(doc, "pok_" .. i, k)}
                for kk = 0, 3 do row.seg[kk + 1] = rect(doc, "pa_" .. i .. "_" .. kk, k) end
                pcall(function() row.list_text = doc["plist_" .. i].text end)
                r.perm_rows[i] = row
            end
            pcall(function() r.perm_note = doc.perm_note.text end)
            r.mob = MB.editor_f2f(doc, k)        -- UX B1: profile text, version rows, error line / caret
        end
        local st = S.open and S.st[S.open]
        if st then
            r.st = {eid = st.eid, name = st.name, status = st.status, error = st.error, owner = st.owner,
                    lock_holder = st.lock_holder, can_edit = st.can_edit, editing = st.editing, code_len = #st.code,
                    meters = st.meters}
            r.prof = S.prof[st.eid]
            r.hist_n = #(S.hist[st.eid] or {})
        end
        r.console_lines = #S.console
        r.edited = S.edited
        r.notice = S.notice
        r.ui_error = S.ui_error
        r.files = M.list_files()
        r.perms = st and S.perms[st.eid] or nil          -- UX A1
        return r
    elseif op == "friends_gui" then            -- UX A1: the friends page (rects in frame pixels)
        local doc = S.fr_doc
        local r = {doc = doc ~= nil, overlay = hud and hud.is_open and hud.is_open("olife_client:friends") or false,
                   rows = {}, friends = S.friends}
        if doc then
            local vp = gui.get_viewport()
            local k = 854 / vp[1]
            r.rects = {}
            for _, id in ipairs({"fr_root", "fr_name", "fr_add", "fr_close", "fr_back", "fr_rows", "fr_count"}) do
                r.rects[id] = rect(doc, id, k)
            end
            for i, row in ipairs(S.fr_rows) do
                r.rows[i] = {kind = row.kind, account = row.account, online = row.online, accept = rect(doc, "fa_" .. i, k),
                             deny = rect(doc, "fd_" .. i, k), remove = rect(doc, "fr_" .. i, k)}
            end
            pcall(function() r.count = doc.fr_count.text end)
        end
        return r
    elseif op == "aim" then
        local e = cl().S.ents[args.eid]
        if not e or not S.cam_pid then error("no entity/camera") end
        local p = e.shown or e.pos
        return look_at(S.cam_pid, p.x + (args.dx or 0), p.y + (args.dy or 0), p.z + (args.dz or 0))
    elseif op == "look" then
        if not S.cam_pid then error("no camera") end
        player.set_rot(S.cam_pid, args.yaw or 0, args.pitch or 0, 0)
        return {yaw = args.yaw, pitch = args.pitch}
    elseif op == "place" then
        if not S.cam_pid then error("no camera") end
        local p = args.pos
        player.set_pos(S.cam_pid, p[1], p[2], p[3])
        return {pos = p}
    elseif op == "ui" then
        local f = M["ui_" .. tostring(args.call)]
        if not f then error("no ui_" .. tostring(args.call)) end
        return {result = f(args.arg)}
    elseif op == "send" then
        local msg = args.msg or {}
        msg.seq = msg.seq or next_seq()
        local okb = send(args.name, msg)
        cl().flush()
        return {sent = okb, seq = msg.seq}
    elseif op == "eval" then                 -- dev probe (F2F test build only): a Lua chunk in the world state
        local fn, err = load(tostring(args.code or ""), "olife_eval", "t")
        if not fn then error(err) end
        local ok, res = pcall(fn)
        if not ok then error(res) end
        return {value = res}
    elseif op == "tool" then
        return {seq = M.use_tool(args.tool or 1, S.cam_pid)}
    end
    -- state
    local benches = {}
    for eid, m in pairs(S.meta) do
        local e = cl().S.ents[eid]
        local lk = S.looks[eid]
        benches[#benches + 1] = {eid = eid, label = m.label, status = m.status, owner = m.owner_name,
                                 holder = S.own[eid] and S.own[eid].holder_name or "",
                                 pos = e and {e.pos.x, e.pos.y, e.pos.z} or nil, tag = S.tags[eid] ~= nil,
                                 look = lk and {model = lk.model, texture = lk.texture, applied = lk.applied ~= nil} or nil}
    end
    table.sort(benches, function(a, b) return a.eid < b.eid end)
    local cam
    if S.cam_pid then
        local x, y, z = player.get_pos(S.cam_pid)
        local yaw, pitch = player.get_rot(S.cam_pid)
        local okinv, invid, slot = pcall(player.get_inventory, S.cam_pid)
        cam = {pid = S.cam_pid, pos = {x, y, z}, yaw = yaw, pitch = pitch, tool = M.held_tool(S.cam_pid),
               selected_eid = aimed_eid(S.cam_pid), slot = okinv and slot or nil}
    end
    local ntags = 0
    for _ in pairs(S.tags) do ntags = ntags + 1 end
    -- UX round 1: what the player's inventory holds (by item name) and whether the removed coin exists at all
    local inv = {}
    if S.cam_pid then
        local okinv, invid = pcall(player.get_inventory, S.cam_pid)
        if okinv and invid then
            for i = 0, inventory.size(invid) - 1 do
                local id, n = inventory.get(invid, i)
                if id and id ~= 0 then
                    local okn, nm = pcall(item.name, id)
                    inv[#inv + 1] = {slot = i, item = okn and nm or tostring(id), count = n}
                end
            end
        end
    end
    local okc, cid = pcall(item.index, "olife_proto:coin")
    local snd = {}
    for i, s in ipairs(S.sounds) do snd[i] = s.name end
    return {open = S.open, holding = S.holding, grab_pending = S.grab_pending and true or false, benches = benches,
            replies = S.replies, stats = S.stats, camera = cam, console_lines = #S.console, tags = ntags,
            tags_on = S.tags_on, last_opened = S.last_opened, toast = S.toast and S.toast.text or nil, sounds = snd,
            last_toast = S.last_toast,
            perms = (function()                -- UX A1 (a list: sparse eid keys do not make a JSON array)
                local l = {}
                for _, pm in pairs(S.perms) do l[#l + 1] = pm end
                table.sort(l, function(a, b) return a.eid < b.eid end)
                return l
            end)(), friends = S.friends, forks = S.forks, fr_open = S.fr_doc ~= nil,
            rmb_held = S.rmb_held, inventory = inv, coin_defined = okc and cid ~= nil and cid > 0 or false,
            items_count = item.defs_count()}
end

return M
