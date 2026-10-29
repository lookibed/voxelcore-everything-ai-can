-- olife_world:mobs — UX B1 (03.10, olife_b1): "my mobs" mode of the Injector (OLIFE_UX §2) on the authoritative world.
--   MobsRequest  -> MobsList: the player's benches with status, cost (ScriptMeters), memory (A4 KV, owner VM heap),
--                   position and `loaded` (the chunk under the mob is loaded here); watch=1 = refresh every second
--                   while the client's panel is open; + the "last state" slots of the player's removed mobs (DeadMob).
--   MobAction    -> two-step emergency actions: token 0 asks (the world checks rights and feasibility, answers
--                   MobConfirm{token} + RequestReply 22), the token confirms (RequestReply 0):
--                   1 rescue  — back to the last SAFE known position (ring of 16 positions per mob, sampled every
--                               10 ticks; safe = own cell air, a solid block within 3 below, inside the play area);
--                               a position whose chunk is not loaded is skipped (25 when none is loaded; 24 when
--                               nothing safe is known); needs `move` (owner / admin always). MobRescued to the owner.
--                   2 destroy — editor.delete_entity (`destroy`); the last state is snapshotted first (see below).
--                   3 restore — the snapshot taken when the mob was removed (/kill of an operator, Shift+LMB,
--                               destroy) becomes a new bench through A4 STORE.restore (quota + tariff of the owner,
--                               20 store credits; 29 with the store code on refusal); same code hash, look, KV,
--                               rights, code history; 5 restores a minute per account (27); the slot is consumed.
--   MobProfileRequest -> MobProfile (owner, rights line, code hash/size, commits, run ticks, errors, KV, VM, costs,
--                   last error lines); CodeHistoryRequest -> CodeHistory; CodeVersionOp: 1 open -> CodeVersionText,
--                   2 restore -> the version becomes the code as a NEW commit (lock holder with `edit_code`).
--   Code history: every ScriptSave (and a version restore) adds a commit {n, fnv, size, ms, tick, author, note, code}
--   per entity: 16 kept, <= 256 KiB per entity (oldest dropped); travels with the Spammer/B1 snapshot (store hook).
-- State file: world:olife_mobs.json (dead slots per account with the snapshot blob, code history per entity), written
-- when dirty at most once a second. Every request is billed to the account and goes through the editor's request
-- bucket (code 9). Codes 22..29 and ops 12..18 — client.yaml «UX B1».
local net = require "olife_world:net"
local STORE = require "olife_world:store"
local MT = require "olife_world:sbmeter"
local P = require "olife_world:perms"

local M = {}
local server, editor, sandbox, S
local floor, sqrt, max, min = math.floor, math.sqrt, math.max, math.min

local cfg = {
    safe_every = 10,        -- ticks between position samples per mob
    ring = 16,              -- safe positions kept per mob
    support_depth = 3,      -- a solid block within this many blocks below the mob's cell = standing
    confirm_ticks = 200,    -- a confirmation token lives 10 s
    watch_every = 20,       -- MobsList refresh to watching sessions
    dead_max = 8,           -- "last state" slots per account
    versions_max = 16, versions_bytes = 262144,
    restores_per_min = 5,
    file_every = 20,        -- ticks between state file writes when dirty
    list_max = 64,
}
M.cfg = cfg

local OP = {mobs = 12, rescue = 13, destroy = 14, restore = 15, profile = 16, history = 17, version = 18}
M.OP = OP
local CODE = {confirm = 22, bad_token = 23, no_safe = 24, not_loaded = 25, nothing = 26, limit = 27, no_version = 28,
              store = 29}
M.CODE = CODE
local REASON = {[22] = "confirm", [23] = "bad or expired confirmation token", [24] = "no safe position known",
                [25] = "chunk not loaded: come closer", [26] = "nothing to restore", [27] = "limit",
                [28] = "no such version", [29] = "store refused"}
M.REASON = REASON
local ACT_OP = {[1] = OP.rescue, [2] = OP.destroy, [3] = OP.restore}
local ACT_TXT = {[1] = "rescue", [2] = "destroy", [3] = "restore"}

local FILE = "world:olife_mobs.json"
local ST = {dead = {}, versions = {}, dirty = false, written_tick = 0, loaded = false,
            stats = {lists = 0, watch_lists = 0, confirms = 0, rescues = 0, destroys = 0, restores = 0, profiles = 0,
                     histories = 0, version_opens = 0, version_restores = 0, commits = 0, dead_saved = 0,
                     refused = {}, samples = 0}}
M.ST = ST

local function log(fmt, ...) print("[olife_world] mobs: " .. string.format(fmt, ...)) end
local function now_ms() return time.uptime() * 1000 end

-- ------------------------------------------------------------------------------------------ state file
local function load_file()
    ST.loaded = true
    if not file.exists(FILE) then return end
    local ok, d = pcall(function() return json.parse(file.read(FILE)) end)
    if not ok or type(d) ~= "table" then log("state unreadable: %s", tostring(d)); return end
    local nd, nv = 0, 0
    for acct, l in pairs(d.dead or {}) do
        ST.dead[acct] = {}
        for _, x in ipairs(l) do
            if type(x) == "table" and type(x.blob) == "string" then ST.dead[acct][#ST.dead[acct] + 1] = x; nd = nd + 1 end
        end
    end
    for k, v in pairs(d.versions or {}) do
        local eid = tonumber(k)
        if eid and type(v) == "table" and type(v.items) == "table" then
            ST.versions[eid] = {next = tonumber(v.next) or (#v.items + 1), items = v.items}
            nv = nv + 1
        end
    end
    log("state loaded: dead=%d entities_with_history=%d", nd, nv)
end

local function save_file()
    local vers = {}
    for eid, v in pairs(ST.versions) do
        if S.ents[eid] then vers[tostring(eid)] = v end           -- history of a gone entity lives in its snapshot
    end
    local ok, err = pcall(file.write, FILE, json.tostring({v = 1, tick = S.tick, dead = ST.dead, versions = vers}))
    if not ok then log("state write failed: %s", tostring(err)) end
    ST.dirty, ST.written_tick = false, S.tick
end

local function dirty() ST.dirty = true end

-- ------------------------------------------------------------------------------------------ helpers
local function is_bench(e) return editor.is_bench(e) end

local function reply(sess, seq, op, eid, code, reason)
    if code ~= 0 then ST.stats.refused[code] = (ST.stats.refused[code] or 0) + 1 end
    return editor.reply(sess, seq, op, eid, code, reason or REASON[code])
end

local function clip(s, n) return tostring(s or ""):sub(1, n) end

local function fnv(e) return editor.fnv_str(e.code or "") end

local function sessions_of(account)
    local l = {}
    for _, s in pairs(S.sessions) do if s.account == account then l[#l + 1] = s end end
    return l
end

local function send_owner(e, name, msg, also)
    local acct = e.owner_acct or ""
    local sent = {}
    if acct ~= "" then
        for _, s in ipairs(sessions_of(acct)) do net.send_client(s.gw, s.sid, name, msg); sent[s.key] = true end
    end
    if also and not sent[also.key] then net.send_client(also.gw, also.sid, name, msg) end
end

-- the chunk of the cell under the mob is loaded on this world (block.get == -1 means not loaded)
local function cell(e)
    return floor(e.pos.x), max(0, min(255, floor(e.pos.y))), floor(e.pos.z)
end

local function loaded_at(x, y, z)
    return block.get(floor(x), max(0, min(255, floor(y))), floor(z)) ~= -1
end

function M.loaded(e) local x, y, z = cell(e); return block.get(x, y, z) ~= -1 end

-- safe = own cell is air, a solid block within support_depth below, inside the play area, 1..254: true / false /
-- nil (unknown: a needed chunk is not loaded)
local function safe_at(x, y, z)
    local fx, fy, fz = floor(x), floor(y), floor(z)
    if fy < 1 or fy > 254 then return false end
    local sp = S.spawn
    local dx, dz = x - sp.x, z - sp.z
    if dx * dx + dz * dz > (editor.cfg.area - 1) ^ 2 then return false end
    local here = block.get(fx, fy, fz)
    if here == -1 then return nil end
    if here ~= 0 then return false end
    for k = 1, cfg.support_depth do
        local b = block.get(fx, fy - k, fz)
        if b == -1 then return nil end
        if b > 0 then return true end
    end
    return false
end
M.safe_at = safe_at

local function ring_of(e)
    local r = e.b1
    if not r then r = {ring = {}, i = 0, n = 0}; e.b1 = r end
    return r
end

local function sample(e)
    local r = ring_of(e)
    r.last = {x = e.pos.x, y = e.pos.y, z = e.pos.z, tick = S.tick}
    if safe_at(e.pos.x, e.pos.y, e.pos.z) ~= true then return end
    local top = r.ring[r.i]
    if top and math.abs(top.x - e.pos.x) + math.abs(top.y - e.pos.y) + math.abs(top.z - e.pos.z) < 0.05 then
        top.tick = S.tick
        return
    end
    r.i = r.i % cfg.ring + 1
    r.ring[r.i] = {x = e.pos.x, y = e.pos.y, z = e.pos.z, tick = S.tick}
    r.n = min(cfg.ring, r.n + 1)
    ST.stats.samples = ST.stats.samples + 1
end

-- the newest safe position whose chunk is loaded and which is still safe -> pos | nil, code
local function rescue_target(e)
    local r = e.b1
    if not r or r.n == 0 then return nil, CODE.no_safe end
    local unloaded = 0
    for k = 0, r.n - 1 do
        local idx = (r.i - 1 - k) % cfg.ring + 1
        local p = r.ring[idx]
        if p then
            local s = safe_at(p.x, p.y, p.z)
            if s == true then return p
            elseif s == nil then unloaded = unloaded + 1 end
        end
    end
    if unloaded > 0 then return nil, CODE.not_loaded end
    return nil, CODE.no_safe
end
M.rescue_target = rescue_target

-- ------------------------------------------------------------------------------------------ code history
function M.versions_of(eid)
    local v = ST.versions[eid]
    return v and v.items or {}
end

-- a commit of the entity's current code (ScriptSave, version restore); identical code to the last commit is not
-- repeated (the note is refreshed)
function M.on_code_saved(e, sess, note)
    if not is_bench(e) then return end
    local v = ST.versions[e.eid]
    if not v then v = {next = 1, items = {}}; ST.versions[e.eid] = v end
    local code = e.code or ""
    local h = fnv(e)
    local last = v.items[#v.items]
    local who = sess and sess.name or "world"
    if last and last.fnv == h and last.size == #code then
        last.note = clip(note or "save", 32)
        dirty()
        return last
    end
    local item = {n = v.next, fnv = h, size = #code, ms = now_ms(), tick = S.tick, author = clip(who, 32),
                  note = clip(note or "save", 32), code = code}
    v.next = v.next + 1
    v.items[#v.items + 1] = item
    while #v.items > cfg.versions_max do table.remove(v.items, 1) end
    local bytes = 0
    for _, it in ipairs(v.items) do bytes = bytes + it.size end
    while bytes > cfg.versions_bytes and #v.items > 1 do
        bytes = bytes - v.items[1].size
        table.remove(v.items, 1)
    end
    ST.stats.commits = ST.stats.commits + 1
    dirty()
    return item
end

local function history_msg(eid, seq)
    local items = {}
    for i, it in ipairs(M.versions_of(eid)) do
        items[i] = {n = it.n, fnv = it.fnv, size = it.size, ms = it.ms, tick = it.tick, author = clip(it.author, 32),
                    note = clip(it.note, 32)}
    end
    while #items > 16 do table.remove(items, 1) end
    return {seq = seq or 0, eid = eid, items = items}
end

local function push_history(e, sess, seq)
    local sent = {}
    for skey in pairs(e.subs or {}) do
        local s = S.sessions[skey]
        if s then net.send_client(s.gw, s.sid, "CodeHistory", history_msg(e.eid, s == sess and seq or 0)); sent[skey] = true end
    end
    if sess and not sent[sess.key] then net.send_client(sess.gw, sess.sid, "CodeHistory", history_msg(e.eid, seq)) end
end

-- ------------------------------------------------------------------------------------------ dead slots
-- editor.delete_entity (owner's Shift+LMB / button / B1 destroy, operator /kill): the full A4 snapshot of the mob
-- (code, status, look, KV, asset slots, rights, A3 appearance, B1 code history) becomes the owner's "last state" slot
function M.on_deleted(e, by)
    if not is_bench(e) then return end
    local acct = e.owner_acct or ""
    if acct == "" then acct = "_world" end
    local blob, n, code, reason = STORE.snapshot(e.eid, {charge = false, pin = true})
    if not blob then
        log("eid=%d: last state not saved (%s %s)", e.eid, tostring(code or n), tostring(reason))
        return
    end
    local l = ST.dead[acct]
    if not l then l = {}; ST.dead[acct] = l end
    l[#l + 1] = {eid = e.eid, name = clip(e.name, 32), tick = S.tick, ms = now_ms(), by = clip(by, 32), code_fnv = fnv(e),
                 size = n, blob = blob, pos = {e.pos.x, e.pos.y, e.pos.z}, account = acct}
    while #l > cfg.dead_max do table.remove(l, 1) end
    ST.versions[e.eid] = nil                      -- the history is inside the snapshot (store hook)
    ST.stats.dead_saved = ST.stats.dead_saved + 1
    dirty()
    log("eid=%d (%s) of %s: last state kept (%d B, slots %d)", e.eid, tostring(e.name), acct, n, #l)
end

local function dead_find(acct, eid, any)
    if any then
        for a, l in pairs(ST.dead) do
            for i, d in ipairs(l) do if d.eid == eid then return d, l, i, a end end
        end
        return nil
    end
    local l = ST.dead[acct]
    if not l then return nil end
    for i, d in ipairs(l) do if d.eid == eid then return d, l, i, acct end end
    return nil
end

local function dead_list(acct)
    local out = {}
    for _, d in ipairs(ST.dead[acct] or {}) do
        out[#out + 1] = {eid = d.eid, name = d.name, tick = d.tick, ms = d.ms, code_fnv = d.code_fnv, size = d.size,
                         by = d.by}
    end
    while #out > 8 do table.remove(out, 1) end
    return out
end

-- ------------------------------------------------------------------------------------------ MobsList
local function info_of(e)
    local mt = editor.meters_of(e)
    local t = MT.ents[e.eid] or {}
    local st = t.st or {}
    local vm = MT.svc and MT.svc[e.owner] or nil
    local kv = STORE.kv_usage(e.eid) or 0
    local code = e.code or ""
    return {eid = e.eid, name = clip(e.name, 32), status = editor.shown_status(e),
            pos = {x = e.pos.x, y = e.pos.y, z = e.pos.z}, loaded = M.loaded(e),
            credits_min = mt.credits_min or 0, fuel_min = mt.fuel_min or 0, kv_bytes = min(kv, 4294967295),
            vm_heap = vm and tonumber(vm.lua_heap) or -1, run_ticks = t.ticks or 0,
            errors = (st.error or 0) + (st.killed or 0), code_fnv = fnv(e), code_size = #code,
            versions = min(#M.versions_of(e.eid), 65535), error = clip(e.error, 128)}
end

local function list_msg(sess, seq)
    local mobs = {}
    for _, e in pairs(S.ents) do
        if is_bench(e) and e.owner_acct == sess.account then mobs[#mobs + 1] = e end
    end
    table.sort(mobs, function(a, b) return a.eid < b.eid end)
    local out = {}
    for i = 1, min(#mobs, cfg.list_max) do out[i] = info_of(mobs[i]) end
    return {seq = seq or 0, tick = S.tick, mobs = out, dead = dead_list(sess.account)}
end

local function send_list(sess, seq)
    ST.stats.lists = ST.stats.lists + 1
    net.send_client(sess.gw, sess.sid, "MobsList", list_msg(sess, seq))
end

function M.MobsRequest(sess, m)
    editor.bill(sess)
    if not editor.bucket(sess, "req_b", editor.cfg.req_rate, editor.cfg.req_burst) then
        return reply(sess, m.seq, OP.mobs, 0, 9)
    end
    sess.b1_watch = m.watch and true or nil
    send_list(sess, m.seq)
end

-- ------------------------------------------------------------------------------------------ MobAction
local function restores_ok(sess)
    local now = S.tick
    local keep = {}
    for _, t in ipairs(sess.b1_restores or {}) do if now - t < 1200 then keep[#keep + 1] = t end end
    sess.b1_restores = keep
    return #keep < cfg.restores_per_min
end

local function issue_token(sess, seq, eid, op, text)
    local tok = math.random(1, 2147483646)
    sess.b1_tok = {token = tok, eid = eid, op = op, exp = S.tick + cfg.confirm_ticks, seq = seq}
    ST.stats.confirms = ST.stats.confirms + 1
    net.send_client(sess.gw, sess.sid, "MobConfirm", {seq = seq, eid = eid, op = op, token = tok,
                                                      expires_tick = sess.b1_tok.exp, text = clip(text, 128)})
    return reply(sess, seq, ACT_OP[op], eid, CODE.confirm, "confirm: " .. text)
end

local function take_token(sess, m)
    local t = sess.b1_tok
    if not t or t.token ~= m.token or t.eid ~= m.eid or t.op ~= m.op or S.tick > t.exp then return false end
    sess.b1_tok = nil
    return true
end

local function fmt_pos(p) return string.format("%.1f,%.1f,%.1f", p.x or p[1], p.y or p[2], p.z or p[3]) end

local function do_rescue(sess, m, e)
    local p, code = rescue_target(e)
    if not p then return reply(sess, m.seq, OP.rescue, e.eid, code) end
    local from = {x = e.pos.x, y = e.pos.y, z = e.pos.z}
    if e.holder then editor.drop_hold(e, "rescued") end
    e.pos.x, e.pos.y, e.pos.z = p.x, p.y, p.z
    e.vel.x, e.vel.y, e.vel.z = 0, 0, 0
    ST.stats.rescues = ST.stats.rescues + 1
    editor.console_add(e, 2, string.format("rescued by %s: %s -> %s", sess.name, fmt_pos(from), fmt_pos(p)))
    log("eid=%d rescued by %s (%s): %s -> %s", e.eid, sess.name, sess.account, fmt_pos(from), fmt_pos(p))
    send_owner(e, "MobRescued", {eid = e.eid, pos = {x = p.x, y = p.y, z = p.z}, from = from, by = clip(sess.name, 32)}, sess)
    return reply(sess, m.seq, OP.rescue, e.eid, 0, "rescued to " .. fmt_pos(p))
end

local function do_destroy(sess, m, e)
    editor.delete_entity(e, sess.name .. " (" .. sess.account .. ", mobs panel)")
    ST.stats.destroys = ST.stats.destroys + 1
    return reply(sess, m.seq, OP.destroy, m.eid, 0, "destroyed")
end

local function restore_pos(sess, d)
    local p = d.pos
    if p and loaded_at(p[1], p[2], p[3]) and safe_at(p[1], p[2], p[3]) == true then return {x = p[1], y = p[2], z = p[3]} end
    local yaw = math.rad(sess.rot.x or 0)
    local px, pz = sess.pos.x - math.sin(yaw) * 2, sess.pos.z - math.cos(yaw) * 2
    local sp, area = S.spawn, editor.cfg.area - 1
    local dx, dz = px - sp.x, pz - sp.z
    local r = sqrt(dx * dx + dz * dz)
    if r > area then px, pz = sp.x + dx / r * area, sp.z + dz / r * area end
    return {x = px, y = max(1, min(255, sess.pos.y + 1.0)), z = pz}
end

local function do_restore(sess, m, d, l, i)
    if not restores_ok(sess) then return reply(sess, m.seq, OP.restore, m.eid, CODE.limit, "restores: " .. cfg.restores_per_min .. " a minute") end
    local pos = restore_pos(sess, d)
    local eid, code, reason = STORE.restore(d.blob, {owner = d.account ~= "_world" and d.account or nil, pos = pos})
    if not eid then
        return reply(sess, m.seq, OP.restore, m.eid, CODE.store, string.format("store refused %s: %s", tostring(code), tostring(reason)))
    end
    table.remove(l, i)
    sess.b1_restores[#sess.b1_restores + 1] = S.tick
    ST.stats.restores = ST.stats.restores + 1
    dirty()
    local e = S.ents[eid]
    if e then
        editor.console_add(e, 2, string.format("restored from the last state of #%d by %s", d.eid, sess.name))
        editor.meta_changed(e)
        editor.push_state(e)
    end
    log("eid=%d restored as eid=%d by %s (%s) at %s", d.eid, eid, sess.name, sess.account, fmt_pos(pos))
    net.send_client(sess.gw, sess.sid, "MobRestored", {seq = m.seq, src_eid = d.eid, eid = eid,
                                                       name = clip(e and e.name or d.name, 32), code_fnv = e and fnv(e) or d.code_fnv})
    return reply(sess, m.seq, OP.restore, eid, 0, "restored #" .. eid)
end

function M.MobAction(sess, m)
    editor.bill(sess)
    local op = ACT_OP[m.op]
    if not op then return reply(sess, m.seq, OP.mobs, m.eid, 15, "bad op") end
    if not editor.bucket(sess, "req_b", editor.cfg.req_rate, editor.cfg.req_burst) then return reply(sess, m.seq, op, m.eid, 9) end
    if m.op == 3 then
        local d, l, i = dead_find(sess.account, m.eid, editor.is_admin(sess))
        if not d then
            local any = dead_find(nil, m.eid, true)
            if any then return reply(sess, m.seq, op, m.eid, 3, "forbidden: not your mob") end
            return reply(sess, m.seq, op, m.eid, CODE.nothing)
        end
        if m.token == 0 then
            if not restores_ok(sess) then return reply(sess, m.seq, op, m.eid, CODE.limit, "restores: " .. cfg.restores_per_min .. " a minute") end
            return issue_token(sess, m.seq, m.eid, 3, string.format("restore %s (#%d, %d B) as a new mob", d.name, d.eid, d.size))
        end
        if not take_token(sess, m) then return reply(sess, m.seq, op, m.eid, CODE.bad_token) end
        return do_restore(sess, m, d, l, i)
    end
    local e = S.ents[m.eid]
    if not e then return reply(sess, m.seq, op, m.eid, 1) end
    if not is_bench(e) then return reply(sess, m.seq, op, m.eid, 2) end
    local ok, why = P.allowed(sess, e, m.op == 1 and "move" or "destroy")
    if not ok then return reply(sess, m.seq, op, m.eid, 3, why) end
    if m.op == 1 then
        local p, code = rescue_target(e)
        if not p then return reply(sess, m.seq, op, m.eid, code) end
        if m.token == 0 then
            return issue_token(sess, m.seq, m.eid, 1, string.format("move %s back to %s (now %s)", tostring(e.name), fmt_pos(p), fmt_pos(e.pos)))
        end
        if not take_token(sess, m) then return reply(sess, m.seq, op, m.eid, CODE.bad_token) end
        return do_rescue(sess, m, e)
    end
    if m.token == 0 then
        return issue_token(sess, m.seq, m.eid, 2, string.format("destroy %s (#%d); the last state stays restorable", tostring(e.name), e.eid))
    end
    if not take_token(sess, m) then return reply(sess, m.seq, op, m.eid, CODE.bad_token) end
    return do_destroy(sess, m, e)
end

-- ------------------------------------------------------------------------------------------ profile / history
function M.MobProfileRequest(sess, m)
    local e = editor.target(sess, m.seq, OP.profile, m.eid, false, "read_code")
    if not e then return end
    local mt = editor.meters_of(e)
    local t = MT.ents[e.eid] or {}
    local st = t.st or {}
    local vm = MT.svc and MT.svc[e.owner] or nil
    local used, _, keys = STORE.kv_usage(e.eid)
    local errs = {}
    for _, l in ipairs(e.console or {}) do
        if l.kind == 1 then errs[#errs + 1] = clip(l.text, 160) end
    end
    while #errs > 4 do table.remove(errs, 1) end
    ST.stats.profiles = ST.stats.profiles + 1
    net.send_client(sess.gw, sess.sid, "MobProfile", {seq = m.seq, eid = e.eid, owner = clip(e.owner_acct, 64),
        perms = clip(P.describe_rules(e), 160), code_fnv = fnv(e), code_size = #(e.code or ""),
        versions = min(#M.versions_of(e.eid), 65535), run_ticks = t.ticks or 0, errors = (st.error or 0) + (st.killed or 0),
        kv_bytes = min(used or 0, 4294967295), kv_keys = min(keys or 0, 65535), vm_heap = vm and tonumber(vm.lua_heap) or -1,
        credits_min = mt.credits_min or 0, fuel_min = mt.fuel_min or 0,
        forked_from = e.forked_from and e.forked_from.eid or 0, last_errors = errs})
    reply(sess, m.seq, OP.profile, e.eid, 0)
end

function M.CodeHistoryRequest(sess, m)
    local e = editor.target(sess, m.seq, OP.history, m.eid, false, "read_code")
    if not e then return end
    ST.stats.histories = ST.stats.histories + 1
    net.send_client(sess.gw, sess.sid, "CodeHistory", history_msg(e.eid, m.seq))
    reply(sess, m.seq, OP.history, e.eid, 0)
end

local function version_find(eid, n)
    for _, it in ipairs(M.versions_of(eid)) do if it.n == n then return it end end
    return nil
end

function M.CodeVersionOp(sess, m)
    if m.op == 1 then
        local e = editor.target(sess, m.seq, OP.version, m.eid, false, "read_code")
        if not e then return end
        local it = version_find(e.eid, m.n)
        if not it then return reply(sess, m.seq, OP.version, e.eid, CODE.no_version) end
        ST.stats.version_opens = ST.stats.version_opens + 1
        net.send_client(sess.gw, sess.sid, "CodeVersionText", {seq = m.seq, eid = e.eid, n = it.n, fnv = it.fnv, code = it.code})
        return reply(sess, m.seq, OP.version, e.eid, 0, "version #" .. it.n)
    elseif m.op == 2 then
        local e = editor.target(sess, m.seq, OP.version, m.eid, true, "edit_code")
        if not e then return end
        local it = version_find(e.eid, m.n)
        if not it then return reply(sess, m.seq, OP.version, e.eid, CODE.no_version) end
        e.code = it.code
        editor.mark_dirty()
        ST.stats.version_restores = ST.stats.version_restores + 1
        editor.console_add(e, 2, string.format("code restored to version #%d (fnv %d) by %s", it.n, it.fnv, sess.name))
        M.on_code_saved(e, sess, "restore of #" .. it.n)
        reply(sess, m.seq, OP.version, e.eid, 0, "restored version #" .. it.n)
        editor.push_state(e)
        push_history(e, sess, m.seq)
        return
    end
    editor.bill(sess)
    return reply(sess, m.seq, OP.version, m.eid, 15, "bad op")
end

-- ------------------------------------------------------------------------------------------ tick / lifecycle
function M.init(srv, ed, sb)
    server, editor, sandbox, S = srv, ed, sb, srv.S
    -- the code history travels with the A4 snapshot (Spammer, B1 last-state slot) and comes back on restore
    if type(STORE.snapshot_hooks) == "table" then
        STORE.snapshot_hooks.b1_versions = {
            save = function(e)
                local v = ST.versions[e.eid]
                return v and {next = v.next, items = v.items} or nil
            end,
            load = function(e, t)
                if type(t) == "table" and type(t.items) == "table" then
                    ST.versions[e.eid] = {next = tonumber(t.next) or (#t.items + 1), items = t.items}
                    dirty()
                end
            end,
        }
    end
    load_file()
    -- histories of entities that are gone (crash between a delete and the file write) are dropped
    for eid in pairs(ST.versions) do if not S.ents[eid] then ST.versions[eid] = nil end end
    for _, e in pairs(S.ents) do if is_bench(e) then sample(e) end end
end

function M.tick()
    if S.tick % cfg.safe_every == 0 then
        for _, e in pairs(S.ents) do if is_bench(e) then sample(e) end end
    end
    if S.tick % cfg.watch_every == 0 then
        for _, s in pairs(S.sessions) do
            if s.b1_watch then ST.stats.watch_lists = ST.stats.watch_lists + 1; send_list(s, 0) end
        end
    end
    if ST.dirty and S.tick - ST.written_tick >= cfg.file_every then save_file() end
end

function M.flush() if ST.dirty then save_file() end end

-- ------------------------------------------------------------------------------------------ admin / tests
function M.register_commands()
    console.add_command("mobs_status", "UX B1: my-mobs counters (lists, confirms, rescues, destroys, restores, commits)",
        function() return "[olife_world] " .. M.status() end)
    console.add_command("mob_safe eid:int", "UX B1: safe-position ring of a bench and its rescue target", function(args)
        local e = S.ents[args[1]]
        if not is_bench(e) then return "[olife_world] mob_safe: no bench eid=" .. tostring(args[1]) end
        local r = e.b1 or {ring = {}, n = 0, i = 0}
        local p, code = rescue_target(e)
        local l = {}
        for k = 0, (r.n or 0) - 1 do
            local x = r.ring[(r.i - 1 - k) % cfg.ring + 1]
            if x then l[#l + 1] = string.format("%.2f,%.2f,%.2f@%d", x.x, x.y, x.z, x.tick) end
        end
        return string.format("[olife_world] mob_safe eid=%d pos=%.3f,%.3f,%.3f loaded=%s safe_now=%s n=%d target=%s code=%s ring=%s",
            e.eid, e.pos.x, e.pos.y, e.pos.z, tostring(M.loaded(e)), tostring(safe_at(e.pos.x, e.pos.y, e.pos.z)), r.n or 0,
            p and string.format("%.3f,%.3f,%.3f", p.x, p.y, p.z) or "-", tostring(code or 0), table.concat(l, ";"))
    end)
    console.add_command("mob_dead account:str", "UX B1: last-state slots of an account", function(args)
        local l = {}
        for _, d in ipairs(ST.dead[args[1]] or {}) do
            l[#l + 1] = string.format("%d:%s:fnv=%d:size=%d:by=%s:tick=%d", d.eid, d.name, d.code_fnv, d.size, (d.by or ""):gsub(" ", "_"), d.tick)
        end
        return string.format("[olife_world] mob_dead account=%s n=%d %s", args[1], #l, table.concat(l, " "))
    end)
    console.add_command("mob_versions eid:int", "UX B1: code commits of a bench", function(args)
        local l = {}
        for _, it in ipairs(M.versions_of(args[1])) do
            l[#l + 1] = string.format("%d:fnv=%d:size=%d:by=%s:note=%s", it.n, it.fnv, it.size, it.author, (it.note or ""):gsub(" ", "_"))
        end
        return string.format("[olife_world] mob_versions eid=%d n=%d %s", args[1], #l, table.concat(l, " "))
    end)
    console.add_command("mobs_flush", "UX B1: write world:olife_mobs.json now", function() save_file(); return "[olife_world] mobs_flush ok" end)
end

function M.status()
    local s = ST.stats
    local r = {}
    for c, n in pairs(s.refused) do r[#r + 1] = c .. ":" .. n end
    table.sort(r)
    local nd, nv = 0, 0
    for _, l in pairs(ST.dead) do nd = nd + #l end
    for _ in pairs(ST.versions) do nv = nv + 1 end
    return string.format("mobs(lists=%d,watch=%d,confirms=%d,rescues=%d,destroys=%d,restores=%d,profiles=%d,histories=%d," ..
        "version_opens=%d,version_restores=%d,commits=%d,dead_saved=%d,dead=%d,histories_kept=%d,samples=%d,refused={%s})",
        s.lists, s.watch_lists, s.confirms, s.rescues, s.destroys, s.restores, s.profiles, s.histories, s.version_opens,
        s.version_restores, s.commits, s.dead_saved, nd, nv, s.samples, table.concat(r, ","))
end

return M
