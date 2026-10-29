-- olife_world:spammer — UX B2 (03.10, olife_b2): the Spammer tool (OLIFE_UX §3), the world side.
-- LMB with the Spammer = SpamCapture{target, origin, dir}: the world raycasts (as ToolUse), checks the `clone` right
-- (A1 perms: owner / admin always), takes the full snapshot of the mob (A4 store.snapshot: code, KV memory, look,
-- script appearance, asset refs, rights, run status) and keeps it in the SENDER's library on the world
-- (store.snap_put: quota snap_max / snap_quota, tariff price_snapshot charged to the capturer). The Lua VM state is NOT
-- in it: olife-sandboxd keeps one VM per owner (Snapshot{owner} = the whole owner), a per-entity image does not exist;
-- what survives is what the script put into memory.* (KV). RMB = SpamThrow{id, origin, dir}: a ball (entity kind 5,
-- def olife_client:spam_ball, replicated like any entity) flies by simple ballistics in the tick (phase 3); where it
-- hits a block the world does store.restore(blob, {owner = thrower's account, name = "<snap>#n", pos}) — the same
-- rights (A1 hook), the same run state, the KV copied (the instance's memory counters go on independently). Limits:
-- spawn_per_min per owner (52), mobs_max benches per owner (53), the restore's own asset quota / credits (43/44/47).
-- Every answer is a SpamReply{seq, op, id, eid, code, reason}; the library goes as SpamList; ball events as SpamBall.
local net = require "olife_world:net"
local LOOKS = require "olife_proto:looks"
local ED = require "olife_world:editor"
local P = require "olife_world:perms"
local STORE = require "olife_world:store"
local U = require "olife_proto:util"

local M = {}
local server, sandbox, S
local floor, sqrt, min, max = math.floor, math.sqrt, math.min, math.max

M.OP = {capture = 1, throw = 2, list = 3, rename = 4, delete = 5}
local OP = M.OP
M.CODE = {no_snapshot = 50, snap_quota = 51, spawn_rate = 52, mob_limit = 53, bad_throw = 54}
local C = M.CODE
local REASON = {[0] = "ok", [1] = "no such entity", [2] = "not a scripted entity", [3] = "forbidden", [6] = "out of reach",
                [7] = "ray missed the target", [9] = "rate limit", [14] = "bad origin/dir", [15] = "bad name/op",
                [50] = "no such snapshot", [51] = "snapshot quota (count or bytes)", [52] = "spawn rate (per minute)",
                [53] = "mob limit (benches of the owner)", [54] = "bad throw"}
M.REASON = REASON

local cfg = {
    ball_speed = 12.0,        -- blocks/s along the look direction
    ball_up = 2.0,            -- extra upward speed: a horizontal throw arcs
    gravity = 20.0,           -- blocks/s^2
    substeps = 4,             -- collision steps per tick
    ball_max_ticks = 100,     -- 5 s of flight at most -> lost (54)
    ball_start = 0.8,         -- blocks in front of the eye
    origin_slack = 3.0,       -- client eye vs the world's player position (as ToolUse)
}
M.cfg = cfg

local ST = {balls = {}, events = {}, spawns = {}, q = {}, next_ball = 0,
            stats = {captures = 0, throws = 0, landed = 0, lost = 0, lists = 0, renames = 0, deletes = 0, refused = {},
                     capture_ms = 0, throw_ms = 0, land_ms = 0, flight_ticks = 0}}
M.ST = ST

local function log(fmt, ...) print("[olife_world] spammer: " .. string.format(fmt, ...)) end
local function now_ms() return U.now_ms() end           -- precise wall clock (time.uptime is coarse headless)

function M.init(srv, sb)
    server, sandbox, S = srv, sb, srv.S
end

-- the same chunk key as olife_world:server (ckey) — balls are replicated by chunk interest like every entity
local function ckey_of(x, z)
    return (floor(x / 16) + 32768) * 65536 + (floor(z / 16) + 32768)
end

local function reply(sess, seq, op, id, eid, code, reason)
    if code ~= 0 then ST.stats.refused[code] = (ST.stats.refused[code] or 0) + 1 end
    net.send_client(sess.gw, sess.sid, "SpamReply", {seq = seq, op = op, id = id or 0, eid = eid or 0, code = code,
                                                     reason = tostring(reason or REASON[code] or STORE.REASON[code] or "?"):sub(1, 128)})
    return code == 0
end

local function norm(v)
    local l = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    if l ~= l or l < 1e-6 or l == math.huge then return nil end
    return {x = v.x / l, y = v.y / l, z = v.z / l}
end

local function mobs_of(account)
    local n = 0
    for _, e in pairs(S.ents) do
        if ED.is_bench(e) and e.owner_acct == account then n = n + 1 end
    end
    return n
end
M.mobs_of = mobs_of

local function spawns_min(account)
    local l = ST.spawns[account] or {}
    local keep = {}
    for _, t in ipairs(l) do if S.tick - t < 1200 then keep[#keep + 1] = t end end
    ST.spawns[account] = keep
    return #keep
end

-- ------------------------------------------------------------------------------------------ library
local function list_msg(sess, seq)
    local acct = sess.account
    local q = STORE.snap_quota(acct)
    local snaps = {}
    for _, r in ipairs(STORE.snap_list(acct)) do
        if #snaps >= 64 then break end
        snaps[#snaps + 1] = {id = r.id, name = (r.name or ""):sub(1, 32), size = r.size or 0, tick = r.tick or 0,
                             ms = r.ms or 0, ver = min(r.ver or 1, 65535), spawned = r.spawned or 0,
                             status = r.status == "run" and 1 or 0, model = (r.model or ""):sub(1, 32),
                             texture = (r.texture or ""):sub(1, 64), code_fnv = r.code_fnv or 0, src_eid = r.src_eid or 0,
                             src_name = (r.src_name or ""):sub(1, 32), src_owner = (r.src_owner or ""):sub(1, 64)}
    end
    return {seq = seq or 0, account = acct:sub(1, 64), snaps = snaps, count = min(q.count, 65535),
            max_count = min(q.max_count, 65535), used = q.used, quota = q.quota, spawns_min = min(spawns_min(acct), 65535),
            spawn_limit = min(STORE.T.spawn_per_min, 65535), mobs = min(mobs_of(acct), 65535),
            mobs_max = min(STORE.T.mobs_max, 65535)}
end

function M.send_list(sess, seq)
    ST.stats.lists = ST.stats.lists + 1
    net.send_client(sess.gw, sess.sid, "SpamList", list_msg(sess, seq))
end

local function push_list(account)
    for _, s in pairs(S.sessions) do
        if s.account == account then M.send_list(s, 0) end
    end
end

-- the capture itself (also the admin command): -> id | nil, code, reason
function M.capture(account, e, by_name)
    local t0 = now_ms()
    local owner = STORE.acct_of(e)
    if not STORE.charge(account, STORE.T.price_snapshot) then return nil, 44, STORE.REASON[44] end
    local q = STORE.snap_quota(account)
    if q.count + 1 > q.max_count then return nil, C.snap_quota, "snapshot quota: " .. q.max_count .. " snapshots" end
    local blob, n, reason = STORE.snapshot(e.eid, {charge = false, pin = false})
    if not blob then return nil, n, reason end
    if q.used + #blob > q.quota then return nil, C.snap_quota, ("snapshot quota: %d + %d > %d bytes"):format(q.used, #blob, q.quota) end
    local id, code, why = STORE.snap_put(account, blob, {name = e.name, src_eid = e.eid, src_name = e.name, src_owner = owner,
                                                         code_fnv = ED.fnv_str(e.code or "")})
    if not id then return nil, code == 43 and C.snap_quota or code, why end
    ST.stats.captures = ST.stats.captures + 1
    ST.stats.capture_ms = now_ms() - t0
    ED.console_add(e, 2, ("captured by %s (snapshot #%d, %d bytes)"):format(tostring(by_name or account), id, #blob))
    log("captured eid=%d (%s, owner %s) by %s -> snapshot #%d %d bytes in %.2f ms", e.eid, tostring(e.name), owner,
        tostring(by_name or account), id, #blob, ST.stats.capture_ms)
    return id, 0, #blob
end

function M.SpamCapture(sess, m)
    ED.bill(sess)
    if not ED.bucket(sess, "req_b", ED.cfg.req_rate, ED.cfg.req_burst) then return reply(sess, m.seq, OP.capture, 0, m.target, 9) end
    local d = norm(m.dir)
    if not d then return reply(sess, m.seq, OP.capture, 0, m.target, 14) end
    local o = m.origin
    local dx, dy, dz = o.x - sess.pos.x, o.y - sess.pos.y, o.z - sess.pos.z
    if dx * dx + dy * dy + dz * dz > cfg.origin_slack * cfg.origin_slack then
        return reply(sess, m.seq, OP.capture, 0, m.target, 14, "origin too far from the player")
    end
    local e = ED.raycast(o, d)
    if not e then
        local t = S.ents[m.target]
        if t and t.kind == 3 then
            local ex, ey, ez = t.pos.x - o.x, t.pos.y - o.y, t.pos.z - o.z
            if ex * ex + ey * ey + ez * ez > ED.cfg.reach * ED.cfg.reach then return reply(sess, m.seq, OP.capture, 0, m.target, 6) end
        end
        return reply(sess, m.seq, OP.capture, 0, m.target, 7)
    end
    if m.target ~= 0 and m.target ~= e.eid then return reply(sess, m.seq, OP.capture, 0, m.target, 7, "ray hit eid " .. e.eid) end
    if not ED.is_bench(e) then return reply(sess, m.seq, OP.capture, 0, e.eid, 2) end
    local ok, why = P.allowed(sess, e, "clone")
    if not ok then return reply(sess, m.seq, OP.capture, 0, e.eid, 3, why) end
    local id, code, extra = M.capture(sess.account, e, sess.name)
    if not id then return reply(sess, m.seq, OP.capture, 0, e.eid, code, extra) end
    reply(sess, m.seq, OP.capture, id, e.eid, 0, ("captured #%d (%d bytes)"):format(id, extra))
    M.send_list(sess, m.seq)
end

-- ------------------------------------------------------------------------------------------ throw / balls
local function area_clamp(x, z)
    local sp, area = S.spawn, ED.cfg.area - 1
    local dx, dz = x - sp.x, z - sp.z
    local r = sqrt(dx * dx + dz * dz)
    if r > area then return nil end
    return x, z
end

local function block_at(x, y, z)
    if y < 0 or y > 255 then return 0 end
    local ok, id = pcall(block.get, floor(x), floor(y), floor(z))
    if not ok then return -1 end
    return id
end

-- spawn an instance of snapshot `rec` (owner = library owner) at the free cell containing p -> eid | nil, code, reason
function M.spawn_from(account, id, rec, p, name)
    local t0 = now_ms()
    local x, z = area_clamp(p.x, p.z)
    if not x then return nil, C.bad_throw, "outside the play area" end
    local pos = {x = floor(p.x) + 0.5, y = max(1, min(254, floor(p.y))) + 0.5, z = floor(p.z) + 0.5}
    if block_at(pos.x, pos.y, pos.z) ~= 0 then return nil, C.bad_throw, "landing cell is not free" end
    if spawns_min(account) >= STORE.T.spawn_per_min then return nil, C.spawn_rate, ("spawn rate: %d a minute"):format(STORE.T.spawn_per_min) end
    if mobs_of(account) >= STORE.T.mobs_max then return nil, C.mob_limit, ("mob limit: %d benches"):format(STORE.T.mobs_max) end
    local n = (rec.spawned or 0) + 1
    local base = (name ~= nil and name ~= "") and name or (rec.name or "snap")
    local suffix = "#" .. n
    local full = base:sub(1, 32 - #suffix) .. suffix
    local eid, code, reason = STORE.restore(rec.blob, {owner = account, name = full, pos = pos})
    if not eid then return nil, code, reason end
    local e = S.ents[eid]
    if e then
        e.spawned_from = {id = id, n = n, owner = account, src_eid = rec.src_eid, src_name = rec.src_name}
        ED.console_add(e, 2, ("spawned from snapshot #%d (%s) by %s, instance #%d"):format(id, tostring(rec.src_name), account, n))
        ED.meta_changed(e)
    end
    STORE.snap_bump(account, id)
    local l = ST.spawns[account] or {}
    l[#l + 1] = S.tick
    ST.spawns[account] = l
    ST.stats.landed = ST.stats.landed + 1
    ST.stats.land_ms = now_ms() - t0
    log("spawned eid=%d %s from snapshot #%d of %s at %.1f,%.1f,%.1f in %.2f ms (status %s)", eid, full, id, account,
        pos.x, pos.y, pos.z, ST.stats.land_ms, tostring(e and e.status))
    return eid, 0, n
end

local function event(b, state, spawned_eid)
    ST.events[#ST.events + 1] = {eid = b.eid, state = state, thrower = b.thrower, snap = b.snap_name,
                                 pos = {x = b.pos.x, y = b.pos.y, z = b.pos.z}, spawned_eid = spawned_eid or 0,
                                 tick = S.tick, ck = ckey_of(b.pos.x, b.pos.z), sess_key = b.sess_key}
end

local function finish_ball(b, state, code, reason, spawned_eid, n)
    ST.balls[b.eid] = nil
    server.remove_entity(b.eid)
    event(b, state, spawned_eid)
    ST.stats.flight_ticks = ST.stats.flight_ticks + b.ticks
    local s = S.sessions[b.sess_key]
    if s then
        if code == 0 then
            reply(s, b.seq, OP.throw, b.snap_id, spawned_eid, 0, ("spawned #%d"):format(n or 0))
            M.send_list(s, 0)
        else
            reply(s, b.seq, OP.throw, b.snap_id, 0, code, reason)
        end
    end
end

local function land(b, p)
    local eid, code, reason = M.spawn_from(b.owner, b.snap_id, b.rec, p, b.name)
    if eid then
        finish_ball(b, 2, 0, nil, eid, reason)
    else
        ST.stats.lost = ST.stats.lost + 1
        log("ball eid=%d of %s: landing refused %d %s", b.eid, b.owner, code, tostring(reason))
        finish_ball(b, 3, code, reason)
    end
end

function M.SpamThrow(sess, m)
    local t0 = now_ms()
    ED.bill(sess)
    if not ED.bucket(sess, "req_b", ED.cfg.req_rate, ED.cfg.req_burst) then return reply(sess, m.seq, OP.throw, m.id, 0, 9) end
    local rec = STORE.snap_get(sess.account, m.id)
    if not rec or not rec.blob then return reply(sess, m.seq, OP.throw, m.id, 0, C.no_snapshot) end
    if m.name ~= "" and not LOOKS.valid_name(m.name) then return reply(sess, m.seq, OP.throw, m.id, 0, 15, "bad name") end
    local d = norm(m.dir)
    if not d then return reply(sess, m.seq, OP.throw, m.id, 0, 14) end
    local o = m.origin
    local dx, dy, dz = o.x - sess.pos.x, o.y - sess.pos.y, o.z - sess.pos.z
    if dx * dx + dy * dy + dz * dz > cfg.origin_slack * cfg.origin_slack then
        return reply(sess, m.seq, OP.throw, m.id, 0, 14, "origin too far from the player")
    end
    -- limits before the ball flies (the restore itself re-checks them when it lands)
    if spawns_min(sess.account) >= STORE.T.spawn_per_min then
        require("olife_world:fraud").event(sess, "spawn")          -- antifraud: spawn spam
        return reply(sess, m.seq, OP.throw, m.id, 0, C.spawn_rate, ("spawn rate: %d a minute"):format(STORE.T.spawn_per_min))
    end
    if mobs_of(sess.account) >= STORE.T.mobs_max then
        return reply(sess, m.seq, OP.throw, m.id, 0, C.mob_limit, ("mob limit: %d benches"):format(STORE.T.mobs_max))
    end
    local code, why = STORE.snap_can_restore(sess.account, rec.blob)
    if code ~= 0 then return reply(sess, m.seq, OP.throw, m.id, 0, code, why) end
    local start = {x = o.x + d.x * cfg.ball_start, y = o.y + d.y * cfg.ball_start, z = o.z + d.z * cfg.ball_start}
    local bid = block_at(start.x, start.y, start.z)
    if bid ~= 0 then return reply(sess, m.seq, OP.throw, m.id, 0, C.bad_throw, bid == -1 and "chunk not loaded" or "the ball starts inside a block") end
    local e = server.new_entity(5, "olife_client:spam_ball", (rec.name or "snap"):sub(1, 32), 0, start)
    local b = {eid = e.eid, ent = e, owner = sess.account, sess_key = sess.key, thrower = sess.name, seq = m.seq,
               snap_id = m.id, rec = rec, snap_name = rec.name or "", name = m.name, pos = e.pos,
               vel = {x = d.x * cfg.ball_speed, y = d.y * cfg.ball_speed + cfg.ball_up, z = d.z * cfg.ball_speed},
               ticks = 0, at = S.tick}
    ST.balls[e.eid] = b
    ST.stats.throws = ST.stats.throws + 1
    ST.stats.throw_ms = now_ms() - t0
    event(b, 1, 0)
    log("ball eid=%d thrown by %s (%s) snapshot #%d from %.1f,%.1f,%.1f", e.eid, sess.name, sess.account, m.id, start.x, start.y, start.z)
    reply(sess, m.seq, OP.throw, m.id, e.eid, 0, "thrown")
end

-- phase 3: ballistics of the balls (substeps; a block cell hit = landing at the last free position)
local function step_balls()
    local dt = 0.05 / cfg.substeps
    for eid, b in pairs(ST.balls) do
        b.ticks = b.ticks + 1
        local p, v = b.pos, b.vel
        local done = false
        for _ = 1, cfg.substeps do
            v.y = v.y - cfg.gravity * dt
            local nx, ny, nz = p.x + v.x * dt, p.y + v.y * dt, p.z + v.z * dt
            local id = block_at(nx, ny, nz)
            if id == -1 or ny < 0 then
                ST.stats.lost = ST.stats.lost + 1
                finish_ball(b, 3, C.bad_throw, "the ball left the loaded world")
                done = true
                break
            elseif id ~= 0 then
                land(b, {x = p.x, y = p.y, z = p.z})
                done = true
                break
            end
            p.x, p.y, p.z = nx, ny, nz
            b.ent.rot.y = (b.ent.rot.y + 18) % 360
        end
        if not done and b.ticks >= cfg.ball_max_ticks then
            ST.stats.lost = ST.stats.lost + 1
            finish_ball(b, 3, C.bad_throw, "the ball never landed")
        end
    end
end

-- ------------------------------------------------------------------------------------------ library ops
function M.SpamSlotOp(sess, m)
    ED.bill(sess)
    if not ED.bucket(sess, "req_b", ED.cfg.req_rate, ED.cfg.req_burst) then return reply(sess, m.seq, OP.list, m.id, 0, 9) end
    if m.op == 1 then
        reply(sess, m.seq, OP.list, 0, 0, 0, "list")
        return M.send_list(sess, m.seq)
    elseif m.op == 2 then
        if not LOOKS.valid_name(m.name) then return reply(sess, m.seq, OP.rename, m.id, 0, 15, "bad name") end
        local code = STORE.snap_rename(sess.account, m.id, m.name)
        if code ~= 0 then return reply(sess, m.seq, OP.rename, m.id, 0, code == 47 and C.no_snapshot or code) end
        ST.stats.renames = ST.stats.renames + 1
        reply(sess, m.seq, OP.rename, m.id, 0, 0, "renamed")
        return push_list(sess.account)
    elseif m.op == 3 then
        local code = STORE.snap_delete(sess.account, m.id)
        if code ~= 0 then return reply(sess, m.seq, OP.delete, m.id, 0, code == 47 and C.no_snapshot or code) end
        ST.stats.deletes = ST.stats.deletes + 1
        reply(sess, m.seq, OP.delete, m.id, 0, 0, "deleted")
        return push_list(sess.account)
    end
    return reply(sess, m.seq, OP.list, m.id, 0, 15, "bad op")
end

-- ------------------------------------------------------------------------------------------ tick / replication
function M.tick()
    if next(ST.balls) then step_balls() end
    if #ST.q > 0 then
        local q = ST.q
        ST.q = {}
        for _, a in ipairs(q) do
            if a.op == "capture" then
                local e = S.ents[a.eid]
                if not ED.is_bench(e) then log("spam_capture: no bench eid=%d", a.eid)
                else
                    local id, code, extra = M.capture(a.account, e, "console")
                    log("spam_capture account=%s eid=%d id=%s code=%d %s", a.account, a.eid, tostring(id), code, tostring(extra))
                    push_list(a.account)
                end
            elseif a.op == "spawn" then
                local rec = STORE.snap_get(a.account, a.id)
                if not rec or not rec.blob then log("spam_spawn: no snapshot %s/%d", a.account, a.id)
                else
                    local eid, code, reason = M.spawn_from(a.account, a.id, rec, a.pos, "")
                    log("spam_spawn account=%s id=%d eid=%s code=%d %s", a.account, a.id, tostring(eid), code, tostring(reason))
                    push_list(a.account)
                end
            end
        end
    end
end

-- phase 4, per session: ball events of this tick for the balls in its chunks (the thrower always)
function M.replicate(sess)
    if #ST.events == 0 then return end
    for _, ev in ipairs(ST.events) do
        if ev.tick == S.tick and (sess.chunks[ev.ck] or sess.key == ev.sess_key) then
            net.send_client(sess.gw, sess.sid, "SpamBall", {eid = ev.eid, state = ev.state, thrower = ev.thrower:sub(1, 32),
                snap = ev.snap:sub(1, 32), pos = ev.pos, spawned_eid = ev.spawned_eid, tick = ev.tick})
        end
    end
end

-- after the last session of the tick (server.lua calls it from the tick end): drop the events of this tick
function M.after_replicate()
    if #ST.events > 0 then ST.events = {} end
end

function M.on_session_removed(sess)
    for _, b in pairs(ST.balls) do
        if b.sess_key == sess.key then b.sess_key = "" end   -- the ball still lands; nobody to answer
    end
end

-- balls are not persisted: a world stop drops them (the thrower gets nothing; the snapshot is still in the library)
function M.shutdown()
    for eid, b in pairs(ST.balls) do
        ST.balls[eid] = nil
        server.remove_entity(eid)
    end
end

-- ------------------------------------------------------------------------------------------ admin / tests
function M.register_commands()
    console.add_command("spam_list account:str", "UX B2: snapshot library of an account (JSON)", function(args)
        local l = STORE.snap_list(args[1])
        return string.format("[olife_world] spam_list %s quota=%s snaps=%s", args[1], json.tostring(STORE.snap_quota(args[1])),
            json.tostring(l))
    end)
    console.add_command("spam_capture account:str eid:int", "UX B2 (tests): capture a bench into <account>'s library " ..
        "(no rights check; queued into the tick)", function(args)
        ST.q[#ST.q + 1] = {op = "capture", account = args[1], eid = args[2]}
        return "[olife_world] spam_capture queued"
    end)
    console.add_command("spam_spawn account:str id:int x:num y:num z:num", "UX B2 (tests): spawn an instance of " ..
        "snapshot <id> of <account> at x y z (no ball; queued)", function(args)
        ST.q[#ST.q + 1] = {op = "spawn", account = args[1], id = args[2], pos = {x = args[3], y = args[4], z = args[5]}}
        return "[olife_world] spam_spawn queued"
    end)
    console.add_command("spam_status", "UX B2: spammer counters, balls in flight", function()
        return "[olife_world] " .. M.status()
    end)
    console.add_command("spam_mobs account:str", "UX B2: benches of an account and spawns in the last minute", function(args)
        return string.format("[olife_world] spam_mobs %s mobs=%d spawns_min=%d mobs_max=%d spawn_per_min=%d", args[1],
            mobs_of(args[1]), spawns_min(args[1]), STORE.T.mobs_max, STORE.T.spawn_per_min)
    end)
end

function M.status()
    local s = ST.stats
    local r = {}
    for c, n in pairs(s.refused) do r[#r + 1] = c .. ":" .. n end
    table.sort(r)
    local nb = 0
    for _ in pairs(ST.balls) do nb = nb + 1 end
    return string.format("spammer(captures=%d,throws=%d,landed=%d,lost=%d,balls=%d,lists=%d,renames=%d,deletes=%d," ..
        "capture_ms=%.2f,throw_ms=%.2f,land_ms=%.2f,refused={%s})", s.captures, s.throws, s.landed, s.lost, nb, s.lists,
        s.renames, s.deletes, s.capture_ms, s.throw_ms, s.land_ms, table.concat(r, ","))
end

function M.sup_state()
    local nb = 0
    for _ in pairs(ST.balls) do nb = nb + 1 end
    return {captures = ST.stats.captures, throws = ST.stats.throws, landed = ST.stats.landed, lost = ST.stats.lost, balls = nb}
end

return M
