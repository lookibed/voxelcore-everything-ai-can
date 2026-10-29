-- olife_world:editor — wave 4a: the player-facing Olife layer on the authoritative world.
-- Scripted benches (kind 3, def olife_client:bench) carry their own code, run status and console; the editor lock
-- (one editor per entity), console subscriptions, the Injector (RMB -> editor) and the GravityGun (grab / hold /
-- release, one holder at a time, the world moves the entity) are decided here. Everything a client asks for is a
-- request with seq -> RequestReply{seq, op, code}; state changes are pushed (ScriptState to subscribers, EntityMeta /
-- EntityOwnership to sessions that see the entity). Code, status and console survive a restart (registry).
-- Permissions: the bench owner (account) or an admin (Attach.perms bit 1, or `olife.admins <csv>`) may edit/run/stop;
-- everybody may open read-only. Every request is billed to the account (S.acct_actions — the supervisor meter) and
-- rate-limited (bucket 10/s, burst 20); sandbox credits/fuel per bench and per owner are reported in ScriptMeters.
local U = require "olife_proto:util"
local net = require "olife_world:net"
local LOOKS = require "olife_proto:looks"       -- UX round 1: models/textures an owner may pick
local MT = require "olife_world:sbmeter"       -- UX round 1: profiler page (per-entity totals, owner VM memory)
local P = require "olife_world:perms"          -- UX A1: per-entity rights (owner/friends/list/everyone), friends, fork

local M = {}
local server, sandbox, S
local sqrt, floor, min, max = math.sqrt, math.floor, math.min, math.max

local cfg = {
    lock_timeout = 1200,     -- ticks without a request from the lock holder (60 s; the editor heartbeats every 20 s)
    console_max = 64,        -- lines kept per entity (ring; also the tail in ScriptState)
    line_max = 1024,         -- bytes per console line
    delta_every = 5,         -- ticks between ConsoleDelta flushes per subscriber (4/s)
    delta_lines = 16, delta_bytes = 4096,   -- per ConsoleDelta
    sub_pending = 64,        -- pending lines per subscriber; older ones are dropped (counted)
    text_rate = 5, text_burst = 10,          -- console lines per second per bench (sandbox print/oprint/say)
    req_rate = 10, req_burst = 20,           -- editor/tool requests per second per session
    aim_rate = 20,                           -- ToolUse aim per second per session (separate bucket)
    reach = 8.0,             -- tool reach from the player
    origin_slack = 3.0,      -- client eye vs the world's player position
    box_half = 0.6,          -- bench hit box half extent (model is a 1x1x1 box centred on pos)
    hold_min = 1.5, hold_max = 6.0, hold_step = 1.0,   -- gravity gun: distance range, max move per tick
    hold_drop = 16.0,        -- holder farther than this from the entity -> released
    area = 48,               -- same area as sandbox set_pos (radius from spawn)
    code_max = 16384,
    registry_every = 20,     -- ticks between registry writes when something changed (code/status/console/owner)
}
M.cfg = cfg

local ST = {owner_ids = {}, next_owner = 1000, admins = {}, dirty = false, written_tick = 0,
            stats = {open = 0, save = 0, run = 0, stop = 0, release = 0, tool = 0, refused = {}, deltas = 0,
                     delta_lines = 0, delta_dropped = 0, states = 0, grabs = 0, releases = 0, held_ticks = 0,
                     text_rejected = 0, locks_expired = 0, deleted = 0, renamed = 0, looks = 0, profiles = 0}}
M.ST = ST

local OP = {open = 1, save = 2, run = 3, stop = 4, release = 5, tool = 6, edit = 7,
            perms = 8, fork = 9, friend = 10, check = 11}      -- UX A1 (olife_world:perms)
M.OP = OP
local STATUS = {stop = 0, run = 1, error = 2}
local REASON = {[1] = "no such entity", [2] = "not a scripted entity", [3] = "forbidden: not the owner or an admin",
                [4] = "locked by another editor", [5] = "you do not hold the lock", [6] = "out of reach",
                [7] = "ray missed the target", [8] = "held by another player", [9] = "rate limit",
                [10] = "bad code", [11] = "not holding", [12] = "sandbox unavailable", [13] = "bad tool/action",
                [14] = "bad origin/dir", [15] = "bad name/model/texture/op",
                [16] = "unknown account", [17] = "no such request", [18] = "limit"}       -- UX A1
M.REASON = REASON

local DEFAULT_CODE = [[
-- Olife bench: on_tick(dt) runs 20 times a second in the sandbox (self, print).
local t = 0
function on_tick(dt)
    t = t + dt
    self:set_rot(0, (t * 30) % 360, 0)
end
]]
M.DEFAULT_CODE = DEFAULT_CODE

-- FNV-1a 32 of a Lua string (same as olife_proto:wire fnv1a over its bytes; the lab compares code hashes)
local function fnv_str(str)
    local h = 2166136261
    for i = 1, #str do
        h = bit.bxor(h, str:byte(i))
        local lo = h % 65536
        local hi = (h - lo) / 65536
        h = (lo * 16777619 + ((hi * 16777619) % 65536) * 65536) % 4294967296
    end
    if h < 0 then h = h + 4294967296 end
    return h
end
M.fnv_str = fnv_str

local function log(fmt, ...) print("[olife_world] editor: " .. string.format(fmt, ...)) end

function M.init(srv, sb)
    server, sandbox, S = srv, sb, srv.S
    P.init(srv, M)
end

-- ------------------------------------------------------------------------------------------ helpers
local function is_bench(e) return e and e.kind == 3 and e.code ~= nil end
M.is_bench = is_bench

function M.is_admin(sess)
    return sess and ((sess.perms or 0) % 2 == 1 or ST.admins[sess.account] == true) or false
end

-- UX A1: editing the code is the `edit_code` right (owner and admins by default; the owner may share it)
local function can_edit(sess, e)
    return (P.allowed(sess, e, "edit_code"))
end

function M.owner_id(account)
    local id = ST.owner_ids[account]
    if not id then
        id = ST.next_owner
        ST.next_owner = ST.next_owner + 1
        ST.owner_ids[account] = id
        ST.dirty = true
    end
    return id
end

-- the sandbox source of a scripted entity: the bench's own code, else the pack script (legacy orbit / neg_*)
function M.src(e)
    if e.code ~= nil then return e.code end
    local ok, s = pcall(file.read, "olife_world:sandbox/" .. tostring(e.script) .. ".lua")
    return ok and s or ("-- missing script " .. tostring(e.script))
end

-- entities that get a TickInput: legacy scripted always, benches only while running
function M.runnable(e)
    if e.kind ~= 3 or e.frozen then return false end    -- UX A2: a frozen entity gets no TickInput (VM state kept)
    if e.code == nil then return true end
    return e.status == "run"
end

-- UX A2: shown status 0 STOP, 1 RUN, 2 ERROR, 3 THROTTLED (running, sandbox throttled it recently), 4 FROZEN (op)
local SHOWN_TXT = {[0] = "STOP", [1] = "RUN", [2] = "ERROR", [3] = "THROTTLED", [4] = "FROZEN"}
function M.shown_status(e)
    if e.frozen then return 4 end
    if e.code == nil then return 1 end                   -- legacy scripted (pack script): always running
    if e.status == "run" then return e.throttled and 3 or 1 end
    return e.status == "error" and 2 or 0
end

local function label_of(e)
    local st = SHOWN_TXT[M.shown_status(e)]
    local who = (e.owner_name and e.owner_name ~= "") and e.owner_name or (e.owner_acct ~= "" and e.owner_acct or "world")
    return string.format("%s [%s] %s", e.name or ("bench" .. e.eid), who, st):sub(1, 64)
end

local function meta_changed(e)
    e.meta_ver = (e.meta_ver or 0) + 1
    e.label = label_of(e)
    ST.dirty = true
end
M.meta_changed = meta_changed

local function hold_changed(e)
    e.hold_ver = (e.hold_ver or 0) + 1
end

function M.mark_dirty() ST.dirty = true end           -- UX A1: perms/friends changed -> registry write

local function bucket(sess, k, rate, burst)
    local now = S.tick
    local b = sess[k]
    if not b then b = {t = burst, at = now}; sess[k] = b end
    b.t = min(burst, b.t + (now - b.at) * rate / 20)
    b.at = now
    if b.t < 1 then
        if k == "req_b" then require("olife_world:fraud").event(sess, "req") end   -- antifraud: request spam
        return false
    end
    b.t = b.t - 1
    return true
end

local function reply(sess, seq, op, eid, code, reason)
    if code ~= 0 then
        ST.stats.refused[code] = (ST.stats.refused[code] or 0) + 1
    end
    net.send_client(sess.gw, sess.sid, "RequestReply", {seq = seq, op = op, eid = eid, code = code,
                                                        reason = (reason or REASON[code] or "ok"):sub(1, 128)})
    return code == 0
end

local function bill(sess, n)
    S.acct_actions[sess.account] = (S.acct_actions[sess.account] or 0) + (n or 1)
    sess.actions = (sess.actions or 0) + (n or 1)
end
M.bucket, M.reply, M.bill = bucket, reply, bill            -- UX A1: olife_world:perms requests

-- ------------------------------------------------------------------------------------------ console
local function console_of(e)
    if not e.console then e.console = {}; e.cseq = e.cseq or 0 end
    return e.console
end

function M.console_add(e, kind, text)
    local c = console_of(e)
    e.cseq = (e.cseq or 0) + 1
    local line = {seq = e.cseq, tick = S.tick, kind = kind, text = tostring(text):sub(1, cfg.line_max)}
    c[#c + 1] = line
    if #c > cfg.console_max then table.remove(c, 1) end
    for _, sub in pairs(e.subs or {}) do
        local p = sub.pending
        p[#p + 1] = line
        if #p > cfg.sub_pending then
            table.remove(p, 1)
            sub.dropped = sub.dropped + 1
        end
    end
    ST.console_dirty = true
end

-- sandbox print/oprint/say of a bench: per-bench bucket (legacy entities keep the old 1-per-20-ticks rule)
function M.text_allowed(e)
    local b = e.text_b
    if not b then b = {t = cfg.text_burst, at = S.tick}; e.text_b = b end
    b.t = min(cfg.text_burst, b.t + (S.tick - b.at) * cfg.text_rate / 20)
    b.at = S.tick
    if b.t < 1 then
        ST.stats.text_rejected = ST.stats.text_rejected + 1
        e.text_dropped = (e.text_dropped or 0) + 1
        return false
    end
    b.t = b.t - 1
    return true
end

-- ------------------------------------------------------------------------------------------ meters
-- per-second buckets over the last 60 s (credits, fuel, applied, rejected) per bench and per owner account
local function mbucket(m, sec)
    local i = sec % 60 + 1
    local b = m[i]
    if not b or b.sec ~= sec then b = {sec = sec, credits = 0, fuel = 0, applied = 0, rejected = 0}; m[i] = b end
    return b
end

local function msum(m, sec)
    local r = {credits = 0, fuel = 0, applied = 0, rejected = 0}
    for _, b in pairs(m or {}) do
        if b.sec > sec - 60 then
            r.credits, r.fuel = r.credits + b.credits, r.fuel + b.fuel
            r.applied, r.rejected = r.applied + b.applied, r.rejected + b.rejected
        end
    end
    return r
end

ST.owner_meter = {}
function M.on_result(e, er, applied, rejected)
    if not is_bench(e) then return end
    local m = er.meter or {}
    local cr, fuel = tonumber(m.credits) or 0, tonumber(m.fuel) or 0
    local sec = floor(S.tick / 20)
    e.meter = e.meter or {}
    local b = mbucket(e.meter, sec)
    b.credits, b.fuel, b.applied, b.rejected = b.credits + cr, b.fuel + fuel, b.applied + applied, b.rejected + rejected
    local acct = e.owner_acct or ""
    local om = ST.owner_meter[acct]
    if not om then om = {}; ST.owner_meter[acct] = om end
    local ob = mbucket(om, sec)
    ob.credits = ob.credits + cr
    e.credits_tick, e.sb_status = cr, tostring(er.status or "")
    if (er.status == "error" or er.status == "killed") and e.status == "run" then
        e.status, e.error = "error", tostring(er.error or er.status):sub(1, 256)
        M.console_add(e, 1, "[" .. tostring(er.status) .. "] " .. e.error)
        meta_changed(e)
        M.push_state(e)
    end
end

function M.on_load_result(eid, ok, err)
    local e = S.ents[eid]
    if not is_bench(e) then return end
    if ok then
        M.console_add(e, 2, "loaded")
    else
        e.status, e.error = "error", tostring(err or "load failed"):sub(1, 256)
        M.console_add(e, 1, "[load] " .. e.error)
        meta_changed(e)
        M.push_state(e)
    end
end

local function meters_of(e)
    local sec = floor(S.tick / 20)
    local r = msum(e.meter, sec)
    local o = msum(ST.owner_meter[e.owner_acct or ""], sec)
    return {sb_status = (e.status == "run" and (e.sb_status or "") or ""):sub(1, 16), credits_tick = e.credits_tick or 0,
            credits_min = r.credits, fuel_min = r.fuel, actions_min = r.applied, rejected_min = r.rejected,
            owner_credits_min = o.credits}
end
M.meters_of = meters_of

-- ------------------------------------------------------------------------------------------ editor state
local function state_msg(sess, e, seq)
    local tail = {}
    for i, l in ipairs(console_of(e)) do tail[i] = l end
    local lk = e.lock
    return {eid = e.eid, seq = seq or 0, name = (e.name or ""):sub(1, 32), code = e.code or "",
            status = STATUS[e.status or "stop"] or 0, error = (e.error or ""):sub(1, 256), owner = (e.owner_acct or ""):sub(1, 64),
            owner_name = (e.owner_name or ""):sub(1, 32), lock_holder = lk and lk.name:sub(1, 32) or "",
            lock_eid = lk and lk.eid or 0, can_edit = can_edit(sess, e), editing = lk ~= nil and lk.key == sess.key,
            console = tail, meters = meters_of(e)}
end

local function send_state(sess, e, seq)
    ST.stats.states = ST.stats.states + 1
    return net.send_client(sess.gw, sess.sid, "ScriptState", state_msg(sess, e, seq))
end

function M.push_state(e)
    for skey in pairs(e.subs or {}) do
        local s = S.sessions[skey]
        if s then send_state(s, e, 0) end
    end
end

local function subscribe(sess, e)
    e.subs = e.subs or {}
    if not e.subs[sess.key] then
        e.subs[sess.key] = {pending = {}, dropped = 0, last = S.tick}
    end
    sess.subs = sess.subs or {}
    sess.subs[e.eid] = true
end

local function unsubscribe(sess, e)
    if e.subs then e.subs[sess.key] = nil end
    if sess.subs then sess.subs[e.eid] = nil end
end

local function release_lock(e, why)
    if not e.lock then return end
    log("lock eid=%d released by %s (%s)", e.eid, e.lock.name, why)
    e.lock = nil
    M.push_state(e)
end

-- common checks for a request on entity eid -> e or nil (reply already sent)
-- UX A1: `action` = the right needed (olife_world:perms; refusal 3 names it); need_lock true = the session must hold
-- the editor lock (save), "free" = nobody else may hold it (run/stop: a `run` right without `edit_code` needs no lock)
local function target(sess, seq, op, eid, need_lock, action)
    bill(sess)
    if not bucket(sess, "req_b", cfg.req_rate, cfg.req_burst) then reply(sess, seq, op, eid, 9); return nil end
    local e = S.ents[eid]
    if not e then reply(sess, seq, op, eid, 1); return nil end
    if not is_bench(e) then reply(sess, seq, op, eid, 2); return nil end
    if action then
        local ok, why = P.allowed(sess, e, action)
        if not ok then reply(sess, seq, op, eid, 3, why); return nil end
    end
    if need_lock == "free" then
        if e.lock and e.lock.key ~= sess.key then reply(sess, seq, op, eid, 4); return nil end
        if e.lock then e.lock.at = S.tick end
    elseif need_lock then
        if not e.lock or e.lock.key ~= sess.key then reply(sess, seq, op, eid, 5); return nil end
        e.lock.at = S.tick
    end
    return e
end
M.target = target

-- ------------------------------------------------------------------------------------------ requests
function M.ScriptOpen(sess, m)
    ST.stats.open = ST.stats.open + 1
    local e = target(sess, m.seq, OP.open, m.eid, false)
    if not e then return end
    local okr, whyr = P.allowed(sess, e, "read_code")          -- UX A1: reading the code is a right too
    if not okr then
        P.send_perms(sess, e, m.seq)
        return reply(sess, m.seq, OP.open, e.eid, 3, whyr)
    end
    subscribe(sess, e)
    local code, why = 0, nil
    if m.edit then
        local oke, whye = P.allowed(sess, e, "edit_code")
        if not oke then
            code, why = 3, whye
        elseif e.lock and e.lock.key ~= sess.key then
            code = 4
        else
            local fresh = not e.lock
            e.lock = {key = sess.key, name = sess.name, eid = sess.eid, at = S.tick}
            if fresh then
                log("lock eid=%d taken by %s (%s)", e.eid, sess.name, sess.account)
                for skey in pairs(e.subs) do         -- others see the new holder
                    local s = S.sessions[skey]
                    if s and skey ~= sess.key then send_state(s, e, 0) end
                end
            end
        end
    end
    -- state first (read-only when refused), then the verdict: the client renders the state either way
    send_state(sess, e, m.seq)
    P.send_perms(sess, e, m.seq)                                -- UX A1: rights panel + what this session may do
    reply(sess, m.seq, OP.open, e.eid, code, why)
end

function M.ScriptSave(sess, m)
    ST.stats.save = ST.stats.save + 1
    local e = target(sess, m.seq, OP.save, m.eid, true, "edit_code")
    if not e then return end
    if #m.code > cfg.code_max then return reply(sess, m.seq, OP.save, e.eid, 10, "code longer than " .. cfg.code_max) end
    e.code = m.code
    ST.dirty = true
    M.console_add(e, 2, string.format("saved by %s (%d bytes)", sess.name, #m.code))
    pcall(function() require("olife_world:mobs").on_code_saved(e, sess, "save") end)   -- UX B1: a commit per save
    reply(sess, m.seq, OP.save, e.eid, 0)
    M.push_state(e)
end

function M.ScriptRun(sess, m)
    ST.stats.run = ST.stats.run + 1
    local e = target(sess, m.seq, OP.run, m.eid, "free", "run")
    if not e then return end
    if not sandbox.connected() then return reply(sess, m.seq, OP.run, e.eid, 12) end
    e.status, e.error = "run", nil
    e.owner = M.owner_id(e.owner_acct ~= "" and e.owner_acct or "_world")
    sandbox.load_entity(e)                       -- (re)load: the service replaces the entity's chunk
    M.console_add(e, 2, "run by " .. sess.name)
    meta_changed(e)
    reply(sess, m.seq, OP.run, e.eid, 0)
    M.push_state(e)
end

function M.ScriptStop(sess, m)
    ST.stats.stop = ST.stats.stop + 1
    local e = target(sess, m.seq, OP.stop, m.eid, "free", "run")
    if not e then return end
    if e.status == "run" then sandbox.unload_entity(e) end
    e.status, e.error = "stop", nil
    e.vel.x, e.vel.y, e.vel.z = 0, 0, 0
    M.console_add(e, 2, "stopped by " .. sess.name)
    meta_changed(e)
    reply(sess, m.seq, OP.stop, e.eid, 0)
    M.push_state(e)
end

function M.ScriptLockRelease(sess, m)
    ST.stats.release = ST.stats.release + 1
    bill(sess)
    local e = S.ents[m.eid]
    if not is_bench(e) then return reply(sess, m.seq, OP.release, m.eid, e and 2 or 1) end
    if m.close then unsubscribe(sess, e) end
    if e.lock and e.lock.key == sess.key then
        release_lock(e, m.close and "closed" or "released")
        return reply(sess, m.seq, OP.release, e.eid, 0)
    end
    return reply(sess, m.seq, OP.release, e.eid, m.close and 0 or 5)
end

-- ------------------------------------------------------------------------------------------ UX round 1: entity settings
-- EntityEdit{seq, eid, op, name, model, texture} -> RequestReply op 7. Owner or admin only (code 3).
--   op 1 delete: the holder lets go, the lock goes, the sandbox forgets it, every subscriber is dropped, the entity
--        leaves the world (the next snapshot despawns it everywhere) and the registry (written at once);
--   op 2 rename: name tag (EntityMeta) to everybody who sees it;
--   op 3 look: model / texture from olife_proto:looks (EntityLook to everybody who sees it; kept in the registry).
local drop_hold
-- delete = despawn + forget (code, console, registry); also the operator's /kill (UX A2, olife_world:ops)
function M.delete_entity(e, by)
    if e.holder then drop_hold(e, "deleted") end
    if e.lock then e.lock = nil end
    if e.kind == 3 and (e.status == "run" or e.code == nil) and sandbox.connected() then pcall(sandbox.unload_entity, e) end
    for skey in pairs(e.subs or {}) do
        local s = S.sessions[skey]
        if s and s.subs then s.subs[e.eid] = nil end
    end
    e.subs = nil
    -- UX B1: the full snapshot of the mob becomes the owner's "last state" slot (restorable from the mobs panel)
    pcall(function() require("olife_world:mobs").on_deleted(e, by) end)
    server.remove_entity(e.eid)
    ST.stats.deleted = ST.stats.deleted + 1
    ST.dirty = true
    log("eid=%d (%s) deleted by %s", e.eid, tostring(e.name), tostring(by))
    server.save_registry(true)
    ST.written_tick = S.tick
end

function M.EntityEdit(sess, m)
    local e = target(sess, m.seq, OP.edit, m.eid, false)
    if not e then return end
    -- UX A1: delete = `destroy`, rename / look = `appearance` (bad op -> 15 after the rights of a known op)
    local need = m.op == 1 and "destroy" or ((m.op == 2 or m.op == 3) and "appearance" or nil)
    if need then
        local ok, why = P.allowed(sess, e, need)
        if not ok then return reply(sess, m.seq, OP.edit, e.eid, 3, why) end
    end
    if m.op == 1 then
        M.delete_entity(e, sess.name .. " (" .. sess.account .. ")")
        reply(sess, m.seq, OP.edit, e.eid, 0, "deleted")
        return
    elseif m.op == 2 then
        if not LOOKS.valid_name(m.name) then return reply(sess, m.seq, OP.edit, e.eid, 15, "bad name") end
        local old = e.name
        e.name = m.name
        meta_changed(e)
        ST.stats.renamed = ST.stats.renamed + 1
        M.console_add(e, 2, string.format("renamed by %s: %s -> %s", sess.name, tostring(old), m.name))
        reply(sess, m.seq, OP.edit, e.eid, 0)
        return M.push_state(e)
    elseif m.op == 3 then
        if m.model ~= "" and not LOOKS.model(m.model) then return reply(sess, m.seq, OP.edit, e.eid, 15, "bad model") end
        if m.texture ~= "" and not LOOKS.texture(m.texture) then
            return reply(sess, m.seq, OP.edit, e.eid, 15, "bad texture")
        end
        if m.model ~= "" then e.model = m.model end
        if m.texture ~= "" then e.texture = m.texture end
        e.look_ver = (e.look_ver or 0) + 1
        ST.dirty = true
        ST.stats.looks = ST.stats.looks + 1
        M.console_add(e, 2, string.format("look by %s: %s / %s", sess.name, e.model or LOOKS.DEFAULT_MODEL,
                                          e.texture or LOOKS.DEFAULT_TEXTURE))
        return reply(sess, m.seq, OP.edit, e.eid, 0)
    end
    return reply(sess, m.seq, OP.edit, e.eid, 15, "bad op")
end

-- profiler page: per-entity totals of the sandbox results + the owner's VM (when the sandbox reports it)
local function profile_msg(e)
    local t = MT.ents[e.eid] or {}
    local st = t.st or {}
    local vm = MT.svc and MT.svc[e.owner] or nil
    return {eid = e.eid, tick = S.tick, ticks = t.ticks or 0, errors = (st.error or 0) + (st.killed or 0),
            text_dropped = e.text_dropped or 0, rejected_total = t.rejected or 0,
            vm_heap = vm and tonumber(vm.lua_heap) or -1, vm_peak = vm and tonumber(vm.mem_peak) or -1,
            vm_state = vm and tostring(vm.state or ""):sub(1, 16) or ""}
end
M.profile_msg = profile_msg

-- ------------------------------------------------------------------------------------------ tools
local function norm(v)
    local l = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    if l ~= l or l < 1e-6 or l == math.huge then return nil end
    return {x = v.x / l, y = v.y / l, z = v.z / l}
end

-- ray (o, d) vs axis-aligned cube centred on c with half extent h -> distance or nil
local function ray_box(o, d, c, h)
    local tmin, tmax = 0, cfg.reach
    for _, a in ipairs({"x", "y", "z"}) do
        local lo, hi = c[a] - h, c[a] + h
        if math.abs(d[a]) < 1e-9 then
            if o[a] < lo or o[a] > hi then return nil end
        else
            local t1, t2 = (lo - o[a]) / d[a], (hi - o[a]) / d[a]
            if t1 > t2 then t1, t2 = t2, t1 end
            tmin, tmax = max(tmin, t1), min(tmax, t2)
            if tmin > tmax then return nil end
        end
    end
    return tmin
end

-- the world's ray: nearest scripted entity hit within reach
local function raycast(o, d)
    local best, bd
    for _, e in pairs(S.ents) do
        if e.kind == 3 then
            local t = ray_box(o, d, e.pos, cfg.box_half)
            if t and (not bd or t < bd) then best, bd = e, t end
        end
    end
    return best, bd
end
M.raycast = raycast

function drop_hold(e, why)
    local h = e.holder
    if not h then return end
    e.holder = nil
    local s = S.sessions[h.key]
    if s and s.holding == e.eid then s.holding = nil end
    ST.stats.releases = ST.stats.releases + 1
    hold_changed(e)
    log("eid=%d released by %s (%s) at %.2f,%.2f,%.2f", e.eid, h.name, why, e.pos.x, e.pos.y, e.pos.z)
end
M.drop_hold = function(e, why) return drop_hold(e, why) end     -- UX B1: rescue lets a held mob go

function M.ToolUse(sess, m)
    ST.stats.tool = ST.stats.tool + 1
    local seq = m.seq
    if m.action == 4 then                                   -- aim: cheap, own bucket, no reply when fine
        if not bucket(sess, "aim_b", cfg.aim_rate, cfg.aim_rate) then return end
        local e = sess.holding and S.ents[sess.holding]
        if not e or not e.holder or e.holder.key ~= sess.key then return reply(sess, seq, OP.tool, m.target, 11) end
        local d = norm(m.dir)
        if not d then return reply(sess, seq, OP.tool, e.eid, 14) end
        e.holder.dir = d
        return
    end
    bill(sess)
    if not bucket(sess, "req_b", cfg.req_rate, cfg.req_burst) then return reply(sess, seq, OP.tool, m.target, 9) end
    if (m.tool ~= 1 and m.tool ~= 2) or m.action < 1 or m.action > 3 or (m.tool == 1 and m.action ~= 1) then
        return reply(sess, seq, OP.tool, m.target, 13)
    end
    if m.action == 3 then                                   -- release
        local e = sess.holding and S.ents[sess.holding]
        if not e or not e.holder or e.holder.key ~= sess.key then return reply(sess, seq, OP.tool, m.target, 11) end
        drop_hold(e, "release")
        return reply(sess, seq, OP.tool, e.eid, 0)
    end
    -- use / grab: the world's own ray from (near) its player position
    local o, d = m.origin, norm(m.dir)
    if not d then return reply(sess, seq, OP.tool, m.target, 14) end
    local dx, dy, dz = o.x - sess.pos.x, o.y - sess.pos.y, o.z - sess.pos.z
    if dx * dx + dy * dy + dz * dz > cfg.origin_slack * cfg.origin_slack then
        return reply(sess, seq, OP.tool, m.target, 14, "origin too far from the player")
    end
    local e, dist = raycast(o, d)
    if not e then
        local t = S.ents[m.target]
        if t and t.kind == 3 then
            local ex, ey, ez = t.pos.x - o.x, t.pos.y - o.y, t.pos.z - o.z
            if ex * ex + ey * ey + ez * ez > cfg.reach * cfg.reach then return reply(sess, seq, OP.tool, m.target, 6) end
        end
        return reply(sess, seq, OP.tool, m.target, 7)
    end
    if m.target ~= 0 and m.target ~= e.eid then return reply(sess, seq, OP.tool, m.target, 7, "ray hit eid " .. e.eid) end
    if m.tool == 1 then                                     -- injector: open the editor (read-only unless allowed)
        reply(sess, seq, OP.tool, e.eid, 0)
        return M.ScriptOpen(sess, {seq = seq, eid = e.eid, edit = can_edit(sess, e)})
    end
    -- gravity gun grab: UX A1 — the `move` right (legacy scripted entities: anyone)
    local okm, whym = P.allowed(sess, e, "move")
    if not okm then return reply(sess, seq, OP.tool, e.eid, 3, whym) end
    if e.holder and e.holder.key ~= sess.key then return reply(sess, seq, OP.tool, e.eid, 8, "held by " .. e.holder.name) end
    if sess.holding and sess.holding ~= e.eid then
        local old = S.ents[sess.holding]
        if old then drop_hold(old, "grabbed another") end
    end
    e.holder = {key = sess.key, eid = sess.eid, name = sess.name, dist = max(cfg.hold_min, min(cfg.hold_max, dist + cfg.box_half)),
                dir = d, off = {x = dx, y = dy, z = dz}, at = S.tick}
    sess.holding = e.eid
    ST.stats.grabs = ST.stats.grabs + 1
    hold_changed(e)
    log("eid=%d grabbed by %s dist=%.2f", e.eid, sess.name, e.holder.dist)
    return reply(sess, seq, OP.tool, e.eid, 0)
end

-- a held entity: the sandbox may not move it
function M.is_held(e) return e.holder ~= nil end

-- ------------------------------------------------------------------------------------------ tick (phase 3)
local function step_holds()
    local sp = S.spawn
    for _, e in pairs(S.ents) do
        local h = e.holder
        if h then
            local s = S.sessions[h.key]
            if not s then
                drop_hold(e, "holder gone")
            else
                local ex, ey, ez = s.pos.x + h.off.x, s.pos.y + h.off.y, s.pos.z + h.off.z
                local tx, ty, tz = ex + h.dir.x * h.dist, ey + h.dir.y * h.dist, ez + h.dir.z * h.dist
                local ddx, ddz = tx - sp.x, tz - sp.z
                local r = sqrt(ddx * ddx + ddz * ddz)
                if r > cfg.area - 1 then tx, tz = sp.x + ddx / r * (cfg.area - 1), sp.z + ddz / r * (cfg.area - 1) end
                ty = max(1, min(255, ty))
                local mx, my, mz = tx - e.pos.x, ty - e.pos.y, tz - e.pos.z
                local l = sqrt(mx * mx + my * my + mz * mz)
                if l > cfg.hold_step then
                    local k = cfg.hold_step / l
                    mx, my, mz = mx * k, my * k, mz * k
                end
                e.pos.x, e.pos.y, e.pos.z = e.pos.x + mx, e.pos.y + my, e.pos.z + mz
                ST.stats.held_ticks = ST.stats.held_ticks + 1
                local fx, fy, fz = e.pos.x - s.pos.x, e.pos.y - s.pos.y, e.pos.z - s.pos.z
                if fx * fx + fy * fy + fz * fz > cfg.hold_drop * cfg.hold_drop then drop_hold(e, "too far") end
            end
        end
    end
end

local function flush_console()
    if S.tick % cfg.delta_every ~= 0 then return end
    for _, e in pairs(S.ents) do
        for skey, sub in pairs(e.subs or {}) do
            local s = S.sessions[skey]
            if not s then
                e.subs[skey] = nil
            elseif #sub.pending > 0 or sub.dropped > 0 or (e.status == "run" and S.tick % 20 == 0) then
                -- lines, drops, or (running) a meters refresh once a second
                local lines, bytes, n = {}, 0, 0
                for _, l in ipairs(sub.pending) do
                    if n >= cfg.delta_lines or bytes + #l.text > cfg.delta_bytes then break end
                    n = n + 1
                    lines[n] = l
                    bytes = bytes + #l.text
                end
                local rest = {}
                for i = n + 1, #sub.pending do rest[#rest + 1] = sub.pending[i] end
                sub.pending = rest
                net.send_client(s.gw, s.sid, "ConsoleDelta", {eid = e.eid, lines = lines, dropped = sub.dropped,
                                                               meters = meters_of(e)})
                ST.stats.deltas = ST.stats.deltas + 1
                ST.stats.delta_lines = ST.stats.delta_lines + n
                ST.stats.delta_dropped = ST.stats.delta_dropped + sub.dropped
                s.console_deltas = (s.console_deltas or 0) + 1
                sub.dropped = 0
            end
            if s and S.tick % 20 == 0 then          -- UX round 1: profiler page, once a second (running or not)
                net.send_client(s.gw, s.sid, "ScriptProfile", profile_msg(e))
                ST.stats.profiles = ST.stats.profiles + 1
            end
        end
    end
end

function M.tick()
    step_holds()
    for _, e in pairs(S.ents) do
        local lk = e.lock
        if lk and (not S.sessions[lk.key] or S.tick - lk.at > cfg.lock_timeout) then
            ST.stats.locks_expired = ST.stats.locks_expired + 1
            release_lock(e, S.sessions[lk.key] and "timeout" or "holder gone")
        end
    end
    flush_console()
    if (ST.dirty or ST.console_dirty) and S.tick - ST.written_tick >= cfg.registry_every then
        ST.dirty, ST.console_dirty = false, false
        ST.written_tick = S.tick
        server.save_registry(true)
    end
end

-- phase 4, per session after its EntitySnapshot: name tags and hold state of entities it sees
function M.replicate(sess)
    P.replicate(sess)                               -- UX A1: FriendList at the first tick, friends see it online
    sess.meta_seen = sess.meta_seen or {}
    sess.hold_seen = sess.hold_seen or {}
    sess.look_seen = sess.look_seen or {}
    for eid in pairs(sess.view) do
        local e = S.ents[eid]
        if e and e.kind == 3 then
            local mv = e.meta_ver or 0
            if is_bench(e) and sess.meta_seen[eid] ~= mv then
                sess.meta_seen[eid] = mv
                e.label = e.label or label_of(e)
                net.send_client(sess.gw, sess.sid, "EntityMeta", {eid = eid, owner_name = (e.owner_name or ""):sub(1, 32),
                                                                  status = M.shown_status(e), label = e.label})
            end
            local lv = e.look_ver or 0                  -- UX round 1: chosen model / texture
            if is_bench(e) and lv > 0 and sess.look_seen[eid] ~= lv then
                sess.look_seen[eid] = lv
                net.send_client(sess.gw, sess.sid, "EntityLook", {eid = eid, model = (e.model or ""):sub(1, 32),
                                                                  texture = (e.texture or ""):sub(1, 64)})
            end
            local hv = e.hold_ver or 0
            if sess.hold_seen[eid] ~= hv then
                local first = sess.hold_seen[eid] == nil
                sess.hold_seen[eid] = hv
                if not (first and not e.holder) then
                    local h = e.holder
                    net.send_client(sess.gw, sess.sid, "EntityOwnership", {eid = eid, holder_eid = h and h.eid or 0,
                        holder_name = h and h.name:sub(1, 32) or "", tool = h and 2 or 0, tick = S.tick})
                end
            end
        end
    end
    for eid in pairs(sess.meta_seen) do if not sess.view[eid] then sess.meta_seen[eid] = nil end end
    for eid in pairs(sess.hold_seen) do if not sess.view[eid] then sess.hold_seen[eid] = nil end end
    for eid in pairs(sess.look_seen) do if not sess.view[eid] then sess.look_seen[eid] = nil end end
end

function M.on_session_removed(sess)
    P.on_session_removed(sess)                      -- UX A1: friends see it offline
    for _, e in pairs(S.ents) do
        if e.lock and e.lock.key == sess.key then release_lock(e, "holder left") end
        if e.subs then e.subs[sess.key] = nil end
        if e.holder and e.holder.key == sess.key then drop_hold(e, "holder left") end
    end
end

-- ------------------------------------------------------------------------------------------ registry
function M.save_fields(e, rec)
    if not is_bench(e) then return end
    rec.code, rec.status, rec.error = e.code, e.status, e.error
    rec.owner_acct, rec.owner_name, rec.cseq = e.owner_acct, e.owner_name, e.cseq
    rec.model, rec.texture = e.model, e.texture          -- UX round 1
    P.save_fields(e, rec)                                -- UX A1: rights, forked_from
    local c = {}
    for i, l in ipairs(e.console or {}) do c[i] = {l.seq, l.tick, l.kind, l.text} end
    rec.console = c
end

function M.load_fields(e, r)
    if r.code == nil then return end
    e.code, e.status, e.error = r.code, r.status or "stop", r.error
    e.owner_acct, e.owner_name, e.cseq = r.owner_acct or "", r.owner_name or "", r.cseq or 0
    e.model, e.texture = r.model, r.texture             -- UX round 1
    if e.model or e.texture then e.look_ver = 1 end
    P.load_fields(e, r)                                 -- UX A1
    e.console = {}
    for i, l in ipairs(r.console or {}) do e.console[i] = {seq = l[1], tick = l[2], kind = l[3], text = l[4]} end
    e.label = label_of(e)
end

function M.save_top()
    local adm = {}
    for a in pairs(ST.admins) do adm[#adm + 1] = a end
    table.sort(adm)
    return {owner_ids = ST.owner_ids, next_owner = ST.next_owner, admins = adm, perms = P.save_top()}   -- + UX A1
end

function M.load_top(t)
    if type(t) ~= "table" then return end
    for a, id in pairs(t.owner_ids or {}) do ST.owner_ids[a] = id end
    ST.next_owner = max(ST.next_owner, t.next_owner or 0)
    for _, a in ipairs(t.admins or {}) do ST.admins[a] = true end
    P.load_top(t.perms)                                 -- UX A1: friends, requests, known accounts, defaults
end

-- after the registry was loaded: benches that were running start again when the sandbox connects (runnable)
function M.after_load()
    local n, run = 0, 0
    for _, e in pairs(S.ents) do
        if is_bench(e) then
            n = n + 1
            if e.status == "run" then
                run = run + 1
                M.console_add(e, 2, "world restarted: running again")
            end
        end
    end
    if n > 0 then log("restored %d benches (%d running)", n, run) end
end

-- ------------------------------------------------------------------------------------------ admin
function M.spawn_bench(account, name, count, code)
    count = count or 1
    local out = {}
    for i = 1, count do
        S.bench_i = (S.bench_i or 0) + 1
        local sp = S.spawn
        local a = (S.bench_i - 1) * 0.9
        local p = {x = sp.x + 3 + math.cos(a) * 2, y = sp.y + 1.5, z = sp.z + 3 + math.sin(a) * 2}
        local e = server.new_entity(3, "olife_client:bench", "", 0, p)
        e.name = (name and name ~= "" and (count > 1 and name .. i or name) or ("bench" .. e.eid)):sub(1, 32)
        e.code, e.status = code or DEFAULT_CODE, "stop"
        e.owner_acct = account or ""
        e.owner_name = account or ""
        e.owner = M.owner_id(account ~= "" and account or "_world")
        e.cseq = 0
        P.init_entity(e)                                 -- UX A1: the owner's default rights
        M.console_add(e, 2, "spawned for " .. (account ~= "" and account or "world"))
        meta_changed(e)
        out[#out + 1] = e.eid
    end
    ST.dirty = true
    return out
end

-- play path (olife_play, 02.10): a sample bench with the code of olife_world:sandbox/samples/<code_id>.lua owned by
-- <account>; run = true starts it at once (loaded into the sandbox now if connected, else on connect: runnable)
function M.spawn_sample(account, name, code_id, run)
    local ok, src = pcall(file.read, "olife_world:sandbox/samples/" .. tostring(code_id) .. ".lua")
    if not ok or type(src) ~= "string" or src == "" then return nil, "no sample " .. tostring(code_id) end
    local l = M.spawn_bench(account, name, 1, src)
    local e = S.ents[l[1]]
    if e then          -- on a ring of radius 3 around the spawn: inside the sandbox view (6) of a player at the spawn
        S.sample_i = (S.sample_i or 0) + 1
        local a, sp = (S.sample_i - 1) * 2.1, S.spawn
        e.pos.x, e.pos.y, e.pos.z = sp.x + math.cos(a) * 3, sp.y + 1.5, sp.z + math.sin(a) * 3
    end
    if run and e then
        e.status, e.error = "run", nil
        e.owner = M.owner_id(account ~= "" and account or "_world")
        if sandbox.connected() then sandbox.load_entity(e) end
        M.console_add(e, 2, "sample " .. tostring(code_id) .. ": running")
        meta_changed(e)
    end
    return l
end

-- dry run of the play path (olife_play_dry, UX round 1): the world is a COPY of the user's persistent world, where
-- the user may have stopped / edited / renamed a sample -> put the sample back to its file code, running
function M.sample_reset(account, name, slot)
    for _, e in pairs(S.ents) do
        if is_bench(e) and e.owner_acct == account and e.name == name then
            if slot and slot >= 0 then        -- back to its place on the ring around the spawn (as spawn_sample)
                local a, sp = slot * 2.1, S.spawn
                e.pos.x, e.pos.y, e.pos.z = sp.x + math.cos(a) * 3, sp.y + 1.5, sp.z + math.sin(a) * 3
                if e.holder then drop_hold(e, "sample reset") end
            end
            local ok, src = pcall(file.read, "olife_world:sandbox/samples/" .. name .. ".lua")
            if not ok or type(src) ~= "string" or src == "" then return nil, "no sample file " .. name end
            if e.status == "run" and sandbox.connected() then pcall(sandbox.unload_entity, e) end
            e.code, e.status, e.error = src, "run", nil
            e.owner = M.owner_id(account ~= "" and account or "_world")
            if sandbox.connected() then sandbox.load_entity(e) end
            M.console_add(e, 2, "sample reset (dry run)")
            meta_changed(e)
            M.push_state(e)
            return e.eid
        end
    end
    return nil, "no bench " .. tostring(name)
end

function M.set_admins(csv)
    ST.admins = {}
    for a in tostring(csv or ""):gmatch("[^,%s]+") do ST.admins[a] = true end
    ST.dirty = true
    local l = {}
    for a in pairs(ST.admins) do l[#l + 1] = a end
    table.sort(l)
    return table.concat(l, ",")
end

function M.describe(eid)
    local e = S.ents[eid]
    if not e then return "[olife_world] bench: no entity eid=" .. tostring(eid) end
    local subs = {}
    for skey in pairs(e.subs or {}) do local s = S.sessions[skey]; subs[#subs + 1] = s and s.name or skey end
    table.sort(subs)
    local mt = is_bench(e) and meters_of(e) or {}
    local code = e.code or ""
    return string.format("[olife_world] bench eid=%d name=%s kind=%d owner=%s status=%s sb=%s code_len=%d code_fnv=%d " ..
        "pos=%.3f,%.3f,%.3f lock=%s holder=%s subs=%s console=%d cseq=%d credits_min=%.1f fuel_min=%.0f actions_min=%d " ..
        "rejected_min=%d text_dropped=%d model=%s texture=%s forked_from=%s label=%s",
        e.eid, tostring(e.name), e.kind, tostring(e.owner_acct), tostring(e.status), tostring(e.sb_status),
        #code, fnv_str(code), e.pos.x, e.pos.y, e.pos.z, e.lock and e.lock.name or "-",
        e.holder and e.holder.name or "-", #subs > 0 and table.concat(subs, ",") or "-", #(e.console or {}), e.cseq or 0,
        mt.credits_min or 0, mt.fuel_min or 0, mt.actions_min or 0, mt.rejected_min or 0, e.text_dropped or 0,
        tostring(e.model or "-"), tostring(e.texture or "-"), e.forked_from and tostring(e.forked_from.eid) or "-",
        (e.label or ""):gsub(" ", "_"))
end

function M.list()
    local l = {}
    for _, e in pairs(S.ents) do
        if is_bench(e) then l[#l + 1] = e end
    end
    table.sort(l, function(a, b) return a.eid < b.eid end)
    local out = {}
    for _, e in ipairs(l) do
        out[#out + 1] = string.format("%d:%s:%s:%s", e.eid, e.name or "", e.owner_acct or "", e.status or "")
    end
    return "[olife_world] benches n=" .. #l .. " " .. table.concat(out, " ")
end

function M.status()
    local r = {}
    for c, n in pairs(ST.stats.refused) do r[#r + 1] = c .. ":" .. n end
    table.sort(r)
    local s = ST.stats
    return string.format("editor(open=%d,save=%d,run=%d,stop=%d,release=%d,tool=%d,grabs=%d,releases=%d,states=%d," ..
        "deltas=%d,delta_lines=%d,delta_dropped=%d,text_rejected=%d,locks_expired=%d,deleted=%d,renamed=%d,looks=%d," ..
        "profiles=%d,refused={%s})", s.open, s.save, s.run,
        s.stop, s.release, s.tool, s.grabs, s.releases, s.states, s.deltas, s.delta_lines, s.delta_dropped,
        s.text_rejected, s.locks_expired, s.deleted, s.renamed, s.looks, s.profiles, table.concat(r, ",")) ..
        " " .. P.status()
end

return M
