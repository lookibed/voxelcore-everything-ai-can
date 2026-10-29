-- olife_world:snapdelta — wave 4c: quantised per-session delta snapshots (EntityDelta) instead of EntitySnapshot.
-- Baseline = what THIS session was last sent (TCP is reliable and ordered, so no acks are needed): positions are
-- quantised to 1/256 block (i32 absolute, i8 or i16 delta), rotations to 1/65536 turn (each component only when it
-- changed); an entity whose quantised state did not
-- change is not sent; an entity gets a per-session u16 slot at spawn (moves/despawns carry 2 bytes, not the eid).
-- Every `keyframe` ticks (staggered by session) the session gets every entity in view as an absolute move (`key`).
-- Interest (chunks the session holds) is as before; on top: priority by distance and a byte budget per session and
-- tick (`snap_budget`): despawns always go, then spawns nearest first, then moves by priority
-- (ticks since last sent + 1) / (1 + (d/16)^2), and far entities are sent every 2nd (d > snap_near) or 4th
-- (d > 2*snap_near) tick; what does not fit waits (its baseline stays, the next delta carries
-- the whole change). Keyframes ignore the budget. The view hash uses the DEQUANTISED values both sides compute.
-- Mode `full` (old EntitySnapshot) stays for comparison: `olife.snap full|delta` switches at runtime (each session's
-- view is despawned in the old form and respawned in the new one, so hashes stay equal).
local U = require "olife_proto:util"
local net = require "olife_world:net"
local PF = require "olife_world:prof"   -- wave 5p profiler

local M = {}
local srv, S, cfg
local floor, sqrt = math.floor, math.sqrt
local add32 = U.add32

M.stats = {delta_msgs = 0, delta_bytes = 0, full_bytes = 0, spawns = 0, moves = 0, moves_dp = 0, moves_d8 = 0,
           moves_pa = 0, rot = 0, despawns = 0, deferred = 0, keyframes = 0, budget_hits = 0, resets = 0, decimated = 0}

function M.init(server)
    srv, S, cfg = server, server.S, server.cfg
    cfg.snap = cfg.snap or "full"
    cfg.snap_budget = cfg.snap_budget or 1200
    cfg.keyframe = cfg.keyframe or 100
    cfg.snap_near = cfg.snap_near or 24      -- blocks: every tick within, every 2nd tick within 2x, every 4th beyond
end

local Q = 256
local RQ = 65536 / 360
local RD = 360 / 65536
local function qpos(v) return floor(v * Q + 0.5) end
local function qrot(a) return floor((a % 360) * RQ + 0.5) % 65536 end
M.qpos, M.qrot = qpos, qrot

local function term_of(eid, v)
    return U.entity_term(eid, {x = v.qx / Q, y = v.qy / Q, z = v.qz / Q}, {x = v.rx * RD, y = v.ry * RD, z = v.rz * RD})
end

-- despawn everything of the session's current view (mode switch): full -> EntitySnapshot despawns, delta -> EntityDelta
function M.reset_view(sess)
    M.stats.resets = M.stats.resets + 1
    if sess.snap_mode == "delta" and sess.dview then
        local ds = {}
        for eid, v in pairs(sess.dview) do
            ds[#ds + 1] = v.slot
            sess.ent_hash = add32(sess.ent_hash, 4294967296 - v.term)
        end
        if #ds > 0 then
            local n = net.send_client(sess.gw, sess.sid, "EntityDelta", {tick = S.tick, key = false, spawns = {},
                                                                         moves = {}, despawns = ds})
            M.stats.delta_bytes = M.stats.delta_bytes + n
            sess.bytes = sess.bytes + n
        end
    elseif sess.view then
        local ds = {}
        for eid, v in pairs(sess.view) do
            ds[#ds + 1] = eid
            sess.ent_hash = add32(sess.ent_hash, 4294967296 - v.term)
        end
        if #ds > 0 then
            local n = net.send_client(sess.gw, sess.sid, "EntitySnapshot", {tick = S.tick, spawns = {}, updates = {},
                                                                            despawns = ds})
            M.stats.full_bytes = M.stats.full_bytes + n
            S.stats.snap_bytes = S.stats.snap_bytes + n
            sess.bytes = sess.bytes + n
        end
    end
    sess.view, sess.nview = {}, 0
    sess.dview, sess.dslot_next, sess.dslot_free = {}, 0, {}
end

-- called for every session at the start of its replication: switch mode if the world's mode changed
-- In delta mode sess.view IS sess.dview (both keyed by eid): code that only asks "does this session see eid"
-- (wave 4a editor.replicate: name tags, hold state) works in both modes.
function M.check_mode(sess)
    local want = cfg.snap == "delta" and "delta" or "full"
    if sess.snap_mode == nil then
        sess.snap_mode = want
        sess.dview, sess.dslot_next, sess.dslot_free = sess.dview or {}, 0, {}
    elseif sess.snap_mode ~= want then
        M.reset_view(sess)
        sess.snap_mode = want
    end
    if want == "delta" then sess.view = sess.dview end
    return want
end

local function alloc_slot(sess)
    local f = sess.dslot_free
    if #f > 0 then
        local s = f[#f]
        f[#f] = nil
        return s
    end
    if sess.dslot_next >= 65535 then return nil end
    sess.dslot_next = sess.dslot_next + 1
    return sess.dslot_next
end

local function spawn_size(e)
    return 2 + 4 + 1 + 2 + #e.def + 2 + #(e.name or "") + 4 + 12 + 6
end

-- one session, delta mode (S.ents already have e.ck for this tick)
local replicate_session
function M.replicate_session(sess)
    local t0 = U.now_ms()
    replicate_session(sess)
    M.stats.ms = (M.stats.ms or 0) + U.now_ms() - t0
end
-- Low-allocation version: the live world has a large Lua heap (chunk cache, sandbox results), so every table made
-- here pays for incremental GC over all of it — candidate state lives on the view entries and reused arrays; the
-- per-tick message tables (spawns/moves) are pooled per session; sorting only when the budget is exceeded.
local scand, mcand = {}, {}            -- reused candidate arrays (entities to spawn, view entries to move)
local function by_d2(a, b) if a.q_d2 ~= b.q_d2 then return a.q_d2 < b.q_d2 end return a.eid < b.eid end
local function by_prio(a, b) if a.c_prio ~= b.c_prio then return a.c_prio > b.c_prio end return a.eid < b.eid end

local function move_size(v, key)
    local sz = 2 + 6
    local ddx, ddy, ddz = v.c_qx - v.qx, v.c_qy - v.qy, v.c_qz - v.qz
    if key or ddx < -32768 or ddx > 32767 or ddy < -32768 or ddy > 32767 or ddz < -32768 or ddz > 32767 then
        sz = sz + 12
    elseif v.c_pch then
        if ddx >= -128 and ddx <= 127 and ddy >= -128 and ddy <= 127 and ddz >= -128 and ddz <= 127 then sz = sz + 3
        else sz = sz + 6 end
    end
    if v.c_rx ~= v.rx then sz = sz + 2 end
    if v.c_ry ~= v.ry then sz = sz + 2 end
    if v.c_rz ~= v.rz then sz = sz + 2 end
    return sz
end

function replicate_session(sess)
    local view = sess.dview
    local tick = S.tick
    local px, py, pz = sess.pos.x, sess.pos.y, sess.pos.z
    local key = cfg.keyframe > 0 and (tick + sess.sid * 7) % cfg.keyframe == 0
    local near2 = cfg.snap_near * cfg.snap_near
    local ns, nm = 0, 0
    for eid, e in pairs(S.ents) do
        if eid ~= sess.eid and sess.chunks[e.ck] then
            local dx, dy, dz = e.pos.x - px, e.pos.y - py, e.pos.z - pz
            local d2 = dx * dx + dy * dy + dz * dz
            -- quantised state and its hash term: once per entity per tick (the same for every session)
            if e.q_tick ~= tick then
                e.q_tick = tick
                e.qx, e.qy, e.qz = qpos(e.pos.x), qpos(e.pos.y), qpos(e.pos.z)
                e.qrx, e.qry, e.qrz = qrot(e.rot.x), qrot(e.rot.y), qrot(e.rot.z)
                e.qterm = nil
            end
            local v = view[eid]
            if not v then
                e.q_d2 = d2
                ns = ns + 1
                scand[ns] = e
            else
                v.seen = tick
                local pch = e.qx ~= v.qx or e.qy ~= v.qy or e.qz ~= v.qz
                local rch = e.qrx ~= v.rx or e.qry ~= v.ry or e.qrz ~= v.rz
                -- distance decimation: near every tick, then every 2nd / 4th tick (the client interpolates 3 ticks)
                local every = d2 < near2 and 1 or (d2 < 4 * near2 and 2 or 4)
                if (pch or rch) and not key and tick - v.last < every then
                    M.stats.decimated = M.stats.decimated + 1
                elseif pch or rch or key then
                    v.c_pch = pch
                    v.c_qx, v.c_qy, v.c_qz, v.c_rx, v.c_ry, v.c_rz = e.qx, e.qy, e.qz, e.qrx, e.qry, e.qrz
                    v.c_prio = (tick - v.last + 1) / (1 + d2 / 256)
                    nm = nm + 1
                    mcand[nm] = v
                end
            end
        end
    end
    for i = ns + 1, #scand do scand[i] = nil end
    for i = nm + 1, #mcand do mcand[i] = nil end
    -- despawns: always (entries not seen this tick; new spawns are added after this loop)
    local despawns = sess.d_despawns
    if not despawns then despawns = {}; sess.d_despawns = despawns end
    local nd = 0
    for eid, v in pairs(view) do
        if v.seen ~= tick then
            nd = nd + 1
            despawns[nd] = v.slot
            sess.ent_hash = add32(sess.ent_hash, 4294967296 - v.term)
            view[eid] = nil
            sess.nview = sess.nview - 1
            local f = sess.dslot_free
            f[#f + 1] = v.slot
        end
    end
    for i = nd + 1, #despawns do despawns[i] = nil end
    local budget = key and math.huge or cfg.snap_budget
    local bytes = 4 + 1 + 2 + 2 + 2 + 2 * nd + 7
    -- sort only when everything does not fit
    local total = bytes
    for i = 1, ns do total = total + spawn_size(scand[i]) end
    for i = 1, nm do total = total + move_size(mcand[i], key) end
    if total > budget then
        table.sort(scand, by_d2)
        table.sort(mcand, by_prio)
    end
    local spawns = sess.d_spawns
    if not spawns then spawns = {}; sess.d_spawns = spawns end
    local nsp = 0
    for i = 1, ns do
        local e = scand[i]
        local sz = spawn_size(e)
        if bytes + sz > budget and nsp > 0 then
            M.stats.deferred = M.stats.deferred + 1
            M.stats.budget_hits = M.stats.budget_hits + 1
        else
            local slot = alloc_slot(sess)
            if slot then
                local v = {eid = e.eid, slot = slot, qx = e.qx, qy = e.qy, qz = e.qz, rx = e.qrx, ry = e.qry, rz = e.qrz, last = tick,
                           seen = tick}
                if not e.qterm then e.qterm = term_of(e.eid, v) end
                v.term = e.qterm
                view[e.eid] = v
                sess.nview = sess.nview + 1
                sess.ent_hash = add32(sess.ent_hash, v.term)
                nsp = nsp + 1
                spawns[nsp] = {slot = slot, eid = e.eid, kind = e.kind, def = e.def, name = e.name or "",
                               owner = e.owner or 0, pos = {x = e.qx, y = e.qy, z = e.qz},
                               rot = {x = e.qrx, y = e.qry, z = e.qrz}}
                bytes = bytes + sz
            end
        end
    end
    for i = nsp + 1, #spawns do spawns[i] = nil end
    local moves, pool = sess.d_moves, sess.d_pool
    if not moves then moves, pool = {}, {}; sess.d_moves, sess.d_pool = moves, pool end
    local nmv = 0
    for i = 1, nm do
        local v = mcand[i]
        local sz = move_size(v, key)
        if bytes + sz > budget and not key then
            M.stats.deferred = M.stats.deferred + 1
            M.stats.budget_hits = M.stats.budget_hits + 1
        else
            bytes = bytes + sz
            nmv = nmv + 1
            local mv = pool[nmv]
            if not mv then mv = {d = {}}; pool[nmv] = mv end
            mv.slot, mv.d8, mv.d16, mv.pa, mv.rx, mv.ry, mv.rz = v.slot, nil, nil, nil, nil, nil, nil
            local ddx, ddy, ddz = v.c_qx - v.qx, v.c_qy - v.qy, v.c_qz - v.qz
            local d = mv.d
            if key or ddx < -32768 or ddx > 32767 or ddy < -32768 or ddy > 32767 or ddz < -32768 or ddz > 32767 then
                d.x, d.y, d.z = v.c_qx, v.c_qy, v.c_qz
                mv.pa = d
                M.stats.moves_pa = M.stats.moves_pa + 1
            elseif v.c_pch then
                d.x, d.y, d.z = ddx, ddy, ddz
                if ddx >= -128 and ddx <= 127 and ddy >= -128 and ddy <= 127 and ddz >= -128 and ddz <= 127 then
                    mv.d8 = d
                    M.stats.moves_d8 = M.stats.moves_d8 + 1
                else
                    mv.d16 = d
                    M.stats.moves_dp = M.stats.moves_dp + 1
                end
            end
            if v.c_rx ~= v.rx then mv.rx = v.c_rx end
            if v.c_ry ~= v.ry then mv.ry = v.c_ry end
            if v.c_rz ~= v.rz then mv.rz = v.c_rz end
            if mv.rx or mv.ry or mv.rz then M.stats.rot = M.stats.rot + 1 end
            moves[nmv] = mv
            sess.ent_hash = add32(sess.ent_hash, 4294967296 - v.term)
            v.qx, v.qy, v.qz, v.rx, v.ry, v.rz, v.last = v.c_qx, v.c_qy, v.c_qz, v.c_rx, v.c_ry, v.c_rz, tick
            local e = S.ents[v.eid or 0]
            if e and e.q_tick == tick then
                if not e.qterm then e.qterm = term_of(e.eid, v) end
                v.term = e.qterm
            else
                v.term = term_of(v.eid, v)
            end
            sess.ent_hash = add32(sess.ent_hash, v.term)
        end
    end
    for i = nmv + 1, #moves do moves[i] = nil end
    if nsp + nmv + nd > 0 then
        local msg = sess.d_msg
        if not msg then msg = {}; sess.d_msg = msg end
        msg.tick, msg.key, msg.spawns, msg.moves, msg.despawns = tick, key, spawns, moves, despawns
        local n = net.send_client(sess.gw, sess.sid, "EntityDelta", msg)
        M.stats.delta_msgs = M.stats.delta_msgs + 1
        M.stats.delta_bytes = M.stats.delta_bytes + n
        M.stats.spawns = M.stats.spawns + nsp
        M.stats.moves = M.stats.moves + nmv
        M.stats.despawns = M.stats.despawns + nd
        if key then M.stats.keyframes = M.stats.keyframes + 1; if PF.on then PF.inc("keyframes") end end
        S.stats.snap_bytes = S.stats.snap_bytes + n
        sess.bytes = sess.bytes + n
    end
end

function M.set_mode(mode)
    if mode ~= "full" and mode ~= "delta" then return "[olife_world] snap: mode must be full|delta" end
    cfg.snap = mode
    return string.format("[olife_world] snap mode=%s budget=%d keyframe=%d tick=%d", mode, cfg.snap_budget, cfg.keyframe,
        S.tick)
end

function M.status()
    local s = M.stats
    return string.format("snap=%s snap_delta_bytes=%d snap_full_bytes=%d snap_msgs=%d snap_spawns=%d snap_moves=%d " ..
        "snap_d8=%d snap_d16=%d snap_pa=%d snap_rot=%d snap_despawns=%d snap_deferred=%d snap_decimated=%d " ..
        "snap_keyframes=%d snap_resets=%d snap_ms=%.1f", cfg.snap, s.delta_bytes, s.full_bytes, s.delta_msgs, s.spawns, s.moves,
        s.moves_d8, s.moves_dp, s.moves_pa, s.rot, s.despawns, s.deferred, s.decimated, s.keyframes, s.resets, s.ms or 0)
end

return M
