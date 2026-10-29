-- olife_world:server — authoritative Olife world on a headless VoxelCore 0.32 (OLIFE_ARCHITECTURE §4).
-- Ticked from scripts/world.lua on_world_tick (20 Hz, our own scheduler, not ECS on_update which runs at 6.7 Hz).
-- Tick order: 1 incoming (<= max_frames) -> 2 sandbox actions of the previous tick -> 3 world (mobs, mirrored
-- engine entities, server-side chunk changes) -> 4 replication (block updates, chunks, entity snapshots, TickSync)
-- + TickInput to the sandbox -> 5 send (one socket:send per gateway).
-- Authority: the client proposes (PlayerInput, BlockAction, ChatSend); the world validates (speed, reach, rate,
-- loaded, in view) and replies with state or a correction/reject. Server entity ids (eid) are the only id space.
local C = require "olife_proto:client"
local W = require "olife_proto:wire"
local U = require "olife_proto:util"
local net = require "olife_world:net"
local sandbox = require "olife_world:sandbox"
local editor = require "olife_world:editor"     -- wave 4a: benches, editor lock, console, Injector/GravityGun
local move_auth = require "olife_world:move_auth" -- wave 4c: predicted movement (MoveInput -> PlayerState)
local snapdelta = require "olife_world:snapdelta" -- wave 4c: quantised per-session entity deltas (EntityDelta)
local inventory4c = require "olife_world:inventory" -- wave 4c: server-authoritative inventory
local PF = require "olife_world:prof"             -- wave 5p: per-tick phase profiler (--opts prof=1), JIT trace log
local ops = require "olife_world:ops"             -- UX A2: chat, operator commands, audit, bans/freeze/limits, notices
local storenet = require "olife_world:storenet"   -- UX A4: per-mob KV + per-owner asset store (CAS), EntityAssets
local spammer = require "olife_world:spammer"     -- UX B2: Spammer — snapshot library, capture/throw, balls (kind 5)
local mobapi = require "olife_world:mobapi"       -- UX A3: mob script API (appearance/anim/sound/blocks/memory)
local STORE = require "olife_world:store"
local mobs = require "olife_world:mobs"         -- UX B1: "my mobs" panel, rescue/destroy/restore, code history
local fraud = require "olife_world:fraud"       -- antifraud 16.10: per-account scores, warn/throttle/kick/autoban
local EMPTY4C = {}

local M = {}
local floor, sqrt, max, min, abs = math.floor, math.sqrt, math.max, math.min, math.abs
local now_ms, add32 = U.now_ms, U.add32

local cfg = {
    port = 0, secret = "", sandbox_port = 0, ticks = 0, view = 3, world = "olife", seed = "2026",
    generator = "base:demo", mobs = 3, scripted = 2, max_frames = 2048, chunks_per_tick = 4,
    max_speed = 12.0,       -- blocks/s accepted from PlayerInput (with slack)
    reach = 8.0,            -- block action reach from the player's eye
    block_rate = 10, block_burst = 20, chat_rate = 2, chat_burst = 5,
    chunk_cache = 256, rehash_per_tick = 2, export = true,
    journal_every = 0,      -- stage 6: write the supervisor state file (journal ring, players, sandbox) every N ticks
}
M.cfg = cfg

local S = {
    running = false, stop = false, save_req = false, tick = 0, app_ticks = 0,
    sessions = {},          -- key "gw:sid" -> session
    by_eid = {},            -- player eid -> session
    ents = {},              -- eid -> entity
    next_eid = 1,
    saved_players = {},     -- account -> {x,y,z}
    changes = {}, change_at = {},       -- block changes of this tick (deduplicated by position)
    cache = {}, cache_n = 0,            -- chunk key -> {cx, cz, data, hash, tick}
    holders = {},           -- chunk key -> {session key -> true}
    kc = {},                -- chunk key -> {cx, cz}
    modified = {},          -- "x,y,z" -> {x, y, z}: every position the world changed (olife_blocks check)
    rehash_keys = {}, rehash_i = 0,
    mirror = {},            -- engine uid -> eid (engine-spawned entities: falling blocks, drops)
    ignore_uid = {},        -- engine uids of our own engine players
    spawn = {x = 8.5, y = 80, z = 8.5},
    keeper = nil,
    stats = {inputs = 0, corrections = 0, block_ok = 0, block_rej = {}, chat = 0, kicks = 0, chunks_sent = 0,
             chunk_bytes = 0, rehash_checks = 0, rehash_resends = 0, unknown_session = 0, snap_bytes = 0,
             sync_bytes = 0, block_bytes = 0, sandbox_applied = 0, sandbox_rejected = 0},
    tick_ms = {}, phase_ms = {0, 0, 0, 0, 0}, phase_max = {0, 0, 0, 0, 0},
    acct_actions = {},      -- account -> block/chat actions since this world process started (supervisor meter)
    sup_writes = 0,
}
M.S = S

local function log(fmt, ...)
    print("[olife_world] " .. string.format(fmt, ...))
end

-- chunk key: always >= 2^31 (wave 5p): keys 1..n near the origin gave sess.chunks / S.cache / S.holders an array
-- part, and a lookup with a computed key then aborted traces ("NYI: mixed sparse/dense table", snapdelta, rehash)
local function ckey(cx, cz) return (cx + 32768) * 65536 + (cz + 32768) end
local function chunk_of(x, z) return floor(x / 16), floor(z / 16) end

-- ------------------------------------------------------------------------------------------ entities
local function new_entity(kind, def, name, owner, pos, rot, eid)
    eid = eid or S.next_eid
    if eid >= S.next_eid then S.next_eid = eid + 1 end
    local e = {eid = eid, kind = kind, def = def, name = name or "", owner = owner or 0,
               pos = {x = pos.x, y = pos.y, z = pos.z}, rot = rot and {x = rot.x, y = rot.y, z = rot.z} or {x = 0, y = 0, z = 0},
               vel = {x = 0, y = 0, z = 0}}
    S.ents[eid] = e
    return e
end
M.new_entity = new_entity

local function remove_entity(eid)
    S.ents[eid] = nil
    STORE.on_entity_removed(eid)                 -- UX A4: KV and asset slots of the entity go with it
end
M.remove_entity = remove_entity

-- ------------------------------------------------------------------------------------------ chunks
local function chunk_get(cx, cz)
    local k = ckey(cx, cz)
    local c = S.cache[k]
    if c then c.tick = S.tick; return c end
    local d = world.get_chunk_data(cx, cz)
    if d == nil then return nil end
    if S.cache_n >= cfg.chunk_cache then
        local oldest, ok
        for kk, cc in pairs(S.cache) do
            if not oldest or cc.tick < oldest then oldest, ok = cc.tick, kk end
        end
        S.cache[ok] = nil
        S.cache_n = S.cache_n - 1
    end
    c = {cx = cx, cz = cz, data = d, hash = W.fnv1a(d), tick = S.tick}
    S.cache[k] = c
    S.cache_n = S.cache_n + 1
    return c
end

local function holders_of(k, cx, cz)
    local h = S.holders[k]
    if not h then h = {}; S.holders[k] = h; S.kc[k] = {cx, cz} end
    return h
end

local function send_chunk(sess, c)
    local n = net.send_client(sess.gw, sess.sid, "ChunkData", {cx = c.cx, cz = c.cz, data = c.data, hash = c.hash})
    S.stats.chunks_sent = S.stats.chunks_sent + 1
    if PF.on then PF.inc("chunks") end
    S.stats.chunk_bytes = S.stats.chunk_bytes + n
    sess.bytes = sess.bytes + n
end

-- an external (not ours) change of a chunk: resend to every holder
local function resend_chunk(k, c)
    S.stats.rehash_resends = S.stats.rehash_resends + 1
    for skey in pairs(S.holders[k] or {}) do
        local sess = S.sessions[skey]
        if sess then send_chunk(sess, c) end
    end
end

-- compare the cached bytes of chunk k with the world now; resend if different
local function rehash(k)
    local c = S.cache[k]
    if not c then return end
    S.stats.rehash_checks = S.stats.rehash_checks + 1
    local d = world.get_chunk_data(c.cx, c.cz)
    if d == nil then return end
    local h = W.fnv1a(d)
    if h ~= c.hash or #d ~= #c.data then
        c.data, c.hash = d, h
        resend_chunk(k, c)
    end
end

-- ------------------------------------------------------------------------------------------ block changes
-- apply a validated change now (phase 1/2); replication in phase 4
local function apply_block(x, y, z, id, states, source)
    local cx, cz = chunk_of(x, z)
    local k = ckey(cx, cz)
    if S.cache[k] then
        rehash(k)                 -- catch external changes before ours make the cache stale
    end
    block.set(x, y, z, id, states)
    local actual, ast = block.get(x, y, z), block.get_states(x, y, z)
    local pk = x .. "," .. y .. "," .. z
    local ch = S.change_at[pk]
    if ch then
        ch.id, ch.states = actual, ast
    else
        ch = {x = x, y = y, z = z, id = actual, states = ast, k = k, source = source}
        S.changes[#S.changes + 1] = ch
        S.change_at[pk] = ch
    end
    if S.cache[k] then
        S.cache[k] = nil
        S.cache_n = S.cache_n - 1
    end
    S.modified[pk] = {x, y, z}
    return actual, ast
end
M.apply_block = apply_block

-- ------------------------------------------------------------------------------------------ sessions
local function engine_player(name, pos)
    local pid = player.create(name)
    pcall(player.set_flight, pid, true)
    pcall(player.set_noclip, pid, true)
    pcall(player.set_loading_chunks, pid, true)
    player.set_pos(pid, pos.x, pos.y, pos.z)
    local uid = player.get_entity(pid)
    if uid then S.ignore_uid[uid] = true end
    return pid
end

local function by_gateway(sessions)
    local out = {}
    for _, s in ipairs(sessions) do
        local l = out[s.gw.id]
        if not l then l = {}; out[s.gw.id] = l end
        l[#l + 1] = s.sid
    end
    return out
end

local function all_sessions()
    local l = {}
    for _, s in pairs(S.sessions) do l[#l + 1] = s end
    return l
end

local function remove_session(key, reason)
    local sess = S.sessions[key]
    if not sess then return end
    S.sessions[key] = nil
    S.by_eid[sess.eid] = nil
    editor.on_session_removed(sess)
    spammer.on_session_removed(sess)             -- UX B2: balls of a gone thrower still land, nobody is answered
    inventory4c.on_leave(sess)                   -- wave 4c: keep the inventory for the next login
    S.saved_players[sess.account .. "/" .. sess.name] = {x = sess.pos.x, y = sess.pos.y, z = sess.pos.z}
    for k in pairs(sess.chunks) do
        local h = S.holders[k]
        if h then h[key] = nil end
    end
    remove_entity(sess.eid)
    pcall(player.delete, sess.pid)
    log("leave %s (%s) eid=%d: %s", sess.name, sess.account, sess.eid, tostring(reason))
    ops.on_leave(sess, reason)                   -- UX A2: system line
end

local function kick(sess, code, reason)
    S.stats.kicks = S.stats.kicks + 1
    net.send(sess.gw, "Detach", {session = sess.sid, code = code, reason = reason})
    remove_session(sess.key, "kick: " .. reason)
end
M.kick = kick

local handlers = {}

function handlers.hello(gw, m)
    log("gateway #%d hello: %s (proto %d, client proto %d)", gw.id, m.gateway, m.proto, m.client_proto)
    net.send(gw, "WorldHello", {proto = 1, world = cfg.world, tick = S.tick, tps = 20, client_proto = C.version})
end

function handlers.attach(gw, m)
    local key = gw.id .. ":" .. m.session
    local ban = ops.ban_of(m.account)            -- UX A2: banned by an operator -> refused (gateway: Disconnect 5)
    if ban then
        ops.ST.stats.bans_refused = ops.ST.stats.bans_refused + 1
        net.send(gw, "Detach", {session = m.session, code = 5, reason = ops.clip(ops.ban_text(ban), 250)})
        log("attach refused %s (%s): %s", m.name, m.account, ops.ban_text(ban))
        return
    end
    if S.sessions[key] then remove_session(key, "re-attach") end
    local saved = S.saved_players[m.account .. "/" .. m.name]
    local pos = saved or {x = S.spawn.x, y = S.spawn.y, z = S.spawn.z}
    local e = new_entity(1, "olife_client:avatar", m.name, 0, pos)
    local sess = {key = key, gw = gw, sid = m.session, account = m.account, name = m.name, addr = m.addr,
                  eid = e.eid, pos = e.pos, rot = e.rot, pid = engine_player("olife_" .. m.name, pos),
                  chunks = {}, nchunks = 0, view = {}, nview = 0, ent_hash = 0, block_hash = 0,
                  pcx = nil, pcz = nil, queue = {}, last_input_tick = S.tick, input_seq = 0,
                  btokens = cfg.block_burst, ctokens = cfg.chat_burst, joined = S.tick, bytes = 0, inputs = 0,
                  actions = 0, perms = m.perms or 0}
    S.sessions[key] = sess
    S.by_eid[e.eid] = sess
    gw.sessions[m.session] = key
    net.send_client(gw, m.session, "Welcome", {proto = C.version, session = m.session, player_eid = e.eid,
        tick = S.tick, tps = 20, spawn = U.vec_round(pos), view_radius = cfg.view, world = cfg.world,
        blocks = block.defs_count()})
    move_auth.on_attach(sess)                    -- wave 4c: movement state, inventory (full state in phase 4)
    inventory4c.on_attach(sess)
    ops.on_attach(sess)                          -- UX A2: chat history (late joiners), join line, frozen state
    fraud.on_attach(sess)                        -- antifraud: reconnect loops
    log("join %s (%s) from %s session=%d eid=%d pos=%.1f,%.1f,%.1f%s", m.name, m.account, m.addr, m.session, e.eid,
        pos.x, pos.y, pos.z, saved and " (restored)" or "")
end

function handlers.detach(gw, m)
    remove_session(gw.id .. ":" .. m.session, "gateway: " .. m.reason)
end

function handlers.lost(gw, why)
    for key, s in pairs(S.sessions) do
        if s.gw == gw then remove_session(key, "gateway lost: " .. why) end
    end
end

-- ---------------------------------------------------------------- client messages (validated)
local client = {}

function client.PlayerInput(sess, m)
    S.stats.inputs = S.stats.inputs + 1
    sess.inputs = sess.inputs + 1
    local p = m.pos
    local dt = max(1, S.tick - sess.last_input_tick)
    local dx, dy, dz = p.x - sess.pos.x, p.y - sess.pos.y, p.z - sess.pos.z
    local d = sqrt(dx * dx + dy * dy + dz * dz)
    local allowed = cfg.max_speed / 20 * dt * 1.5 + 0.25
    local reason = 0
    if d > allowed then reason = 1
    elseif p.y < 0 or p.y > 300 then reason = 2
    elseif block.get(floor(p.x), floor(min(max(p.y, 0), 255)), floor(p.z)) == -1 then reason = 3 end
    if reason ~= 0 then
        S.stats.corrections = S.stats.corrections + 1
        net.send_client(sess.gw, sess.sid, "PlayerCorrect", {seq = m.seq, pos = U.vec_round(sess.pos), reason = reason})
        sess.last_input_tick = S.tick
        return
    end
    sess.pos.x, sess.pos.y, sess.pos.z = p.x, p.y, p.z
    sess.rot.x, sess.rot.y, sess.rot.z = m.rot.x, m.rot.y, m.rot.z
    sess.last_input_tick = S.tick
    sess.input_seq = m.seq
    player.set_pos(sess.pid, p.x, p.y, p.z)
    move_auth.on_legacy(sess)                    -- wave 4c: keep the predicted-movement state in step
end

local function reject(sess, m, reason)
    S.stats.block_rej[reason] = (S.stats.block_rej[reason] or 0) + 1
    local x, y, z = m.pos.x, m.pos.y, m.pos.z
    local id, st = block.get(x, y, z), 0
    if id < 0 then id = 0 else st = block.get_states(x, y, z) end
    net.send_client(sess.gw, sess.sid, "BlockReject", {seq = m.seq, reason = reason,
        actual = {pos = {x = x, y = y, z = z}, id = id, states = st}})
end

function client.BlockAction(sess, m)
    sess.actions = sess.actions + 1
    S.acct_actions[sess.account] = (S.acct_actions[sess.account] or 0) + 1
    if sess.btokens < 1 then fraud.event(sess, "action"); return reject(sess, m, 2) end
    sess.btokens = sess.btokens - 1
    local x, y, z = m.pos.x, m.pos.y, m.pos.z
    local ex, ey, ez = sess.pos.x, sess.pos.y + 1.6, sess.pos.z
    local dx, dy, dz = x + 0.5 - ex, y + 0.5 - ey, z + 0.5 - ez
    if dx * dx + dy * dy + dz * dz > cfg.reach * cfg.reach then return reject(sess, m, 1) end
    if y < 0 or y > 255 then return reject(sess, m, 3) end
    local cur = block.get(x, y, z)
    if cur == -1 then return reject(sess, m, 3) end
    local cx, cz = chunk_of(x, z)
    if not sess.chunks[ckey(cx, cz)] then return reject(sess, m, 6) end
    if m.action == 0 then
        if cur == 0 then return reject(sess, m, 4) end
        apply_block(x, y, z, 0, 0, sess.eid)
        if cfg.inv_enforce then inventory4c.on_broken(sess, cur, x, y, z) end   -- wave 4c: picking item
    elseif m.action == 1 then
        if m.block <= 0 or m.block >= block.defs_count() then return reject(sess, m, 5) end
        if not block.is_replaceable_at(x, y, z) then return reject(sess, m, 4) end
        -- wave 4c: not into a player's box; the selected slot must hold an item placing this block (consumed)
        if cfg.inv_enforce and inventory4c.cell_has_player(x, y, z) then return reject(sess, m, 4) end
        if cfg.inv_enforce and not inventory4c.check_place(sess, m) then return reject(sess, m, 7) end
        apply_block(x, y, z, m.block, m.states, sess.eid)
        if cfg.inv_enforce then inventory4c.on_placed(sess) end
    else
        return reject(sess, m, 5)
    end
    S.stats.block_ok = S.stats.block_ok + 1
end

function client.ChatSend(sess, m)
    sess.actions = sess.actions + 1
    S.acct_actions[sess.account] = (S.acct_actions[sess.account] or 0) + 1
    -- UX A2: rate limit (ctokens) with a Notice, ChatLine{sender, role, time} + history; "/" = operator command
    return ops.on_chat(sess, m.text)
end

-- wave 4a: editor / console / tools (olife_world:editor)
for _, n in ipairs({"ScriptOpen", "ScriptSave", "ScriptRun", "ScriptStop", "ScriptLockRelease", "ToolUse",
                    "EntityEdit"}) do                            -- + UX round 1: entity settings / delete
    client[n] = function(sess, m) return editor[n](sess, m) end
end
-- UX A1: rights, fork, friends, rights check (olife_world:perms)
local perms = require "olife_world:perms"
for _, n in ipairs({"EntityPermsSet", "EntityFork", "FriendRequest", "PermsCheck"}) do
    client[n] = function(sess, m) return perms[n](sess, m) end
end

-- UX B1: my mobs list, emergency actions, profile, code history (olife_world:mobs)
for _, n in ipairs({"MobsRequest", "MobAction", "MobProfileRequest", "CodeHistoryRequest", "CodeVersionOp"}) do
    client[n] = function(sess, m) return mobs[n](sess, m) end
end

-- UX A4: asset upload / library / slots (olife_world:storenet)
function client.AssetUpload(sess, m) return storenet.AssetUpload(sess, m) end
function client.AssetOp(sess, m) return storenet.AssetOp(sess, m) end
-- UX B2: Spammer — capture a snapshot, throw a ball, library ops (olife_world:spammer)
function client.SpamCapture(sess, m) return spammer.SpamCapture(sess, m) end
function client.SpamThrow(sess, m) return spammer.SpamThrow(sess, m) end
function client.SpamSlotOp(sess, m) return spammer.SpamSlotOp(sess, m) end

-- wave 4c: predicted movement and inventory requests
function client.MoveInput(sess, m) return move_auth.on_input(sess, m) end
function client.InvAction(sess, m) return inventory4c.on_action(sess, m) end

function client.Bye(sess, m)
    remove_session(sess.key, "bye: " .. m.reason)
end

function handlers.data(gw, sid, mtype, payload)
    local key = gw.sessions[sid] or (gw.id .. ":" .. sid)
    local sess = S.sessions[key]
    if not sess then
        S.stats.unknown_session = S.stats.unknown_session + 1
        return
    end
    local name = C.names[mtype]
    if not name or C.dirs[mtype] ~= "c2s" then
        return kick(sess, 4, "unexpected message type " .. tostring(mtype))
    end
    local ok, m = pcall(C.decode_body, mtype, payload)
    if not ok then
        return kick(sess, 4, "bad payload: " .. tostring(m))
    end
    local h = client[name]
    if fraud.blocked(sess, name, m) then return end    -- antifraud: throttled account (chat/blocks/requests dropped)
    if sess.frozen then                          -- UX A2: a frozen player does not move or act
        local b = ops.blocked(sess, name)
        if b == "drop" then return
        elseif b == "keys" then m.keys = 0
        elseif b == "correct" then
            return net.send_client(sess.gw, sess.sid, "PlayerCorrect", {seq = m.seq, pos = U.vec_round(sess.pos), reason = 5})
        end
    end
    if h then
        if PF.on then
            local t = PF.now()
            h(sess, m)
            PF.add(name == "MoveInput" and "h_move" or name == "BlockAction" and "h_block" or name == "InvAction" and "h_inv"
                   or "h_other", PF.now() - t)
        else
            h(sess, m)
        end
    end
end

-- ------------------------------------------------------------------------------------------ engine entities
function M.on_engine_spawn(uid)
    if not S.running or S.ignore_uid[uid] or S.mirror[uid] then return end
    local okd, def = pcall(function() return entities.def_name(entities.get_def(uid)) end)
    if not okd or def == "base:player" then return end
    local ent = entities.get(uid)
    if not ent then return end
    local p = ent.transform:get_pos()
    local e = new_entity(2, def, "", 0, {x = p[1], y = p[2], z = p[3]})
    e.uid = uid
    S.mirror[uid] = e.eid
end

function M.on_engine_despawn(uid)
    local eid = S.mirror[uid]
    if eid then
        S.mirror[uid] = nil
        remove_entity(eid)
    end
end

-- ------------------------------------------------------------------------------------------ phases
local function step_world()
    local pf = PF.on
    local pt = pf and PF.now()
    local t = S.tick * 0.05
    for _, e in pairs(S.ents) do
        if e.kind == 2 and e.mob then
            local a = t * 0.6 + e.mob * 2.0944
            local r = 4 + e.mob
            e.pos.x = S.spawn.x + math.cos(a) * r
            e.pos.z = S.spawn.z + math.sin(a) * r
            e.pos.y = S.spawn.y + 2
            e.rot.y = (a * 57.29578) % 360
        elseif e.uid then
            local ent = entities.get(e.uid)
            if ent then
                local p = ent.transform:get_pos()
                e.pos.x, e.pos.y, e.pos.z = p[1], p[2], p[3]
            end
        end
    end
    if pf then local x = PF.now(); PF.add("w_ents", x - pt); pt = x end
    move_auth.step_world()                       -- wave 4c: input buckets; pickups and expiry of dropped items
    if pf then local x = PF.now(); PF.add("w_move", x - pt); pt = x end
    inventory4c.step_world()
    if pf then local x = PF.now(); PF.add("w_inv", x - pt); pt = x end
    -- refill rate buckets
    for _, s in pairs(S.sessions) do
        s.btokens = min(cfg.block_burst, s.btokens + cfg.block_rate / 20)
        s.ctokens = min(cfg.chat_burst, s.ctokens + cfg.chat_rate / 20)
    end
    -- server-side chunk changes (no engine event for them): re-hash chunks somebody holds, round robin
    if S.tick % 20 == 0 then
        local keys = {}
        for k, h in pairs(S.holders) do
            if next(h) then keys[#keys + 1] = k end
        end
        S.rehash_keys, S.rehash_i = keys, 0
    end
    for _ = 1, cfg.rehash_per_tick do
        local keys = S.rehash_keys
        if #keys == 0 then break end
        S.rehash_i = S.rehash_i % #keys + 1
        local k = keys[S.rehash_i]
        if S.cache[k] then rehash(k) else
            local h, c = S.holders[k], S.kc[k]
            if h and next(h) and c then
                chunk_get(c[1], c[2])     -- not cached any more: cache now (the next pass compares)
            end
        end
    end
    if pf then PF.add("w_rehash", PF.now() - pt) end
end

local function update_interest(sess)
    local pcx, pcz = chunk_of(sess.pos.x, sess.pos.z)
    if pcx == sess.pcx and pcz == sess.pcz and #sess.queue == 0 then return end
    local moved = pcx ~= sess.pcx or pcz ~= sess.pcz
    sess.pcx, sess.pcz = pcx, pcz
    local r = cfg.view
    if moved then
        -- unload chunks out of r+1
        for k, c in pairs(sess.chunks) do
            if abs(c.cx - pcx) > r + 1 or abs(c.cz - pcz) > r + 1 then
                sess.chunks[k] = nil
                sess.nchunks = sess.nchunks - 1
                local h = S.holders[k]
                if h then h[sess.key] = nil end
                net.send_client(sess.gw, sess.sid, "ChunkUnload", {cx = c.cx, cz = c.cz})
            end
        end
        local q = {}
        for dx = -r, r do
            for dz = -r, r do
                local k = ckey(pcx + dx, pcz + dz)
                if not sess.chunks[k] then q[#q + 1] = {cx = pcx + dx, cz = pcz + dz, d = dx * dx + dz * dz} end
            end
        end
        table.sort(q, function(a, b) return a.d < b.d end)
        sess.queue = q
    end
    local sent, rest = 0, {}
    for _, it in ipairs(sess.queue) do
        local k = ckey(it.cx, it.cz)
        if sess.chunks[k] then
            -- already there
        elseif sent < cfg.chunks_per_tick then
            local c = chunk_get(it.cx, it.cz)
            if c then
                send_chunk(sess, c)
                sess.chunks[k] = {cx = it.cx, cz = it.cz}
                sess.nchunks = sess.nchunks + 1
                holders_of(k, it.cx, it.cz)[sess.key] = true
                sent = sent + 1
            else
                rest[#rest + 1] = it
            end
        else
            rest[#rest + 1] = it
        end
    end
    sess.queue = rest
end

local function replicate()
    local pf = PF.on
    local pt = pf and PF.now()
    -- block changes of this tick -> holders (before new chunks: a chunk sent now already contains them)
    if #S.changes > 0 then
        local per = {}          -- session key -> list of changes
        for _, ch in ipairs(S.changes) do
            for skey in pairs(S.holders[ch.k] or {}) do
                local l = per[skey]
                if not l then l = {}; per[skey] = l end
                l[#l + 1] = ch
            end
        end
        -- group sessions with the same change list -> one Multicast per group
        local groups = {}
        for skey, l in pairs(per) do
            local sess = S.sessions[skey]
            if sess then
                local sig = {}
                for i, ch in ipairs(l) do sig[i] = tostring(ch) end
                sig = table.concat(sig, ",")
                local g = groups[sig]
                if not g then g = {list = l, sessions = {}}; groups[sig] = g end
                g.sessions[#g.sessions + 1] = sess
                for _, ch in ipairs(l) do
                    sess.block_hash = add32(sess.block_hash, U.block_term(ch.x, ch.y, ch.z, ch.id, ch.states))
                end
            end
        end
        for _, g in pairs(groups) do
            local changes = {}
            for i, ch in ipairs(g.list) do
                changes[i] = {pos = {x = ch.x, y = ch.y, z = ch.z}, id = ch.id, states = ch.states}
            end
            local n = net.multicast(by_gateway(g.sessions), "BlockUpdate", {tick = S.tick, changes = changes})
            S.stats.block_bytes = S.stats.block_bytes + n
        end
        S.changes, S.change_at = {}, {}
    end
    if pf then local x = PF.now(); PF.add("r_blocks", x - pt); pt = x end
    -- entity terms of this tick (f32 as on the wire)
    for _, e in pairs(S.ents) do
        e.rp, e.rr = U.vec_round(e.pos), U.vec_round(e.rot)
        e.term = U.entity_term(e.eid, e.rp, e.rr)
        e.ck = ckey(chunk_of(e.pos.x, e.pos.z))
    end
    if pf then local x = PF.now(); PF.add("r_terms", x - pt); pt = x end
    local ts = now_ms()
    local views = {}
    for _, sess in pairs(S.sessions) do
        if pf then pt = PF.now() end
        update_interest(sess)
        if pf then local x = PF.now(); PF.add("r_interest", x - pt); pt = x end
        local delta4c = snapdelta.check_mode(sess) == "delta"     -- wave 4c: EntityDelta instead of EntitySnapshot
        if delta4c then snapdelta.replicate_session(sess) end
        if pf then local x = PF.now(); PF.add("r_snap", x - pt); pt = x end
        local spawns, updates, despawns = {}, {}, {}
        for eid, e in pairs(delta4c and EMPTY4C or S.ents) do
            if eid ~= sess.eid and sess.chunks[e.ck] then
                local v = sess.view[eid]
                if not v then
                    spawns[#spawns + 1] = {eid = eid, kind = e.kind, def = e.def, name = e.name, owner = e.owner,
                                           pos = e.rp, rot = e.rr}
                    sess.view[eid] = {p = e.rp, r = e.rr, term = e.term}
                    sess.nview = sess.nview + 1
                    sess.ent_hash = add32(sess.ent_hash, e.term)
                elseif v.term ~= e.term then
                    local u = {eid = eid}
                    if v.p.x ~= e.rp.x or v.p.y ~= e.rp.y or v.p.z ~= e.rp.z then u.pos = e.rp end
                    if v.r.x ~= e.rr.x or v.r.y ~= e.rr.y or v.r.z ~= e.rr.z then u.rot = e.rr end
                    updates[#updates + 1] = u
                    sess.ent_hash = add32(sess.ent_hash, e.term - v.term + 4294967296)
                    v.p, v.r, v.term = e.rp, e.rr, e.term
                end
            end
        end
        for eid, v in pairs(delta4c and EMPTY4C or sess.view) do
            local e = S.ents[eid]
            if not e or not sess.chunks[e.ck] then
                despawns[#despawns + 1] = eid
                sess.view[eid] = nil
                sess.nview = sess.nview - 1
                sess.ent_hash = add32(sess.ent_hash, 4294967296 - v.term)
            end
        end
        if #spawns + #updates + #despawns > 0 then
            local n = net.send_client(sess.gw, sess.sid, "EntitySnapshot", {tick = S.tick, spawns = spawns,
                                                                            updates = updates, despawns = despawns})
            S.stats.snap_bytes = S.stats.snap_bytes + n
            sess.bytes = sess.bytes + n
        end
        if pf then local x = PF.now(); PF.add("r_full", x - pt); pt = x end
        editor.replicate(sess)                   -- wave 4a: name tags / hold state of entities in view
        mobapi.replicate(sess)                   -- UX A3: EntityAppearance / EntityAnim / EntitySound
        storenet.replicate(sess)                 -- UX A4: EntityAssets (asset manifests) of entities in view
        spammer.replicate(sess)                  -- UX B2: SpamBall events (thrown / landed / lost) in view
        if pf then local x = PF.now(); PF.add("r_editor", x - pt); pt = x end
        move_auth.send(sess)                     -- wave 4c: PlayerState, InventoryState
        if pf then local x = PF.now(); PF.add("r_move", x - pt); pt = x end
        inventory4c.send(sess)
        if pf then local x = PF.now(); PF.add("r_inv", x - pt); pt = x end
        local vh = add32(sess.ent_hash, sess.block_hash)
        local n = net.send_client(sess.gw, sess.sid, "TickSync", {tick = S.tick, server_ms = ts, view_hash = vh,
                                                                  entities = sess.nview, chunks = sess.nchunks})
        S.stats.sync_bytes = S.stats.sync_bytes + n
        views[tostring(sess.eid)] = vh
        if pf then PF.add("r_sync", PF.now() - pt); PF.inc("sessions") end
    end
    return ts, views
end

-- ------------------------------------------------------------------------------------------ lifecycle
function M.configure(t)
    for k, v in pairs(t) do
        if v ~= nil then cfg[k] = v end
    end
end

local function find_surface(x, z)
    for y = 250, 1, -1 do
        local id = block.get(x, y, z)
        if id > 0 then return y + 1 end
    end
    return 80
end

local function registry_path() return "world:olife_registry.json" end

function M.save_registry(quiet)
    local ents = {}
    for _, e in pairs(S.ents) do
        if (e.kind == 2 and e.mob) or e.kind == 3 then
            local rec = {eid = e.eid, kind = e.kind, def = e.def, name = e.name, owner = e.owner, mob = e.mob,
                         script = e.script, pos = {e.pos.x, e.pos.y, e.pos.z}, rot = {e.rot.x, e.rot.y, e.rot.z}}
            editor.save_fields(e, rec)           -- wave 4a: code, status, owner account, console tail
            mobapi.save_fields(e, rec)           -- UX A3: appearance set by the script
            ents[#ents + 1] = rec
        end
    end
    local players = {}
    for k, p in pairs(S.saved_players) do players[k] = {p.x, p.y, p.z} end
    for _, s in pairs(S.sessions) do players[s.account .. "/" .. s.name] = {s.pos.x, s.pos.y, s.pos.z} end
    local ok, err = pcall(file.write, registry_path(), json.tostring({next_eid = S.next_eid, tick = S.tick,
        entities = ents, players = players, spawn = {S.spawn.x, S.spawn.y, S.spawn.z}, editor = editor.save_top(),
        ops = ops.save(),                        -- UX A2: chat history, bans, frozen, op limits
        inventories = inventory4c.save()}))    -- wave 4c: inventories by account/name (item names, not ids)
    if ok and quiet then return ok end
    if ok then log("registry saved: %d entities, players %d", #ents, table.count_pairs and table.count_pairs(players) or 0)
    else log("registry save failed: %s", tostring(err)) end
    return ok
end

local function load_registry()
    if not file.exists(registry_path()) then return false end
    local ok, d = pcall(function() return json.parse(file.read(registry_path())) end)
    if not ok or type(d) ~= "table" then log("registry unreadable: %s", tostring(d)); return false end
    S.next_eid = d.next_eid or 1
    for _, r in ipairs(d.entities or {}) do
        local e = new_entity(r.kind, r.def, r.name, r.owner, {x = r.pos[1], y = r.pos[2], z = r.pos[3]},
                             {x = r.rot[1], y = r.rot[2], z = r.rot[3]}, r.eid)
        e.mob, e.script = r.mob, r.script
        editor.load_fields(e, r)
        mobapi.load_fields(e, r)                 -- UX A3
    end
    editor.load_top(d.editor)
    ops.load(d.ops)                              -- UX A2
    inventory4c.load(d.inventories)              -- wave 4c
    for k, p in pairs(d.players or {}) do S.saved_players[k] = {x = p[1], y = p[2], z = p[3]} end
    if d.spawn then S.spawn = {x = d.spawn[1], y = d.spawn[2], z = d.spawn[3]} end
    log("registry loaded: %d entities, next_eid=%d", #(d.entities or {}), S.next_eid)
    return true
end

-- called by the start script once the world is open and the spawn chunk is loaded
function M.start()
    S.keeper = engine_player("olife_spawn", {x = S.spawn.x, y = 100, z = S.spawn.z})
    return S.keeper
end

function M.spawn_ready()
    return block.get(floor(S.spawn.x), 10, floor(S.spawn.z)) ~= -1
end

-- admin commands (--stdin-cmd). Registered from the MAIN Lua state (begin() runs in on_world_tick): a callback
-- created inside the start-script coroutine stays bound to that coroutine's lua_State, and the engine calling it
-- between frames killed the script ("cannot resume dead coroutine", 0xC0000409) — seen 02.10 on kick/check_blocks.
local function register_commands()
    console.add_command("status", "Olife world status", function() return M.status() end)
    console.add_command("players", "Olife players", function() return M.players() end)
    console.add_command("kick eid:int", "Kick an Olife player by entity id", function(args) return M.kick_eid(args[1]) end)
    console.add_command("save", "Save the Olife world and registry", function() return M.request_save() end)
    console.add_command("journal n:int=20", "Last incoming frames (ring of 256)", function(args) return M.journal(args[1]) end)
    console.add_command("olife.dump_blocks", "Write user:export/blocks_world.json", function() return M.dump_blocks() end)
    console.add_command("olife.stop", "Stop the Olife world", function() return M.request_stop() end)
    -- stage 6 (supervisor)
    console.add_command("journal_dump path:str=''", "Write the supervisor state (journal ring of 256, players, " ..
        "sandbox) to a file (default user:export/journal_dump.json)", function(args) return M.journal_dump(args[1]) end)
    console.add_command("sandbox_reconnect", "Reconnect to the sandbox service now (it was restarted)",
        function() return sandbox.request_reconnect() end)
    -- wave 3a (real sandboxd): scripted entities by code id (content/olife_world/sandbox/<code>.lua) and meters
    console.add_command("spawn_scripted code:str owner:int=1 count:int=1 owners:int=1",
        "Spawn <count> scripted entities running sandbox/<code>.lua for each of <owners> owners starting at <owner>",
        function(args) return M.spawn_scripted(args[1], args[2], args[3], args[4]) end)
    -- wave 4a: benches (editor / console / tools)
    console.add_command("spawn_bench account:str='' name:str='' count:int=1",
        "Spawn <count> scripted benches owned by <account> ('' = admins only), stopped, with the default code",
        function(args) return M.spawn_bench(args[1], args[2], args[3]) end)
    -- play path (olife_play): sample benches with example code (sandbox/samples/<code>.lua), running
    console.add_command("spawn_sample account:str name:str code:str run:int=1",
        "Spawn one bench owned by <account> named <name> with the code of sandbox/samples/<code>.lua (run=1: running)",
        function(args) return M.spawn_sample(args[1], args[2], args[3], args[4]) end)
    console.add_command("sample_reset account:str name:str slot:int=-1",
        "UX round 1, dry run: the sample bench <name> of <account> back to sandbox/samples/<name>.lua, running " ..
        "(slot >= 0: also back to its place on the ring around the spawn)",
        function(args) return M.sample_reset(args[1], args[2], args[3]) end)
    console.add_command("bench_place eid:int x:num y:num z:num",
        "UX round 1 (tests / rescue): put a bench at the absolute position x y z", function(args)
            local e = S.ents[args[1]]
            if not editor.is_bench(e) then return "[olife_world] bench_place: no bench eid=" .. tostring(args[1]) end
            e.pos.x, e.pos.y, e.pos.z = args[2], args[3], args[4]
            return string.format("[olife_world] bench_place eid=%d pos=%.2f,%.2f,%.2f", e.eid, args[2], args[3], args[4])
        end)
    console.add_command("bench eid:int", "Bench state: owner, status, code hash, lock, holder, subscribers, meters",
        function(args) return editor.describe(args[1]) end)
    console.add_command("olife.admins accounts:str=''", "Set editor admins (comma separated accounts)",
        function(args) return "[olife_world] admins=" .. editor.set_admins(args[1]) end)
    console.add_command("benches", "List benches: eid:name:owner:status", function() return editor.list() end)
    -- UX A2: operator commands of the lab (CLI `lab olife op`, panel buttons) — the chat "/" commands, as operator
    console.add_command("olife.op rid:str by:str via:str text:str",
        "UX A2: run an operator command (text = chat command without or with '/'), answer: op_result rid=<rid>",
        function(args) return ops.queue(args[1], args[2], args[3], args[4]) end)
    console.add_command("olife.op_state", "UX A2: write user:export/ops_state.json (chat, bans, frozen, limits, audit)",
        function() return ops.dump() end)
    console.add_command("ops_status", "UX A2: chat/operator counters", function() return "[olife_world] " .. ops.status() end)
    console.add_command("olife.fraud_state", "antifraud: write user:export/fraud_state.json (scores, events, cfg)",
        function() return fraud.dump() end)
    console.add_command("fraud_status", "antifraud counters", function() return "[olife_world] " .. fraud.status() end)
    perms.register_commands()                    -- UX A1: bench_perms, friends, olife.friends/friend_set/acct_settings
    storenet.register_commands()                 -- UX A4: store_status/kv/snapshot/restore/gc/tariff/canvas_test
    spammer.register_commands()                  -- UX B2: spam_list/spam_capture/spam_spawn/spam_status/spam_mobs
    mobapi.register_commands()                   -- UX A3: mob_api <eid>, mobapi_status, olife.api_deny/api_allow
    mobs.register_commands()                     -- UX B1: mobs_status, mob_safe, mob_dead, mob_versions, mobs_flush
    console.add_command("editor_status", "Editor/tool counters", function() return "[olife_world] " .. editor.status() end)
    console.add_command("olife.sandbox_dump", "Write user:export/sandbox_entities.json (sandbox meters per owner/entity)",
        function() return M.sandbox_dump() end)
    -- wave 4c: netcode (snapshot mode, movement state, inventories)
    console.add_command("olife.snap mode:str", "Entity replication: full (EntitySnapshot) | delta (EntityDelta)",
        function(args) return snapdelta.set_mode(args[1]) end)
    console.add_command("olife.snap_budget bytes:int near:int=24", "EntityDelta byte budget per session and tick, decimation distance",
        function(args)
            cfg.snap_budget, cfg.snap_near = args[1], args[2]
            return string.format("[olife_world] snap budget=%d near=%d", args[1], args[2])
        end)
    console.add_command("olife.move_state", "Exact predicted-movement state of every session (hash, pos, vel, ack)",
        function()
            local out = {}
            for _, s in pairs(S.sessions) do out[#out + 1] = move_auth.state_line(s) end
            table.sort(out)
            return #out > 0 and table.concat(out, "\n") or "[olife_world] move: no sessions"
        end)
    console.add_command("olife.disturb ticks:int", "olife_prediction: walls in front of predicting players every N ticks (0 off)",
        function(args) cfg.disturb = args[1]; return "[olife_world] disturb every " .. args[1] .. " ticks" end)
    console.add_command("olife.dump_inventory", "Write user:export/inventory_world.json (inventories, drops, ledger)",
        function() return inventory4c.dump("user:export/inventory_world.json") end)
    console.add_command("olife.jit", "Wave 5p: LuaJIT trace statistics (jitlog=1): aborts by function and reason, flushes",
        function() PF.dump_jit(); return PF.jit_summary(30) end)
    console.add_command("netcode", "Wave 4c counters (movement, snapshots, inventory)", function()
        return "[olife_world] netcode tick=" .. S.tick .. " " .. move_auth.status() .. " " .. snapdelta.status() ..
            " " .. inventory4c.status()
    end)
end

-- the start script asks, the first world tick (main Lua state) begins: sockets and their callbacks, commands
function M.request_begin() S.begin_requested = true end

function M.maybe_begin()
    if S.begin_requested and not S.running then
        S.begin_requested = false
        M.begin()
    end
end

function M.begin()
    PF.init(cfg)                                 -- wave 5p: profiler (prof=1) and JIT trace log (jitlog=1)
    move_auth.init(M)                            -- wave 4c (before the registry: it holds saved inventories)
    snapdelta.init(M)
    inventory4c.init(M)
    storenet.init(M)                             -- UX A4: store index (world:olife_store) before the registry
    register_commands()
    local restored = load_registry()
    if not restored then
        S.spawn.y = find_surface(floor(S.spawn.x), floor(S.spawn.z))
        for i = 1, cfg.mobs do
            local e = new_entity(2, "olife:mob", "mob" .. i, 0, {x = S.spawn.x, y = S.spawn.y + 2, z = S.spawn.z})
            e.mob = i - 1
        end
        for i = 1, cfg.scripted do
            local e = new_entity(3, "olife:scripted", "bench" .. i, 1,
                                 {x = S.spawn.x + 3 * i, y = S.spawn.y + 1, z = S.spawn.z - 3})
            e.script = "orbit"
        end
    end
    player.set_pos(S.keeper, S.spawn.x, S.spawn.y + 20, S.spawn.z)
    net.open(cfg, handlers)
    sandbox.init(cfg, M)
    editor.init(M, sandbox)
    spammer.init(M, sandbox)                     -- UX B2 (after the editor: raycast, rights, store)
    mobapi.init(M, sandbox)                      -- UX A3
    ops.init(M, editor, sandbox, cfg)            -- UX A2 (after the registry: frozen mobs / op limits back on entities)
    fraud.init(M, ops, cfg)                      -- antifraud (16.10)
    if restored then editor.after_load() end
    STORE.after_load()                           -- UX A4: drop slots of entities that are gone
    mobs.init(M, editor, sandbox)                -- UX B1: safe-position rings, last-state slots, code history (after the registry)
    if cfg.export then
        S.states = U.jsonl("user:export/world_states.jsonl")
    end
    S.running = true
    S.started_ms = now_ms()
    log("ready port=%d spawn=%.1f,%.1f,%.1f entities=%d sandbox=%s view=%d", cfg.port, S.spawn.x, S.spawn.y,
        S.spawn.z, M.entity_count(), cfg.sandbox_port > 0 and tostring(cfg.sandbox_port) or "off", cfg.view)
end

function M.entity_count()
    local n = 0
    for _ in pairs(S.ents) do n = n + 1 end
    return n
end

-- wave 5p: GC between ticks (--opts gc=tick[,gcbudget=<ms>][,gcmax=<MB>]). The automatic incremental GC ran its steps
-- (and the non-incremental atomic phase) inside whatever phase allocated — the p95/max spikes of the tick under
-- olife_sandbox_load (OLIFE_WORLD_PERF.md). Here the automatic collector is stopped and a whole cycle is run after
-- the tick, in the idle part of the 50 ms period (at most `gcbudget` ms per tick, the rest next tick), as soon as the
-- heap has grown by 1 MB or 25 % since the last cycle: small cycles that fit into one call. Tried and dropped (same
-- day, olife_w5p_*_final): a full cycle after EVERY tick — same tick times, ~1 ms of GC per tick even at 35 KB/tick
-- of garbage; letting the heap double first (setpause 200) or steps paced 1 per KB — the cycle was still running at
-- the start of many ticks, and the forced `collectgarbage("step", 200)` of the engine's Bytearray allocator (every
-- 50 MB of FFI allocations) finished it inside the tick: p95 8 ms, max 20 ms. A heap above `gcmax` MB (the steps do
-- not keep up) hands the work back to the automatic collector.
local gc_cycles, gc_est, gc_on = 0, nil, false
local function gc_after_tick()
    if cfg.gc ~= "tick" then return end
    local kb = collectgarbage("count")
    if kb > (cfg.gcmax or 512) * 1024 then
        collectgarbage("restart")
        return
    end
    if not gc_on then
        if gc_est and kb < gc_est + math.max(1024, gc_est * 0.25) then collectgarbage("stop"); return end
        gc_on = true
    end
    local t0 = now_ms()
    local budget = cfg.gcbudget or 6
    repeat
        if collectgarbage("step", 0) then
            gc_cycles, gc_on, gc_est = gc_cycles + 1, false, collectgarbage("count")
            break
        end
    until now_ms() - t0 >= budget
    collectgarbage("stop")       -- a finished cycle re-arms the automatic threshold: keep it off inside the tick
end
M.gc_cycles = function() return gc_cycles end

local function world_hash()
    local h = 0
    for _, e in pairs(S.ents) do h = add32(h, e.term or 0) end
    return h
end

function M.tick()
    if not S.running then return end
    S.tick = S.tick + 1
    local pf = PF.on
    if pf then PF.tick = S.tick; PF.tick_begin(); PF.kb() end
    local t0 = now_ms()
    net.poll(S.tick, cfg.max_frames)                              -- 1 incoming
    local ta = pf and now_ms()
    M.run_admin_queue()                                           -- queued admin actions (kick)
    local t1 = now_ms()
    if pf then PF.add("admin", t1 - ta); PF.kb("kb_in") end
    sandbox.apply(S.tick)                                         -- 2 sandbox actions of the previous tick
    local t2 = now_ms()
    if pf then PF.kb("kb_sb") end
    step_world()                                                  -- 3 world
    local te = pf and now_ms()
    editor.tick()                                                 --   + wave 4a: holds, locks, console deltas
    mobapi.tick()                                                 --   + UX A3: block fill jobs, sound queue
    ops.tick()                                                    --   + UX A2: queued operator commands, statuses
    fraud.tick()                                                  --   + antifraud: supervisor cfg/trust poll (5 s)
    storenet.tick()                                               --   + UX A4: store flush/GC, queued store commands
    spammer.tick()                                                --   + UX B2: ball ballistics, landings, queued commands
    mobs.tick()                                                   --   + UX B1: position samples, panel refresh, state file
    local t3 = now_ms()
    if pf then PF.add("w_editor", t3 - te); PF.kb("kb_world") end
    local ts, views = replicate()                                 -- 4 replication
    spammer.after_replicate()                                     --   + UX B2: ball events of this tick are out
    if pf then PF.kb("kb_repl") end
    sandbox.send_input(S.tick, S.ents)
    local t4 = now_ms()
    if pf then PF.kb("kb_si") end
    net.flush()                                                   -- 5 send
    local tn = pf and now_ms()
    sandbox.flush()
    local t5 = now_ms()
    if pf then PF.add("s_net", tn - t4); PF.add("s_sb", t5 - tn); PF.phases(t1 - t0, t2 - t1, t3 - t2, t4 - t3, t5 - t4); PF.kb("kb_send") end
    local ph = {t1 - t0, t2 - t1, t3 - t2, t4 - t3, t5 - t4}
    for i = 1, 5 do
        S.phase_ms[i] = S.phase_ms[i] + ph[i]
        if ph[i] > S.phase_max[i] then S.phase_max[i] = ph[i] end
    end
    S.tick_ms[(S.tick - 1) % 200 + 1] = t5 - t0
    local p0 = pf and now_ms()
    if S.states then
        S.states:write({tick = S.tick, ts = ts, hash = world_hash(), views = views, sessions = table.count_pairs(views)})
        S.states:flush()
    end
    local p1 = pf and now_ms()
    if cfg.journal_every > 0 and S.tick % cfg.journal_every == 0 then M.write_sup_state() end
    local p2 = pf and now_ms()
    if cfg.export then                                            -- wave 3a: sandbox meter rows (after the tick)
        S.sb_rows = S.sb_rows or U.jsonl("user:export/sandbox_ticks.jsonl")
        sandbox.meter.export(S.sb_rows, t5 - t0, ph)
    end
    local p3 = pf and now_ms()
    local c0 = gc_cycles
    gc_after_tick()
    if pf then
        local p4 = now_ms()
        PF.add("post_states", p1 - p0); PF.add("post_sup", p2 - p1); PF.add("post_rows", p3 - p2); PF.kb("kb_post")
        PF.add("post_gc", p4 - p3); PF.inc("gc_cycles", gc_cycles - c0)
        p3 = p4
        PF.tick_end(S.tick, t5 - t0, p3 - p0)
    end
    if cfg.ticks > 0 and S.tick >= cfg.ticks then S.stop = true end
end

-- ------------------------------------------------------------------------------------------ admin
local function tick_stats()
    local v = {}
    for _, x in pairs(S.tick_ms) do v[#v + 1] = x end
    table.sort(v)
    if #v == 0 then return 0, 0, 0 end
    local s = 0
    for _, x in ipairs(v) do s = s + x end
    return s / #v, v[math.max(1, math.floor(#v * 0.95))], v[#v]
end

function M.status()
    local n = 0
    for _ in pairs(S.sessions) do n = n + 1 end
    local avg, p95, mx = tick_stats()
    local up = (now_ms() - (S.started_ms or now_ms())) / 1000
    local st = net.stats
    local rej = {}
    for r, c in pairs(S.stats.block_rej) do rej[#rej + 1] = r .. ":" .. c end
    return string.format("[olife_world] status tick=%d tps=%.1f app_ticks=%d sessions=%d gateways=%d entities=%d " ..
        "cached_chunks=%d frames_in=%d bad_frames=%d bytes_in=%d bytes_out=%d chunks_sent=%d chunk_bytes=%d " ..
        "snap_bytes=%d sync_bytes=%d block_bytes=%d inputs=%d corrections=%d blocks_ok=%d blocks_rej={%s} chat=%d " ..
        "kicks=%d rehash=%d/%d tick_ms avg=%.2f p95=%.2f max=%.2f phases_avg=%s journal=%d sandbox=%s uptime=%.1f headless=%s " ..
        "scripted=%d",
        S.tick, S.tick / math.max(up, 0.001), S.app_ticks, n, net.count(), M.entity_count(), S.cache_n,
        st.frames_in, st.bad_frames, st.bytes_in, st.bytes_out, S.stats.chunks_sent, S.stats.chunk_bytes,
        S.stats.snap_bytes, S.stats.sync_bytes, S.stats.block_bytes, S.stats.inputs, S.stats.corrections,
        S.stats.block_ok, table.concat(rej, ","), S.stats.chat, S.stats.kicks, S.stats.rehash_resends,
        S.stats.rehash_checks, avg, p95, mx,
        string.format("%.2f/%.2f/%.2f/%.2f/%.2f", S.phase_ms[1] / math.max(S.tick, 1), S.phase_ms[2] / math.max(S.tick, 1),
            S.phase_ms[3] / math.max(S.tick, 1), S.phase_ms[4] / math.max(S.tick, 1), S.phase_ms[5] / math.max(S.tick, 1)),
        net.journal.total, sandbox.status(), up, tostring(vc.is_headless()), M.scripted_count()) .. " " .. editor.status() ..
        " " .. move_auth.status() .. " " .. snapdelta.status() .. " " .. inventory4c.status()    -- wave 4c
        .. " " .. storenet.status()                                                          -- UX A4
        .. " " .. spammer.status()                                                           -- UX B2
end

function M.players()
    local out = {}
    for _, s in pairs(S.sessions) do
        out[#out + 1] = string.format("[olife_world] player eid=%d name=%s account=%s session=%d gw=%d pos=%.2f,%.2f,%.2f " ..
            "chunks=%d view=%d inputs=%d bytes=%d joined=%d", s.eid, s.name, s.account, s.sid, s.gw.id, s.pos.x,
            s.pos.y, s.pos.z, s.nchunks, s.nview, s.inputs, s.bytes, s.joined)
    end
    if #out == 0 then return "[olife_world] players: none" end
    return table.concat(out, "\n")
end

-- admin commands run in the console callback (outside the tick): state changes are queued and applied in phase 1
-- (a player.delete from the callback killed the start-script coroutine: "cannot resume dead coroutine")
function M.kick_eid(eid, reason)
    if not S.by_eid[eid] then return "[olife_world] kick: no player eid=" .. tostring(eid) end
    S.admin_q = S.admin_q or {}
    S.admin_q[#S.admin_q + 1] = {op = "kick", eid = eid, reason = reason or "kicked by admin"}
    return "[olife_world] kick queued eid=" .. eid
end

-- wave 3a: queued (applied in phase 1 like kick): entities are created in the tick, not in the console callback
function M.spawn_scripted(code, owner, count, owners)
    owner, count, owners = owner or 1, count or 1, owners or 1
    if not sandbox.script_exists(code) then return "[olife_world] spawn_scripted: no script sandbox/" .. tostring(code) .. ".lua" end
    if owner < 1 or count < 1 or owners < 1 or count * owners > 2000 then
        return "[olife_world] spawn_scripted: bad numbers (owner>=1, count>=1, owners>=1, count*owners<=2000)"
    end
    S.admin_q = S.admin_q or {}
    S.admin_q[#S.admin_q + 1] = {op = "spawn_scripted", code = code, owner = owner, count = count, owners = owners}
    return string.format("[olife_world] spawn_scripted queued code=%s owner=%d count=%d owners=%d", code, owner, count, owners)
end

-- wave 4a: queued like spawn_scripted (entities are created in the tick, not in the console callback)
function M.spawn_bench(account, name, count)
    count = count or 1
    if count < 1 or count > 64 then return "[olife_world] spawn_bench: count 1..64" end
    S.admin_q = S.admin_q or {}
    S.admin_q[#S.admin_q + 1] = {op = "spawn_bench", account = account or "", name = name or "", count = count}
    -- the eids are known now (next_eid is only advanced in the tick by this queue)
    local first = S.next_eid
    return string.format("[olife_world] spawn_bench queued account=%s count=%d eids=%d..%d", account or "", count, first,
        first + count - 1)
end

-- play path: queued like spawn_bench (created in the tick)
function M.spawn_sample(account, name, code, run)
    S.admin_q = S.admin_q or {}
    S.admin_q[#S.admin_q + 1] = {op = "spawn_sample", account = account or "", name = name or "", code = code or "",
                                 run = (run or 1) ~= 0}
    return string.format("[olife_world] spawn_sample queued account=%s name=%s code=%s", tostring(account), tostring(name),
        tostring(code))
end

-- UX round 1 (dry run of the play path): a sample bench back to its file code, running — queued like spawn_sample
function M.sample_reset(account, name, slot)
    S.admin_q = S.admin_q or {}
    S.admin_q[#S.admin_q + 1] = {op = "sample_reset", account = account or "", name = name or "", slot = slot}
    return string.format("[olife_world] sample_reset queued account=%s name=%s", tostring(account), tostring(name))
end

function M.sandbox_dump()
    local n = sandbox.dump_meters("user:export/sandbox_entities.json")
    return string.format("[olife_world] sandbox_dump entities=%d tick=%d", n, S.tick)
end

function M.run_admin_queue()
    local q = S.admin_q
    if not q or #q == 0 then return end
    S.admin_q = {}
    for _, a in ipairs(q) do
        if a.op == "kick" then
            local s = S.by_eid[a.eid]
            if s then
                kick(s, 2, a.reason)
                log("kicked eid=%d", a.eid)
            end
        elseif a.op == "spawn_bench" then
            local l = editor.spawn_bench(a.account, a.name, a.count)
            log("spawned_bench account=%s eids=%s", a.account, table.concat(l, ","))
        elseif a.op == "spawn_sample" then
            local l, err = editor.spawn_sample(a.account, a.name, a.code, a.run)
            if l then
                log("spawned_sample account=%s name=%s code=%s run=%s eids=%s", a.account, a.name, a.code,
                    tostring(a.run), table.concat(l, ","))
            else
                log("spawn_sample failed: %s", tostring(err))
            end
        elseif a.op == "sample_reset" then
            local eid, err = editor.sample_reset(a.account, a.name, a.slot)
            if eid then
                log("sample_reset account=%s name=%s eid=%d", a.account, a.name, eid)
            else
                log("sample_reset failed: %s", tostring(err))
            end
        elseif a.op == "spawn_scripted" then
            S.slots = S.slots or sandbox.meter.slots(S.spawn)
            local n, loaded = 0, 0
            for o = a.owner, a.owner + a.owners - 1 do
                for i = 1, a.count do
                    S.slot_i = (S.slot_i or 0) + 1
                    local p = S.slots[(S.slot_i - 1) % #S.slots + 1]
                    local e = new_entity(3, "olife:scripted", a.code .. "_" .. o .. "_" .. i, o, p)
                    e.script = a.code
                    n = n + 1
                    if sandbox.load_entity(e) then loaded = loaded + 1 end
                end
            end
            log("spawned_scripted code=%s owners=%d..%d count=%d total=%d loaded=%d entities=%d", a.code, a.owner,
                a.owner + a.owners - 1, a.count, n, loaded, M.entity_count())
        end
    end
end

function M.journal(n)
    local out = {}
    for _, r in ipairs(net.journal:last(n or 20)) do
        out[#out + 1] = string.format("[olife_world] journal tick=%d gw=%d session=%s type=%d size=%d%s", r.tick, r.gw,
            tostring(r.session), r.type, r.size, r.err and (" err=" .. r.err) or "")
    end
    return string.format("[olife_world] journal total=%d last=%d\n", net.journal.total, #out) .. table.concat(out, "\n")
end

function M.scripted_count()
    local n = 0
    for _, e in pairs(S.ents) do if e.kind == 3 then n = n + 1 end end
    return n
end

-- stage 6: supervisor state — what the supervisor needs AFTER a crash (the ring of the last 256 incoming frames
-- with session/type/size/tick, the last sandbox TickResult summary) and for the panel/meter (players, per-account
-- actions, per-owner entities and sandbox fuel). Written every `journal_every` ticks to two alternating files
-- (<base>_a.json / <base>_b.json): a kill in the middle of a write leaves the other one intact.
function M.sup_state()
    local frames = {}
    local ring = net.journal:last(256)
    for i = #ring, 1, -1 do                      -- oldest first
        local r = ring[i]
        frames[#frames + 1] = {r.tick, r.gw, r.session or -1, r.type, r.ctype or -1, r.size, r.ms or 0, r.err}
    end
    local players = {}
    for _, s in pairs(S.sessions) do
        players[#players + 1] = {eid = s.eid, name = s.name, account = s.account, session = s.sid, gw = s.gw.id,
                                 pos = {s.pos.x, s.pos.y, s.pos.z}, chunks = s.nchunks, view = s.nview,
                                 inputs = s.inputs, actions = s.actions, bytes = s.bytes, joined = s.joined}
    end
    table.sort(players, function(a, b) return a.eid < b.eid end)
    local owners, nent, nscripted = {}, 0, 0
    for _, e in pairs(S.ents) do
        nent = nent + 1
        if e.kind == 3 then
            nscripted = nscripted + 1
            local k = tostring(e.owner or 0)
            owners[k] = (owners[k] or 0) + 1
        end
    end
    local avg, p95, mx = (function()
        local v = {}
        for _, x in pairs(S.tick_ms) do v[#v + 1] = x end
        table.sort(v)
        if #v == 0 then return 0, 0, 0 end
        local sum = 0
        for _, x in ipairs(v) do sum = sum + x end
        return sum / #v, v[math.max(1, math.floor(#v * 0.95))], v[#v]
    end)()
    return {v = 1, tick = S.tick, ms = now_ms(), seq = S.sup_writes, world = cfg.world, port = cfg.port,
            uptime_s = (now_ms() - (S.started_ms or now_ms())) / 1000, entities = nent, scripted = nscripted,
            entities_by_owner = owners, sessions = #players, players = players, acct_actions = S.acct_actions,
            tick_ms = {avg = avg, p95 = p95, max = mx}, journal_total = net.journal.total,
            journal_fields = {"tick", "gw", "session", "type", "ctype", "size", "ms", "err"}, journal = frames,
            friends_ev = perms.sup_events(),     -- UX A1: friend events -> supervisor DB
            ops = ops.sup_state(),               -- UX A2: players/mobs/bans for the panel's op buttons
            store = storenet.sup_state(),        -- UX A4: per-owner store usage/writes/credits -> supervisor DB
            spammer = spammer.sup_state(),       -- UX B2: captures/throws/landed/lost, balls in flight
            sandbox = sandbox.summary(), stats = {inputs = S.stats.inputs, corrections = S.stats.corrections,
            blocks_ok = S.stats.block_ok, chat = S.stats.chat, kicks = S.stats.kicks, bytes_in = net.stats.bytes_in,
            bytes_out = net.stats.bytes_out, bad_frames = net.stats.bad_frames}}
end

function M.write_sup_state()
    S.sup_writes = S.sup_writes + 1
    local path = "user:export/sup_state_" .. (S.sup_writes % 2 == 0 and "a" or "b") .. ".json"
    local ok, err = pcall(file.write, path, json.tostring(M.sup_state()))
    if not ok and S.sup_writes < 5 then log("supervisor state write failed: %s", tostring(err)) end
end

function M.journal_dump(path)
    if path == nil or path == "" then path = "user:export/journal_dump.json" end
    local st = M.sup_state()
    local ok, err = pcall(file.write, path, json.tostring(st))
    if not ok then return "[olife_world] journal_dump failed: " .. tostring(err) end
    return string.format("[olife_world] journal_dump path=%s frames=%d total=%d tick=%d", path, #st.journal,
        net.journal.total, S.tick)
end

-- blocks check for olife_blocks: every position the world changed and what is there now
function M.dump_blocks()
    local list = {}
    for _, p in pairs(S.modified) do
        local id = block.get(p[1], p[2], p[3])
        list[#list + 1] = {p[1], p[2], p[3], id, id >= 0 and block.get_states(p[1], p[2], p[3]) or 0}
    end
    table.sort(list, function(a, b)
        if a[1] ~= b[1] then return a[1] < b[1] end
        if a[2] ~= b[2] then return a[2] < b[2] end
        return a[3] < b[3]
    end)
    file.write("user:export/blocks_world.json", json.tostring({tick = S.tick, blocks = list}))
    return string.format("[olife_world] dump_blocks n=%d tick=%d", #list, S.tick)
end

function M.request_save() S.save_req = true; return "[olife_world] save requested at tick " .. S.tick end
function M.take_save() local r = S.save_req; S.save_req = false; return r end
function M.request_stop() S.stop = true; return "[olife_world] stopping at tick " .. S.tick end
function M.should_stop() return S.stop end
function M.get_tick() return S.tick end
function M.app_tick() S.app_ticks = S.app_ticks + 1 end

function M.finish()
    S.running = false
    collectgarbage("restart")                    -- wave 5p: gc=tick stopped the automatic collector between ticks
    for key in pairs(S.sessions) do
        local s = S.sessions[key]
        net.send(s.gw, "Detach", {session = s.sid, code = 1, reason = "world shutting down"})
    end
    net.flush()
    if S.states then S.states:close() end
    if S.sb_rows then S.sb_rows:close() end
    PF.close()
    spammer.shutdown()                           -- UX B2: balls in flight are dropped (not persisted)
    STORE.flush(true)                            -- UX A4
    mobs.flush()                                 -- UX B1
    sandbox.shutdown()
    net.shutdown()
    log("finished tick=%d", S.tick)
end

return M
